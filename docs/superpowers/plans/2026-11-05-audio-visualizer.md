# Audio Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one "Audio Visualizer" dock that renders the audio the operator hears (RX mix, or TX mic audio while transmitting voice/digital) as 25-bar, FFT line, Scope or Radial, on the GPU, with a Visualizer settings tab that has live thumbnails.

**Architecture:** A Qt-free core (`src/dsp/AudioVis*.{h,cpp}`) holds the lock-free sample rings, FFT→band analysis, span rule, level shaping, palettes and a demo signal, and is unit-tested in `scratch/`. `WdspEngine` only pushes bounded copies into the rings (audio thread + TX pump thread). A `QQuickItem` (`AudioVisItem`) pulls frames on a `QTimer` (like `Panadapter`), shapes them, and builds scene-graph geometry; glow/echo/background are `ShaderEffect` layers in QML. The Settings tab hosts four `AudioVisItem` thumbnails in a `QQuickWidget`.

**Tech Stack:** C++17, Qt 6.11 (Quick scene graph, `qt_add_shaders`, QtWidgets for Settings), CMake. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-05-audio-visualizer-design.md` (look reference: `docs/superpowers/specs/2026-11-05-audio-visualizer-mockup.html`, its `draw()` function). Read both before starting any task.

## Global Constraints

- Four views only: **25-bar, FFT line, Scope, Radial**. No Waterfall/Galaxy/Orb/Big Bang/Tunnel/Stars/Plasma, no stubs for them.
- No link to the panadapter (no shared palettes, no overlay).
- Qt 6.11 (`find_package(Qt6 6.11 …)`), shaders via `qt_add_shaders` only; no raw Metal/GL/D3D calls; no new third-party dependencies (ask first if one seems needed).
- Audio-thread and TX-pump-thread code may only do a bounded copy into a lock-free ring: no locks, allocation, FFT, or Qt signals there. Hidden dock + closed Settings ⇒ no FFT, no rendering, taps cost one relaxed atomic load.
- No CPU rendering (QML `Canvas`/`QPainter`) for the views.
- Span: clamp to **4 kHz min, 10 kHz max**. AM/SAM/DSB = full filter width (`passbandHigh − passbandLow`); every other mode = `max(|passbandLow|, |passbandHigh|)`. With RX2 in the mix use the wider of the two receivers; a muted receiver is excluded. During TX keep the current RX span.
- Source: RX = post-RX-EQ audio, pre-volume, pre-master-mute; per-receiver mute excludes that receiver in SUB. TX audio only when MOX is up **and** mode is voice/digital (not CW, not TUNE, not two-tone).
- Remote desk clients: dock shows "Not available on a remote desk", no analysis; Settings thumbnails use the demo signal.
- Defaults/ranges: View Radial; Peak hold on; Palette Neon; Echo 0–95 (40); Glow 0–100 (50); Background opacity 0–100 (0); Attack 5–100 (70); Decay 1–60 (12); Smoothing 0–90 (30); Peak hold time 0–3000 ms (800); Sensitivity 20–300 % (100); Floor −120…−40 dB (−90).
- Palettes (stops low→high): Neon `#06021a #00e5ff #ff2bd6`; Synthwave `#140028 #8a2be2 #ff3d9a #ffa64d`; Aurora `#001a14 #00e08a #00c8d6 #a066ff`; Ember `#1a0000 #c41a00 #ff7a00 #ffe14d`; Ice `#000a24 #1460ff #5fe6ff #ffffff`; Toxic `#001400 #14b400 #9cff00 #f0ff4d`; Sunset `#12003a #c1307a #ff6b4a #ffd166`; Phosphor `#000d00 #0f7a2a #33ff66 #c8ffd8`; Prism `#ff004d #ffb300 #3dff5a #00b3ff #b14dff`. Colour is mapped by **amplitude** for every palette.
- Repo rules (`~/.claude/CLAUDE.md`): never commit unless the operator says "commit it" (the "Commit" steps below mean: stage and show the diff, then wait for the go-ahead); never push; no dependency or CI/Dockerfile changes; no drive-by refactors; match surrounding code style/comments. Pre-existing `scratch/` failures (CW decoder, divext, HL2 IO board frames, P2 TX packets, P2 session, `test_ivac`) are not regressions.
- Local machine is macOS arm64; keep Linux/Windows buildable (MSVC targets need `/utf-8 /Zc:preprocessor` like the neighbouring test targets).
- "Build" means compile and make the DMG (see `docs/MACOS_BUILD.md`).

## Review Focus

1. Radio stopped / no audio ever pushed → views show idle (levels at floor), never NaN/garbage; thumbnails fall back to the demo signal. (Task 2)
2. All-zero or DC-only audio (muted receivers, TX-muted RX on the air) → floor-level display, no `-inf` dB/NaN reaching geometry. (Tasks 1, 2)
3. Mode/filter changes mid-stream (USB→AM, filter 2.4k→10k, RX2 toggled) → span recomputes on the next frame without a crash or stale bands. (Task 1)
4. Window/dock resized very small or hidden/shown repeatedly → no zero-size geometry, timer stops when hidden and restarts when shown. (Task 5)
5. Settings out of range from a stale/corrupt QSettings file → clamped to the ranges above on load. (Task 4)

---

### Task 1: Core pure functions (span, source choice, shaping, palettes)

**Files:**
- Create: `src/dsp/AudioVisCore.h`, `src/dsp/AudioVisCore.cpp`
- Test: `scratch/test_audio_vis_core.cpp`
- Modify: `CMakeLists.txt` (add `src/dsp/AudioVisCore.{h,cpp}` to the `lyra` sources next to `EqAnalyzer`, and a `test_audio_vis_core` target like `test_eq_analyzer`: `EXCLUDE_FROM_ALL`, `target_include_directories(... src)`, MSVC flags)

**Interfaces:**
- Produces (namespace `lyra::dsp::vis`):
  - `double spanHz(std::string_view mode, double lowHz, double highHz) noexcept;` → span in Hz clamped to 4000–10000
  - `double combinedSpanHz(double rx1Span, bool rx1Audible, double rx2Span, bool rx2Open, bool rx2Audible) noexcept;` (wider of audible receivers; if none audible returns 4000)
  - `float mixSample(float l, float r, bool sub, bool muteRx1, bool muteRx2) noexcept` (mono-dup: `l`; SUB: mean of audible channels; none audible → 0)
  - `bool useTxSource(bool mox, std::string_view mode, bool tuneOrTwoTone) noexcept` (true only for voice/digital modes: USB LSB AM SAM DSB FM DIGU DIGL)
  - `struct Settings { int attack=70, decay=12, smoothing=30, peakHoldMs=800, sensitivity=100; float floorDb=-90.f; }`
  - `struct Shaper { void reset(int n); void step(const float *targets, float dtSec, const Settings &s); std::vector<float> level, peak; }` — `targets` are 0..1 normalised; `level` applies smoothing + attack/decay (per-frame fractions at 60 fps, made frame-rate independent via `1-(1-f)^(dt*60)`); `peak` holds for `peakHoldMs` then falls at 0.5/s.
  - `float dbToUnit(float db, float floorDb, int sensitivityPct) noexcept` (`(db − floor)/(0 − floor)` scaled by sensitivity/100, clamped 0..1; NaN/−inf → 0)
  - `constexpr int kPaletteCount = 9; const char *paletteName(int i); void paletteColor(int palette, float t, uint8_t rgb[3]);` (linear interpolation across the stops in Global Constraints; `t` clamped)

- [ ] **Step 1: Write failing tests** in `scratch/test_audio_vis_core.cpp` (plain `main()` with an `expect` helper like `test_eq_analyzer.cpp`): `spanHz("USB",100,2900)==4000`; `spanHz("USB",100,6000)==6000`; `spanHz("AM",-5000,5000)==10000`; `spanHz("AM",-8000,8000)==10000` (cap); `spanHz("CWU",300,900)==4000`; `spanHz("LSB",-2900,-100)==4000`; `combinedSpanHz(4000,true,10000,true,false)==4000` (muted RX2 ignored); `mixSample(0.5,0.1,false,…)==0.5`; `mixSample(0.5,0.1,true,true,false)==0.1`; `useTxSource(true,"USB",false)`, `!useTxSource(true,"CWU",false)`, `!useTxSource(true,"USB",true)`, `!useTxSource(false,"USB",false)`; `dbToUnit(-90,-90,100)==0`, `dbToUnit(0,-90,100)==1`, `dbToUnit(-INFINITY,-90,100)==0`, `dbToUnit(NAN,…)==0`; Shaper: stepping a constant target 1.0 from 0 with attack 70 reaches >0.9 in ≤10 frames at dt=1/60 and the same elapsed time at dt=1/30 gives the same level ±0.02; with decay 12 a drop to 0 falls slowly (>0.5 left after 5 frames); peak stays at 1.0 for `peakHoldMs` then falls; `paletteColor(0 /*Neon*/,0)` = `06021a`, `paletteColor(0,1)` = `ff2bd6`, `paletteColor(8 /*Prism*/,0)` = `ff004d`.
- [ ] **Step 2: Run to verify failure:** `cmake --build build --target test_audio_vis_core` → fails to compile (no header).
- [ ] **Step 3: Implement** `AudioVisCore.{h,cpp}` per the Interfaces block. Mode strings are the engine's (`USB/LSB/CWU/CWL/DSB/AM/SAM/FM/DIGU/DIGL`); treat AM, SAM, DSB as full-width.
- [ ] **Step 4: Run** `cmake --build build --target test_audio_vis_core && ./build/test_audio_vis_core` → all expectations pass, exit 0.
- [ ] **Step 5: Commit** (stage `src/dsp/AudioVisCore.*`, `scratch/test_audio_vis_core.cpp`, `CMakeLists.txt`; wait for "commit it"). Message: `feat(vis): audio visualizer core (span, source choice, shaping, palettes)`.

### Task 2: Rings, FFT analysis, hub, demo signal

**Files:**
- Create: `src/dsp/AudioVisHub.h`, `src/dsp/AudioVisHub.cpp`
- Test: `scratch/test_audio_vis_hub.cpp`
- Modify: `CMakeLists.txt` (sources + `test_audio_vis_hub` target; the target also compiles `AudioVisCore.cpp`)

**Interfaces:**
- Consumes: Task 1 `Settings` is not needed here; uses `spanHz` outputs passed in.
- Produces (namespace `lyra::dsp::vis`):
  - `struct Frame { float lineDb[256]; float bandsDb25[25]; float bandsDbRadial[24]; float scope[512]; double spanHz; bool tx; bool live; }` — dB values, `-200` = silence; `live=false` when no samples arrived recently.
  - `class AudioVisHub { public: static AudioVisHub &instance(); void acquire(); void release(); bool active() const noexcept; void pushRx(const double *interleavedLR, int nframes, bool sub, bool muteRx1, bool muteRx2) noexcept; void pushTx(const double *mono, int n) noexcept; void setSource(bool tx) noexcept; bool frame(double spanHz, Frame &out); };`
    - `acquire/release` ref-count consumers (atomic int); `active()` = count > 0; `pushRx`/`pushTx` return immediately when `!active()`.
    - `pushRx` mixes with `mixSample` and pushes mono floats into an SPSC ring (reuse `lyra::dsp::MonitorRing` from `src/dsp/MonitorRing.h`, producer = audio thread, consumer = GUI thread); `pushTx` likewise into a second ring.
    - `frame()` (GUI thread only) drains the ring chosen by `setSource` into a 4096-sample sliding window, Hann window + radix-2 FFT (reuse `EqAnalyzer`'s FFT if reachable without editing it, else a private radix-2 in the .cpp), maps bins to `spanHz` (log-spaced bands for 25-bar and Radial, 256 linear points for the line), `scope` = the latest 512 samples starting at the last rising zero-crossing in the window. Returns false if the hub is inactive.
  - `class DemoSignal { public: void fill(float *dst, int n, double fs); };` voice-like formant signal (any sensible synthesis), used by the Item when `frame().live==false`.

- [ ] **Step 1: Write failing tests** in `scratch/test_audio_vis_hub.cpp`: (a) with `acquire()`, push 8192 samples of a 1 kHz sine at amplitude 0.5 via `pushRx` (mono-dup, 48 kHz), `setSource(false)`, `frame(4000, f)` → the FFT-line peak index maps to 1000 Hz ±50 Hz and its dB is within 3 dB of the expected value for amplitude 0.5; (b) with no `acquire()`, `pushRx` leaves `frame()` returning false and the ring untouched; (c) all-zero input → every `lineDb`/`bandsDb*` value is finite and ≤ −100 (Review Focus 2); (d) never pushed → `frame()` returns true with `live=false` and finite values (Review Focus 1); (e) `setSource(true)` reads only `pushTx` samples (push a 2 kHz tone via `pushTx` and a 1 kHz tone via `pushRx`, expect 2 kHz); (f) `spanHz=10000` moves the 1 kHz peak to a lower line index than at 4000; (g) the rising-zero-crossing trigger: a 200 Hz sine's `scope[0]` is within 0.05 of 0 and `scope[1] > scope[0]`.
- [ ] **Step 2: Run** `cmake --build build --target test_audio_vis_hub` → fails (missing header).
- [ ] **Step 3: Implement** `AudioVisHub` per Interfaces (no allocation in `pushRx`/`pushTx`; ring capacity 16384 floats/doubles; overflow drops newest per `MonitorRing`). `live` = samples consumed within the last 250 ms of wall clock.
- [ ] **Step 4: Run** `./build/test_audio_vis_hub` → all pass.
- [ ] **Step 5: Commit** (wait for "commit it"): `feat(vis): lock-free sample rings, FFT analysis hub, demo signal`.

### Task 3: Engine taps

**Files:**
- Modify: `src/wdsp_engine.cpp` (`dispatchAudioFrame` next to the `rxRecordTap_` block ~line 5799; `txMonitorTapCb` ~line 5195), `src/wdsp_engine.h` (new setters), `src/mainwindow.cpp` or `src/main.cpp` (wire mode/filter/MOX changes into the hub's source/span inputs)
- Test: build + `scratch/test_audio_vis_core.cpp` already covers the pure rules; add one more case there for the exact tap helper if one is extracted.

**Interfaces:**
- Consumes: `AudioVisHub::instance()`, `pushRx`, `pushTx`, `setSource` (Task 2); `useTxSource`, `combinedSpanHz`, `spanHz` (Task 1).
- Produces: `WdspEngine::visSpanHz() const` (thread: GUI; combines `mode`/`passbandLowHz`/`passbandHighHz` and the RX2 equivalents, excludes muted receivers via `muted_`/`mutedRx2_`) and `WdspEngine::visUsesTx() const` (GUI; MOX from the engine's existing MOX flag + `mode()` + tune/two-tone flags). Both are called by the Item (Task 5), not on the audio thread.

- [ ] **Step 1:** In `dispatchAudioFrame`, immediately after the `rxRecordTap_` block, add one call: `lyra::dsp::vis::AudioVisHub::instance().pushRx(audio, nframes, subMix, muted_.load(relaxed), mutedRx2_.load(relaxed));` — `audio` there is already post-EQ and pre-volume. **Check** that per-receiver mute flags are the ones used later in the same function (`muted_` is RX1/master manual mute — if `muted_` is the master mute, pass `false` for RX1 and only pass the RX2 mute; confirm by reading the SUB branch in the output loop and note the finding in a code comment).
- [ ] **Step 2:** In `txMonitorTapCb`, call `AudioVisHub::instance().pushTx(mono, nsamples)` **before** the `route.fillTap` early return, with `mono` extracted into the stack scratch exactly as the existing code does (restructure so the copy loop runs once for both uses; keep the monitor behaviour byte-identical).
- [ ] **Step 3:** Add `visSpanHz()` and `visUsesTx()` to `WdspEngine` (declare near `setCoachTaps` docs; GUI-thread-only, document that).
- [ ] **Step 4:** Build: `cmake --build build --target lyra` → compiles clean. Run `./build/test_audio_vis_core` and `./build/test_audio_vis_hub` → still pass.
- [ ] **Step 5:** Manual audio-safety check: launch the app against the radio (or the existing demo/stub path), confirm RX audio is unchanged with the hub inactive (default) — the taps must be a no-op until a consumer acquires. Record what was and wasn't verified.
- [ ] **Step 6: Commit** (wait for "commit it"): `feat(vis): tap RX mix and TX mic audio into the visualizer hub`.

### Task 4: Prefs

**Files:**
- Modify: `src/prefs.h`, `src/prefs.cpp`

**Interfaces:**
- Produces on `lyra::ui::Prefs` (each `Q_PROPERTY` with `READ/WRITE/NOTIFY`, persisted under QSettings keys `visualizer/<name>`, clamped on load and set, pattern of `setGlow`): `int visView` (0=25-bar,1=FFT line,2=Scope,3=Radial; default 3), `bool visPeakHold` (true), `int visPalette` (0–8; 0), `int visEcho` (0–95; 40), `int visGlow` (0–100; 50), `int visBgOpacity` (0–100; 0), `int visAttack` (5–100; 70), `int visDecay` (1–60; 12), `int visSmoothing` (0–90; 30), `int visPeakHoldMs` (0–3000; 800), `int visSensitivity` (20–300; 100), `int visFloorDb` (−120…−40; −90). Notify signals `visViewChanged()` etc.

- [ ] **Step 1: Write a failing test** `scratch/test_prefs_visualizer.cpp` (new `test_prefs_visualizer` target, links Qt6::Core + `src/prefs.cpp` only if `Prefs` can be built standalone; if not, state that and instead verify with a temporary `QSettings` org/app in a tiny `QCoreApplication` program using the real `Prefs`): defaults match the Global Constraints; setting `visEcho=500` stores 95; setting `visFloorDb=-10` stores −40; a pre-seeded out-of-range `visualizer/visDecay=999` loads as 60 (Review Focus 5).
- [ ] **Step 2: Run** the target → fails.
- [ ] **Step 3: Implement** the twelve properties following the `glow` pattern (key constants near `kGlow`, load in the ctor block at `prefs.cpp:298`, setters at ~`1021`).
- [ ] **Step 4: Run** the test → passes; `cmake --build build --target lyra` compiles.
- [ ] **Step 5: Commit** (wait): `feat(vis): visualizer preferences`.

### Task 5: AudioVisItem — four views on the GPU

**Files:**
- Create: `src/audiovisitem.h`, `src/audiovisitem.cpp`
- Modify: `CMakeLists.txt` (sources), `src/main.cpp:1150` (`qmlRegisterType<lyra::ui::AudioVisItem>("LyraUI", 1, 0, "AudioVisItem");`)

**Interfaces:**
- Consumes: `AudioVisHub` (`acquire/release/frame`), `DemoSignal`, `Shaper`, `Settings`, `dbToUnit`, `paletteColor` (Tasks 1–2); `WdspEngine::visSpanHz()/visUsesTx()` (Task 3); `Prefs` vis properties (Task 4).
- Produces: QML type `AudioVisItem : QQuickItem` with properties `int view` (0–3), `bool peakHold`, `int palette`, `bool demo` (force demo signal; true for desk and thumbnails with no live audio), and `QObject *prefsSource` (the `Prefs` to read settings from; null ⇒ item uses its own property values so thumbnails can be overridden); read-only `QString statusText` ("0–4 kHz · RX" / "· TX") with `statusTextChanged`. Echo, glow and background opacity are **not** handled here (Task 6).

- [ ] **Step 1: Write failing test** `scratch/test_audio_vis_geometry.cpp` (Qt-free) only for the pure layout helpers you extract into `AudioVisCore` (e.g. `radialSpokeEnds(level, peak, n, w, h, rotation)` and `barRects(...)`), asserting: Radial has 48 spokes, inner radius 0.20·min(w,h), max length 0.28·min(w,h), spoke k=0 starts at 12 o'clock; 25-bar has 25 rects each 76 % of the slot width. If you extract no helpers, skip this step and say so.
- [ ] **Step 2:** Implement `AudioVisItem`: `acquire()` when `isVisible()` and the window exists, `release()` when hidden/destroyed; `QTimer` at 60 fps calls `update()` (stop it when hidden — Review Focus 4); `updatePaintNode` builds `QSGGeometryNode`s with per-vertex colour (`QSGGeometry::ColoredPoint2D`, `QSGVertexColorMaterial`, **alpha premultiplied** because echo/transparency need it) for the active view following the "Look details" section of the spec: 25-bar bars + peak caps; FFT line as a triangle strip line + translucent gradient fill + thinner peak trace; Scope line; Radial 48 spokes + peak dots + faint inner circle, ring rotating slowly. Guard width/height < 8 px by emitting no geometry.
- [ ] **Step 3:** `frame()` input: span from `WdspEngine::visSpanHz()`; `setSource(visUsesTx())` each tick; if `frame.live` is false or `demo` is true feed `DemoSignal` through the same path instead. Normalise with `dbToUnit`, run `Shaper::step`, peaks only drawn when `peakHold`. Skip all of it for the Scope view's spectrum work (it only needs `scope[]`).
- [ ] **Step 4:** Build `lyra`; open a temporary QML test window or the existing QML preview path with `AudioVisItem { view: 3 }` and verify on macOS (Metal) that all four views draw and animate on the demo signal; log "Using QRhi with backend Metal" is present. Remove any temporary harness.
- [ ] **Step 5: Commit** (wait): `feat(vis): AudioVisItem scene-graph item with four views`.

### Task 6: Effects layer and AudioVisPanel.qml

**Files:**
- Create: `src/shaders/audiovis_glow.frag`, `src/qml/AudioVisPanel.qml`
- Modify: `CMakeLists.txt` (`qt_add_shaders` FILES list near `glow.frag`; QML resource list near `CwDecoderPanel.qml:642`)

**Interfaces:**
- Consumes: `AudioVisItem` (Task 5), `Prefs.vis*` (Task 4).
- Produces: `AudioVisPanel.qml` — root item with a top bar (view `ComboBox`/`LyraComboBox` bound to `Prefs.visView`, a Peak hold toggle bound to `Prefs.visPeakHold`, and a read-only status label bound to `item.statusText`), and below it a `Item` containing: background `Rectangle` (`color: Qt.rgba(0,0,0, Prefs.visBgOpacity/100)`), the `AudioVisItem` inside a `ShaderEffectSource { recursive: true }` for echo (feedback blended under the new frame with decay = `Prefs.visEcho/100`, premultiplied; disabled when echo is 0), and a glow `ShaderEffect` using `audiovis_glow.frag` (disabled/`visible:false` when `Prefs.visGlow == 0`). Also a reusable component file `AudioVisCanvas.qml` (the stack below the bar) that Task 8's thumbnails reuse with explicit property overrides.

- [ ] **Step 1:** Write `audiovis_glow.frag` (GLSL 440, Qt 6 `layout(binding=1) uniform sampler2D source` + `qt_Matrix` block, same conventions as `src/shaders/glow.frag`; blur-radius uniform from the Glow setting) and add it to `qt_add_shaders`.
- [ ] **Step 2:** Build `lyra` → shader compiles to SPIR-V/MSL/HLSL (watch the qsb output for errors on all targets).
- [ ] **Step 3:** Implement `AudioVisCanvas.qml` + `AudioVisPanel.qml` as described; follow `CwDecoderPanel.qml` / `RxEqPanel.qml` for fonts, colours, `Prefs` access and sizing.
- [ ] **Step 4:** Verify visually (in the dock once Task 7 lands, or a temporary window now): echo trails fade to transparent (not black) with background opacity 0; glow 0 and echo 0 each remove their layer; background opacity 100 is solid black; ensure trails don't ghost forever (echo 95 decays within ~1–2 s when audio stops).
- [ ] **Step 5: Commit** (wait): `feat(vis): visualizer panel with glow, echo and background effects`.

### Task 7: Dock, chip, help topic, desk notice

**Files:**
- Modify: `src/mainwindow.cpp` (dock near `cwdecoder` ~3351; chip near ~4911; the option-rack list at ~304 and ~4948 if the chip belongs in the Options rack), `src/helpdialog.cpp` (~69 topic), `CMakeLists.txt` only if a new file is needed
- Possibly modify: `src/qml/AudioVisPanel.qml` (desk notice)

**Interfaces:**
- Consumes: `AudioVisPanel.qml` (Task 6). Produces: dock objectName `audiovis` (floating, hidden by default, with `FloatingDockMemory` key `ui/audioVisDock`), toolbar chip "Visualizer" (same `txDspChip` styling as "CW Dec").

- [ ] **Step 1:** Register `addQuickDock(QStringLiteral("audiovis"), tr("Audio Visualizer"), QStringLiteral("AudioVisPanel.qml"), QStringLiteral("audiovis"), Qt::BottomDockWidgetArea, /*resizable=*/true);` and the floating/hidden + `FloatingDockMemory` block exactly like `cwdecoder`.
- [ ] **Step 2:** Add the launcher chip alongside "CW Dec" (and add `audiovis` to the grouped rack list only if the existing chips are grouped the same way — follow what `cwdecoder` does in both modes).
- [ ] **Step 3:** Add a help topic `audiovis` in `helpdialog.cpp` mirroring the `cwdecoder` entry (text pointing at the User Guide section from Task 9).
- [ ] **Step 4:** Desk notice: find how the app knows it is a remote desk client (`src/desk_link.cpp` / `desk_session.h` role flag; grep `DeskLink` usage in `main.cpp`/`mainwindow.cpp`); expose it to the panel (existing context property if present, else a new read-only property on an existing context object) and have `AudioVisPanel.qml` show a centered "Not available on a remote desk" label instead of the canvas, with `AudioVisItem` never `acquire()`d.
- [ ] **Step 5:** Verify: launch, click the chip → dock appears (floating), view picker switches views, Peak hold toggles, dock hides → timer stops (`AudioVisHub::active()` false: temporarily log or assert in a debug build), re-show resumes; close/reopen the app → dock geometry restored; saved layouts from before the change still restore.
- [ ] **Step 6: Commit** (wait): `feat(vis): Audio Visualizer dock and launcher chip`.

### Task 8: Settings → Visualizer tab with live thumbnails

**Files:**
- Modify: `src/settingsdialog.cpp` (new `buildVisualizerTab()`; add after the Visuals tab at ~381 via `tabs_->addTab(wrapScroll(buildVisualizerTab()), tr("Visualizer"))`), `src/settingsdialog.h`
- Create: `src/qml/AudioVisThumb.qml` (a thin wrapper over `AudioVisCanvas` with fixed `view`, `prefsSource: Prefs`, `demo` falling back automatically when no live audio)

**Interfaces:**
- Consumes: `AudioVisCanvas.qml` (Task 6), `Prefs.vis*` (Task 4), `paletteName/paletteColor` for swatches (build swatch gradients from the same stops, via a small `Q_INVOKABLE` on a QObject exposed to the widget side, or compute colours in QML).

- [ ] **Step 1:** Build the tab with QtWidgets groups matching the neighbours: **Look** (a `QQuickWidget` row of four `AudioVisThumb` items, click selects `Prefs.visView`, selected one outlined), **Palette** (nine clickable swatches with the palette name, selecting `Prefs.visPalette`), **Effects** (Echo/trails, Glow, Background opacity sliders), **Speed & smoothing** (Attack, Decay, Smoothing, Peak hold time), **Audio reactivity** (Sensitivity, Floor dB). Each slider shows its value and is bound two-way to `Prefs` (use the same slider+label helper style as the Visuals tab).
- [ ] **Step 2:** Thumbnails consume the same `AudioVisHub` (one `acquire()` per thumbnail while the tab is visible; released on tab change/close so the hub goes inactive and costs nothing — Review Focus 4). With the radio stopped or on a desk they run on `DemoSignal`.
- [ ] **Step 3:** Verify: open Settings → Visualizer; thumbnails animate; changing palette/echo/glow updates thumbnails and the dock instantly; values persist across restart; closing Settings drops hub consumers back to the dock's count.
- [ ] **Step 4: Commit** (wait): `feat(vis): Visualizer settings tab with live thumbnails`.

### Task 9: User Guide, What's new, final verification

**Files:**
- Modify: `docs/help/USER_GUIDE.md` (a "Audio Visualizer" section plus an entry in the Contents list ~714 and a "What's new" bullet in the current-build block at the top; do not bump the version number)

- [ ] **Step 1:** Write the User Guide section: what it shows (RX mix / TX audio while transmitting voice), the four views, span rule (incl. the AM 0–10 kHz note that the upper half is mostly empty), peak hold, palettes/effects/speed/reactivity settings, the Settings → Visualizer tab and live thumbnails, the "Visualizer" chip, and that it's unavailable on a remote desk. Match the guide's existing tone and heading style.
- [ ] **Step 2:** Full checks: `cmake --build build --target test_audio_vis_core test_audio_vis_hub` and run both; build `lyra` clean on macOS arm64 (report warnings you introduced); run the existing `test_eq_analyzer` and `test_parameq` to confirm no regression; confirm Linux/Windows buildability by inspection (no platform-specific graphics code, MSVC flags on new test targets, new sources listed in the shared source list).
- [ ] **Step 3:** Run an end-to-end pass on the Mac: RX in USB (span 4 kHz), AM (span 10 kHz), and a ±5 kHz filter; toggle RX2/SUB and mute each receiver; key MOX in USB (dock flips to "· TX") and in CW/TUNE (stays on RX); stop the radio (demo/idle, no garbage). Record exactly what was run versus what could not be (no radio ⇒ say so).
- [ ] **Step 4:** Build the DMG per `docs/MACOS_BUILD.md` ("build" means build + DMG).
- [ ] **Step 5: Commit** (wait): `docs: Audio Visualizer user guide section`.
