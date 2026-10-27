# eSSB Practice Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a 15–30 s practice clip, loop it unkeyed through Lyra's native TX rack, hear it in headphones and see it on the eSSB Coach graph, and A/B the saved profile's rack against live edits.

**Architecture:** The existing voice-keyer injector (`ClipRecorderPlayer`, at `TxClipInject` before the rack) gains a gap-free loop and a refuse guard. `WdspEngine` gains a `practiceActive_` flag that drives the post-rack monitor to the local output only and feeds the coach from the monitor audio. Two small Qt-Core classes carry the logic: `RackAbSwitch` (A/B of the four rack blobs) and `PracticePassTracker` (which loop passes are clean). `PracticeLoop` (QObject) ties them to the recorder, ClipBank, ProfileManager, HL2Stream and `EssbCoachModel`, whose new practice mode shows A as the baseline and B as the re-check. The UI is a Practice section in `EssbCoachPanel.qml`.

**Tech Stack:** C++23, Qt 6 (Core/Qml/Quick), QML, CMake. Standalone tests use the `CHECK` idiom of `scratch/test_clip_player.cpp`.

**Spec:** `docs/superpowers/specs/2026-10-27-essb-practice-loop-design.md`

## Global Constraints

- **The clip never reaches the air.** Practice plays with `ota = false`. It stops on the earliest key intent from any source, and the injector refuses on any block where a key is requested or MOX is active.
- **No change to the RX EQ** (`src/eqmodel.*`, `src/qml/EqPanel.qml`, `src/dsp/EqAnalyzer.*`, the `#59 RX EQ` block in `dispatchAudioFrame`).
- **No WDSP TXA changes.** The loop is the native rack only (Speech → EQ → Combinator → Plate). Practice forces `bypassDsp = false`, so the injector returns 1, never 2.
- **Practice audio never goes to TCI (Route 3) or VAC (Route 2).** `txMuted_` keeps its meaning (wire MOX). Practice uses its own `practiceActive_`.
- **Audio-thread / cm-thread code:** no allocation, no Qt, no logging, no new locks.
- **Clip length:** cap 30 s (`30 * 48000` samples); a clip under 10 s is rejected with the note "Practice clip too short — record at least 10 s."
- **A/B swaps exactly** `eq`, `speech`, `combinator` and `plate` (the `saveState()`/`loadState()` blobs of `EqModel`, `SpeechModel`, `CombinatorModel` and `PlateModel`), nothing else.
- **Voice modes only** (`CoachAdvisor::isVoiceMode`); HL2Stream only (if `stream_` is not an `HL2Stream`, practice is unavailable with the note "Practice needs an HL2 connection.").
- **Builds on macOS arm64 and Linux. No new dependencies.**
- **Committing:** commit only when the user says "commit it". Each task ends with a **checkpoint** (build and tests green, files listed), not a commit. Never push.
- **Branch:** `macos-port` in `/Users/bcrier/Documents/dev/Lyra`. The eSSB Coach work there is uncommitted; build on top of it and do not revert any of it.

## Review Focus

1. **A key while the loop runs** (manual MOX, HW PTT, VOX, TCI, CAT): the clip must not be transmitted, even on the block between the key intent and `stop()`. Owned by Task 1 (`refuse_stops_and_reverts_to_mic`) and Task 3 (`keyIntentOrMox` set before the inhibit checks).
2. **A/B apply re-entering as an "edit"**: loading A emits the rack models' change signals, which must not count as a B edit or wipe B. Owned by Task 2 (`apply_does_not_count_as_edit`).
3. **Leaving practice while on A**: your live edits (B) must be restored, not lost. Owned by Task 2 (`end_on_a_restores_b`).
4. **Flip mid-pass**: the partial pass must not overwrite either side's curve. Owned by Task 2 (`flip_mid_pass_discards`).
5. **MON off, TCI connected, practice running**: the headphones play practice; TCI and VAC carry RX as before. Owned by Task 3 (`routing_practice_local_only`).

---

### Task 1: Loop and refuse guard in `ClipRecorderPlayer`

**Files:**
- Modify: `src/tx/ClipRecorderPlayer.h`, `src/tx/ClipRecorderPlayer.cpp`
- Test: `scratch/test_clip_player.cpp` (add cases; target `test_clip_player` already exists)

**Interfaces:**
- Produces:
  - `PlayOptions::loop` (`bool`, default `false`). `play()` returns `false` when `loop && ota`.
  - `using RefuseFn = std::function<bool()>; void setRefuseFn(RefuseFn f);` (mutex-guarded like `setBlockedFn`). Consulted at the top of every `fillBlock` while a non-OTA clip is active. If it returns true, the player goes Idle (no key toggling), zero-fills nothing, and returns `false`, so the adapter reverts to live mic for that same block.
  - `unsigned passCount() const noexcept` (atomic; 0 at `play()`, +1 each time a loop wraps).
  - `std::size_t clipSamples() const` (0 when idle).
- Loop wrap: when `pos_` reaches the end with `loop` set, continue from index 0 inside the same block (no silence, no Draining, no KeyFn).

- [ ] **Step 1: Write the failing tests** in `scratch/test_clip_player.cpp`:
  - `loop_wraps_without_gap`: a 10-sample ramp with `loop=true, ota=false` and `fillBlock(25)` gives I = ramp[0..9], ramp[0..9], ramp[0..4]; `passCount()==2`; `active()` still true; no KeyFn call.
  - `loop_with_ota_refused`: `play(clip, {ota=true, loop=true})` returns false; `playing()==false`.
  - `refuse_stops_and_reverts_to_mic`: `setRefuseFn` returns true on the 2nd call. The 1st `fillBlock` returns true with clip samples. The 2nd returns false, the buffer is left untouched (pre-filled 9.0 stays 9.0), `active()==false`, no KeyFn call.
  - `refuse_ignored_for_ota`: with `ota=true`, a refuse fn returning true has no effect (OTA keeps its own BlockedFn discipline).
- [ ] **Step 2:** `cmake --build build --target test_clip_player` fails (unknown members).
- [ ] **Step 3: Implement** as specified in Interfaces. The refuse check leaves `buff` untouched so the live mic in `pcm->in` flows on.
- [ ] **Step 4:** `cmake --build build --target test_clip_player && ./build/test_clip_player`: every case `ok`, 0 FAIL, and the existing cases are unchanged.
- [ ] **Step 5: Checkpoint.**

### Task 2: `RackAbSwitch` and `PracticePassTracker`

**Files:**
- Create: `src/tx/RackAbSwitch.h`, `src/tx/RackAbSwitch.cpp`, `src/tx/PracticePassTracker.h` (header-only)
- Create: `scratch/test_practice.cpp`
- Modify: `CMakeLists.txt`: add `test_practice` (EXCLUDE_FROM_ALL, `PRIVATE src`, `Qt6::Core`, MSVC flags as for `test_profile`) next to `test_clip_player`.

**Interfaces:**
- Produces (namespace `lyra::tx`):
  - `struct RackState { QJsonObject eq, speech, combinator, plate; bool operator==(const RackState&) const; };`
  - `class RackAbSwitch`:
    - `RackAbSwitch(std::function<RackState()> capture, std::function<void(const RackState&)> apply);`
    - `enum class Side { A, B };`
    - `void begin(const RackState &savedA);` sets side B and changes nothing live.
    - `void flip();` B→A: `b_ = capture(); apply(a_)`. A→B: `apply(b_)`.
    - `void setA(const RackState &s);` (after Save; also sets side B).
    - `void end();` if on A, `apply(b_)`. Idle afterwards.
    - `bool noteEdit();` ignored (returns false) while `apply` is running or when idle. On A: side becomes B and `b_ = capture()`, then returns true. On B: returns true.
    - `Side side() const; bool active() const;`
  - `class PracticePassTracker` (pure, no Qt):
    - `void reset();`
    - `void onPassStart(Side s);` marks the new pass clean, on side `s`.
    - `void onFlip();` / `void onEdit();` mark the pass dirty.
    - `struct Result { bool clean; Side side; };`
    - `Result onPassEnd();`
    - Uses `RackAbSwitch::Side`.

- [ ] **Step 1: Write the failing tests** in `scratch/test_practice.cpp`, with fakes over a local `RackState live` and an apply counter:
  - `begin_changes_nothing`: after `begin(A)`, apply count 0, side B.
  - `flip_round_trip_restores_b`: live = B1; flip → live == A; flip → live == B1 exactly.
  - `apply_does_not_count_as_edit`: the fake apply calls `sw.noteEdit()` from inside; that returns false, and the side and `b_` are unchanged.
  - `edit_on_a_becomes_b`: on A, change live, `noteEdit()` → side B, and a later flip-to-A then flip-to-B restores the edited state.
  - `end_on_a_restores_b`: live = B1, flip, `end()` → live == B1.
  - `setA_after_save`: `setA(B1)`; flip → live == B1.
  - `pass_clean_whole_side`: `onPassStart(B)`, `onPassEnd()` → {clean, B}.
  - `flip_mid_pass_discards`: `onPassStart(B)`, `onFlip()`, `onPassEnd()` → clean false.
  - `edit_mid_pass_discards`: as above with `onEdit()`.
- [ ] **Step 2:** `cmake --build build --target test_practice` fails.
- [ ] **Step 3: Implement.** `noteEdit` uses an `applying_` guard set around every `apply` call.
- [ ] **Step 4:** `cmake --build build --target test_practice && ./build/test_practice`: all `ok`, 0 FAIL.
- [ ] **Step 5: Checkpoint.**

### Task 3: Engine and stream seams

**Files:**
- Create: `src/dsp/MonitorRouting.h` (header-only, pure)
- Modify: `src/wdsp_engine.h`, `src/wdsp_engine.cpp`, `src/hl2_stream.h`, `src/hl2_stream.cpp`
- Test: `scratch/test_practice.cpp` (add the routing cases; add the header to the target)

**Interfaces:**
- Produces:
  - `namespace lyra::dsp { struct MonitorRoute { bool fillTap, local, remote; }; constexpr MonitorRoute routeMonitor(bool monEnabled, bool txMuted, bool practice); }`
    - `fillTap = monEnabled || practice`
    - `local = (monEnabled && txMuted) || practice`
    - `remote = monEnabled && txMuted`
  - `WdspEngine::setPracticeActive(bool on)` (Q_INVOKABLE, GUI thread) stores the atomic `practiceActive_` and nothing else. The ring is never touched from the GUI thread; the audio thread flushes it whenever neither route is active, as it does today. Add `bool practiceActive() const`.
  - In `dispatchAudioFrame`:
    - Drain `monScratch_` when `route.local || route.remote`.
    - Route 1 (the output loop) uses `route.local`.
    - Route 2 (VAC) and Route 3 (TCI) use `route.remote` in place of today's `monActive`.
    - While practice runs, RX audio on the local output is replaced by the monitor, exactly as the MOX monitor path does today.
  - In `txMonitorTapCb`: fill when `route.fillTap`.
  - Coach feed: while `practiceActive_`, feed `monScratch_` (mono) with `agcGainDb = 0.0` in place of RX audio. Keep the voice-mode NaN gate. Apply `coachTxGated()` as today; a keyed practice has already stopped.
  - `HL2Stream`:
    - `std::atomic<bool> keyIntent_`, set to `on` as the **first** statement of `requestMox(bool, PttSource)`, before the inhibit checks.
    - `bool keyIntentOrMox() const noexcept` returns `keyIntent_ || moxActive()`. If `moxActive()` is not lock-free, read the existing atomic behind it.

- [ ] **Step 1: Write the failing tests** (`test_practice`):
  - `routing_mon_off_idle`: (false, false, false) → all false.
  - `routing_mox_monitor`: (true, true, false) → fillTap, local and remote all true.
  - `routing_practice_local_only`: (false, false, true) and (true, false, true) → fillTap, local; remote false.
  - `routing_mon_on_rx`: (true, false, false) → fillTap only.
- [ ] **Step 2:** The build fails (missing header).
- [ ] **Step 3: Implement** the header, then wire it into the engine and stream as specified.
- [ ] **Step 4:** `cmake --build build --target test_practice && ./build/test_practice` passes. `cmake --build build --target lyra` builds with no new warnings in `wdsp_engine.cpp` or `hl2_stream.cpp`. `cmake --build build --target test_essb_coach test_eq_analyzer && ./build/test_essb_coach && ./build/test_eq_analyzer` still pass.
- [ ] **Step 5: Checkpoint.**

### Task 4: Coach practice mode

**Files:**
- Modify: `src/essbcoachmodel.h`, `src/essbcoachmodel.cpp`, `src/essbcoachreport.h`, `src/essbcoachreport.cpp`, `docs/essb-coach-report.md`
- Test: `scratch/test_essb_report.cpp`

**Interfaces:**
- Consumes: `CoachAnalyzer::startRecheck/stopRecheck/reset`, `CoachSnapshot`.
- Produces on `EssbCoachModel`:
  - `Q_PROPERTY(bool practice READ practice NOTIFY updated)`
  - `void setPracticeMode(bool on);` enters or leaves practice. Both edges call `reset()`, so neither RX nor practice data carries across.
  - `void practicePassStarted();` posts `startRecheck()` on the analyzer.
  - `void practicePassEnded(int side, bool clean);` posts `stopRecheck()`. When clean, the next snapshot whose `recheck == Stopped` copies `recheckDb`, `recheckComp` and `recheckSpeechSec` into the store for `side` (0 = A, 1 = B). A dirty pass copies nothing.
  - `void clearPracticeSide(int side);` (B edits).
  - `void setTxEdgesProvider(std::function<std::pair<double,double>()> fn);` gives the live TX low and high edges (Hz).
- Behaviour while `practice`:
  - `view_.baselineDb` and `comp` come from store A; `view_.recheckDb` and `recheckComp` come from store B. The advisor and the graph read `view_` as they do today.
  - `rxLowHz`/`rxHighHz` come from the TX edges provider.
  - The splatter map's status is `"practice"`, and the panel shows "Not measured in practice".
  - The baseline and re-check buttons are disabled; Reset leaves practice (the panel calls `PracticeLoop.stop()`).
  - The report gets `source: "practice"`; it is `"rx"` otherwise. Report schema version stays 1, and the field is documented in `docs/essb-coach-report.md`.
- Ruling carried from the spec: a side's curve is its **most recent clean pass**. Every pass plays identical audio, so averaging several passes adds nothing.

- [ ] **Step 1: Write the failing test** in `scratch/test_essb_report.cpp`: `report_source_field` — a report built with source "practice" has `"source":"practice"`, and the default is `"rx"`.
- [ ] **Step 2:** It fails to build.
- [ ] **Step 3: Implement** the report field, then the model practice mode.
- [ ] **Step 4:** `cmake --build build --target test_essb_report test_essb_coach lyra && ./build/test_essb_report && ./build/test_essb_coach` all pass, and `lyra` builds.
- [ ] **Step 5: Checkpoint.**

### Task 5: `PracticeLoop` controller

**Files:**
- Create: `src/tx/PracticeLoop.h`, `src/tx/PracticeLoop.cpp`
- Modify: `CMakeLists.txt` (add the sources to the `lyra` target next to `VoiceKeyer.cpp`)

**Interfaces:**
- Consumes:
  - Task 1: `loop`, `setRefuseFn`, `passCount`, `clipSamples`.
  - Task 2: `RackAbSwitch`, `PracticePassTracker`.
  - Task 3: `setPracticeActive`, `keyIntentOrMox`.
  - Task 4: the coach practice API.
  - Existing: `ClipRecorder::start(Source::Mic, 30*48000)/full()/stop()/durationMs()`, `ClipBank::addFromSamples(label, ClipBank::Voice, samples)`, `ClipBank::loadSamples(id)`, `ProfileManager::activeName()/storedProfile()/saveActive()`, `VoiceKeyer::player()/recorder()/recording()/playingId()`.
- Produces: `class PracticeLoop : public QObject` (namespace `lyra::tx`), a QML context property `Practice`:
  - `Q_PROPERTY`s, all NOTIFY `changed`:
    - `bool recording`, `int recordMs`, `bool looping`, `QString clipId`
    - `int side` (0 A / 1 B), `bool abAvailable`, `QString note`
    - `double progress`, `int passes`
  - `Q_INVOKABLE`:
    - `startRecord()`, `stopRecord()`
    - `play(const QString &clipId)`, `stop()`
    - `flip()`, `save()`
  - `void noteRackEdit();` (connected to the rack models' change signals)
  - `void onKeyIntent();` (connected to `HL2Stream::moxIntentPulse`, which calls `stop()`)
  - Constructor seams: `std::function<bool()> canRun` (HL2 present, voice mode, radio streaming, not keyed); `std::function<RackState()> captureRack` and `std::function<void(const RackState&)> applyRack`.
- Behaviour:
  - `startRecord` is refused while looping, while the voice keyer is recording or playing, or while `!canRun()`. A refusal from `!canRun()` sets the note "Practice needs the HL2 connected, receiving, and a voice mode."
  - Recording honours the voice keyer's get-set countdown (`VoiceKeyer::recordDelaySec()`, 0/5/10 s) with PracticeLoop's own timer. It does not change any voice keyer setting.
  - It records from the selected mic source. The label is `"Practice: <profile or 'no profile'> (<micSource>) yyyy-MM-dd HH:mm"`, which shows which source was recorded.
  - A 50 ms poll auto-stops at `full()`.
  - A clip under 10 s gives the too-short note and is not saved.
  - `play`:
    - It is refused unless `canRun()` holds and the voice keyer is idle.
    - It calls `player()->setRefuseFn([stream]{ return stream->keyIntentOrMox(); })` and then plays with `{ota=false, loop=true, bypassDsp=false, gainLin = 10^(clipGainDb/20)}`.
    - It calls `engine->setPracticeActive(true)` and `coach->setPracticeMode(true)`.
    - It starts A/B with `begin(stored active profile's rack)` when there is an active profile. Otherwise `abAvailable` is false and the note is "Save a profile first to use A/B."
  - The 50 ms poll:
    - When `passCount()` advances: `tracker.onPassEnd()` → `coach->practicePassEnded(side, clean)`; then `onPassStart(side)` and `coach->practicePassStarted()`.
    - When the player goes inactive unexpectedly (refused), it calls `stop()` with the note "Stopped — the radio keyed."
  - `flip`: `ab.flip()`, `tracker.onFlip()`.
  - `noteRackEdit`: when `ab.noteEdit()` returns true, `tracker.onEdit()` and `coach->clearPracticeSide(1)`.
  - `save`: `profiles->saveActive()`, `ab.setA(captureRack())`, `coach->clearPracticeSide(0)`. The store for A is re-filled by the next clean pass.
  - `stop` (idempotent):
    - It calls `player()->stop()`, `ab.end()`, `engine->setPracticeActive(false)` and `coach->setPracticeMode(false)`.
    - It clears the refuse fn and resets the tracker.
  - `stop` also runs on any of these:
    - a profile `activeChanged`;
    - a mode change away from a voice mode;
    - the coach dock closing;
    - destruction.

- [ ] **Step 1:** `cmake --build build --target lyra` builds with `PracticeLoop` compiled in. It is not yet wired.
- [ ] **Step 2: Checkpoint.** The logic is covered by Tasks 1–2 tests; integration is checked in Task 6.

### Task 6: Wiring, Practice UI and docs

**Files:**
- Modify: `src/mainwindow.h`, `src/mainwindow.cpp`, `src/main.cpp` (only if the rack signal connections must live there), `src/qml/EssbCoachPanel.qml`, `docs/help/USER_GUIDE.md`, `src/helpdialog.cpp` (only if the help index lists coach sections)

**Interfaces:**
- Consumes: `PracticeLoop` (Task 5).
- `MainWindow` constructs `PracticeLoop` after `voiceKeyer_`, `clipBank_` and `essbCoachModel_` exist, and supplies these seams:
  - **Keying:** `canRun` uses `qobject_cast<HL2Stream*>(stream_)`, `CoachAdvisor::isVoiceMode(current mode)`, "streaming" (the same condition the coach uses for "radio connected") and `!keyIntentOrMox()`. Connect `HL2Stream::moxIntentPulse` → `PracticeLoop::onKeyIntent`.
  - **Rack A/B:** `captureRack`/`applyRack` go through the four model `instance()` `saveState`/`loadState` calls. The rack change signals (the same set wired to `refreshModified` in `main.cpp` ~1609–1631) go to `noteRackEdit`.
  - **Coach:** `setTxEdgesProvider` returns the live TX low edge and high edge (TX low + TX bandwidth from Prefs / the stream).
  - **QML:** register the context property `Practice`.
- `EssbCoachPanel.qml` Practice section, beside the graph:
  - controls: clip picker (ClipBank Voice clips, newest first), Record/Stop record with the seconds counter, Loop/Stop, an `A | B` toggle, Save;
  - status: the note line, plus the source line "Practice: post-rack TX" or "RX1";
  - the line "Mic gain and PHROT are not in the loop."
  - Lit style `#ff9a3c` on `#3a2a14` for Loop, Record and the active side.
- `USER_GUIDE.md` gets a "Practice loop" subsection under the eSSB Coach section. It covers:
  - record 10–30 s, loop, headphones, A/B, Save;
  - the radio never transmits the clip;
  - the leveler, ALC and TX filter are not in the loop.

- [ ] **Step 1: Implement** the wiring and QML.
- [ ] **Step 2:** `cmake --build build --target lyra` builds; `open build/lyra.app` loads with no QML warnings for `EssbCoachPanel.qml`.
- [ ] **Step 3:** All test targets pass: `cmake --build build --target test_clip_player test_practice test_essb_coach test_essb_report test_eq_analyzer`, then run each.
- [ ] **Step 4: In-app check (needs the operator's off-air go-ahead before relaunching Lyra):**
  1. Open the coach and record 12 s; the clip appears in the picker.
  2. Loop it; it is audible in the headphones with MON off.
  3. Flip A and B; the two curves appear after one full pass each.
  4. An edit on B clears B's curve.
  5. Save; then press MOX (dummy load or off-band, with the operator's approval). The loop stops at once and the note says the radio keyed.
  6. With TCI connected, the TCI audio stays RX throughout.
- [ ] **Step 5:** Build the DMG from a copy, so the running app is untouched:
  - `ditto build/lyra.app build-dmg/lyra.app`
  - `tools/package_macos.sh build-dmg/lyra.app`
  - `APP=build-dmg/lyra.app tools/make_dmg.sh` → `dist/Lyra-<ver>-arm64.dmg`

  Then mount it and verify: the codesign check passes, there are no Homebrew paths, it is arm64, and the version is right.
- [ ] **Step 6: Checkpoint.**
