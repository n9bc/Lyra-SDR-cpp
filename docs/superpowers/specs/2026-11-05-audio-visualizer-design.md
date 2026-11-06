# Audio Visualizer — design

Status: draft for operator review (2026-11-05). Branch: `macos-port`.

## Intent

A dock that shows what the operator is hearing as a live, GPU-rendered
picture. It serves two jobs equally: a **working tool** (see the audio
spectrum and waveform while tuning, judging filter width, spotting tones)
and **something nice to look at** while listening. Four views only, done
well, with palettes, glow, echo trails and a background that blends into
Lyra's panels.

## Goals

1. One new dock, **Audio Visualizer**, showing one view at a time:
   - **25-bar** — 25-band bar analyser.
   - **FFT line** — continuous spectrum line with a soft fill under it.
   - **Scope** — oscilloscope of the audio waveform.
   - **Radial** — spectrum bars bent into a ring (spokes out from a circle).
2. **Source = what the operator hears.** On RX, the final mixed audio
   (RX1, or RX1+RX2 when both are in the mix), after RX EQ. While
   transmitting (MOX up) the dock switches to the **TX audio** — the
   post-rack mic, "what you sound like" — and switches back on unkey.
3. **Frequency span follows the RX filter**, clamped to **4 kHz minimum,
   10 kHz maximum**:
   - AM, SAM, DSB: span = the **full filter width** (`passbandHigh −
     passbandLow`), so a ±5 kHz AM filter shows 0–10 kHz. (Operator's
     explicit choice — see "Known consequence" below.)
   - Every other mode: span = the top audio edge of the filter
     (`max(|passbandLow|, |passbandHigh|)`), e.g. USB 100–2900 → 0–4 kHz
     (floor), CW at 600 Hz pitch → 0–4 kHz (floor), a 6 kHz ESSB filter → 0–6 kHz.
   - The span applies to 25-bar, FFT line and Radial. Scope is time-domain.
4. **Optional peak hold** (toggle on the dock), applied to 25-bar (peak
   caps), FFT line (a fainter peak trace) and Radial (peak dots past each
   spoke). Not applied to Scope.
5. **Nine new visualizer palettes** (not the panadapter's): Neon,
   Synthwave, Aurora, Ember, Ice, Toxic, Sunset, Phosphor, Prism. Stops as
   in the approved mockup (Appendix A).
6. **Effects:** echo/trails (previous frames fade out behind the current
   one), glow (neon bloom), background opacity (0 = transparent, drawn on
   Lyra's own panel background; 100 = solid black).
7. **Settings** in a new **Visualizer** tab of the Settings dialog:
   - Look: four **live thumbnails** (one per view), animated from the real
     audio with the current settings; clicking one selects that view.
     When no audio is flowing (radio stopped), the thumbnails run on a
     built-in demo signal so they still show the look.
   - Palette: the nine palettes as clickable swatches.
   - Effects: Echo/trails, Glow, Background opacity.
   - Speed & smoothing: Attack (rise), Decay (fall), Smoothing (temporal
     averaging), Peak hold time (+ a fixed peak fall rate after the hold).
   - Audio reactivity: Sensitivity (gain), Floor (dB). Auto-level is not
     in scope (see Non-goals).
8. **Dock bar** carries only the view picker and the Peak hold toggle,
   plus a small read-only span/source label (e.g. "0–4 kHz · RX",
   "0–4 kHz · TX"). Everything else lives in Settings.
9. Renders on the **GPU** on macOS (Metal), Linux (Vulkan/GL) and Windows
   (D3D/Vulkan) through Qt's RHI — same route as the panadapter.
10. Docs: a section in `docs/help/USER_GUIDE.md` and a "What's new" entry.

## Non-goals

- Waterfall, Galaxy, Orb (any style), Big Bang, Tunnel, Stars, Plasma, and
  orb hybrids. All explored in the mockups and **rejected by the
  operator**. Do not leave stubs or hidden code for them.
- Any link to the panadapter: no shared palettes, no "same as panadapter"
  option, no overlay on the panadapter/waterfall.
- More than one visualizer dock open at once, or split views.
- A per-receiver picker (RX1 vs RX2). It always follows what is heard.
- Auto-level / AGC on the display.
- Lens/refraction effects (only made sense for the dropped Crystal orb).
  "Glow / lens" in the operator's list is delivered as glow.
- **Remote desk clients** (operator decision). On a desk, host audio
  arrives via `DeskLink` (`src/desk_link.cpp`) and never passes through
  `dispatchAudioFrame`, and TX uses the desk's own mic. The dock there
  shows a plain notice, "Not available on a remote desk", and runs no
  analysis. Settings thumbnails on a desk run on the demo signal.
- A desktop-see-through floating window. "Transparent" means blending into
  Lyra's panel background, docked or floating.

## Anti-goals (would be a failure even if it works)

- **Any risk to the audio path.** The audio thread and TX pump thread may
  do no more than a bounded copy into a lock-free ring. No locks, no
  allocation, no FFT, no Qt signals on those threads. A stall or glitch in
  received or transmitted audio is a hard fail.
- **GPU/CPU cost when nobody is looking.** Dock hidden and Settings closed
  → no FFT, no rendering, taps reduced to one relaxed atomic read.
- CPU rendering (QML `Canvas`, `QPainter`) for the views. The mockups were
  Canvas2D only to settle the look.
- Breaking the Linux or Windows build, or depending on a graphics API
  directly (no raw Metal/GL calls).
- New third-party dependencies.

## Constraints

- Qt 6.11 (`find_package(Qt6 6.11 … ShaderTools …)` in `CMakeLists.txt`).
  Shaders go through `qt_add_shaders` like `src/shaders/glow.frag`, so one
  GLSL source compiles to SPIR-V/MSL/HLSL/GLSL.
- Local machine is macOS arm64; production also Linux and Windows.
- Repo rules (`~/.claude/CLAUDE.md`): ask before adding dependencies, keep
  the change in scope, no drive-by refactors.
- Pre-existing `scratch/` test failures (CW decoder, divext, HL2 IO board
  frames, P2 TX packets, P2 session, `test_ivac`) are not regressions.

## How it fits Lyra (facts from the code)

**RX audio.** `WdspEngine::dispatchAudioFrame(const double *audio, int
nframes)` (`src/wdsp_engine.cpp`) is the single point every *local-radio*
RX output block passes through, on the audio (AAMix outbound) thread
(remote desk clients bypass it — out of scope, see Non-goals). `audio` is
interleaved stereo doubles at `cfg_.outRate` (48 kHz): mono-dup (L==R)
with one receiver, L = RX1 / R = RX2 when `subMixActive_`. After the RX EQ
block `audio` is repointed to the EQ'd buffer; the recorder tap
(`rxRecordTap_`) sits right after that and is documented as "what you
heard". **The visualizer RX tap goes next to the recorder tap**, takes
`(L+R)/2` (equal to L in mono-dup), and is **pre-volume / pre-mute** — so
the volume knob doesn't change the picture. *(Builder's call recorded:
pre-volume.)*

**TX audio.** `WdspEngine::txMonitorTapCb(int nsamples, double *buff)`
runs on the cm_main TX pump thread on the post-rack mic (interleaved I/Q,
I=Q=mono). It currently returns early unless MON/practice is on. The
visualizer TX tap is a **separate, independent** copy into the
visualizer's TX ring, gated on MOX + visualizer active, placed before
that early return without changing the monitor logic.

**Switching RX↔TX.** Use the engine's existing MOX state (`txMuted_` is
the wire-MOX flag used by the monitor routing; `HL2Stream::moxActive` is
the GUI-side property). The analyzer reads from the TX ring while MOX is
up and from the RX ring otherwise.

**Existing analyzer pattern.** `src/dsp/EqAnalyzer.{h,cpp}` is a Qt-free,
unit-tested magnitude-FFT engine with a GUI snapshot. The visualizer core
should follow its shape (Qt-free, testable in `scratch/`), but must move
the FFT off the audio thread: the audio thread only pushes samples, the
GUI/render side pulls the latest window and transforms it. Reuse
EqAnalyzer's FFT code or FFTW (already linked for WDSP) — no new library.

**Span inputs.** `WdspEngine` exposes `mode`, `passbandLowHz`,
`passbandHighHz` (+ `modeRx2`, `passbandLowHzRx2`, `passbandHighHzRx2`)
with `NOTIFY` signals. When RX2 is in the mix, use the wider of the two
receivers' spans. *(Builder's call recorded.)* During TX the span stays at
the current RX span. *(Builder's call recorded.)*

**Docks.** QML panels register via `MainWindow::addQuickDock(objectName,
title, qmlFile, helpTopic, area, resizable)` in `src/mainwindow.cpp`
(e.g. `rxeq`, `cwdecoder`). Dock `objectName` is load-bearing for
saveState/restoreState. New dock: objectName `audiovis`, title "Audio
Visualizer", help topic `audiovis`. Default: floating + hidden, summoned
like the CW Decoder (with `FloatingDockMemory`), so existing layouts are
untouched. Hidden ⇒ the item stops updating.

**Prefs.** `lyra::ui::Prefs` (`src/prefs.h/.cpp`) is the single source of
truth, exposed to QML as the `Prefs` context property and written by the
Settings dialog. All visualizer settings become `Q_PROPERTY`s there with
`NOTIFY` signals, persisted under a `visualizer/` QSettings group.

**Settings dialog.** `src/settingsdialog.cpp` is QtWidgets with one
`buildXxxTab()` per tab. The Visuals tab is already three dense columns,
so the visualizer gets **its own "Visualizer" tab** placed after
"Visuals". The live thumbnails are hosted in a `QQuickWidget` (the dock
already uses `QQuickWidget` via `makeQuick`), each thumbnail an instance
of the same visualizer item.

## Rendering design (builder's call, recorded)

The scene-graph route the panadapter already uses, all inside Qt Quick:

- A C++ `QQuickItem` (e.g. `AudioVisItem`) that builds `QSGGeometryNode`s
  (vertex-coloured triangles/lines) for the current view in
  `updatePaintNode`. Colours come from the selected palette as a small
  LUT. Re-render paced by a `QTimer` calling `update()`, as
  `src/panadapter.cpp` does (`afterAnimating`/`frameSwapped` don't fire
  continuously inside a `QQuickWidget`); the timer runs only while the
  item is visible.
- **Glow**: a `ShaderEffect` layer like the panadapter's `glow.frag`
  (a visualizer-specific shader is fine; off when Glow = 0 → no cost).
- **Echo/trails**: a feedback pass — `ShaderEffectSource { recursive:
  true }` holding the previous output, blended under the new frame with
  a decay factor from the Echo setting (premultiplied alpha, so trails
  fade to transparent rather than to black when Background opacity is 0).
  Off when Echo = 0.
- **Background opacity**: the item clears to `rgba(0,0,0, opacity)` over
  the dock's own panel colour.
- **Rejected:** QML `Canvas` (CPU); a raw `QQuickRhiItem` render pass
  (more code and risk than this needs; revisit only if the feedback pass
  can't hit frame rate).

The data path, per frame on the GUI/render side: pull the latest N
samples from the active ring → window + FFT (size chosen so 4–10 kHz
spans look smooth; 4096 at 48 kHz ≈ 11.7 Hz bins is a reasonable start) →
map bins to the current span (25 log-spaced bands for 25-bar; ~48–64
bands for Radial; per-pixel-column for FFT line) → dB with Floor and
Sensitivity → attack/decay/smoothing → peak hold → geometry. Scope uses
the raw samples, triggered on a rising zero crossing so the trace stands
still on steady tones. *(Builder's call recorded.)*

## Look details from the approved mockup

The approved mockup is committed alongside this spec:
`docs/superpowers/specs/2026-11-05-audio-visualizer-mockup.html` (Canvas2D,
fake audio — reference for look and feel, not for implementation). Open it
in a browser; its `draw()` function is the reference for each view.

- **Colour mapping is by amplitude, for every palette (Prism included):**
  palette position t = the band's current level 0..1. Bars use a vertical
  gradient from t=0.15 at the base to t=1 at full height; spokes and the
  glow colour use t = level; peak caps/dots/trace use t = 1 (the
  palette's top stop).
- **25-bar:** 25 bands, bar width 76 % of the slot, peak cap a thin bar
  just above the held peak.
- **FFT line:** line at t=0.85 with glow, translucent gradient fill below
  (t=0.7 at 35 % alpha at top, fading to 0), peak trace thinner at 60 %
  alpha.
- **Scope:** single line at t=0.8 with glow.
- **Radial:** 48 spokes around the full circle (24 bands mirrored), inner
  radius 0.20 × min(w,h), maximum spoke length 0.28 × min(w,h), spokes
  start at 12 o'clock and the ring rotates very slowly; peak dots sit just
  beyond each spoke's held peak; a faint inner circle at 0.92 × the inner
  radius.
- **Setting semantics (mockup):** Attack and Decay are per-frame
  approach fractions (value/100 of the gap to the target, at ~60 fps);
  Smoothing is an exponential average weight on the input (value/100);
  Sensitivity is a linear gain (value/100). The builder may re-express
  these frame-rate-independently, as long as the defaults feel the same.

## Behaviour edge cases (builder's calls, recorded)

- **Muted receivers.** "What I hear" respects per-receiver mute: in SUB,
  a muted RX1 or RX2 is left out of both the picture and the span rule.
  The master volume and master mute do *not* blank the picture (pre-volume
  tap), so turning the volume down doesn't kill the display.
- **CW, TUNE and two-tone.** The dock switches to TX mic audio only when
  MOX is up in a voice or digital mode. In CW (paddle, CWX or serial), TUNE
  and two-tone, it stays on the RX tap (which is muted on the air, so the
  views settle to idle). This avoids showing room noise from the mic or
  flickering with the CW hang timer.

## Appendix A — approved palette stops

| Palette | Stops (low → high) |
|---|---|
| Neon | `#06021a` `#00e5ff` `#ff2bd6` |
| Synthwave | `#140028` `#8a2be2` `#ff3d9a` `#ffa64d` |
| Aurora | `#001a14` `#00e08a` `#00c8d6` `#a066ff` |
| Ember | `#1a0000` `#c41a00` `#ff7a00` `#ffe14d` |
| Ice | `#000a24` `#1460ff` `#5fe6ff` `#ffffff` |
| Toxic | `#001400` `#14b400` `#9cff00` `#f0ff4d` |
| Sunset | `#12003a` `#c1307a` `#ff6b4a` `#ffd166` |
| Phosphor | `#000d00` `#0f7a2a` `#33ff66` `#c8ffd8` |
| Prism | `#ff004d` `#ffb300` `#3dff5a` `#00b3ff` `#b14dff` |

## Appendix B — settings, defaults and ranges

Defaults are the values in the approved mockup.

| Setting | Range | Default |
|---|---|---|
| View | 25-bar / FFT line / Scope / Radial | Radial |
| Peak hold | on/off | on |
| Palette | 9 above | Neon |
| Echo / trails | 0–95 % | 40 |
| Glow | 0–100 | 50 |
| Background opacity | 0–100 % | 0 |
| Attack | 5–100 | 70 |
| Decay | 1–60 | 12 |
| Smoothing | 0–90 % | 30 |
| Peak hold time | 0–3000 ms | 800 |
| Sensitivity | 20–300 % | 100 |
| Floor | −120 … −40 dB | −90 |

## Known consequence the operator accepted

In AM/SAM/DSB the demodulated audio only reaches half the filter width
(±5 kHz filter → audio up to 5 kHz), so with the full-width span the upper
half of 0–10 kHz will be close to empty. The operator chose this anyway.

## Left to the builder

Class and file names, FFT size and window, band edges, exact easing
curves, thumbnail size, the demo signal's character, how the dock is
summoned (header chip and/or View menu, following the CW Decoder
pattern), and test structure — subject to the anti-goals above.

## Done looks like

- The dock shows all four views on live RX audio in every mode, with the
  span following the filter as above, and flips to TX audio while keyed.
- Settings tab works; thumbnails are live and reflect palette/effect
  changes immediately; settings persist across restarts.
- No audible change to RX or TX audio; no measurable cost while hidden.
- Builds on macOS arm64; Linux and Windows builds unaffected (shaders via
  `qt_add_shaders`, no platform-specific graphics code).
- Unit tests for the Qt-free core (ring, FFT→bands, span rule, attack/
  decay/peak) in `scratch/`, following `test_eq_analyzer.cpp`.
- `docs/help/USER_GUIDE.md` updated.
