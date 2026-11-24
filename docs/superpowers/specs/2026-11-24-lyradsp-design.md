# LyraDSP — Apple Silicon DSP library extracted from WDSP 2.11

Date: 2026-11-24. Branch: `macos-port`. Status: draft for approval (revised after builder check).

Companion material:
- `docs/wdsp-review/README.md`: the verified WDSP 2.11 algorithm review (22 findings re-checked with compiled harnesses).
- WDSP 2.11 deep dive (Claude Doc): https://claude.ai/artifact/MFHN8nTMwJ8p2URa5FM9vc
- WDSP 2.11 source: `/Users/bcrier/Documents/dev/wdsp/wdsp 2.11/Source` (TAPR/OpenHPSDR-wdsp).

## 1. Intent

Build **LyraDSP**, a DSP library for the macOS build of Lyra. Its algorithms are extracted from WDSP 2.11 and rebuilt
for Apple Silicon:

- Accelerate (vDSP) replaces FFTW.
- Neural noise reduction (NNR) runs on Core ML.
- Processing never allocates or locks on the audio path.
- The verified fixes from the WDSP review are built in.

LyraDSP is not a port. It is a clean extraction with one Apple-native target.

Why:
- **WDSP was written for Windows.** It uses Win32 threading and FFTW, and it is built today through a POSIX shim
  (`third_party/wdsp_posix`) as a dynamically loaded dylib. Nothing in it uses the hardware Lyra actually runs on.
- **The review found real defects in paths Lyra uses today**, including:
  - NR2 silently switches itself off after about 1.2 s of digital silence (#0).
  - The noise blanker misses strong impulses when impulses are dense (#7).
  - The filter-design cache hangs or crashes under two threads (#11).
  - The rmatch control loop is unstable at 256-sample blocks and larger (#14).

  Owning the code is the way to fix them.
- **The Mac build currently runs WDSP 2.00** (`tools/build_wdsp_macos.sh:30`), which has no NNR. Windows ships a 2.10
  `wdsp.dll` (`src/wdsp_native.cpp:451`), so NNR is only reachable there.
- **ArcturusSDR (HamTEK) shows a WDSP-free, FFTW-free Accelerate stack is viable on the Mac.** It runs neural NR
  through ONNX Runtime, not Core ML, so the Neural Engine is an open advantage.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A drop-in replacement for the WDSP C interface that Lyra uses (section 3.2), statically linked into the macOS app.
2. The same signal chain, order, exchange timing and behaviour as WDSP 2.11 by default, with the verified bug fixes
   applied (section 7).
3. No FFTW on macOS. All FFTs and vector kernels go through Accelerate.
4. NNR on Core ML, with a measured accuracy match to WDSP's `nnet.c`.
5. No allocation, locks, logging or Objective-C messaging on the sample-processing path.
6. Every replaced block proven against the WDSP 2.11 reference by an automated test before it ships (section 8).

**Non-goals**
- Windows or Linux support. Those builds keep upstream WDSP unchanged. This follows the user's direction ("built
  specifically for Apple … will not be used for Windows") and overrides the global "production targets Linux" default
  for this library. Section 5.1 keeps the block layer free of Apple APIs anyway, as cheap insurance.
- Lyra engine changes beyond the list in section 3.5.
- A new public API for third parties.
- Rewriting Lyra-native stages before or after WDSP: captured-profile IQ NR (`src/iqstft.*`), the TX mic rack, the
  combinator and plate reverb.
- Retraining NNR models. The four shipped slots are converted as they are.
- WDSP features Lyra never reaches (section 3.3).

**Anti-goals** (a failure even if it works)
- A silent behaviour change. Any audible difference from WDSP 2.11 that isn't a listed, verified fix is a defect.
- Float32 everywhere for speed. Several blocks fail silently in float32 (section 6).
- A "big bang" swap. Every block lands one at a time, behind a reference test, with a rollback path.
- Faster on paper, worse latency or dropouts on the air.

## 3. Constraints

### 3.1 Project rules (`docs/RULES.md`)
- **Rule 1 (reference parity).** Replacing WDSP on macOS, the parity baseline, and each default-on fix are deviations
  from the reference. Each must be agreed **before code is written** and recorded in the design ledger.
- **Rule 4 (one change between benches, with rollback)** and **Rules 6 and 23 (signed mapping document and parity
  checkpoint before code)**: section 9 is shaped around them, but their granularity is open (Q1).
- **Rule 11.** Replacing WDSP's `csDSP` critical sections with atomic swaps (section 5.3) is a threading-primitive
  change and needs approval.
- **Rule 8 (wire-inert until bench-validated)** and bench-driven verification apply. TX and PureSignal need an HL2
  bench check, not just tests.
- **Licence.** WDSP is GPL (v2 or later per the headers, packaged as GPL v3+). LyraDSP is a derived work under GPL v3+,
  with per-file attribution headers in the style of RULES.md §AA ("Extracted from WDSP 2.11, Warren Pratt NR0V …").
  NOTICE.md gains an entry.

### 3.2 The interface contract
Lyra reaches WDSP through two seams. Both resolve function pointers by exact WDSP export name:
- `src/wdsp_native.{h,cpp}` (`WdspApi`): the RX engine, analyzer, notches, NNR, wisdom and impulse cache.
- `src/wire/wdspcalls.{h,cpp}`: the ported Thetis ChannelMaster (TX channel, resamplers, rmatchV, EER, PureSignal).

The contract LyraDSP must honour is:

1. **178 entry points** (Appendix A), with **identical C signatures**, including WDSP's `double*` interleaved-complex
   buffers. The ported ChannelMaster's call sites stay byte-identical to the reference.
2. **Public struct layouts the port touches directly.** These are fixed layouts, read fresh on every call:
   - `RESAMPLE`: the port writes `rsmp->in/out/size/run` between calls (`AAMix.cpp:249-253,638-641,679-680`;
     `wire/resample.h`).
   - `EER` and the struct whose `run` field the port reads (`wire/cmcomm.h:137-156`; `Network.cpp:127`,
     `NetworkProto1.cpp:74`).

   The builder lists every such struct in Phase 1.
3. **Version gate.** `GetWDSPVersion()` must return 211. Lyra picks the `GetPSDisp` argument form by checking
   `>= 200` (`wdspcalls.cpp:105,188`, `PsFsm.cpp:352`).
4. **Exchange timing.** `fexchange0`, `SetChannelState` and the iobuffs ring semantics must match WDSP exactly: when
   output becomes available, how many calls a block hand-off takes, and the flush and drain behaviour. The eSSB Coach
   models this timing (`src/wdsp_engine.cpp:5400-5440`, `lyra::dsp::coach::RxaAgcModel`), as well as post-AGC stage
   latencies such as EMNR at position 1 (3072 samples) and bp1 (2047.5).
5. **New symbols** are added only when ported code first calls them (the existing seam rule).

Channel configurations in use:

| Channel | in rate | DSP rate | out rate | in_size | dsp_size | block | Source |
|---|---|---|---|---|---|---|---|
| RX1 / RX2 | 192 kHz (HL2 default) | 48 kHz | 48 kHz | 1024 | 4096 | cfg | `src/wdsp_engine.h:95-99` |
| TX (ChannelMaster) | xcm_inrate | 96 kHz | ch_outrate | xcm_insize | 4096 | 1 | `src/wire/CMaster.cpp:201` |

Other input rates (48k–384k, and more for P2 radios) must work. The table shows the defaults.

### 3.3 Scope of blocks
In scope: every block that `create_rxa`/`create_txa` instantiate (it must behave identically even while its run flag is
off), plus the external blocks Lyra calls directly:
- analyzer
- resample and resampleFV
- rmatchV
- EER
- divEXT
- nobEXT
- PureSignal (`calcc`, `iqc`, `nurbs*`, `extrapolate`, `lmath`)
- NNR
- impulse cache

Blocks reachable only through entry points outside the 178 may be extracted mechanically, without optimisation. The
builder lists them in Appendix B during Phase 1.

### 3.4 Platform
- Apple Silicon only. The chip and macOS floors are open question Q2.
- The `lyra` binary sets no deployment target today (it inherits the build host's, minos 27.2). Observatory targets
  macOS 14 (`CMakeLists.txt:921`). Stateful Core ML models and BNNS Graph need macOS 15. LyraDSP's floor is therefore
  at least macOS 15, and Phase 0 sets an explicit deployment target.
- Toolchain: the project's clang and CMake. C++23 inside the library, with an `extern "C"` interface layer.
- Frameworks: Accelerate (vDSP, vForce), Core ML, Darwin pthreads and QoS. **No new runtime dependencies.** The
  model-conversion tools in 5.5 are a separate, approval-gated build-tool question.

### 3.5 Lyra-side changes allowed
*My call, kept to what the design needs:*
1. A macOS "linked" backend in both seams that fills the same pointer tables from `&Symbol`, plus a launch-time backend
   selector (5.6).
2. A macOS path in `ensureWisdom` and the wisdom setup dialog (`wdsp_native.cpp:738-800`) that skips FFTW wisdom.
3. CMake: the `LyraDSP` target, an explicit deployment target, and `LYRA_WDSP_FROM_INTREE_SOURCE` defined for LyraDSP
   builds (`CMakeLists.txt:1036-1042`) so the eSSB Coach stays aligned.
4. Keeping the eSSB Coach's `RxaAgcModel` stage-latency table in step with any LyraDSP latency change.
5. The noise-blanker strength-to-threshold mapping in `pushNbState` (fix #7 step 4).
6. Lyra-native controls for the opt-in modes in section 7. These come later, under a separate design.

## 4. Approaches considered

| | A. Layered extraction behind the WDSP interface (**chosen**) | B. Fork-and-patch WDSP 2.11 | C. New Lyra-native API and rewrite |
|---|---|---|---|
| What | New library that exports WDSP's C interface. Starts as WDSP 2.11 source and replaces blocks one by one with Accelerate-native code. | Keep WDSP's C, swap FFTW for a vDSP shim, apply the review fixes as patches. | Design a Swift/C++ API from scratch and rewrite Lyra's engine against it. |
| Keeps ChannelMaster byte-identical | Yes | Yes | No: breaks Rule 1 across the TX port |
| Gets off FFTW and Win32 idioms | Yes, block by block | Partly: an FFTW-shaped shim over vDSP, threading still WDSP's | Yes |
| Risk | Medium, contained per block by reference tests and the backend switch | Low at first, but the result is still WDSP with patches (Rule 5 friction) | High: engine rewrite and DSP rewrite at once |
| Uses Apple hardware well | Yes | Little | Yes |

The user leaned toward extraction ("algorithms extracted into a new library"). The ArcturusSDR evidence and the
existing seams make A clearly best. B is kept as **Phase 0–1 scaffolding**: LyraDSP starts as WDSP 2.11 compiled into
the new target, so the static-link swap is proven before any algorithm changes. C is rejected because it breaks the
ChannelMaster port that Rule 1 depends on.

Refinements to the three-layer sketch from the earlier conversation:
- **No new "LyraEngine".** The orchestration already exists: WdspEngine plus the ported ChannelMaster. The library's
  orchestration layer is WDSP's own channel model, kept for interface and timing parity.
- **No GCD on the sample path.** See 5.3.

## 5. Architecture

```
Lyra: WdspEngine ─┐                                   ┌─ ported ChannelMaster (src/wire/)
                  ▼                                   ▼
     WdspApi table (wdsp_native)               wdspcalls.h pointers
                  └──── macOS backend selector (launch time) ────┘
                     │                                   │
          "WDSP 2.11" (dlopen libwdsp.dylib)     "LyraDSP" (linked symbols)
                                                         ▼
 ┌──────────────────────────────── LyraDSP (static lib) ────────────────────────────────┐
 │ L3  C interface   extern "C", 178 names + public structs, double↔float at boundary  │
 │ L2  Channel engine channels, RXA/TXA order (xrxa/xtxa), iobuffs timing, DSP threads  │
 │ L1  DSP blocks    C++23 classes: fircore, filters, resamplers, AGC, NR, demod, …     │
 │     (no Apple APIs; calls L0 interfaces only)                                        │
 │ L0  Kernels       vDSP FFT/convolution/vector ops; Core ML runner for NNR            │
 └──────────────────────────────────────────────────────────────────────────────────────┘
   tests: reference runner = separate process linking stock WDSP 2.11 (golden vectors)
```

### 5.1 Layering and linking
- **L1 blocks contain no Apple API calls.** They call L0 kernel interfaces (FFT, complex MAC, vector ops, model
  runner), and only L0 talks to Accelerate and Core ML. *My call:* this costs nothing, keeps the blocks testable, and
  leaves a door open if Linux is ever wanted.
- **Linking.** The macOS app links LyraDSP statically. The "linked" backend fills the existing pointer tables from
  `&Symbol`. Every call site stays as it is.
- **Wisdom.** `WDSPwisdom` and `wisdom_get_status` return success, and the FFTW wisdom dialog is skipped on macOS,
  because vDSP has no planning step.

### 5.2 Data format
- **At the interface:** WDSP's interleaved `double` complex, as today.
- **Between blocks inside a channel:** interleaved complex `float` (`DSPComplex`), converted once at channel entry and
  exit with `vDSP_vdpsp`/`vDSP_vspdp`.
- **Inside FFT-based blocks:** split complex (`DSPSplitComplex`) scratch, converted with `vDSP_ctoz`/`vDSP_ztoc`.

  *My call:* interleaved complex between blocks matches WDSP's topology, so blocks can be replaced one at a time with no
  glue.

- **Double-precision blocks** (section 6) keep `double` state and run their sample loops in `double`, converting at
  their edges.
- Buffers are allocated at create and resize time only, 64-byte aligned (`posix_memalign`). `malloc0` (zeroed)
  semantics are preserved.

### 5.3 Threading
WDSP runs one DSP thread per channel, fed through `iobuffs.c` pseudo-rings and semaphores. `fexchange0` with
`block=1` waits for output. LyraDSP keeps **the exact same exchange semantics** (3.2 item 4) and changes how it is
done:
- **Thread class follows Lyra's existing policy:** `QOS_CLASS_USER_INTERACTIVE`, the same as the shim's MMCSS stand-ins
  (`src/platform/thread_priority.h:15-19`). There is no Mach time-constraint policy on DSP threads.
  - Lyra decided against time-constraint threads for variable-length DSP work.
  - The network wire threads (EP2 about every 2.6 ms, EP6) must not be preempted by 85 ms DSP blocks.
  - RX DSP is paced by the radio's IQ, so no Core Audio workgroup matches it.
  - The one Core Audio-thread caller, rmatchV from the PortAudio callback (`Ivac.cpp:238-301`), runs on the caller's
    thread as today.
  - *Answered from the codebase.*
- **Handoff:** the iobuffs rings and semaphores are rebuilt with lock-free single-producer, single-consumer rings and
  Mach semaphores, with identical token counts and ordering.
- **Parameter changes** (the `SetRXA*`/`SetTXA*` calls) are applied at block boundaries:
  - Scalars go through atomics.
  - Structural changes (filter redesign, resize, mode change) are prepared off the DSP thread, then installed with an
    atomic pointer exchange. The old object goes to a reclaim queue and is freed off-thread.
  - This replaces `csDSP` and fixes the rmatch `Sleep(10)` race. It needs Rule 11 approval (Q1).
- **GCD only for background work:** filter design, NNR model load and compile.

### 5.4 FFT, convolution and filter design
- `vDSP_DFT_zop`/`zrop` setups are created at block create or resize time and cached per size.
- **FFT size inventory** (*builder task*): list every FFT size WDSP 2.11 creates in Lyra's configurations, against
  vDSP's supported lengths (f·2ⁿ, f ∈ {1,3,5,15}).
  - Convolution blocks pad any unsupported size to the next supported length (no output change).
  - Spectral blocks whose bin grid matters (EMNR, the analyzer, NNR) must keep their size. An unsupported size there is
    reported as an open issue, not padded.
- `fircore`/`firmin` (overlap-save, uniformly partitioned) are rebuilt on vDSP complex multiply-accumulate with the
  same partition and latency. Fix #12 (one-block crossfade on filter exchange) lands here.
- **Impulse / min-phase design cache:**
  - The race (#11) is in the in-memory LRU get/add (`impulse_cache.c:128-185`). LyraDSP locks the cache, off the DSP
    thread, since design never runs there (5.3).
  - Disk persistence is dropped: `save/read_impulse_cache` return success and do nothing. *My call:* without FFTW
    planning, design is cheap enough that the disk cache isn't worth its complexity.
  - The builder confirms that concurrent creation and use of vDSP setups is safe, or serialises it.

### 5.5 NNR on Core ML
Today `xnnr` pushes the whole DSP block in and pulls the whole block out at once (`nnr.c:589-616`). Inference runs
inline in `nnr_push_input` → `nnr_frame` (`nnr.c:346-370`): about five 256-sample frames at 16 kHz per 85 ms DSP block.
`nnrbypass.c` is the alternate band-pass used when NNR runs before AGC (`RXA.c:656-679`), not a deadline bypass.

LyraDSP keeps that structure:

- **Inline, same latency, no new pass-through behaviour.** *My call:* adding a DSP block of delay or skipping frames on
  a late result would both be new behaviour.
  - The Core ML call runs inline in the channel's DSP thread.
  - A compute unit is accepted only if all the frames in one DSP block finish well inside the block period, at worst
    case.
- **Split of work:**
  - LyraDSP code on the CPU: conditioning (`run_cond`), the deep-filter head (`run_dfhead`), STFT framing and the
    16 kHz resampling. These are cheap and precision-sensitive (the `DF_TINY`/`COND_TINY` thresholds).
  - Core ML: the recurrent core, as a stateful model.
- **Compute unit chosen by measurement.** Phase 6 starts with a spike measuring latency per DSP block, jitter and
  accuracy on:
  - ANE (FP16)
  - GPU
  - CPU (FP32)

  The ANE is used only if it meets the inline budget with margin and passes the class-N accuracy test (section 8).
  Otherwise the model runs on CPU through Core ML.
- **Conversion:**
  - Reimplement `nnet.c`'s graph in PyTorch and load the shipped weights.
  - Prove it matches `nnet.c`.
  - Convert with coremltools.
  - *My call:* the `.mlpackage` files are generated once by a checked-in script and committed as generated artifacts.
    PyTorch and coremltools live only in an isolated conversion environment, never in the build or DMG flow.
  - Adding those tools still needs a yes at Phase 6 (dependency rule).

### 5.6 Backend selection, A/B and rollback
*My call, answering the builder's A/B and rollback question:*
- **Selector.** Through Phase 6 the macOS app ships both backends: the stock WDSP 2.11 dylib (via the existing dynamic
  loader) and the linked LyraDSP. A launch-time preference picks one for the whole session. One backend per session
  avoids two libraries sharing FFTW's non-thread-safe global planner and per-thread FTZ state.
- **What it gives:**
  - RX A/B on the bench: restart with the other backend.
  - Rule 4 rollback for every phase: flip the preference.
- **TX wire-inertness (Phase 5):** native TX blocks are compiled behind a CMake option (`LYRADSP_NATIVE_TX`, default
  OFF). Until the bench passes, the LyraDSP backend still uses WDSP's TX source files.
- **Phase 7** removes the selector, the dylib and FFTW.

## 6. Precision policy

Rule: **float32 for bulk vector data; double for recursive state, coefficient design, statistics, and control loops.**
On Apple Silicon this costs almost nothing, because the recursions are scalar and the vector work is in vDSP.

| Block(s) | Precision | Why (evidence) |
|---|---|---|
| FFT convolution (fircore, bandpass, nbp, cfir, eq), resamplers, analyzer FFT, panel/gain | float32 | Linear vector work; float32 error is far below the signal floor |
| Filter *design* (`fir.c` windows, min-phase, `fsamp`), IIR coefficients and state (`iir.c`, biquads, CTCSS notch) | double | Review: cepstral min-phase floor and low-frequency IIR round-off are float32 hazards |
| AGC/ALC/leveler detector, meters (`wcpAGC.c`, `meter.c`) | double | Review: long time constants (c ≈ 1e-5) stall in float32 |
| ANR/ANF leaky NLMS (`anr.c`, `anf.c`) | double | Review: the ANF leak rounds to exactly 1.0 in float32 when lidx is below ~47 |
| PLLs, NCO and phase accumulators (`amd.c`, `fmd.c`, `shift.c`; `varsamp.c` as a 64-bit fixed-point phase) | double / fixed | Phase drift; varsamp also needs its strict-aliasing UB removed |
| EMNR noise estimators and gain statistics (`emnr.c`) | double, plus the #0 guards | Review #0: float32 freezes NR after 0.3 s, or after a −40 dB drop |
| SNB/AR fits, nobII AR interpolation (`lmath.c`, `snb.c`) | double | Levinson stability (#2) |
| PureSignal (`calcc.c`, `iqc.c`, `nurbs*`) | double | Fits reach cond(AᵀA) ~1e8, above float32's ~1.7e7 |
| NNR core | FP16 or FP32, per the spike | Measured, not assumed |

**FTZ.** WDSP's `OpenChannel` sets flush-to-zero on the calling thread (`channel.c:100`). LyraDSP keeps that behaviour
for parity, but sets it on its own DSP threads, where it applies to processing. Blocks proven sensitive to FTZ
(EMNR #0) carry the guards from section 7, which the review showed work with FTZ on and off.

## 7. Behaviour policy: bugs and upgrades

*My call, to confirm under Rule 1 (Q1):*
1. **Verified bugs are fixed by default**, each recorded as a declared deviation citing `docs/wdsp-review`.
2. **Algorithm upgrades are new, opt-in modes.** The default stays WDSP 2.11 behaviour. Exposure comes later as a
   Lyra-native control, never by changing what an existing WDSP setter means.
3. **Latency cuts that leave the output otherwise identical are on by default.**

Findings adopted (numbers from `docs/wdsp-review/README.md`; "D" = default-on, "M" = opt-in mode):

| # | Fix | Type | Phase | Note |
|---|---|---|---|---|
| 0 | EMNR: lower clamp + relative floor + hold on silent frames | D | 3 | All three pieces; each alone failed a float32 or FTZ case |
| 7 | nob/nobII: skip-update censoring, flagged-fraction step guard, median seeding | D | 3 | Needs the `pushNbState` threshold mapping change (3.5 item 5) to keep the strength control's meaning |
| 14 | rmatch loop averaging in seconds, not callbacks | D | 2 | |
| 15 | rmatch `xaamav` divide-by-zero guard | D | 2 | |
| 11 | impulse cache locking | D | 2 | By design, 5.4 |
| 10 | `make_nbp` deletion loop | D | 2 | |
| 12 | one-block crossfade on filter exchange | D | 2 | |
| 6 | NB2 look-ahead: mode 0 uses the causal path (about 0.5 ms instead of 25.5 ms) | D | 3 | No new setter: mode 0 sets it internally. Re-init on mode change. The builder checks nothing in Lyra assumes a fixed NB delay (panadapter alignment, capture, zero-beat) |
| 4 | nobII live-signal slews | D | 3 | |
| 2 | SNB stable AR fit | D | 3 | |
| 8 | WBFM de-emphasis setter takes effect; squelch band-pass | D | 3 | |
| 13 | double-pole CW filter as exact recursion | D | 3 | Output identical to within −46 dB |
| 17 | DEXP retrigger and setter dropout | D | 5 | |
| 19 | PureSignal rejected-fit state | D | 5 | |
| 18 | phase rotator: stop zeroing state | D (state part only) | 5 | |
| 20, 21 | analyzer boxcar reset; Rosenfell `det_offset` | D | 4 | Lyra's settings (peak detector, averaging off on RX, log-recursive on TX: `wdsp_engine.cpp:241,247,1150`) never reach these paths, so there is no visible change today |
| 3 + 5 | residual impulse detector with AR gap fill (they need each other) | M | 3 | |
| 1 | EMNR musical-noise smoothing | M | 3 | |
| 16 | CFC low-latency method | M | 5 | |
| 9 | SAM PLL upgrade | M | later | Low priority |

Low-priority pass-1 items are taken when their block is extracted, if they are cheap and output-neutral. The builder
decides and records each in the ledger.

## 8. Verification

**Reference runner.** A separate executable links stock WDSP 2.11 (built with the existing POSIX shim) and writes
golden output files for each test case. It runs in its own process, because `OpenChannel` sets per-thread FTZ and
FFTW's planner is global and not thread-safe.

Its output is made deterministic:
- FFTW planning is pinned with a fixed wisdom file. Otherwise `FFTW_PATIENT` picks algorithms by timing
  (`firmin.c:148-149`, `fir.c:536-539`).
- FTZ is set as `OpenChannel` sets it.
- The compiler's FP-contraction flags are fixed. The review found EMNR results depend on FMA contraction.

**Parity classes.** *My proposal; tolerances to be approved with Q1.* Each block is assigned one class in the
mapping document.

| Class | Blocks | Pass rule |
|---|---|---|
| L: linear, float32 | convolution filters, resamplers, panel, analyzer FFT path | max error ≤ −100 dBFS against the reference |
| D: double, FFT backend changed | EMNR spectra, filter design | max relative error ≤ 1e-9 |
| S: state machines / decisions | AGC, squelches, DEXP/VOX, blanker flags | Test signals kept ≥ 1 dB from every threshold. Decision events match within ±1 sample. Output ≤ −80 dB elsewhere |
| C: threshold-sensitive or chaotic | EMNR estimator behaviour, PureSignal fits | Over ≥ 20 seeds, the metric (suppression in dB, convergence time, table error) stays within 0.2 dB / 5% of the reference distribution |
| N: neural | NNR core | FP32: per-frame error ≤ −60 dB against `nnet.c`. FP16: allowed only if SI-SDR on the test set stays within 0.1 dB of `nnet.c` |
| F: fixed blocks | any block with a section 7 fix | Its own class outside the fixed case. In the fixed case it reproduces the measurement in `docs/wdsp-review/harnesses/h<id>`, which becomes a regression test |

**Other test layers:**
- **Chain tests.** Full RXA/TXA channels via `OpenChannel`/`fexchange0` at the section 3.2 configurations. They
  check:
  - exchange timing (output-available call counts)
  - channel start/stop
  - mode changes mid-stream
  - rate changes
  - eSSB Coach alignment (`coachAgcState() == Aligned` against the same input)
- **Processing-path tests.**
  - Per-block CPU time at each configuration.
  - A soak test under load for exchange overruns.
  - No allocation on DSP threads (a malloc hook in debug builds).
  - Instruments System Trace before cut-over.
- **Bench (Rule 8).**
  - RX: A/B listening on the HL2 for each phase, using the backend selector (5.6).
  - TX and PureSignal: stay wire-inert until a bench session passes (two-tone IMD, ALC behaviour, PS convergence).
- **Where tests run.** There is no CI today. The parity and chain suites run locally through `ctest` and must pass
  before each phase lands. NNR compute-unit tests need real Apple Silicon; hosted VM runners can't reach the ANE.

## 9. Phases

Each phase ships on its own, leaves the macOS build working, and can be rolled back with the backend selector.

0. **Baseline.**
   - Record the ledger entries and the mapping document (Q1).
   - Move the macOS WDSP build from 2.00 to 2.11, so NNR is available on the Mac immediately. Confirm the POSIX shim
     compiles it.
   - Set an explicit deployment target.
   - Build the reference runner and an empty test harness.
1. **Scaffold.**
   - Create the `LyraDSP` CMake target: WDSP 2.11 sources plus the interface layer, statically linked.
   - Add the linked backend and the selector to both seams.
   - Pass: the linked build matches the dylib backend on the full parity suite.
   - Write Appendix B and the list of public structs (3.2 item 2).
2. **Infrastructure.**
   - L0 kernels: vDSP FFT wrapper, complex MAC.
   - fircore/firmin (#12), filter design, resamplers (resample, resampleFV, varsamp, reshb).
   - rmatchV (#14, #15), impulse cache (#11), nbp (#10).
   - The channel engine: iobuffs timing, DSP threads, parameter swap.
   - FFTW stays linked for blocks not yet replaced.
3. **RX chain**, in `xrxa` order: shift, decimation, nob/anb (#7, #6, #4), demods (AM/SAM, FM, WBFM #8), EQ, ANF/ANR,
   EMNR (#0), SNB (#2), AGC, CW filters (#13), squelches, panel. The opt-in modes (#1, #3+#5) land last.
4. **Analyzer** (#20, #21): vDSP migration, with no visible change in Lyra's settings.
5. **TX chain and PureSignal**, behind `LYRADSP_NATIVE_TX`:
   - `xtxa` blocks, CFC, compressor, CESSB/osctrl, DEXP (#17), phrot (#18), EER, divEXT.
   - PureSignal (#19).
   - The option turns ON only after the bench session passes.
6. **NNR on Core ML.** Spike (5.5), conversion pipeline (dependency approval), runner, class-N parity.
7. **Cut over.** Remove FFTW, the remaining WDSP sources, the dylib and the selector from the macOS build.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Rule 1 approval not given, or Rules 4/6/23 apply per block (about 40 gated steps) | Q1 before Phase 0. Phases 0–2 are parity-only and can proceed apart from the fixes |
| An unsupported vDSP FFT size forces a spectral block to change its bin grid | Inventory in Phase 2; padding only for convolution; spectral cases escalated |
| Exchange-timing drift breaks the eSSB Coach or audio pacing | Timing is part of the contract (3.2); chain tests assert call counts and Coach alignment |
| DSP threads starve the wire threads | Same QoS policy as today; soak tests that include EP2 cadence |
| The NNR inline budget isn't met by any Core ML compute unit | Stay on CPU via Core ML; worst case, keep the C path vectorised in L0 |
| Windows and macOS behaviour diverge as fixes land only in LyraDSP | Accepted under the non-goals; the ledger records each difference; fixes could be offered upstream |
| GPL obligations for converted Core ML models | Generated from GPL weights by a checked-in script; script and weights ship as for any GPL artifact |

## 11. Left to the builder

- The class layout of L1 blocks, the file layout under `src/lyradsp/` (suggested), and naming.
- The FFT size inventory and per-size handling, within 5.4's rules.
- The test-signal set, and each block's class assignment in the mapping document (section 8).
- Appendix B, and the public-struct list.
- Which low-priority pass-1 items to take as each block is extracted.
- Core ML conversion details (coremltools version, stateful model form) after the Phase 6 spike.

## 12. Calls I made (check these)

1. **The interface contract is WDSP's own:** names, signatures, public structs, version 211 and exchange timing.
2. **Interleaved complex float32 between blocks;** split complex only inside FFT blocks; L1 free of Apple APIs.
3. **The precision table** (section 6), and FTZ kept as WDSP sets it.
4. **DSP threads use Lyra's existing QoS policy,** not time-constraint or GCD. Atomic parameter swaps replace `csDSP`.
5. **Impulse cache in memory and locked;** disk persistence and FFTW wisdom dropped on macOS.
6. **Bugs fixed by default, upgrades opt-in, output-identical latency cuts on.** #7 includes the `pushNbState`
   mapping change.
7. **Parity baseline is TAPR WDSP 2.11.** Phase 0 moves the Mac from 2.00. Windows keeps 2.10.
8. **NNR stays inline with today's latency.** The compute unit is chosen by a measured spike, and the `.mlpackage` files
   are generated once and committed.
9. **A launch-time backend selector** for A/B and rollback, plus `LYRADSP_NATIVE_TX` for TX wire-inertness.
10. **Reference runner in its own process,** with deterministic FFTW, FTZ and FP-contraction settings. Parity classes as
    proposed in section 8.
11. **Apple-only,** overriding the global "production targets Linux" default for this library.
12. **Allowed Lyra-side changes** as listed in 3.5.

## 13. Open questions

- **Q1 — Rule approval and granularity.** Who signs off under RULES.md? Does the set below go through as one approval
  per phase, or per block?
  - replacing WDSP on macOS
  - TAPR 2.11 as the baseline, while Windows ships 2.10 and the Rule 1 reference is Thetis 2.10.3.13
  - the default-on fixes
  - atomic swaps in place of `csDSP` (Rule 11)
  - the parity classes
- **Q2 — Chip and macOS floor.** Does "M5 or better" mean LyraDSP is only *tuned* for M5 and must run on any Apple
  Silicon (M1–M4)? Or that M1–M4 are unsupported? The second allows M4/M5-only instructions (SME) and drops testing on
  older Macs. It also sets the macOS floor: at least 15 for stateful Core ML, and 26 in practice if M5-only.

## Appendix A — entry points (snapshot 2026-11-24)

Union of `src/wdsp_native.{h,cpp}` and `src/wire/wdspcalls.{h,cpp}`, 178 names:

CloseChannel, DestroyAnalyzer, GetPSDisp, GetPSHWPeak, GetPSInfo, GetPSMaxTX, GetPixels, GetRXAAGCTop, GetRXAMeter,
GetTXAMeter, GetWDSPVersion, OpenChannel, RXANBPAddNotch, RXANBPDeleteNotch, RXANBPEditNotch, RXANBPGetNumNotches,
RXANBPSetNotchesRun, RXANBPSetShiftFrequency, RXASetMP, RXASetPassband, SetAnalyzer, SetChannelState, SetDSPBuffsize,
SetDSPSamplerate, SetDisplayAvBackmult, SetDisplayAverageMode, SetDisplayDetectorMode, SetDisplayNumAverage,
SetDisplaySampleRate, SetEXTDIVBuffsize, SetEXTDIVNr, SetEXTDIVOutput, SetEXTDIVRotate, SetEXTDIVRun, SetEXTNOBRun,
SetEXTNOBThreshold, SetInputBuffsize, SetInputSamplerate, SetOutputSamplerate, SetPSAutomode, SetPSControl,
SetPSDeadlockMinFrac, SetPSFeedbackRate, SetPSHWPeak, SetPSLoopDelay, SetPSMancal, SetPSMox, SetPSMoxDelay, SetPSReset,
SetPSRunCal, SetPSTXDelay, SetPSTurnon, SetRXAAGCDecay, SetRXAAGCFixed, SetRXAAGCHang, SetRXAAGCHangThreshold,
SetRXAAGCMode, SetRXAAGCSlope, SetRXAAGCThresh, SetRXAAMSQMaxTail, SetRXAAMSQRun, SetRXAAMSQThreshold, SetRXAANFRun,
SetRXAANFVals, SetRXAANRRun, SetRXAANRVals, SetRXABiQuadBandwidth, SetRXABiQuadFreq, SetRXABiQuadGain, SetRXABiQuadRun,
SetRXAEMNRPosition, SetRXAEMNRRun, SetRXAEMNRaeRun, SetRXAEMNRgainMethod, SetRXAEMNRnpeMethod, SetRXAEMNRpost2Run,
SetRXAFMSQRun, SetRXAFMSQThreshold, SetRXAMode, SetRXANNRMaskFloor, SetRXANNRModel, SetRXANNRRun, SetRXAPanelBinaural,
SetRXAPanelGain1, SetRXAPanelPan, SetRXASSQLRun, SetRXASSQLTauMute, SetRXASSQLTauUnMute, SetRXASSQLThreshold,
SetRXAShiftFreq, SetRXAShiftRun, SetTXAALCAttack, SetTXAALCDecay, SetTXAALCHang, SetTXAALCMaxGain, SetTXAALCSt,
SetTXAAMCarrierLevel, SetTXABandpassFreqs, SetTXACFIRRun, SetTXACTCSSFreq, SetTXACTCSSRun, SetTXAFMAFFreqs,
SetTXAFMDeviation, SetTXAFMEmphPosition, SetTXALevelerAttack, SetTXALevelerDecay, SetTXALevelerHang, SetTXALevelerSt,
SetTXALevelerTop, SetTXAMode, SetTXAPHROTCorner, SetTXAPHROTNstages, SetTXAPHROTRun, SetTXAPanelGain1,
SetTXAPostGenMode, SetTXAPostGenRun, SetTXAPostGenTTFreq, SetTXAPostGenTTMag, SetTXAPostGenToneFreq,
SetTXAPostGenToneMag, SetTXAPreGenMode, SetTXAPreGenNoiseMag, SetTXAPreGenRun, SetType, Spectrum0, TXAGetaSipF1,
TXASetMP, TXASetSipDisplay, TXASetSipMode, WDSPwisdom, XCreateAnalyzer, create_divEXT, create_eer, create_nobEXT,
create_resample, create_resampleFV, create_rmatchV, destroy_divEXT, destroy_eer, destroy_impulse_cache, destroy_nobEXT,
destroy_resample, destroy_resampleFV, destroy_rmatchV, fexchange0, flush_divEXT, flush_resample, forceRMatchVar,
getRMatchDiags, init_impulse_cache, pSetEERSamplerate, pSetEERSize, pscc, read_impulse_cache, resetRMatchDiags,
save_impulse_cache, setRMatchFFAlpha, setRMatchFFRingMax, setRMatchFFRingMin, setRMatchFeedbackGain, setRMatchInsize,
setRMatchNomInrate, setRMatchNomOutrate, setRMatchOutsize, setRMatchPropRingMax, setRMatchPropRingMin,
setRMatchRingsize, setRMatchSlewTime, setRMatchSlewTime1, use_impulse_cache, wisdom_get_status, xdivEXT, xeer, xnobEXT,
xresample, xresampleFV, xrmatchIN, xrmatchOUT

## Appendix B — blocks unreachable through the interface

To be written by the builder in Phase 1.
