# eSSB Practice Loop — design

Date: 2026-10-27. Status: draft for operator approval.
Builds on the eSSB Coach (spec `2026-10-26-essb-coach-design.md`).

## Intent

Tuning TX audio by talking into the mic is unreliable: every pass is different
speech, so you cannot tell whether a tweak helped or the words changed. The
operator wants to record 15–30 s once, loop it through Lyra's TX audio
processing, and tweak until it is the best eSSB audio Lyra can make, judged by
ear in headphones and by eye on the eSSB Coach graph against the NU9N target.
One tuning per mic (headset, XLR, built-in Mac mic), each saved as a profile.

## Goals

- Record a 15–30 s practice clip from the currently selected mic source.
- Loop it into the TX audio path in place of the live mic, **never keying the
  radio** (no RF, no MOX).
- Hear the processed result in headphones while the loop runs.
- Show the same processed audio on the eSSB Coach graph against the target.
- A/B: **A = the active profile as last saved, B = the live edits**; one control
  flips between them while the loop keeps playing. Saving makes B the new A.
- Works with the existing profile system: one profile per mic, picked manually.

## Non-goals

- No WDSP TXA in the loop: the leveler, ALC limiter, CFC and TX bandpass are
  not heard or measured. Those are checked later into a dummy load (operator
  decision: "Lyra processing should be good enough until we can test into a
  dummy load").
- No automatic profile switching when the mic/input device changes (operator:
  "I will choose the profile myself").
- No changes to the RX EQ (standing operator rule).
- No RF / dummy-load mode in this project.

## Anti-goals (a failure even if it "works")

- The clip ever reaching the air. If the radio keys for any reason while the
  loop runs, the clip must not be transmitted — live mic (or silence) only.
- A/B flip that glitches VAC/TCI routing or retunes anything outside the TX
  sound chain.
- Practice audio leaking into TCI or VAC outputs (digital apps would hear it).

## Constraints

- macOS on Apple Silicon is the operator's platform; nothing in this design is
  macOS-only, but it ships on `macos-port` with the coach.
- Voice modes only (USB/LSB/DSB/AM/SAM — the coach's `isVoiceMode`). In
  DIGU/DIGL the native rack is bypassed (`tx_rack_bypass`), so practice is
  unavailable there.
- The TX audio pump (`xcmaster` case 1) runs on the mic producer's cadence
  while the radio is connected and streaming. **Assumption for the builder to
  confirm:** it runs unkeyed (the existing record tap and monitor tap already
  run unkeyed). If the radio is not streaming, practice is disabled with a note.

## How it works — decided

### What exists and is reused

- `ClipRecorder` (Mic source) records the selected source after the VAC/TCI
  override (`CMaster.cpp` `TxMicRecordTap`).
- `ClipRecorderPlayer` injects a clip at `TxClipInject`, before the native rack
  (Speech → EQ → Combinator → Plate), so the clip is processed like live mic.
  Practice plays with `ota = false` (no key) and **bypassDsp forced false**
  (return value 1, never 2, so the rack always runs).
- `TxMonitorTap` captures the post-rack audio into `monitorRing_`;
  `dispatchAudioFrame` drains it to the output.
- `ClipBank` stores clips; practice clips are ordinary clips with a label.
- `ProfileManager` / `ProfileBindings` capture and apply live state.

### New behaviour

1. **Record.** Any mic source can be used: codec, VAC (that is how a USB or
   built-in Mac mic arrives) or TCI. The panel shows which source was
   recorded. "Record practice clip" uses the voice keyer recorder with a
   30 s cap (operator range 15–30 s; Stop ends it early). Clips under 10 s are
   rejected with a note. Saved to the ClipBank, labelled with the active
   profile name and date. The countdown option is reused.
2. **Loop.** "Loop" plays the chosen clip into the TX path, restarting at the
   end with no gap (wrap the read position instead of draining). Stop ends it.
3. **Never on air (safety).** The loop stops at the **earliest key request**
   (any PTT source — manual, HW PTT, VOX, TCI, CAT, keyer), not only at the
   TR-settled MOX edge. In addition, the injector itself returns 0 (no clip)
   on any block where MOX is requested or active while in practice mode, so a
   race cannot put the clip on air. Practice cannot start while keyed.
4. **Listening.** While practice runs, the monitor plays the post-rack audio to
   the output RX audio is set to: the HL2 jack or a PC device, whichever is
   selected (the existing output loop in `dispatchAudioFrame` already handles
   both, including the HL2 jack attenuation). It plays at the MON volume,
   regardless of the MON toggle and without MOX. The monitor tap must fill the
   ring while practice runs even if MON is off.
   - Use a **separate `practiceActive_` flag**, not `txMuted_`. `txMuted_` is the
     wire-MOX flag and also drives TCI/VAC muting and the coach's TX gating, so
     it must not change.
   - `practiceActive_` mutes RX on the local output only, and the monitor plays
     there in its place. TCI (Route 3) and VAC (Route 2) ignore it, so they keep
     carrying RX as normal and **never** carry practice audio.
5. **Coach.** While practice runs, the coach analyses the post-rack monitor
   audio instead of RX audio. A and B (below) take over the baseline and
   re-check slots for the duration; the advisor runs on B against the target,
   as it does for a re-check. Capture-as-target and report export work as
   usual, and the report records `source: "practice"`.
   - AGC compensation off (gain 0 dB); RX TX-gating not applied.
   - Splatter readout shows "not measured in practice" (no TX filter in the
     loop, so it would be meaningless).
   - The RX-edge greying uses the live TX filter edges (low edge and TX
     bandwidth as currently set), not the RX filter, and follows edits made
     during practice.
   - When practice stops, the coach returns to RX with its RX state reset.
6. **A/B.** Two curves on the coach graph: A and B, each averaged over the
   audio played while that side was active. A is drawn dimmer.
   - Flipping applies the other side's settings at the next block, so you hear
     it at once; the loop does not restart. A hard parameter swap is fine — no
     crossfade, no flushing of reverb or filter tails.
   - **Curves count whole passes only (my call):** a side's curve averages only
     complete loop passes played entirely on that side. The pass in progress
     when you flip is discarded for both sides. Both curves are always built
     from the same words, and the first one appears after one full pass.
   - **What A/B swaps (my call):** only the four rack blobs (`eq`, `speech`,
     `combinator`, `plate`). Those are the only settings that are heard in the
     loop:
     - `micGainDb` and PHROT live in WDSP TXA, which isn't in the loop.
     - `micBoost` happens before the recording, so it is already part of the clip.
     The panel notes that mic gain and PHROT aren't in the loop. Every other
     profile field stays untouched, so a flip never re-routes audio.
   - Entering A captures the live B values first; returning to B re-applies
     them exactly.
   - Any edit while on B restarts the B curve (use the same change signals
     that drive `ProfileManager::refreshModified`). Editing while on A is
     allowed and switches the display to B (the edit *is* B).
   - "Save" writes B into the active profile (`saveActive`); B becomes A.
   - Loading a different profile, or Reset, stops practice and clears both
     curves.
   - With no active profile, A/B is disabled and the panel says to save a
     profile first.

### Where it lives (my call)

A **Practice** section in the eSSB Coach panel, beside the graph: clip picker,
Record, Loop/Stop, A | B toggle, Save. The panel shows which source the graph
is reading ("Practice: post-rack TX" vs "RX1").

## Left to the builder

- Exact layout of the Practice section inside the coach panel.
- How the coach model's input switch is implemented (a second feed entry fed
  from the monitor tap, or a source flag on the existing one), provided RX
  state is not polluted by practice audio.
- How the wrap-around is added to `ClipRecorderPlayer` (a loop option on
  `PlayOptions` is the obvious place).
- Whether the monitor-ring drain for practice shares `monScratch_` or uses a
  sibling path, provided TCI/VAC routes never carry it.
- Tests: the injector refusing during a key request; the loop wrap without a
  gap; A/B restoring B exactly; coach source switching.

## Open items for later

- A dummy-load mode that includes WDSP TXA (leveler, ALC, TX filter).
- Phase 2 of the coach (AI suggestions from recordings) is separate.
