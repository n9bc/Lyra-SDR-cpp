# eSSB Coach panel — design

Date: 2026-10-26 · Status: draft for approval · Phase 1 of 2 (phase 2 = AI suggestions)

## Why

The operator (N9BC) coaches other hams on the air toward good eSSB audio.
Most of them run Lyra, though not all. In a session the two operators talk
for a couple of minutes to get a baseline. N9BC reads an RTA ("lots of
energy around 80 Hz, not much at 2 kHz") and tells the other operator what to
change in Lyra's TX EQ, Noise Gate, Auto-AGC or Combinator, or in their own
EQ and compressor. The other operator changes it, they talk again, and they
compare.

The existing RX EQ Spec/RTA view is not built for this. It runs a short,
ungated average with no level reference, no target, no tolerance, no
bandwidth reading and no compression measurement.

Success: N9BC can open one panel, take a baseline, and get trustworthy
advice in Lyra's own terms. Then, after each change, he can see what moved
compared with the baseline.

## Goals

- A new, separate **eSSB Coach** panel that measures the received audio of
  the station being coached.
- **Tonal balance**, measured against a target curve and given as
  plain, hedged advice.
- **Occupied bandwidth**: the station's low and high edges, and which tier
  that puts it in.
- **Compression problems** that N9BC actually hears: pumping, and background
  noise pulled up between words. Also over-squashed audio.
- **Splatter**: energy just outside the channel.
- A **baseline → change → compare** workflow.
- Advice in **Lyra terms** by default, with a generic mode for other rigs.
- A **measurement report** with a stable, documented structure, so phase 2
  (AI suggestions) can consume it directly. Phase 2 starts as soon as this
  panel works.

## Non-goals

- **Any change to the RX EQ**: `EqModel`, `EqPanel.qml`, `EqAnalyzer` and
  the RX EQ path in `WdspEngine`. The user said so explicitly. The coach
  may *read* audio from the same point; it does not alter what the RX EQ
  receives, processes or displays.
- Changing the other station's settings remotely, or ever applying settings
  automatically.
- Phase 2 (AI suggestions) beyond the report format and the
  record-a-session hook. It gets its own design.
- **Remote desk mode** (`desk_link` / `desk_session`). The user will not
  coach from a desk client. The coach runs only on the machine connected to
  the radio; in desk mode the panel says it is unavailable.

## Anti-goals (a failure even if it "works")

My call, inferred from the conversation; the user hasn't confirmed these.

- Advice caused by **our own receiver** (narrow RX filter, NR/ANF, AGC) and
  blamed on the other station. The RX EQ can't cause this: the coach taps
  before it.
- **Hiss or band noise** read as "too much high end" on weak signals.
- Advice that **flickers** or changes from one sentence to the next.
- **False precision**, e.g. "cut 3.7 dB at 247 Hz" from a fading HF signal.

## Constraints

- C++23 / Qt 6 / QML. It must build and run on macOS arm64 and Linux.
- Audio is 48 kHz, demodulated RX audio from `WdspEngine`.
- Audio-thread rules match the existing code (`EqAnalyzer`):
  - no allocation on the audio thread;
  - only a short mutex for publishing;
  - FFT math outside the lock;
  - the GUI thread polls snapshots at about 25 Hz.
- New DSP classes are Qt-free so they can be unit-tested standalone (like
  `EqAnalyzer`, `FreqCalMeasure`).
- Follow the existing panel pattern: a dock with an objectName, a header
  chip, floating/docking and saved layouts. Add the panel to
  `kChipSummonedPanels` and to the Options rack member list in grouped mode.
- Styling follows the existing panels. The lit/"on" colour is `#ff9a3c` on
  fill `#3a2a14`, the Audio panel's Auto button.

## Where it taps audio

Add a **new read-only tap** in `WdspEngine`'s RX audio path, immediately
**before** the RX EQ block (`src/wdsp_engine.cpp`, the
`rxEq_.load(...)` block around line 5351).

- It copies RX1's demodulated audio into the coach's analyzer through its
  own atomic pointer, set the same way `setRxEqEngine` sets the RX EQ's.
- A null pointer (coach panel closed) costs one atomic load.
- This is the only change to the audio chain, and it does not touch the RX
  EQ's code path.

The coach also needs the **RX1 IQ** stream for the splatter measurement (see
below). The builder taps it wherever the panadapter's IQ is available,
read-only, by the same pattern.

The coach measures **RX1 only** in phase 1 (my call).

## Measurement engine (new class, e.g. `lyra::dsp::CoachAnalyzer`)

### Frames and bands

- 4096-point FFT at 48 kHz (11.7 Hz bins), Hann window, 50% overlap.
- Bins fold into **1/6-octave bands** from 40 Hz up to the RX filter's
  upper edge.
- The builder may decimate first if that is cleaner; the band output is
  what matters.

### Speech gate

- A frame counts as speech when its in-band energy is sufficiently above an
  adaptive noise floor, with a hangover so word endings aren't cut.
- Only speech frames feed the tonal and bandwidth measurements.
- The builder tunes the thresholds, and must document them and test them
  (see Tests).

### Noise floor

- Band power is tracked during the gaps between words.
- It is subtracted, as power, from the speech average.
- SNR is reported per band and overall.

### Averages

- **Live trace:** about 0.3 s, for the display only.
- **Baseline average:** integrates gated speech from **Start** until
  **Stop**. A baseline is typically a couple of minutes. It is not a fixed
  time constant.
- **Re-check average:** a fresh average started after a change. It
  integrates until the next Stop or Reset.

### Normalisation

Every curve is shifted so the mean of **500 Hz–2 kHz is 0 dB**. All
comparisons use shape only, never absolute level.

### Confidence

- Reported as seconds of gated speech plus median in-band SNR.
- Below **8 s of speech** or **15 dB SNR**, the panel shows why instead of
  giving advice. These are defaults that can be changed in Settings.

### Edges (occupied bandwidth)

- **Low edge:** the lowest frequency where the curve stays within 20 dB of
  the mids.
- **High edge:** the highest such frequency.
- Each edge is reported only when it is inside our RX passband by at least
  150 Hz. Otherwise it reads "beyond your RX filter".

### Compression metrics (from the gated envelope)

- **Gap-to-speech ratio:** median level in the pauses compared with median
  level of speech. A small ratio means background noise is being pulled up.
- **Gap rise (pumping):** the slope of the pause level over the first
  ~150–800 ms after speech stops. If the pause level climbs back, that is
  compressor release pumping.
- **Crest factor:** how far peaks rise above the average. Very low means
  over-squashed.
- Thresholds are defaults chosen by the builder, documented, and editable in
  Settings.

### Our own AGC (user decision: correct for it)

The tap sits after our receiver's AGC. AGC raises the noise between words
and swells back after each word, which would otherwise read as the *other*
station's pumping and noise.

- The **user chose to correct for it**, so AGC can stay on while coaching.
- The coach reads our AGC gain alongside each audio block, on the audio
  thread, and removes it from the envelope before computing gap-to-speech,
  gap rise and crest factor.
- `WdspEngine::agcGainDb()` exists but is a GUI-rate meter property, which
  is probably too coarse. The builder must find a per-block gain reading
  from WDSP's RXA AGC stage. It needs to be time-aligned with the tapped
  audio to within one block.
- The tonal measurement also uses the corrected envelope for its speech
  gate. Spectral shape within a frame is not affected by AGC.
- **Fallback (my call, user not asked):** if no per-block gain is available
  with that alignment, the coach holds back compression advice. It then
  shows "Set AGC to Off/Fixed for compression readings" until AGC is off or
  fixed. Tonal and bandwidth advice still run.
- Test: a synthetic steady-noise-plus-bursts signal passed through a
  simulated AGC whose gain is fed to the coach must NOT trigger the pumping
  or background-noise flags.

### Receive-path conditions

Each snapshot reports:

- the RX filter edges;
- whether NR or ANF is on (both act before the tap; the RX EQ acts after it
  and is irrelevant);
- the AGC mode.

The panel uses these to warn (see Advice).

### Splatter (IQ, not audio)

Demodulated audio can't show energy beyond our own RX filter, so this check
uses the IQ data.

- It compares the energy in a window just outside the station's channel
  (default 0.5–3 kHz past the channel edge) with the in-channel peak, at
  equal bandwidth.
- It alerts when the out-of-channel energy is within **35 dB** of the
  in-channel peak (dB relative to the peak, not dBFS).
- The channel edge defaults to the target tier's high edge.
- The panel says this reading needs a quiet adjacent frequency.

## Targets

A target is **data**: (Hz, dB) points relative to the 500 Hz–2 kHz mids,
interpolated on a log-frequency axis, plus low and high edges and
tolerances.

- Targets are stored in QSettings.
- Presets ship in the app; user presets can be added.

### Shipped presets

The first one is the default.

| Preset | Low edge | High edge | Shape | Tolerance |
|---|---|---|---|---|
| **eSSB (flat, slight bump)** | 50 Hz | 6.0 kHz | +3 dB at 70–150 Hz, flat 0 dB to the high edge | ±5 dB below 150 Hz, ±3 dB above |
| Mid-fi SSB | 100 Hz | 4.0 kHz | flat | ±3 dB |
| Typical SSB | 300 Hz | 2.7 kHz | flat | ±3 dB |
| AM broadcast | 50 Hz | 9 kHz | flat | ±3 dB |

- The user said the eSSB goal is "a fairly flat curve, with maybe a slight
  bump on the low end".
- The +3 dB amount and the 6 kHz edge are **my calls**: the 6 kHz edge comes
  from NU9N's eSSB chart. Both are editable.
- The other tiers' edges come from NU9N's comparison chart, as the user
  supplied it.

**Capture as target:** saves the current baseline curve, with its measured
edges, as a user preset.

### Zones for advice

Defaults, all editable:

| Zone | Range |
|---|---|
| Bass | 60–150 Hz |
| Low-mid ("mud") | 150–600 Hz |
| Body | 600 Hz–2 kHz |
| Upper | 2–3.5 kHz |
| Top | 3.5 kHz to the target's high edge |

- A zone is flagged when its mean deviation exceeds the zone's tolerance.
- Flags use 1 dB hysteresis.

## Advice

### Order

1. **Our own receive path first:**
   - "Your RX filter is 4.0 kHz, too narrow to judge eSSB. Widen it to
     8 kHz or more."
   - "NR is on…"
2. **Confidence**, when it is too low: "Need more speech (5 s of 8)" or
   "Signal too weak (SNR 11 dB)".
3. **Bandwidth.** Example: "Low edge 110 Hz, high edge 4.1 kHz. That's
   mid-fi. To reach eSSB, widen the TX filter toward 6 kHz and add low end
   below 100 Hz."
4. **Tone.** Example: "About 6 dB heavy around 80 Hz. Cut there."
5. **Compression:**
   - "Background noise is coming up between words. Try the Noise Gate, or
     less compression."
   - "Level climbs back after each word (pumping). Try a slower release or
     a lower ratio."
6. **Splatter**, as a separate alert that always shows when triggered.

### Lyra mode

The default. Advice names the control the operator sees, frequency first,
because operators move bands off their defaults. Examples:

- "TX EQ — the band nearest 80 Hz: about −5 dB."
- "Noise Gate: raise Thresh about 5 dB."
- "Combinator: slower Release."
- "Auto-AGC: lower Max gain."

The builder maps each advice type to Lyra's actual controls from the
existing TX EQ, Speech and Combinator models.

### Other-rig mode

The same findings in plain terms: "cut around 80 Hz", "add a gate", "slower
release".

### Wording rules

- Round to whole dB.
- Use "about".
- Never be more precise than the confidence allows.
- Say when an apparent problem may be ours (RX filter, NR/ANF, AGC, fading).

## Workflow and UI (QML panel, `EssbCoachPanel.qml`)

### Header row

- Target preset picker.
- **Advice for:** Lyra / Other rig.
- **Baseline:** Start / Stop.
- **Re-check:** Start / Stop.
- Reset.
- Freeze.
- Capture as target.
- Record.

### Graph

- 1/6-octave bars for the live trace.
- A line for the current average.
- A dimmed line for the baseline.
- The target curve with a shaded tolerance band.
- Regions outside our RX filter greyed out.
- Edge markers.

### Readouts

- Confidence (speech seconds and SNR).
- Edges and tier.
- Gap-to-speech, gap rise, crest factor.
- The splatter status.

### Advice list

Below the graph, in the order given under Advice.

### Compare

After a Re-check, each zone shows its change against the baseline, e.g.
"Bass −4 dB". **Make baseline** promotes the re-check to the new baseline.

## Session record and report (the phase-2 hook)

- **Record** saves the session using the existing recorder
  (`src/recorder/`) where that fits. It holds:
  - the audio;
  - the baseline and each re-check;
  - each one's **measurement report**;
  - timestamps;
  - the target in use.
- The **measurement report** is JSON with a version number. It contains:
  - target id;
  - per-band normalised curve;
  - per-zone deviation and tolerance;
  - edges;
  - SNR and speech seconds;
  - compression metrics;
  - splatter result;
  - receive-path conditions;
  - advice items, each with a type, values and the Lyra control.
- The report schema goes in the repo docs, because phase 2 sends this report
  (not the audio) together with Lyra's control list and ranges to an AI
  service for parameter suggestions.
- Phase 2 must tell the user when a report is sent off-machine.

## Tests (Qt-free, under `scratch/` like `test_vfo_styles`)

1. **Tonal advice:**
   - Pink noise shaped by +6 dB at 80 Hz gives "heavy around 80 Hz".
   - Flat pink noise gives no tone advice.
2. **Gate and hiss:**
   - Speech-like bursts with silences: the silences are excluded from the
     average.
   - Hiss alone: no "too much high end" advice, and confidence too low.
3. **Edges:**
   - Band-limited noise of 100 Hz–4.1 kHz reads edges within one band.
   - A narrow synthetic RX filter marks the edges as "beyond your RX filter".
4. **Pumping:** a synthetic envelope whose pause level rises after each burst
   triggers the pumping flag; a steady pause level does not. The same steady
   signal through a simulated AGC, with its gain reported to the coach, must
   not trigger it.
5. **Splatter:** an IQ tone placed outside the channel at −30 dB and −40 dB
   relative to peak alerts at −30 and not at −40.
6. **Report:** the JSON round-trips, and its version number is present.

## Left to the builder

- The exact speech-gate and compression thresholds, documented and tested.
- Decimation versus a direct 4096-point FFT.
- Class and file names, and how the analyzer state is split between the
  model and the view.
- Graph styling details within the existing panel look.
- How the session record is laid out on disk, if the existing recorder
  doesn't fit as-is.
