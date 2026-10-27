# eSSB Coach Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A separate "eSSB Coach" panel that measures the received audio of a station being coached, compares it with a target curve, and gives hedged advice in Lyra terms. It covers tone, bandwidth, compression and splatter.

**Architecture:** Qt-free DSP classes under `src/dsp/coach/`, tested by one standalone harness:
- band layout and targets;
- an audio-thread analyzer with speech gate, noise floor and AGC correction;
- an IQ splatter meter;
- an advisor that turns measurements into typed findings.

Around them:
- `WdspEngine` gains two read-only taps (RX1 audio before the RX EQ, and RX1 IQ), each behind an atomic pointer.
- An `EssbCoachModel` QObject polls snapshots at 25 Hz, renders the advice text, keeps targets in QSettings and writes versioned JSON reports.
- `EssbCoachPanel.qml` is the view.

**Tech Stack:** C++23, Qt 6 (Core/Qml/Quick), QML, CMake. Standalone tests use the `check()` idiom of `scratch/test_eq_analyzer.cpp`.

**Spec:** `docs/superpowers/specs/2026-10-26-essb-coach-design.md`

## Global Constraints

- **No change to the RX EQ.** Do not edit `src/eqmodel.*`, `src/qml/EqPanel.qml` or `src/dsp/EqAnalyzer.*`. In `src/wdsp_engine.cpp` the RX EQ block (`#59 RX EQ`, in `dispatchAudioFrame`) is not modified. The coach tap is inserted *above* it.
- **Audio-thread code:**
  - No allocation after `prepare()`, no Qt and no logging.
  - The only lock is a short publish mutex; FFT math runs outside it.
- **New DSP classes are Qt-free**, in namespace `lyra::dsp::coach`.
- **Sample rate** is 48 000 Hz audio. The IQ rate is `cfg_.inRate` (192 000 by default, read at runtime).
- **Measures RX1 only.** It is disabled in desk mode (`desk_ && desk_->deskSide()`). There is no remote/desk tap.
- **Normalisation:** every curve is shifted so the mean dB of the bands centred in 500–2000 Hz is 0 dB.
- **Confidence floor:** 8 s of gated speech and a median in-band SNR of 15 dB. Below either, no tone, bandwidth or compression advice.
- **Splatter alert:** out-of-channel energy within 35 dB of the in-channel peak, measured in a window 0.5–3 kHz past the channel edge.
- **Lit/"on" style:** colour `#ff9a3c` on fill `#3a2a14`.
- **Builds on macOS arm64 and Linux.** No new dependencies.
- **Committing:** this repo commits only when the user says "commit it". Each task ends with a **checkpoint** (build plus tests green, files listed), not a commit.
- **Branch:** work on `macos-port` in `/Users/bcrier/Documents/dev/Lyra`.

## Review Focus

1. **Silence or carrier only** (no speech for minutes): no advice, and the confidence line says why. Owned by Task 3 (`gate_silence_no_speech`).
2. **Strong station, then a weak one** (tuning mid-baseline): a Reset must clear everything, with no blend of two stations. Owned by Task 3 (`reset_clears_all`).
3. **RX filter narrower than the target's high edge:** the top zone and the edges read "beyond your RX filter", never "thin top end". Owned by Task 5 (`advisor_narrow_rx_filter`).
4. **Audio block larger than expected** (some backends send >4096 frames): the analyzer must process it in chunks, never skip or overflow. Owned by Task 2 (`feed_large_block_chunks`).
5. **Mode changed to CW/DIG/AM while the panel is open:** the coach shows "Not a voice SSB mode", without stale advice. Owned by Task 5 (`advisor_non_ssb_mode`).

---

### Task 1: Band layout, targets and zones

**Files:**
- Create: `src/dsp/coach/CoachTarget.h`, `src/dsp/coach/CoachTarget.cpp`
- Create: `scratch/test_essb_coach.cpp`
- Modify: `CMakeLists.txt`. Add `test_essb_coach` (EXCLUDE_FROM_ALL, `target_include_directories(... PRIVATE src)`, MSVC flags as for `test_eq_analyzer`), next to the `test_eq_analyzer` block (~line 1339).

**Interfaces:**
- Produces:
  - `struct BandLayout { std::vector<double> centreHz, loHz, hiHz; int size() const; };`
  - `BandLayout makeBands(double fromHz = 40.0, double toHz = 12000.0);` 1/6-octave centres `fromHz·2^(k/6)`, edges `centre·2^(±1/12)`.
  - `struct TargetPoint { double hz, db; };`
  - `struct Target { std::string id, name; double lowEdgeHz, highEdgeHz; std::vector<TargetPoint> points; double tolLowDb, tolDb, tolSplitHz; bool builtin; };`
  - `double targetDbAt(const Target&, double hz);` Linear in log10(hz) between points, clamped flat beyond the ends.
  - `double toleranceAt(const Target&, double hz);` Returns `tolLowDb` below `tolSplitHz`, else `tolDb`.
  - `std::vector<Target> builtinTargets();` Order and values below.
  - `enum class ZoneId { Bass, LowMid, Body, Upper, Top };`
  - `struct Zone { ZoneId id; double loHz, hiHz; };`
  - `std::vector<Zone> defaultZones(double targetHighEdgeHz);` Top runs 3500 Hz → `targetHighEdgeHz`.
  - `void normalise(std::vector<double>& bandDb, const BandLayout&);` Subtracts the mean dB of bands centred in 500–2000 Hz.
  - `std::string targetToJson(const Target&);` and `bool targetFromJson(const std::string&, Target&);` A hand-rolled minimal JSON for this one struct, so it stays Qt-free. The model stores the string in QSettings.

Built-in targets (`id`, edges, points, tolerances `tolLowDb/tolDb/tolSplitHz`):

| id | low | high | points (Hz:dB) | tol |
|---|---|---|---|---|
| `essb` | 50 | 6000 | 50:0, 70:3, 150:3, 200:0, 6000:0 | 5 / 3 / 150 |
| `midfi` | 100 | 4000 | 100:0, 4000:0 | 3 / 3 / 150 |
| `typical` | 300 | 2700 | 300:0, 2700:0 | 3 / 3 / 150 |
| `am` | 50 | 9000 | 50:0, 9000:0 | 3 / 3 / 150 |

- [ ] **Step 1: Write failing tests** in `scratch/test_essb_coach.cpp` (a `check(name, ok, got)` helper copied from `test_eq_analyzer.cpp`; `main` returns non-zero on any failure):
  - `bands_sixth_octave`: `makeBands(40,12000)` has `centreHz[0]==40`, `centreHz[6]≈80` (±0.01), and adjacent ratio `2^(1/6)`.
  - `target_interp_log`: for `essb`, `targetDbAt(100)==3`, `targetDbAt(1000)==0`, and `targetDbAt(60)` is strictly between 0 and 3.
  - `target_tolerance_split`: `toleranceAt(essb,100)==5`, `toleranceAt(essb,1000)==3`.
  - `normalise_mids_zero`: after `normalise`, the mean of the bands centred in 500–2000 Hz is 0 (±1e-9).
  - `target_json_roundtrip`: every built-in survives `targetToJson` → `targetFromJson` with all fields equal.
- [ ] **Step 2:** `cmake --build build --target test_essb_coach` fails (missing header).
- [ ] **Step 3:** Implement `CoachTarget.{h,cpp}` with the signatures above.
- [ ] **Step 4:** `cmake --build build --target test_essb_coach && ./build/test_essb_coach` prints every check OK and exits 0.
- [ ] **Step 5: Checkpoint.** Files: `src/dsp/coach/CoachTarget.*`, `scratch/test_essb_coach.cpp`, `CMakeLists.txt`.

### Task 2: Analyzer — spectrum, bands, averages

**Files:**
- Create: `src/dsp/coach/CoachAnalyzer.h`, `src/dsp/coach/CoachAnalyzer.cpp`
- Modify: `scratch/test_essb_coach.cpp`, `CMakeLists.txt` (add the sources to `test_essb_coach`)

**Interfaces:**
- Consumes: `BandLayout`, `makeBands`, `normalise` (Task 1).
- Produces:
  - `class CoachAnalyzer { public: explicit CoachAnalyzer(double fs = 48000.0); void prepare(); void feed(const double* mono, int n, double agcGainDb); bool snapshot(CoachSnapshot& out); void reset(); void startBaseline(); void stopBaseline(); void startRecheck(); void stopRecheck(); void freeze(bool on); };`
    - `feed` runs on the audio thread.
    - `snapshot`, `reset`, start/stop and `freeze` run on the GUI thread. They are lock-free requests through atomics, consumed at the next `feed`.
  - `enum class AvgState { Idle, Running, Stopped };`
  - `struct CoachSnapshot { BandLayout bands; std::vector<double> liveDb, baselineDb, recheckDb; AvgState baseline, recheck; double speechSec, recheckSpeechSec, medianSnrDb; std::vector<double> bandSnrDb; CompressionMetrics comp, recheckComp; bool frozen; };`
    - All `*Db` curves are normalised.
    - Empty vectors mean "no data yet".
    - `CompressionMetrics` is defined in Task 3. Add it now as an empty struct and fill it there.
- FFT: 4096 points, Hann window, hop 2048. It is the analyzer's own radix-2 FFT; copy the approach of `EqAnalyzer::fft`, don't link `EqAnalyzer`. Band power is the sum of bin power whose centre lies in [loHz, hiHz).
- Live trace: per-band power exponential average with τ = 0.3 s (per-frame coefficient from hop/fs).
- Baseline and re-check: an equal-weight running mean of the power of *speech* frames from start to stop. In this task every frame counts as speech; Task 3 adds the gate.
- Bands are fixed at `makeBands(40, 12000)`; the advisor masks bands outside the RX passband, so the analyzer never re-prepares when the filter changes. `prepare()` sizes every buffer, so `feed()` never allocates. Blocks larger than 4096 frames are processed in chunks of at most 4096.

- [ ] **Step 1: Write failing tests:**
  - `analyzer_tone_lands_in_band`: a 1 kHz sine fed for 2 s gives a live-curve maximum in the band whose range contains 1000 Hz.
  - `analyzer_pink_flat`: 20 s of pink noise (a seeded Voss-McCartney generator in the test) with a baseline started gives `|baselineDb[b]| < 1.5` for every band 100 Hz–5 kHz.
  - `analyzer_shaped_80hz`: pink noise through a +6 dB peaking biquad at 80 Hz (Q 1.0, implemented in the test) gives `baselineDb` at the 80 Hz band of 6 ± 1.5.
  - `feed_large_block_chunks`: feeding one 10 000-sample block and feeding the same signal as 100-sample blocks give live curves equal within 0.1 dB.
- [ ] **Step 2:** Build fails or tests fail.
- [ ] **Step 3:** Implement `CoachAnalyzer` as specified. The publish mutex guards only the copy into the snapshot buffers.
- [ ] **Step 4:** `./build/test_essb_coach` shows all checks OK.
- [ ] **Step 5: Checkpoint.**

### Task 3: Speech gate, noise floor, AGC correction, compression metrics

**Files:**
- Create: `src/dsp/coach/CoachEnvelope.h`, `src/dsp/coach/CoachEnvelope.cpp`
- Modify: `src/dsp/coach/CoachAnalyzer.*`, `scratch/test_essb_coach.cpp`, `CMakeLists.txt`

**Interfaces:**
- Consumes: `CoachAnalyzer` internals (Task 2).
- Produces:
  - `struct CompressionMetrics { double gapToSpeechDb = NAN, gapRiseDb = NAN, crestDb = NAN; int pauses = 0; };`
  - `class CoachEnvelope { public: explicit CoachEnvelope(double fs); void prepare(); bool push(const double* mono, int n, double agcGainDb); /* true = current 10 ms block is speech */ double noiseFloorDb() const; CompressionMetrics metrics() const; void reset(); };`
- Envelope: RMS over 10 ms blocks (480 samples) of the signal band-limited to 100–5000 Hz, in dB.
- **AGC correction:** subtract `agcGainDb` from each block's dB before gating and metrics.
- **Noise floor:** slow-rising, fast-falling tracker on the corrected envelope (minimum statistics over a 2 s window).
- **Speech:** a block counts as speech when it is ≥ 10 dB above the noise floor, with a 200 ms hangover. An FFT frame counts as speech when ≥ 70 % of its blocks are speech.
- Speech frames feed the baseline and re-check; non-speech frames update the per-band noise power. The noise is subtracted from the speech averages as power, floored at −60 dB relative.
- **gapToSpeechDb:** median speech level minus median gap level.
- **gapRiseDb:** median over pauses ≥ 800 ms of (mean level 650–800 ms after speech end) − (mean level 0–150 ms after speech end).
- **crestDb:** 99th-percentile block level minus median speech block level.
- Starting flag defaults, used by Task 5 and tuned only if the tests demand: gap-to-speech `< 25 dB` flags noise; gap rise `> 6 dB` flags pumping; crest `< 8 dB` flags squashed. Name them as `constexpr` in `CoachEnvelope.h`.
- Expose `CoachSnapshot::speechSec` (gated speech seconds since the baseline started) and `medianSnrDb`.

- [ ] **Step 1: Write failing tests:**
  - `gate_silence_no_speech`: 30 s of −60 dBFS white noise gives `speechSec < 0.5` and empty baseline curves.
  - `gate_bursts_excluded`: 1.5 s pink bursts at −20 dBFS alternating with 1 s at −60 dBFS. `speechSec` is within 15 % of the burst time, and `baselineDb` stays flat within 2 dB over 100 Hz–5 kHz. The silences don't tilt it.
  - `hiss_no_highs`: −50 dBFS white noise alone for 30 s gives `medianSnrDb < 15`.
  - `pumping_detected`: bursts, then pauses whose level ramps +10 dB over 800 ms, give `gapRiseDb > 6`.
  - `pumping_steady_none`: the same bursts with steady pauses give `gapRiseDb < 2`.
  - `agc_corrected_no_pumping`: steady bursts and pauses with a simulated AGC applied. The AGC gain jumps −15 dB on each burst and recovers +15 dB across the pause over 600 ms, and the same gain is passed as `agcGainDb`. Expect `gapRiseDb < 2`.
  - `reset_clears_all`: after a baseline on one signal, `reset()` then a snapshot gives empty curves, `speechSec == 0`, and all-NaN metrics.
- [ ] **Step 2:** Tests fail.
- [ ] **Step 3:** Implement `CoachEnvelope` and wire it into `CoachAnalyzer::feed`.
- [ ] **Step 4:** All checks OK.
- [ ] **Step 5: Checkpoint.**

### Task 4: Splatter meter (IQ)

**Files:**
- Create: `src/dsp/coach/SplatterMeter.h`, `src/dsp/coach/SplatterMeter.cpp`
- Modify: `scratch/test_essb_coach.cpp`, `CMakeLists.txt`

**Interfaces:**
- Produces:
  - `struct SplatterResult { bool valid = false; double peakDb = NAN, outDb = NAN, marginDb = NAN; bool alert = false; };` where `marginDb = peakDb − outDb` and `alert = valid && marginDb < 35.0`.
  - `class SplatterMeter { public: void prepare(int iqRate); void setChannel(double shiftHz, bool upperSideband, double channelEdgeHz); void feed(const double* iqInterleaved, int frames); bool snapshot(SplatterResult& out); };`
- Complex FFT of 16 384 points, Hann window, power averaged with τ = 1 s.
- The channel is `[shiftHz, shiftHz ± channelEdgeHz]`, the sign following `upperSideband`.
- `peakDb` is the maximum 100 Hz-band power inside the channel. `outDb` is the maximum 100 Hz-band power in `[edge + 500, edge + 3000]` on the far side. Both are measured at equal 100 Hz bandwidth.
- `valid` is false until 3 s of data has arrived, or when `shiftHz ± (edge + 3000)` falls outside `±iqRate/2`.

- [ ] **Step 1: Write failing tests:**
  - `splatter_alert_at_30`: a USB channel (edge 6000 Hz, shift 0), an in-channel tone at 1 kHz and an out-of-channel tone at 7.5 kHz at −30 dB relative. Expect `alert == true` and `marginDb` of 30 ± 2.
  - `splatter_quiet_at_40`: the same with the out tone at −40 dB. Expect `alert == false`.
  - `splatter_lsb_side`: LSB mirror of the first test. Expect an alert.
  - `splatter_invalid_out_of_span`: `iqRate = 12000` with a 6000 Hz edge gives `valid == false`.
- [ ] **Step 2:** Tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** All checks OK.
- [ ] **Step 5: Checkpoint.**

### Task 5: Advisor — edges, zones, typed findings

**Files:**
- Create: `src/dsp/coach/CoachAdvisor.h`, `src/dsp/coach/CoachAdvisor.cpp`
- Modify: `scratch/test_essb_coach.cpp`, `CMakeLists.txt`

**Interfaces:**
- Consumes: `CoachSnapshot`, `CompressionMetrics` and the threshold constants (Tasks 2–3); `SplatterResult` (Task 4); `Target`, `Zone`, `toleranceAt` (Task 1).
- Produces:
  - `struct RxConditions { double rxLowHz, rxHighHz; bool nrOn, anfOn; std::string agcMode; std::string mode; };` Passband edges are absolute audio Hz: the model passes `abs()` of the passband values.
  - `struct Edges { double lowHz = NAN, highHz = NAN; bool lowBeyondRx = false, highBeyondRx = false; std::string tier; };` `tier` is the id of the built-in target whose edges are nearest.
  - `enum class FindingKind { RxFilterTooNarrow, NrOn, AnfOn, NotVoiceMode, NeedMoreSpeech, SignalTooWeak, Bandwidth, ToneHeavy, ToneThin, NoiseBetweenWords, Pumping, Squashed, Splatter };`
  - `struct Finding { FindingKind kind; ZoneId zone{}; double hz = 0, db = 0, value = 0, value2 = 0; };`
    - `hz` is the zone's worst band centre.
    - `db` is the deviation, rounded to a whole dB.
    - `value`/`value2` carry edges, seconds or SNR as each kind needs.
  - `class CoachAdvisor { public: Edges edges(const CoachSnapshot&, const RxConditions&) const; std::vector<Finding> evaluate(const CoachSnapshot&, const SplatterResult&, const RxConditions&, const Target&); std::vector<std::pair<ZoneId,double>> zoneDelta(const CoachSnapshot&) const; /* recheck − baseline per zone */ void reset(); /* clears hysteresis state */ void setThresholds(const CoachThresholds&); void setZones(std::vector<Zone>); };`
  - `struct CoachThresholds { double minSpeechSec = 8, minSnrDb = 15, gapToSpeechDb = kGapToSpeechFlagDb, gapRiseDb = kGapRiseFlagDb, crestDb = kCrestFlagDb; };` The defaults are the Task 3 constants.
- **Order** of the returned findings: receive path (RxFilterTooNarrow, NrOn, AnfOn, NotVoiceMode) → confidence (NeedMoreSpeech, SignalTooWeak) → Bandwidth → tone → compression → Splatter.
  - When a confidence finding is present, tone, bandwidth and compression findings are omitted.
  - Splatter is always included when `alert`.
- **NotVoiceMode:** the mode is not USB, LSB, DSB, AM or SAM. When present, it is the only finding.
- **RxFilterTooNarrow:** `rxHighHz < target.highEdgeHz + 2000`.
- **Edges:** walking outward from 1 kHz, the last band still within 20 dB of 0. An edge within 150 Hz of an RX edge sets `*BeyondRx`.
- **Zone flags:** the mean (curve − target) over the zone's bands. Bands within 150 Hz of an RX edge, or outside the RX passband, are excluded. A zone left with no bands is skipped. Flag when |mean| > `toleranceAt(zone centre)`; clear when it drops below tolerance − 1 dB (hysteresis). The advisor keeps flag state per zone; it is reset on `CoachAnalyzer::reset`.
- **Bandwidth finding:** when either edge is off the target's edge by more than one band, or the tier differs from `target.id`.

- [ ] **Step 1: Write failing tests:**
  - `advisor_heavy_80`: a snapshot whose baseline is flat 0 dB except +6 dB over 60–150 Hz, against the `essb` target, with confidence OK, gives **no** tone finding: the deviation is 6 − 3 (target bump) = 3, within the Bass tolerance of 5. The same with +9 dB gives one `ToneHeavy`, zone Bass, `db == 6`, `hz` within 60–150.
  - `advisor_flat_none`: a baseline equal to the target gives no tone findings.
  - `advisor_narrow_rx_filter`: `rxHighHz = 4000` with the `essb` target gives `RxFilterTooNarrow` first. Top-zone findings are absent and `edges().highBeyondRx == true`.
  - `advisor_low_confidence`: `speechSec = 5` gives `NeedMoreSpeech` with `value == 5`, `value2 == 8`, and no tone findings.
  - `advisor_non_ssb_mode`: `mode = "CWU"` gives the single finding `NotVoiceMode`.
  - `advisor_hysteresis`: a zone at tolerance + 0.5 flags; at tolerance − 0.5 it stays flagged; at tolerance − 1.5 it clears.
  - `advisor_compression`: metrics with gapRise 8 give `Pumping`; gapToSpeech 18 gives `NoiseBetweenWords`; crest 6 gives `Squashed`.
  - `advisor_bandwidth_midfi`: edges 110 Hz / 4100 Hz against `essb` give `Bandwidth` with tier `midfi`.
- [ ] **Step 2:** Tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** All checks OK.
- [ ] **Step 5: Checkpoint.**

### Task 6: WdspEngine taps (audio before the RX EQ, IQ, AGC gain, shift)

**Files:**
- Modify: `src/wdsp_engine.h`, `src/wdsp_engine.cpp`

**Interfaces:**
- Consumes: `CoachAnalyzer::feed(const double*, int, double)` (Task 2/3) and `SplatterMeter::feed(const double*, int)` (Task 4).
- Produces:
  - `void WdspEngine::setCoachTaps(lyra::dsp::coach::CoachAnalyzer* a, lyra::dsp::coach::SplatterMeter* s);` Stores two `std::atomic<…*>`, release order. `nullptr` detaches.
  - `double WdspEngine::rxShiftHz() const;` Mirrors the last `setRxShiftHz` value through an `std::atomic<double> rxShiftHz_`.
  - `int WdspEngine::iqRate() const;` Use the existing `inRateAtomic_` if it is accessible, else return `cfg_.inRate`.

**Placement:**
- **Audio:** in `dispatchAudioFrame`, immediately above the `// #59 RX EQ` comment:
  - If the coach analyzer is attached, copy RX1 (`audio[2*k]`, the left channel) into a `thread_local double coachBuf[4096]` in chunks of ≤ 4096 frames.
  - Read `api.GetRXAMeter(channel_, 4)` (RXA_AGC_GAIN, dB; the same call as `agcGainDb()`) once per block.
  - Call `feed(coachBuf, chunk, gainDb)`.
  - Nothing after this point changes. Add a comment that the tap is read-only and sits before the RX EQ on purpose.
- **IQ:** in `feedIq`, next to the `// TCI IQ stream tap` block. If the splatter meter is attached, call `feed(accum_.data(), cfg_.inSize)`.
- **AGC alignment check:**
  - Find where `GetRXAMeter` is updated relative to `fexchange0` and the audio callback.
  - If the gain read in `dispatchAudioFrame` belongs to the same block as the audio (or the block before), note that in a comment.
  - If it can lag by more than one block, add `bool WdspEngine::coachAgcAligned() const` returning false. Task 7 then shows the fallback ("Set AGC to Off/Fixed for compression readings").

- [ ] **Step 1:** Implement the taps and accessors as above.
- [ ] **Step 2:** Run `cmake --build build --target lyra`. Expect it to build with no new warnings in `wdsp_engine.cpp`.
- [ ] **Step 3:** Run `cmake --build build --target test_eq_analyzer && ./build/test_eq_analyzer`. The RX EQ analyzer still passes unchanged.
- [ ] **Step 4:** Run `git diff --stat -- src/eqmodel.cpp src/eqmodel.h src/qml/EqPanel.qml src/dsp/EqAnalyzer.cpp src/dsp/EqAnalyzer.h`. Expect empty output.
- [ ] **Step 5: Checkpoint.** Record the AGC-alignment finding in the checkpoint note.

### Task 7: EssbCoachModel (QObject), targets in QSettings, reports

**Files:**
- Create: `src/essbcoachmodel.h`, `src/essbcoachmodel.cpp`
- Create: `docs/essb-coach-report.md` (report schema, version 1)
- Create: `scratch/test_essb_report.cpp`; add the `test_essb_report` target to `CMakeLists.txt` (links `Qt6::Core`, sources `src/essbcoachmodel.cpp` plus the coach DSP sources). If linking the model needs `WdspEngine`, move report building into free functions in `src/essbcoachreport.{h,cpp}` and test those.
- Modify: `src/mainwindow.h`, `src/mainwindow.cpp`. Construct the model next to `combinatorModel_` and register the context property `EssbCoach` beside `Combinator` (~line 2556). Call `engine->setCoachTaps(...)` only while the panel's dock is visible; detach on hide.
- Modify: `CMakeLists.txt` (add the new sources to `lyra`).

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces (QML-facing):
  - `Q_PROPERTY(QVariantList bandsHz …)` for the band centres.
  - `liveDb`, `baselineDb`, `recheckDb`, `targetDb`, `tolDb` as `QVariantList`.
  - `rxLowHz`, `rxHighHz` (double).
  - `speechSec`, `snrDb` (double).
  - `edgesText` (QString).
  - `metrics` (QVariantMap with keys `gapToSpeechDb`, `gapRiseDb`, `crestDb`).
  - `splatter` (QVariantMap with keys `valid`, `marginDb`, `alert`).
  - `adviceLines` (QStringList).
  - `zoneDeltas` (QVariantList of `{zone, db}`).
  - `targets` (QVariantList of `{id, name, builtin}`) and `targetId` (QString, read/write).
  - `lyraAdvice` (bool, read/write, default true).
  - `baselineState`, `recheckState` (int, mirrors AvgState).
  - `frozen` (bool).
  - `available` (bool: false in desk mode).
  - `agcFallback` (bool).
  - `recording` (bool).
  - All notify on `updated()`.
  - `Q_INVOKABLE`: `startBaseline()`, `stopBaseline()`, `startRecheck()`, `stopRecheck()`, `makeBaseline()`, `reset()`, `setFrozen(bool)`, `captureAsTarget(const QString& name)`, `deleteTarget(const QString& id)`, `toggleRecord()`.
- **Editable settings**, stored in QSettings under `essbCoach/`:
  - `minSpeechSec` and `minSnrDb`;
  - the three compression thresholds;
  - the five zone edges.

  They are applied via `CoachAdvisor::setThresholds`/`setZones`, exposed as `Q_PROPERTY(QVariantMap settings …)` and changed with `Q_INVOKABLE void setSetting(const QString& key, double value)` plus `Q_INVOKABLE void resetSettings()`. `reset()` also calls `CoachAdvisor::reset()`.
- Poll: a `QTimer` at 40 ms reads both snapshots, runs `CoachAdvisor`, rebuilds the properties and emits `updated()` once.
- **Conditions** come from `WdspEngine`: `passbandLowHz`/`passbandHighHz` (abs), `nrMode != 0`, `anfEnabled`, `agcMode`, `mode`.
- **Splatter channel:** `setChannel(rxShiftHz(), mode is USB/DIGU-like, target.highEdgeHz)`.
- **Targets** are stored under QSettings `essbCoach/targets/<id>` as `targetToJson` strings. The selected target is `essbCoach/targetId` (default `essb`). Built-ins are never written or deleted.
- **Advice copy**, from `tr()` templates keyed by `FindingKind`. Lyra mode uses the first wording, other-rig mode the one after `|`:
  - ToneHeavy: "About %1 dB heavy around %2 Hz. TX EQ, the band nearest %2 Hz: about −%1 dB." | "About %1 dB heavy around %2 Hz. Cut there."
  - ToneThin: "About %1 dB thin around %2 Hz. TX EQ, the band nearest %2 Hz: about +%1 dB." | "About %1 dB thin around %2 Hz. Lift there."
  - Bandwidth: "Low edge %1 Hz, high edge %2 Hz. That's %3. Target is %4." Same wording for both modes.
  - NoiseBetweenWords: "Background noise is coming up between words. Noise Gate: raise Thresh about 5 dB, or lower Auto-AGC Max gain." | "Background noise is coming up between words. Add a noise gate, or use less compression."
  - Pumping: "Level climbs back after each word (pumping). Combinator: slower Release or lower Ratio." | "Level climbs back after each word (pumping). Try a slower release or a lower ratio."
  - Squashed: "Peaks barely rise above the average (over-compressed). Combinator: lower Ratio or Mix." | "Peaks barely rise above the average (over-compressed). Use less compression."
  - RxFilterTooNarrow: "Your RX filter is %1 kHz, too narrow to judge this target. Widen it to %2 kHz or more."
  - NrOn / AnfOn: "NR is on. Turn it off for a fair reading." / "ANF is on. Turn it off for a fair reading."
  - NotVoiceMode: "Not a voice SSB mode. Switch to USB or LSB."
  - NeedMoreSpeech: "Need more speech (%1 s of %2)."
  - SignalTooWeak: "Signal too weak (SNR %1 dB)."
  - Splatter: "Splatter: energy past the channel edge is only %1 dB below the peak. Check a quiet neighbouring frequency to confirm."
  - Agc fallback: "Set AGC to Off or Fixed for compression readings."
  - When a deviation's confidence is moderate (speechSec < 20 or SNR < 20), the dB is shown as a range "%1–%2 dB" (±1).
- **Report:** `QJsonObject buildReport(...)` with `"version": 1` and the fields listed in the spec's *Session record and report* section. The exact field names go in `docs/essb-coach-report.md`.
- **Record:** `toggleRecord()` starts or stops the existing `RecorderEngine` via `start(freqHz, mode)` / `stop()`. While recording, each Stop (baseline or re-check) writes `coach-<n>-<baseline|recheck>.json` into `RecorderEngine::sessionDir()`, along with `coach-target.json` once.

- [ ] **Step 1: Write failing tests** in `scratch/test_essb_report.cpp`:
  - `report_version`: `buildReport` on a synthetic snapshot gives `version == 1` and every schema key present.
  - `report_roundtrip`: serialise to JSON, parse, and compare `baselineDb` within 1e-6.
  - `report_findings_typed`: each finding is serialised with `kind` (string), `zone`, `hz` and `db`.
- [ ] **Step 2:** Tests fail.
- [ ] **Step 3:** Implement the model and report, and write `docs/essb-coach-report.md` (field, type, unit, meaning).
- [ ] **Step 4:** Both test targets pass, and `cmake --build build --target lyra` builds.
- [ ] **Step 5: Checkpoint.**

### Task 8: Panel, dock, chip, rack membership, docs

**Files:**
- Create: `src/qml/EssbCoachPanel.qml`
- Modify: `CMakeLists.txt` (add the QML file to `qt_add_qml_module(lyra …)`)
- Modify: `src/mainwindow.cpp`:
  - `addQuickDock(QStringLiteral("essbcoach"), tr("eSSB Coach"), QStringLiteral("EssbCoachPanel.qml"), QStringLiteral("essbcoach"), Qt::BottomDockWidgetArea, true)`, floating and hidden by default, plus `FloatingDockMemory(d, QStringLiteral("ui/essbCoachDock"), …)`, all after the CW Decoder block (~line 3156).
  - Add `"essbcoach"` to `kChipSummonedPanels`.
  - Add an "eSSB" chip in the Options group after "CW Dec" (same `toggleViewAction` + `kTxDspChipQss` pattern, ~line 4667).
  - Add `QStringLiteral("essbcoach")` to the Options rack member list (~line 4691).
  - Attach the coach taps on the dock's `visibilityChanged(true)` and detach on `false`.
- Modify: `docs/help/USER_GUIDE.md`. Add an "eSSB Coach" section after the Tuner section, and add it to Contents. Describe the workflow (Baseline → change → Re-check → Make baseline), targets, the AGC note, splatter needing a quiet neighbour, and that it measures RX1 locally only.

**Interfaces:**
- Consumes: the `EssbCoach` context property (Task 7).

**Layout:**
- **Settings gear** (right end of the header): a popup with number fields for every key in `EssbCoach.settings`, and a "Defaults" button calling `resetSettings()`. This is the spec's "editable in Settings", kept in the panel rather than the main Settings dialog.
- **Header row:** Target `LyraComboBox`; "Advice for" Lyra/Other toggle; Baseline Start/Stop; Re-check Start/Stop; Make baseline; Reset; Freeze; Capture as target (prompts for a name); Record.
  - Lit buttons use `#ff9a3c` on `#3a2a14`, like the Audio panel's Auto.
- **Graph:** a `Canvas` with a log-frequency x-axis from 40 Hz to `rxHighHz`, and dB from −20 to +20.
  - Live: bars.
  - Current average: a solid line.
  - Baseline: a dimmed line.
  - Target: a line with a shaded ±tolerance band.
  - Outside `[rxLowHz, rxHighHz]`: grey.
  - Edge markers drawn from `edgesText` values.
- **Readouts row:**
  - confidence ("Speech 12 s · SNR 24 dB");
  - edges and tier;
  - gap-to-speech, gap rise, crest;
  - splatter status, coloured red when alerting.
- **Below the graph:** `adviceLines` as a list, then `zoneDeltas` ("Bass −4 dB") when a re-check exists.
- When `available` is false, the panel shows a single centred label: "eSSB Coach measures the local radio only — not available in desk mode."

- [ ] **Step 1:** Build the panel and the MainWindow wiring.
- [ ] **Step 2:** Run `cmake --build build --target lyra`. It builds, with no QML warnings at load (`open build/lyra.app`, then check the console).
- [ ] **Step 3: Manual check, local radio, USB.**
  - The eSSB chip opens the panel.
  - Talking on a test signal fills the graph.
  - Baseline Start/Stop shows the baseline line.
  - A 4 kHz RX filter shows "too narrow" first.
  - Switching to CWU shows "Not a voice SSB mode".
  - Closing the panel detaches the taps: confirm the panel stops updating and CPU drops back.
- [ ] **Step 4:** Run `cmake --build build --target test_essb_coach test_essb_report test_eq_analyzer`; all pass.
- [ ] **Step 5: Checkpoint.** Ask the user to test on the air and say "commit it".

## Done when

- All three test targets pass.
- The app builds and runs.
- The manual checks in Task 8 hold.
- `git diff` shows no change to the RX EQ files.
- The user has tried it on the air.
