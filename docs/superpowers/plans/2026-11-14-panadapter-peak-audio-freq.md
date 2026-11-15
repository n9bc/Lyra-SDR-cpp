# Panadapter Peak Audio-Frequency Labels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each labeled panadapter peak show its audio frequency, as a toggle independent of the existing dB label.

**Architecture:** Reuse the existing in-passband top-3 peak detection in `Panadapter::onFrame`. Add a pure, Qt-light helper pair (`peakAudioHz`, `formatPeakHz`) so the frequency math and formatting are unit-tested away from the Qt item. Add a second Prefs toggle (`peakShowAudioHz`) mirroring `peakShowDb`; build the label list when *either* toggle is on, carry a formatted `hzText` per entry, and render it in QML under the dB number.

**Tech Stack:** C++17, Qt 6 (Core/Gui/Quick), QML. Build: `cmake --build build --target <t>`.

**Spec:** `docs/superpowers/specs/2026-11-14-panadapter-peak-audio-freq-design.md`

## Global Constraints
- Target `arm64` locally, Linux `x86_64` in prod (no arch-specific code here).
- Do not change peak detection, the in-passband restriction, or the top-3 count.
- Existing `peakShowDb` behaviour unchanged when the new toggle is off.
- New Prefs key: `panadapter/peakShowAudioHz`, default `false`.
- Audio-frequency magnitude only: `audioHz = |(frac − 0.5) × span|`; `span` = `spanHz()` (RX1) or `iqRateHz()` (RX2).
- Commit only on the operator's "commit it".

## Review Focus
- **Signal at zero-beat (frac = 0.5):** audio frequency is `0 Hz`, shown as `0 Hz`, never blank/NaN. → Task 1.
- **Degenerate span (span ≤ 0, e.g. engine stopped):** `peakAudioHz` returns `0.0`, no divide/NaN. → Task 1.
- **Format boundary (exactly 1000 Hz, and < 10 Hz):** `formatPeakHz` gives sensible text on both sides of the Hz/kHz switch. → Task 1.
- **Corrupt stored toggle value:** loads as `false` (default). → Task 2.
- **Both toggles off:** no labels built and `peakLabels` cleared, exactly as today. → Task 3.

---

### Task 1: Pure peak-math helpers

**Files:**
- Create: `src/panadapter_peakmath.h`, `src/panadapter_peakmath.cpp`
- Test: `scratch/test_panadapter_peakmath.cpp`
- Modify: `CMakeLists.txt` (add helper to the `lyra` target sources; add `test_panadapter_peakmath` EXCLUDE_FROM_ALL target linking `Qt6::Core` only)

**Interfaces:**
- Produces:
  - `double lyra::peakAudioHz(double frac, double spanHz) noexcept;` — `std::fabs((frac − 0.5) * spanHz)`, returns `0.0` when `spanHz <= 0`.
  - `QString lyra::formatPeakHz(double hz);` — `< 1000`: nearest-10 `"NNN Hz"`; `>= 1000`: one-decimal `"N.N kHz"`. (Threshold/rounding is the operator's call to refine — see design "left to the builder".)

- [ ] **Step 1: Write the failing test** `scratch/test_panadapter_peakmath.cpp` (plain `main()` + `expect` helper, like `scratch/test_audio_vis_core.cpp`):
  - `peakAudioHz(0.5, 4000) == 0`
  - `peakAudioHz(0.75, 4000) == 1000` and `peakAudioHz(0.25, 4000) == 1000` (magnitude)
  - `peakAudioHz(0.65, 6000) == 900`
  - `peakAudioHz(0.75, 0) == 0` and `peakAudioHz(0.75, -4000) == 0` (degenerate span guard)
  - `formatPeakHz(650) == "650 Hz"`, `formatPeakHz(648) == "650 Hz"` (nearest 10)
  - `formatPeakHz(0) == "0 Hz"`, `formatPeakHz(5) == "0 Hz"` or `"10 Hz"` per the rounding chosen — assert the chosen value
  - `formatPeakHz(1000) == "1.0 kHz"`, `formatPeakHz(1234) == "1.2 kHz"`, `formatPeakHz(2900) == "2.9 kHz"`
- [ ] **Step 2: Run to verify it fails:** `cmake --build build --target test_panadapter_peakmath` → fails to compile (no header).
- [ ] **Step 3: Implement** `peakAudioHz` and `formatPeakHz` in `src/panadapter_peakmath.{h,cpp}` per the Interfaces block.
- [ ] **Step 4: Run** `cmake --build build --target test_panadapter_peakmath && ./build/test_panadapter_peakmath` → all pass, exit 0.
- [ ] **Step 5: Commit** (stage the two sources, the test, `CMakeLists.txt`; wait for "commit it"): `feat(pan): peak audio-frequency + label format helpers`.

---

### Task 2: Prefs `peakShowAudioHz` toggle

**Files:**
- Modify: `src/prefs.h` (property near `peakShowDb`, getter/setter/signal, member), `src/prefs.cpp` (key constant near `kPkShow`, load in ctor, setter)
- Test: `scratch/test_prefs_peaklabel.cpp`
- Modify: `CMakeLists.txt` (add `test_prefs_peaklabel` target, mirroring `test_prefs_visualizer`'s source/link list)

**Interfaces:**
- Consumes: Task 1 (none directly).
- Produces: `bool Prefs::peakShowAudioHz() const;` / `void Prefs::setPeakShowAudioHz(bool);` / `void peakShowAudioHzChanged();`. Key `panadapter/peakShowAudioHz`, default `false`.

- [ ] **Step 1: Write the failing test** `scratch/test_prefs_peaklabel.cpp` (redirect `QSettings` to a `QTemporaryDir` + private org/app, like `scratch/test_prefs_visualizer.cpp`): default `peakShowAudioHz()==false`; `setPeakShowAudioHz(true)` then reload → `true`; a pre-seeded garbage `panadapter/peakShowAudioHz="xyz"` loads as `false`; `peakShowDb` default/behaviour unchanged by the new key.
- [ ] **Step 2: Run** `cmake --build build --target test_prefs_peaklabel` → fails (no symbol).
- [ ] **Step 3: Implement** the property following the `peakShowDb` pattern (constant `kPkShowHz = "panadapter/peakShowAudioHz"`, `peakShowAudioHz_` loaded with `s.value(kPkShowHz, false).toBool()`, setter guards + persists + emits).
- [ ] **Step 4: Run** `./build/test_prefs_peaklabel` → all pass; `cmake --build build --target lyra` still compiles.
- [ ] **Step 5: Commit** (wait): `feat(pan): peakShowAudioHz preference`.

---

### Task 3: Build audio-frequency into the peak labels

**Files:**
- Modify: `src/panadapter.h` (`peakShowAudioHz` property + setter + signal + `bool peakShowAudioHz_ = false;`), `src/panadapter.cpp` (include `panadapter_peakmath.h`; setter; the label-build block)

**Interfaces:**
- Consumes: Task 1 (`peakAudioHz`, `formatPeakHz`), Task 2 (Prefs toggle, bound in Task 4).
- Produces: each `peakLabels` entry gains `audioHz` (raw double) and `hzText` (QString). Label list is built when `peakEnabled_ && (peakShowDb_ || peakShowAudioHz_)`.

- [ ] **Step 1:** Add the `peakShowAudioHz` property to `src/panadapter.h` mirroring `peakShowDb` (lines ~122/196/222/272), and `setPeakShowAudioHz(bool)` in `.cpp` mirroring `setPeakShowDb` — on turning it off while `peakShowDb_` is also off, clear `peakLabels_` and emit (same guard as `setPeakShowDb`).
- [ ] **Step 2:** In `onFrame` change the label-build guard from `peakEnabled_ && peakShowDb_` to `peakEnabled_ && (peakShowDb_ || peakShowAudioHz_)`, and the empty-clear `else` branch to fire when neither is on.
- [ ] **Step 3:** In the per-peak `QVariantMap m`, after `frac`/`db`, compute `span` (`receiver_ == 2 ? engine_->iqRateHz() : engine_->spanHz()`), then `m["audioHz"] = lyra::peakAudioHz(frac, span); m["hzText"] = lyra::formatPeakHz(m["audioHz"].toDouble());`.
- [ ] **Step 4: Build:** `cmake --build build --target lyra` → compiles clean. Re-run `./build/test_panadapter_peakmath` and `./build/test_prefs_peaklabel` → still pass.
- [ ] **Step 5: Commit** (wait): `feat(pan): carry peak audio frequency in the label model`.

---

### Task 4: UI — Settings toggle + QML Hz label

**Files:**
- Modify: `src/settingsdialog.cpp` (~10811, after the `Show dB` checkbox)
- Modify: `src/qml/PanadapterPanel.qml` (item binding ~381; label `Repeater` delegate ~889), `src/qml/Rx2PanadapterPanel.qml` (item binding ~168; and its label delegate if it renders `peakLabels`)

**Interfaces:**
- Consumes: Task 2 (`Prefs.peakShowAudioHz`), Task 3 (`peakShowAudioHz` item property, `modelData.hzText`).

- [ ] **Step 1:** In `src/settingsdialog.cpp` add a `QCheckBox(tr("Show audio frequency"))` right after `pShow`, wired to `Prefs::peakShowAudioHz` / `setPeakShowAudioHz` with the same two-way guard as `pShow` (lines 10811–10816).
- [ ] **Step 2:** Bind `peakShowAudioHz: Prefs.peakShowAudioHz` on the panadapter item in both `PanadapterPanel.qml` (~381) and `Rx2PanadapterPanel.qml` (~168).
- [ ] **Step 3:** In the peak-label `Repeater` delegate of `PanadapterPanel.qml` (~889), keep the dB `Text` visible only when `Prefs.peakShowDb`, and add a second `Text` showing `modelData.hzText`, visible when `Prefs.peakShowAudioHz`, placed directly under the dB number at the same `x` (when dB is off, it takes the dB slot). Use the same font/outline. Apply the same to the RX2 delegate if present.
- [ ] **Step 4: Build + launch:** `cmake --build build --target lyra`; run the app, enable Peak Hold + "Show audio frequency", and confirm a peak at a known offset reads the expected Hz on USB, LSB and CW, with "Show dB" independently on/off. Record what was and wasn't verified (no bench radio ⇒ verify against the demo/stub spectrum or a live signal if available).
- [ ] **Step 5: Commit** (wait): `feat(pan): show audio frequency on panadapter peak labels`.

---

## Self-Review notes
- **Spec coverage:** two independent toggles (Tasks 2+4), formula (Task 1), in-passband reuse (Task 3 keeps existing detection), RX1/RX2 span (Task 3 Step 3, Task 4 Step 2), persistence (Task 2), Display-panel checkbox (Task 4 Step 1). ✓
- **Review Focus → tests:** zero-beat & degenerate span & format boundary in Task 1; corrupt toggle in Task 2; both-off in Task 3 Step 2 (logic) verified at Task 4 Step 4.
- **Type consistency:** `peakAudioHz`/`formatPeakHz` signatures identical in Task 1, 3. Model keys `audioHz`/`hzText` defined in Task 3, consumed in Task 4.
- **Out of scope (design non-goals):** audio-visualizer removal is a separate later task.
