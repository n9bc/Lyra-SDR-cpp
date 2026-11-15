# Panadapter peak labels — add audio-frequency readout

*Design — 2026-11-14. Small change. Branch `macos-port`.*

## Intent / why
When a peak shows on the panadapter, the operator wants to know **where it
lands in the receiver audio** (a het to notch, a CW signal's pitch, a tone
to avoid) without doing the offset math in their head. Today the peak
labels show only the level in dB (`−66`, `−72`, …). This adds the peak's
**audio frequency** as a second, independently-toggled readout.

## Goals
- Each labeled peak can show its audio frequency (e.g. `650 Hz`, `1.2 kHz`).
- dB and audio-frequency are **separate toggles**: a peak can show dB only,
  Hz only, or both.
- Existing dB behaviour is unchanged when the new toggle is off.
- Works on RX1 and RX2.

## Non-goals / anti-goals
- Not changing peak detection, the in-passband restriction, or the count
  (still the top 3).
- Not removing or replacing the dB readout.
- Not touching the audio visualizer (its removal is a separate task, to be
  done *after* this lands and the operator confirms this covers the need).
- No signed/negative audio frequency; magnitude only.

## Constraints
- Reuse the existing `peakLabels` plumbing in `panadapter.cpp` (the list of
  `{frac, db}` the QML overlay already draws).
- Peaks are already restricted to the RX passband, so every labeled peak has
  a real audio frequency — no special-casing out-of-passband signals.
- Persist the new toggle in `Prefs`, following the `peakShowDb` pattern.
- Commit only on the operator's "commit it".

## The audio-frequency mapping (verified)
Panadapter centre (`frac = 0.5`) is the zero-beat / suppressed-carrier
point; `span` is the full display width in Hz (`spanHz()` for RX1,
`iqRateHz()` for RX2). The passband edges are supplied as Hz offset from
centre and are themselves the audio passband (SSB 100–2900 ⇒ 100–2900 Hz
audio), so:

```
audioHz = |(frac − 0.5) × span|
```

This is mode-independent in magnitude (USB / LSB / CW / AM) and immune to
the HL2 spectral reversal (a sign flip the magnitude discards). Confirmed
against `Panadapter::passbandPx` (same `0.5 + offset/span` mapping) and the
`markerOffsetHz` / "Centre = zero-beat" conventions in `wdsp_engine.cpp`.

## Approaches considered
1. **Compute `audioHz` inline where the peak labels are built** (chosen).
   `onFrame()` already has `frac` and the `span`; add one line, add
   `audioHz` to each label entry. Minimal, and DRY with the passband
   mapping that proves the formula.
2. Add a `WdspEngine::audioHzForOffset()` and call it from the panadapter.
   The "correct home" for frequency logic, but the mapping is one magnitude
   and the panadapter already holds `span`; extra indirection for no gain.
   Revisit only if a signed, mode-specific value is ever needed.
3. Replace dB with Hz. Rejected — the operator wants both, via toggles.

## Decisions (as agreed)
- **Two independent toggles.** `peakShowDb` (existing) and `peakShowAudioHz`
  (new). Build `peakLabels` when *either* is on; each entry carries both
  `db` and `audioHz`; the QML overlay renders whichever toggles are on.
- **Formula:** `audioHz = |(frac − 0.5) × span|`, span per receiver above.
- **New toggle** persisted in `Prefs` (`display/peakShowAudioHz`), with a
  checkbox in the Display panel next to the existing "show dB".

## Left to the builder
- Audio-frequency **formatting** (Hz vs kHz threshold, rounding step) — a
  small readability call; the operator may take this one.
- Exact two-line label layout in the QML overlay (Hz above dB, or beside).
- Display-panel checkbox wording.

## Verification
- `test_*` panadapter/prefs unit coverage for the new toggle + formula.
- Build + launch; confirm a peak at a known offset reads the expected Hz on
  USB, LSB and CW, with each toggle independently.
