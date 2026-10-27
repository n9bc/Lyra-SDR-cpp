# eSSB Coach measurement report (schema version 1)

Written by `lyra::coachreport::buildReport` (`src/essbcoachreport.cpp`). While
the session recorder is running, every Stop of a Baseline or Re-check writes
`coach-<n>-<baseline|recheck>.json` into the recording's session folder (n counts
from 1 per recording). In the practice loop (`source: "practice"`) one report is
written on request (`EssbCoachModel::writePracticeReport`, before a Save) with
side A in the baseline fields and side B in the re-check fields; it is named and
labelled `recheck` when B has a curve, else `baseline`. There is no separate target file: every report carries the
target it was compared against (`target`, `targetId`, `targetDb`, `tolDb`).

Phase 2 sends this report, not the audio, with Lyra's control list and ranges to
an AI service for parameter suggestions. Phase 2 must tell the user when a report
leaves the machine.

NaN / not-measured values are written as `null`, and so are readings the panel
withheld (`compression` when `conditions.agcFallback` is true; `splatter` numbers
unless `splatter.status` is `measured` or `pending`) and finding fields a kind
does not use (see Findings). Arrays of per-band values are index-aligned with
`bandsHz`. Units: Hz is audio frequency (absolute, 0 = carrier) unless the field
says baseband offset; curve dB values (`baselineDb`, `recheckDb`, `targetDb`,
`zones[].deviationDb`, `zoneDeltas[].db`) are relative: curves are normalised so
the mean of the bands centred in 500-2000 Hz is 0; dBFS is decibels relative to
digital full scale.

Everything is measured on **RX1 of the local radio**: the audio is RX1's demodulated
audio after our AGC (before our RX EQ), the splatter spectrum is RX1's IQ. Both
describe the *other* station's signal. Nothing is taken while we transmit: from
the TR-settled key-down edge (about 65 ms after the key, with default T/R
delays) until 300 ms after RX audio resumes the audio counts as no information
and the splatter meter is not fed (it restarts on each key edge). Audio received
while RX1 is not in a voice mode (USB, LSB, DSB, AM, SAM) is no information too.

| Field | Type | Unit | Meaning |
|---|---|---|---|
| `version` | int | | Schema version, `1`. |
| `app` | string | | `"Lyra eSSB Coach"`. |
| `promoted` | bool | | The baseline was replaced by a re-check via Make baseline. `snrDb` and `bandSnrDb` still come from the original baseline in that case. |
| `recording` | string | | `"baseline"` or `"recheck"`: which recording this report is for. |
| `createdUtc` | string | ISO-8601 UTC | When the report was written. |
| `freqHz` | number | Hz | RX1 frequency at that moment. |
| `adviceFor` | string | | `"lyra"` (names Lyra controls) or `"other"`. |
| `source` | string | | What was measured: `"rx"` (RX1 audio and IQ, the other station; everything else on this page) or `"practice"` (eSSB practice loop: our own recorded clip after Lyra's TX rack, never transmitted). In a practice report `baselineDb` is side A's curve and `recheckDb` side B's, each from that side's most recent clean loop pass; `speechSec`/`compression` are that side's; AGC is not involved (gain 0 dB, so `agcFallback` is false); `conditions.rxLowHz`/`rxHighHz` are the live TX filter edges, `nrOn`/`anfOn` are false, and `splatter.status` is `practice` (not measured, numbers `null`). Added within schema version 1; a report without the field is `"rx"`. |
| `target` | object | | `{id, name, builtin, lowEdgeHz, highEdgeHz}` of the target compared against. |
| `targetId` | string | | Same as `target.id`. |
| `bandsHz` | number[] | Hz | 1/6-octave band centres, 40 Hz-12 kHz. |
| `baselineDb` | number[] | dB | Baseline curve per band; `[]` = none. |
| `recheckDb` | number[] | dB | Re-check curve per band; `[]` = none. |
| `targetDb` | number[] | dB | Target level at each band centre. |
| `tolDb` | number[] | dB | Target tolerance (+-) at each band centre. |
| `speechSec` | number | s | Gated speech time of this recording. |
| `snrDb` | number | dB | Median in-band SNR (100-5000 Hz) of the baseline (the original one when `promoted`). |
| `bandSnrDb` | number[] | dB | SNR per band (speech power over noise power); `[]` = unknown. |
| `edges` | object | | `{lowHz, highHz, lowBeyondRx, highBeyondRx, tier}`: measured -20 dB edges in Hz (band centres); `*BeyondRx` = within one 1/6-octave band of our RX filter edge, so limited by it; `tier` = id of the nearest built-in target. |
| `zones` | object[] | | Per tonal zone: `{zone, loHz, hiHz, deviationDb, toleranceDb}`. `zone` is `bass`, `lowMid`, `body`, `upper` or `top`; `loHz`/`hiHz` in Hz; `deviationDb` (dB) = mean(curve - target) over bands inside the RX filter (`null` = none usable) for this recording's curve; `toleranceDb` (dB, +-) at the zone's centre. |
| `zoneDeltas` | object[] | | Re-check minus baseline per zone: `{zone, db}` (dB); `[]` unless both curves exist. |
| `compression` | object | | `{gapToSpeechDb, gapRiseDb, crestDb, pauses}` for this recording, from 10 ms RMS levels of the 100-5000 Hz audio with our AGC removed: `gapToSpeechDb` (dB) = median speech level minus median gap level; `gapRiseDb` (dB) = median level rise from 0-150 ms to 650-800 ms into pauses of 800 ms or more; `crestDb` (dB) = 99th-percentile minus median speech level; `pauses` (count) = pauses scored. The three dB fields are `null` when not measured or when `conditions.agcFallback` is true (withheld, as on the panel); `pauses` is always the count. |
| `splatter` | object | | From RX1's IQ spectrum (the other station's signal, not our TX): `{status, valid, alert, peakDb, outDb, marginDb, noiseDb, shiftHz, sideband, edgeHz}`. `status`: `measured` (valid result), `pending` (fed, but under 3 s since a restart, no signal 10 dB above the floor, or the out window does not fit the IQ span), `stale` (nothing fed for 1 s: we were transmitting, or the tap stopped), `am` (not measured in AM/SAM: a carrier-dominated, one-sided reading would not alert honestly) or `practice` (not measured in the practice loop: there is no TX filter in the loop). Numbers are `null` unless `measured` or `pending`. `peakDb` = strongest 100 Hz band inside the channel, `outDb` = strongest 100 Hz band in the out window, `noiseDb` = median 100 Hz band over the IQ span (all dBFS, band power, 1 s average); `marginDb` (dB) = `peakDb` - `outDb`; `alert` = valid, margin < 35 dB and `outDb` at least 6 dB above `noiseDb`. Channel handed to the meter: `shiftHz` (Hz, offset of the carrier in the complex baseband, our RX shift), `sideband` (`usb`/`lsb`), `edgeHz` (Hz, channel width = the target's high edge); USB channel `[shiftHz, shiftHz+edgeHz]`, out window `[shiftHz+edgeHz+500, shiftHz+edgeHz+3000]`, mirrored to negative offsets for LSB; `shiftHz`/`edgeHz` are `null` before the first channel. |
| `conditions` | object | | Receive path during the measurement: `{rxLowHz, rxHighHz, nrOn, anfOn, agcMode, mode, agcCorrected, agcFallback}`. `rxLowHz`/`rxHighHz` = our RX1 audio passband in Hz (AM/DSB: 0 to half the filter width). `agcCorrected` = our own AGC's gain was removed from the compression readings. `agcFallback` = AGC correction was not applied, so the compression readings were withheld (written `null`): either AGC was on without correction (prebuilt WDSP, resync), or AGC was Off but a post-AGC stage of unknown delay ran. With AGC Off and no such stage, both are false on prebuilt-WDSP builds and the readings are valid (our gain is fixed). |
| `thresholds` | object | | Flag thresholds in force: `{minSpeechSec (s), minSnrDb (dB), gapToSpeechDb (dB), gapRiseDb (dB), crestDb (dB)}`. |
| `findings` | object[] | | The advice items: `{kind, zone, hz, db, value, value2, control, text}`. |

## Findings

`kind` is one of `RxFilterTooNarrow`, `NrOn`, `AnfOn`, `NotVoiceMode`,
`NeedMoreSpeech`, `SignalTooWeak`, `Bandwidth`, `ToneHeavy`, `ToneThin`,
`NoiseBetweenWords`, `Pumping`, `Squashed`, `Splatter`. `zone` is set only for tone
findings and `RxFilterTooNarrow` (`bass` = low edge, `top` = high edge), `null`
otherwise. `hz` is set only for tone findings, `db` only for tone and `Splatter`;
`value`/`value2` are `null` for `NrOn`, `AnfOn` and `NotVoiceMode`. Empty cells
below are `null`.
`control` names the Lyra control the advice points at (`"TX EQ"`,
`"Combinator"`, `"Noise Gate / Auto-AGC"`), or `""`. `text` is the sentence the
panel showed.

| kind | hz | db | value | value2 |
|---|---|---|---|---|
| `ToneHeavy` / `ToneThin` | worst band centre, Hz | rounded signed zone mean, dB | zone mean, dB | zone tolerance, dB |
| `Bandwidth` | | | low edge, Hz | high edge, Hz |
| `RxFilterTooNarrow` (`bass`) | | | RX low edge, Hz | target low edge, Hz |
| `RxFilterTooNarrow` (`top`) | | | RX filter width, Hz (the RX BW control's number) | suggested width, Hz |
| `NeedMoreSpeech` | | | speech, s | required, s |
| `SignalTooWeak` | | | median SNR, dB (`null` = no estimate) | required, dB |
| `NoiseBetweenWords` | | | gap-to-speech, dB | threshold, dB |
| `Pumping` | | | gap rise, dB | threshold, dB |
| `Squashed` | | | crest, dB | threshold, dB |
| `Splatter` | | rounded margin, dB | `peakDb`, dBFS | `outDb`, dBFS |
| `NrOn` / `AnfOn` / `NotVoiceMode` | | | | |

`RxFilterTooNarrow` (`top`) fires when the RX high edge is not above the target's
high edge times 2^(1/6) (one 1/6-octave band of guard: below that, the band holding
the target's high edge is not wholly inside the filter and a measured edge there
reads as limited by the filter). The suggested width is the smallest RX BW preset
Lyra offers in the current mode whose high edge clears that (SSB 1.5-10 kHz, DSB
3-10 kHz, AM 3-20 kHz; in AM/DSB the width is twice the high edge), or, past the
largest preset, the needed width rounded up to the next 100 Hz. Example: the eSSB
target (6000 Hz) needs a high edge above 6735 Hz, so USB suggests 8000 Hz.

Post-AGC level changes (AF gain, squelch) are not removed by the AGC correction;
hold them steady while measuring.
