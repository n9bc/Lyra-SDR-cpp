# WDSP 2.11 algorithm review

Date: 2026-11-24. Source reviewed: WDSP 2.11 (TAPR/OpenHPSDR-wdsp, `wdsp 2.11/Source`). Purpose: input to the LyraDSP extraction design (Apple Silicon, float32, Accelerate).

## How this was verified

- **Pass 1:** 11 reviewers, one per DSP area, read the source and proposed 89 improvements. One skeptic per proposal tried to refute it against the code. 67 survived and 22 were refuted.
- **Pass 2:** the 22 medium/high survivors each got three independent verifiers and a judge:
  - **Code trace:** checked the cited lines, callers and stock configuration.
  - **Theory and literature:** checked the cited papers and derived effect sizes.
  - **Compiled harness:** built WDSP 2.11's own C for the block on arm64 macOS (POSIX shim for `comm.h`), then ran the same test signal through the original and the fixed build.
  - **Judge:** weighed the three and opened the code where they disagreed.
- **Not done:** no listening tests, no hardware, and no objective speech-quality metrics (PESQ etc.). Effect sizes are measured on synthetic signals.
- **Harnesses:** `harnesses/h<id>/`. WDSP files are stored as `.diff` against the 2.11 source, not copied. Raw rmatch CSV traces were dropped because the harness regenerates them. Paths quoted in the verdicts point at the original scratch location: `.../scratchpad/verify2/h<id>/` corresponds to `harnesses/h<id>/` here.
- **Raw data:** `pass1-proposals.json` (all 89 proposals with skeptic verdicts) and `pass2-verdicts.json` (judges and per-lens results).

## Pass 2 summary (22 findings)

| # | Priority | Verdict | Area | Finding |
|---|---|---|---|---|
| 0 | high | confirmed | spectral-nr | Digital silence (and in float32, deep level drops) permanently disables NR2's noise estimator until calc_emnr runs again |
| 7 | high | confirmed | noise-blankers | Robust, impulse-censored background estimate with a calibrated false-alarm rate; avg is inflated by impulses, starts at 1.0 and collapses during silence |
| 14 | high | confirmed | resampling | rmatch control loop: averaging windows are counted in callbacks, not seconds, so loop stability depends on buffer size |
| 1 | medium | confirmed-smaller | spectral-nr | Musical-noise control: selective cepstral smoothing of gains, soft (not binary) zeta mask in method 3, and a stronger xi_min |
| 2 | medium | confirmed | lms-nr | SNBA: make the AR fit unconditionally stable (windowed autocorrelation, white-noise correction, bandwidth expansion, reflection guard) |
| 3 | medium | confirmed-smaller | noise-blankers | Detect impulses on a linear-prediction residual instead of raw /x/, so strong signals neither hide impulses nor trigger the blanker |
| 4 | medium | confirmed | noise-blankers | NOB-II slews cross-fade frozen samples instead of windowing the live signal, so the taper does nothing for signals away from IQ DC |
| 5 | medium | confirmed | noise-blankers | Add complex AR (LSAR) gap interpolation; the hold and linear modes only work for content near IQ DC |
| 6 | medium | confirmed | noise-blankers | NOB-II always adds about 25.6 ms of receive latency because of a fixed 25 ms look-ahead; zero mode needs almost none of it |
| 8 | medium | confirmed-smaller | demod | WBFM: de-emphasis setter never reaches the filters, and the noise-squelch 'Butterworth' bandpass is really two identical resonators |
| 10 | medium | confirmed | filtering | make_nbp band-deletion loop shifts bands but not the del[] flags, so it deletes the wrong sub-band; also min_notch_width integer-division edge |
| 11 | medium | confirmed | filtering | Impulse/min-phase cache LRU list is mutated without a lock |
| 12 | medium | confirmed-smaller | filtering | Click-free filter exchange in fircore: crossfade old and new mask outputs |
| 13 | medium | confirmed-smaller | filtering | Run the doublepole CW filter as an exact recursive complex one-pole instead of an nc-tap FIR (up to 16384 taps) |
| 15 | medium | confirmed | resampling | xaamav divides by zero after an input stall and latches feed_forward at +inf |
| 16 | medium | confirmed-smaller | tx-processing | CFC latency of fsize-bsize samples: decouple time smoothing from frame length |
| 17 | medium | confirmed | tx-processing | DEXP cannot re-trigger during DECAY, and its setters reset state and zero the delay ring |
| 18 | medium | confirmed-smaller | tx-processing | Phase-rotator auto-tuner: paired (shadow-chain) evaluation, no state zeroing, and a crest-factor objective |
| 19 | medium | confirmed | puresignal | Rejected fits still update the control-point and pin EMA state; the table clip only applies on the first cycle |
| 20 | medium | confirmed | analyzer | Boxcar averaging (av_mode 2) never clears its running sum, so old frames stay in the display permanently |
| 21 | medium | confirmed | analyzer | Rosenfell detector's next-pixel test omits det_offset and the clamp, so pixels are finalised early and overwritten by a single bin |
| 9 | low | confirmed-smaller | demod | SAM PLL: arm-filtered, sideband-aware phase detector with carrier-fade flywheel and FFT-aided acquisition |

## Pass 2 details

### #0 Digital silence (and in float32, deep level drops) permanently disables NR2's noise estimator until calc_emnr runs again

**Priority:** high · **Verdict:** confirmed · **Area:** spectral-nr · **Where:** `emnr.c:LambdaD (lines 704-713, 719-752, 790-797) and emnr.c:LambdaDs (line 810)`

**Evidence.** All three lenses reproduced a permanent, silent loss of NR with npe_method 0. In the full xemnr harness, suppression goes from -20 dB to +0.81 dB and sigma2N stays frozen for 60-82 s. In double this happens from about 1.1-1.3 s of exact zeros, at 54 of 117 gap lengths between 1 and 30 s. In float32 it happens from about 0.3 s. In float32 it also happens after an ordinary -40 or -60 dB drop in real noise, with no zeros at all. The mechanism the finding describes is wrong. Without FTZ, p and sigma2N never go NaN through 0/0. The real path starts when input resumes: varHat = p2bar - pbar^2 cancels to a negative rounding residue (about 1000 bins). invQeq at emnr.c:728 is clamped only from above (729), so invQbar goes negative and sqrt gives bc = NaN (734). k_mod is then never set (746). A second path also exists: sigma2N^2 underflows, giving invQeq = 0/0 = NaN, which passes the one-sided clamp. LambdaDs (npe 1) recovers in stock double and float without FTZ, but NaN-locks all 2049 bins once FTZ is on (after about 6.3 s of zeros in float).

**Recommended fix.** In LambdaD, add a NaN-safe lower clamp on the variance term before the existing upper clamp: `if (!(invQeq >= 0)) invQeq = 0; if (invQeq > invQeqMax) invQeq = invQeqMax;`. This restores the estimator's own 0 <= 1/Qeq <= 0.5 constraint. Add two more guards with it:
- (a) A relative floor on sigma2N, p, pbar, pmin_u and lambda_y: 1e-10 x a slow EMA of mean lambda_y, plus FLT_MIN.
- (b) Skip LambdaD/LambdaDs (hold state) for frames whose mean lambda_y is at or below that floor. This also covers MOX/TX gaps and zero-filled packet loss.
The (c) x/(y+tiny) ratio guards are optional. In the harness, only the combination (floor + hold + clamp) recovered to -20 dB in every case: double and float, FTZ on and off, npe 0 and 1, zero gaps of 0.2-120 s, and -40/-60 dB level steps. Each piece alone failed some float32 or FTZ case. Keep FTZ/DAZ off for EMNR until these guards are in, then add a regression test for the zero-gap and level-step cases.

**Disagreements.** All three lenses agree the headline holds and the described mechanism and timing are wrong. The code and harness lenses saw no NaN in double; the harness lens confirmed this with npe1_orig.txt and the sweep outputs, which I checked. I treated that as decisive against the 0/0 story.

They disagreed on two points:
1. LambdaDs. The code and theory lenses said "refuted". The harness lens found it is refuted only without FTZ; with FPCR.FZ set, all bins NaN-lock in both double and float. FTZ is plausible on Apple Silicon, so I side with the harness: the LambdaDs part is conditionally true.
2. The fix. The theory lens said the invQeq >= 0 clamp alone fixed everything. The harness lens, using the full xemnr path, found the clamp alone leaves -2.5 dB of suppression and NaN p after gaps of 30 s or more, freezes under FTZ, and fails float at gaps of 3 s or more. The code lens also found the clamp alone and the floor alone each insufficient, and clamp plus floor sufficient. I weighted the measured full-path harness most heavily, so I recommend the combined fix.

I rated this confirmed rather than confirmed-smaller because the real effect is larger than claimed: it triggers about 15x sooner in double, and in float32 it also triggers on non-zero level drops. For LyraDSP, a float32 Apple Silicon port where FTZ is likely, it is high priority: a common event silently and permanently turns off NR, and the user can hear it.

**Per-lens results**

- *code* (partly): Harness: emnr.c code extracted verbatim with sed into a scratch file. Sources: LambdaD/LambdaDs (680-819), np/nps init from calc_emnr (395-516), interpM, and a Windows-style min/max macro. RXA defaults: fsize 4096, ovrlp 4 (incr 1024), 48 kHz, msize 2049, npe_method 0. Input: exponential noise with mean 1e-4 per bin, 2000 frames, then N frames of exact zeros, then 3000 frames of noise. Files are in /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/mytrace/.

Stock double, LambdaD:
- N = 10, 20, 40 recovered. N = 50 was still capped 100 frames after input resumed, then recovered.
- N = 60, 80, 100 and 300 froze for good. All 270 in-band bins had gamma capped at 40, and lambda_d stayed at about 1e-26, 1e-34, 1e-44 and 1e-127 for the whole 3000 frames.
- N = 1000, 1300 and 3000 recovered in this run. The earlier skeptic reported 1300 and 3000 as frozen, so long gaps depend on the noise realisation.
- In double no bin ever went NaN in p or sigma2N. sigma2N stalls at about 2e-162: once sigma2N^2 underflows, invQeq is 0/0 = NaN, so bc is NaN and updates stop during the silence.
- The N = 60 freeze: at the first frames of resumed input, invQbar went from 0.5 to -4e24, then to about -5e26, with 12 to 155 bins having negative invQeq. sqrt of a negative mean gives bc = NaN, k_mod is never set again, and sigma2N is frozen.

float32 port, LambdaD:
- N = 10 recovered. N = 20, 30, 50, 100, 300, 1000 and 3000 all froze permanently.
- From N = 300 on, 16 of 2049 bins reached sigma2N == 0 exactly and their p became NaN. So the finding's 0/0 path is real in float32 only.

LambdaDs (npe 1), double and float, N = 100, 1000, 3000: always recovered within about 100 frames.

Decay during zeros: about 0.45x per frame (sigma2N 1.1e-7 at 10 frames, 3.5e-11 at 20).

Fix variants:
- F1, clamp only: invQeq set to 0 when !(invQeq > 0). Fixes double up to N = 1000 but fails at N = 3000 (136 of 270 bins capped, sigma2N == 0 in some bins). Fails in float from N = 300.
- F4, sigma2N floor only, at 1e-14 (-100 dB re the mean) or 1e-20: fixes double, but float stays frozen at all N tested (270 of 270 capped). A floor of 1e-30 fails in both.
- F2, clamp plus floor: recovered at every N, in both double and float.
- F3, skip the estimator when total lambda_y is 0: recovered at every N, in both.

- *theory* (partly): I rebuilt the first skeptic's harness (scratchpad/emnrsim/sim2.c: LambdaD/LambdaDs taken unchanged from emnr.c, fsize 4096, 1024-sample hop, 48 kHz, exponential noise with mean 1e-4) as copies under scratchpad/v0/.

Stock double, clang -O2 with FMA contraction on: the estimator froze after 60, 100, 300, 1300 and 12000 zero frames, with lambda_d stuck between 1e-27 and 2e-163 against a true level of 1e-4.

Stock double with -ffp-contract=off, which is closer to an x86 build without FMA: it froze after 60 and 1300 frames but recovered after 100 and 300. So the freeze does not depend on FMA, but the trigger lengths do depend on the compiler.

Trace without FMA, 60 zero frames: invQbar was 0.5 on the first two frames after input returned. After that it went to about -1.3e28 and bc became NaN, with 40 to 170 bins having a negative Qeq in every frame.

Float32 without FMA: 20 zero frames recovered, 40 froze.

LambdaDs (npe_method 1) recovered after 60, 300 and 3000 zero frames, ending at mean lambda_d 7.3e-5.

Fix test 1, clamping varHat to 0 or above: this fixed every float case but not double runs of 1300 frames or more. There is a second path: sigma2N falls to about 2e-163, so sigma2N^2 underflows to 0, invQeq = 0/0 = NaN, and the NaN gets past the one-sided clamp (NaN > invQeqMax is false). Trace: nanQ = 2049 bins, sig2underflow = 2049.

Fix test 2, `if (!(invQeq >= 0.0)) invQeq = 0.0;` placed before the existing upper clamp: recovered in double and float for 20, 60, 300, 1300 and 3000 zero frames, and in double for 12000. Mean lambda_d returned to about 9.4e-5 within about 200 frames.

Derived: the negative residue in invQeq is about eps*(p/sigma2N)^2/2 per bin. That only matters when p/sigma2N is above about 1e8 in double or about 1e3 to 1e4 in float32, a jump that only a collapse of sigma2N during digital silence produces.

- *harness* (partly): Setup: the real WDSP 2.11 emnr.c (create_emnr/xemnr/calc_gain/LambdaD/LambdaDs/getKey/aepf/post2, real GG/GGS and zetaHat tables), with only the RXA property setters removed. RXA defaults: 48 kHz, fsize 4096, ovrlp 4 (1024-sample hop), bsize 1024, gain_method 2, ae_run 1. Input: Gaussian noise (rms 1e-3) for 15 s, then Z s of exact zeros, then noise for 20-60 s. Metric: NR noise suppression, output/input power in the steady state after the noise returns. Normal value: -20.0 dB.

DOUBLE, unmodified, npe_method 0:
- Z = 0.5 s and 1.0 s: recovers (-20 dB).
- Z = 1.1, 1.2, 1.25, 1.3, 1.5, 2, 3, 5 and 30 s: NR is off permanently (+0.81 dB, mean mask 0.975). sigma2N never changes again: frozen for 2813-3831 blocks, i.e. 60-82 s, to the end of the run. Same result for 10/10 RNG seeds.
- Z = 10, 20, 60, 120 and 300 s: recovers.
- Sweep of Z from 1.0 to 30 s in 0.25 s steps: frozen in 54/117 lengths. The outcome is deterministic and depends on alignment with the subwindow (V) cycle, not on the RNG seed.
- In the frozen state, lambda_d is about 4e-37 (-340 dB re the true noise). p and lambda_d have 0 NaN. varHat < 0 in about 1000 of 2049 bins.

FLOAT32 build (all doubles become float, fftwf), npe_method 0:
- Freezes for every Z from 0.3 s (about 14 frames) through 120 s; only Z = 0.2 s recovers.
- Also freezes with no zeros at all: real noise stepped down by -40 dB or -60 dB for 10 s and then restored leaves NR off (+0.81 dB). Double recovers from the same steps, and from -120 dB.

npe_method 1 (LambdaDs):
- Double without FTZ: recovers at every Z up to 300 s. sigma2N bottoms out at 4.9e-324 and never reaches 0.
- Double with FTZ (FPCR.FZ): all 2049 lambda_d bins become NaN, and NR stays off (+0.81 dB) for good. In the Z = 120 s run, sigma2N last changed about 2450 frames (about 52 s) into the silence.
- Float without FTZ: recovers.
- Float with FTZ: NaN-locks all 2049 bins after about 293 frames (about 6.3 s) of zeros.

FIXED variants, steady-state suppression after resume (dB):
- (a)+(c), 1e-10 x long-term-mean floor plus robust ratios:
  - Double: 0/80 failures, Z 0.5-60 s x 10 seeds.
  - Float: fails at 9/16 values of Z (0.5-5 s and 30 s), and also fails the -60 dB level step.
- (b), hold state on silence: 0 failures in double and in float, with and without FTZ. Fails the float -40 and -60 dB level steps.
- invQeq >= 0 clamp alone (the first skeptic's fix):
  - Double: fixes Z up to 10 s, but at Z >= 30 s only reaches -2.5 dB. After 180 s it is still -3.3 dB, with 563 bins of p = NaN, so the 0/0 path becomes reachable once the freeze is removed.
  - Double with FTZ: still freezes (+0.81 dB).
  - Float: fails at Z >= 3 s.
- All three combined (a+b+c+clamp): -19.95 to -20.08 dB in every case tested. That covers double and float, FTZ on and off, npe 0 and 1, Z from 0.2 to 120 s, and -40/-60 dB level steps.
- One side effect of (b): a real -120 dB band is treated as silence and the estimator holds through it. This is harmless here, since NR recovers to -20 dB afterwards.

### #7 Robust, impulse-censored background estimate with a calibrated false-alarm rate; avg is inflated by impulses, starts at 1.0 and collapses during silence

**Priority:** high · **Verdict:** confirmed · **Area:** noise-blankers · **Where:** `nob.c:initBlanker line 45, xanb line 119; nobII.c:flush_nob line 148, xnob line 180`

**Evidence.** Harness (the real nobII.c, Lyra's parameters): every number in the finding reproduced. At 100 impulses/s of 100x the threshold rose 4.33 dB and at 1000/s it rose 17.1 dB. At T=12, impulses of 15-20x at 1000/s were 100% missed, and at 2000/s every amplitude was 100% missed. With skip-update censoring both cases dropped to 0-0.6% missed and the threshold rise stayed within ±0.03 dB. Start-up was blind for 100-200 ms (100% then 45% missed) and after silence 37 ms was blanked at T=2.5. Pure noise at T=2.5 had 11.8% of samples zeroed. Code lens: confirmed nob.c:45/119 and nobII.c:148/180, and simulated 43.5% of pure-noise samples altered at T=2.5 at Lyra's default 192 kS/s (about 77 samples blanked per detection). It also found the blind start-up recurs on the first NB enable and avg goes stale across disable and re-enable, because xnob only updates while run=1. Theory lens: derived P_fa=exp(-pi T^2/4) and matched it by simulation, and showed the clipped mean has fixed point (1-d)/(1-dT) and runs away when dT>=1.

**Recommended fix.** Change both nob.c and nobII.c:
(1) Censor the background estimate by skipping the avg update on flagged samples, or use a per-block order-statistic (median) estimator with T rescaled by 0.939. Do not use the clipped mean min(mag, T*avg): it still misses 100% of 15-20x impulses at 1000/s at T=12.
(2) Add a level-step guard based on the fraction of flagged samples, not a K-consecutive count. Example: if more than about 25% of samples in a 5 ms window are flagged, snap avg to an uncensored shadow mean. Scale the window with sample rate. The K-consecutive guard latched after a +20 dB step at T=2.5 and zeroed 80% of samples for at least 400 ms.
(3) Seed avg from the first block's median, not 1.0. Hold avg through exact-zero input. Re-seed on the 0→1 run transition in SetEXTNOBRun / SetEXTANBRun, or have the host flush, because avg is stale from create or from the last disable.
(4) On the Lyra side, in pushNbState, raise the T floor from 2.5 to about 3.5, or map strength through P_fa with T = sqrt(-4 ln P_fa / pi). Recalibrate after censoring, since censoring biases avg slightly low at small T (11.8% to 13.7% of samples zeroed at T=2.5).

**Disagreements.** All three lenses confirmed the finding and agreed the current-behaviour description is accurate. They split on the remedy.
- Clipped mean vs skip-update censoring: the code lens called the clipped mean the safe choice because it cannot latch. The theory lens and the harness showed it fails exactly where the bug matters (dense 15-30x impulses at T=12), so the measured harness result wins and skip-update censoring or an order-statistic estimator is recommended. Their latch risk is handled with a guard on the flagged fraction, which the harness validated: it kept all the gains, and the +20 dB step at T=2.5 came out close to the original (2334/4800 vs 1815/4800).
- Severity: the first skeptic rated it medium, saying the start-up and silence effects happen only at creation. The code lens showed the stale avg also bites on every NB enable. The harness showed the blanker is fully disengaged at realistic dense ignition and arcing rates at the default T=12. At Lyra's 192 kS/s default rate, the false-blanking cost at maximum strength is about 4x the finding's 48 kS/s figure.
- Resolution: the effect is at least the claimed size and the result is confirmed. Priority is high because a blanker that switches itself off in dense impulse noise, and zeroes up to 43% of samples at maximum strength, is audible.

**Per-lens results**

- *code* (confirmed): Simulated the real nobII.c, compiled unmodified from a scratchpad copy with a stub comm.h. Settings were Lyra's: mode 0, slew/adv/hang 0.1 ms, backtau 20 ms, max_imp_seq 25 ms. Input was complex white Gaussian noise. The first 1 s was discarded and 5 s measured. At 48 kS/s: T=2.5 zeroed 7.2% of samples and altered 11.7%; T=3.5 altered 0.10%; T=6 and T=12 altered 0. At 192 kS/s, Lyra's default inRate (wdsp_engine.h:97): T=2.5 zeroed 28.1% and altered 43.5%; T=3.5 altered 0.51%; T=6 and T=12 altered 0. The theoretical per-sample P_fa exp(-pi*T^2/4) is 7.38e-3 at T=2.5 and 7.4e-5 at T=3.5. Derived: impulse inflation of (47700+300*100)/48000 = 1.62x, which is +4.19 dB. Onset blanking after silence is N*ln(T/(T-1)): 83.5 samples (1.74 ms) at T=12 and 490 samples (10.2 ms) at T=2.5 for N=960. The times are the same at 192 kS/s. Start-up blind time is backtau*ln(T/E|x|): 7.8 to 9.4 tau for E|x|=1e-3, and about 10 to 11.7 tau for E|x|=1.25e-4. At 192 kS/s with Lyra timings one detection affects about 77 samples (19+19+20+19), not 17. The finding's 17 is the 48 kS/s figure.

- *theory* (confirmed): I simulated the nobII/nob recursion in Python with fs=48 kS/s, backtau=20 ms (N=960), T=12, Rayleigh background with mean |x| = 1, and 3-sample impulses. avg means the background estimate and is reported in steady state.
- 100 impulses/s at 100x: plain avg 1.62 (+4.2 dB), the same as the finding. Clipped mean 1.07 (+0.6 dB). Skip-on-flag 1.00. No impulses missed with any estimator.
- 1000 impulses/s at 15x: plain avg 1.87 (+5.5 dB) and 100% of impulses missed. Clipped mean also 1.87 and 100% missed. Skip-on-flag 1.00 and 0% missed.
- 1000 impulses/s at 30x: plain avg 2.81 (+9.0 dB) and 100% missed. Clipped mean the same, 100% missed. Skip-on-flag 0% missed.
- 1000 impulses/s at 100x: plain avg 7.19 (+17.1 dB) but still 0% missed, since 12*7.19 = 86 < 100. Clipped mean 3.69 (+11.3 dB).
- Clipped-mean steady state when every impulse is caught: avg = (1-d)/(1-d*T), where d is the impulse duty cycle. It runs away when d*T >= 1, for example d >= 8.3% at T=12.
- False-alarm rate: P_fa = exp(-pi*T^2/4) gives 0.738% at T=2.5, and the simulation gave 0.711%. The same formula gives 6.6e-5 at T=3.5 and 3.5e-6 at T=4.
- Expected blanked fraction at T=2.5 with about 17 blanked samples per detection: 1-exp(-0.0074*17) = about 10-12%.
- Onset lag: N*ln(T/(T-1)) = 84 samples (1.7 ms) at T=12 and 490 samples at T=2.5.
- For Rayleigh noise the median of |x| is 0.939 times the mean.

- *harness* (confirmed): Setup: the real WDSP 2.11 nobII.c (create_nob, flush_nob, xnob) built with clang -O2 -arch arm64 behind a pthread shim. Parameters match Lyra: mode 0 (zero), slew, hang and adv all 0.1 ms, max_imp_seq 25 ms, backtau 20 ms, 48 kS/s, block size 1024. Test signal: complex Gaussian noise with E|x| = 1e-3 plus 3-sample impulses, xorshift RNG. Statistics are taken over the last 1.5 s of a 2 s run.

T1, dense impulses, threshold rise as 20log(avg/E). Each cell is orig -> censored fix (skip the update on flagged samples).
- 100/s at 100x: +4.33 dB -> +0.04 dB. The finding's 4.2 dB figure is confirmed.
- 300/s at 15x, T=12: +2.0 dB with 23.5% of impulse samples missed -> 0% missed.
- 1000/s at 15x or 20x, T=12: +5.5 to +6.8 dB with 100% missed -> 0% missed.
- 1000/s at 50x: +12.1 dB with 14% missed -> 0%.
- 1000/s at 100x: +17.1 dB. The skeptic's roughly 17 dB is confirmed.
- 2000/s, T=12, every amplitude from 15x to 100x: +8.8 to +22.7 dB with 100% missed (the blanker is fully disengaged) -> about 0 dB, 0.3 to 0.6% missed, residual impulse energy -22 to -25 dB.
- At T=4, impulse capture was equally good in orig and fixed (0% missed up to 1000/s; 0.3 to 0.5% at 2000/s), but orig's estimate was still inflated by 0.7 to 22.5 dB and the fix's stayed within ±0.03 dB.
- Clip-mean variant min(mag, T*avg): it helps at T=4 (about 2 dB instead of 17 dB at 1000/s) but barely at T=12. At 1000/s with 15x or 20x impulses it still misses 100%, and at 2000/s it still misses 100%.

T2, start-up with E|x| = 1e-4 and 100x impulses at 200/s, T=12. Orig missed 100% of impulse samples from 0 to 100 ms and 45% from 100 to 200 ms, then 0% after 200 ms. Fixed (seeded from the median of the first block): 0% throughout.

T3, 1 s of exact zeros followed by noise.
- Orig at T=12: 168 of the first 240 samples zeroed, and the first clean 1 ms starts at +172 samples.
- Orig at T=2.5: 1700 of the first 2400 samples zeroed, and the first clean 1 ms starts at +1756 samples (37 ms).
- Fixed (avg held through zeros): 0 zeroed in the first 5 ms in both cases.

T4, pure noise, fraction of samples zeroed, orig / censored / clip.
- T=2.5: 11.8% / 13.7% / 12.3%. The finding's roughly 10% is confirmed, and censoring biases avg about -0.11 dB, which makes this slightly worse.
- T=3: 1.46% / 1.56% / 1.51%.
- T=3.5: 0.145% in all three.
- T=4: 0% / 0.010% / 0.010%.

T5, noise steps up 20 dB.
- T=12: harmless in every build (96 to 132 samples zeroed).
- T=2.5, orig: 1815 of 4800 samples zeroed in 0 to 100 ms, and 2350 of 19200 in 100 to 500 ms.
- T=2.5, censored fix with the proposed K-consecutive guard (K = 5 ms): 4800 of 4800 zeroed in 0 to 100 ms and 15302 of 19200 (80%) in 100 to 500 ms. This is a latch regression.
- T=2.5, guard changed to "more than 25% of samples flagged in a 5 ms window, then snap avg to an uncensored shadow mean": 2334 of 4800 and 2744 of 19200, close to orig. That variant keeps every T1, T2 and T3 gain.

### #14 rmatch control loop: averaging windows are counted in callbacks, not seconds, so loop stability depends on buffer size

**Priority:** high · **Verdict:** confirmed · **Area:** resampling · **Where:** `rmatch.c:control (L256-273), xmav (L56-69), calc_rmatch pr_gain (L147), create_rmatchV defaults (L519-524), xrmatchIN/xrmatchOUT control calls (L359, L464)`

**Evidence.** All three lenses agree. The code lens checked every cited line in rmatch.c. Its linear analysis matches the theory lens exactly: loop gain k = 0.192 s^-1 at any sample rate, and the loop is stable only while kT < pi^2/2, which means more than about 637 calls/s. At 64/64 blocks the phase margin is 38 deg; at 256/256 the phase is -203 deg at crossover, so the loop is unstable. The legacy gain of 1e-6 moves the limit to just above 512-sample blocks, which independently matches the W4WMT comment at L734. The harness lens ran the real rmatch.c and varsamp.c (arm64) with a +100 ppm clock offset and 2 ms jitter. At B=64 and B=128 there were 0 underflows and 0 overflows. At B>=256 the unmodified code fell into a limit cycle bounded by the ring: 4400-10400 underflows and overflows each over 600 s, with ratio swings of +/-1-2% at ring sizes 16384 and 4096 alike. After a step, B=128 overshot by 74% and was still ringing 400 s later. Both fixes gave 0 underflows and overflows at every block size: windows scaled to seconds through the existing setters, and a PI loop. A real Lyra host (Lyra-SDR-cpp, rmatchOUT at 256 samples with the VAC block defaulting to 2048, about 211 calls/s) sits inside the unstable region.

**Recommended fix.** Make the fill-loop smoother time-based while keeping today's loop gain.
- Preferred: replace the call-counted xmav boxcar with a 1-pole updated by elapsed time per call, alpha = (block/rate)/tau. Use tau of about 1/(2k), roughly 2.6 s, for damping near 0.707.
- Alternative: size prop_ringmin/max, and the ff windows, in seconds scaled by the nominal call rate (rate/insize + rate/outsize). Round to a power of two, because xmav/xaamav use a mask.
- Keep the count-ratio feed-forward. It already gives zero steady-state error, so a type-II PI integral is optional. If one is added, it needs anti-windup at the +/-4% clamp and at the over/underflow resets, plus a var slew limit.
- Keep the exported setters (FeedbackGain, PropRingMin/Max, FFRingMin/Max, FFAlpha) working through a compatibility mapping.
- Add regression tests with the harness scenarios (B = 64 to 1024, ring 4096 and 16384, 100 ppm offset, input stall) that require zero underflows and overflows in steady state.
- Note for later: callback-phase aliasing leaves a ratio wobble of about gain*blocksize at large blocks.
- Do not claim lower latency or faster lock until they are measured.

**Disagreements.** There is no disagreement on the finding itself. All three lenses confirm it, agree the description of the code is accurate, and rate the fix "yes-with-changes". They differ only on how much fix is needed.
- The theory and code lenses prefer a minimal fix (a 1-pole or windows in seconds). The harness backs this: the setter-only time scaling (origT) removed every underflow and overflow just as the PI loop did.
- The PI loop improved damping (step overshoot about 24% against 38%), at a small cost: 7 ppm against 3 ppm of steady-state ratio noise at B=64, and a larger initial pitch excursion after a step.
- Resolution: the minimal time-based smoother is the required fix. PI is optional.
- Overstated benefits, flagged by the lenses: "locks in seconds" ignores the deliberate 3 s startup delay, and "shrinks latency" is unverified because the host sets the ring size.

Harness results were checked in /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/verify2/h14/out/summary.txt and are consistent with the linear predictions.

Priority is set high because the effect is audible (periodic glitches and ratio swings of up to +/-2%, which hurt FT8 and voice). The Lyra host's VAC settings (256/2048) fall in the unstable region.

**Per-lens results**

- *code* (confirmed): Every cited line checks out in rmatch.c (WDSP 2.11): control at L256-273, xmav at L56-69, pr_gain at L147, the create_rmatchV defaults at L519-524 (ff 4096/262144/0.01, prop 4096/16384, gain 4e-6), the control calls at L359 and L464, and the W4WMT 1e-6 comment at L734. var multiplies the resampling ratio (varsamp.c L133, cvar = var*nom_ratio), so the feedback sign is correct. The plant gain is k = 4e-6*48000 = 0.192 s^-1 at any rate.

I solved s^2*T + k(1 - e^{-sT}) = 0 for the closed-loop poles, with T = 16384/(calls per second):
- 1500 calls/s (64/64 at 48k): T = 10.9 s, phase margin 37.9 deg, pole -0.061 +/- 0.21j.
- 797 calls/s (64/1024): phase margin 10.1 deg, about 44 s ringing period, decay time constant 119 s.
- 750 calls/s: phase margin 7.4 deg, decay time constant 175 s.
- 637 calls/s: stability boundary (T = pi^2/(2k) = 25.7 s).
- 375 calls/s (256/256): phase margin -22.7 deg, crossover 0.090 rad/s, phase -202.7 deg, growth time constant 112 s.
- 187.5 calls/s: phase margin -47 deg.

Time-domain simulation of the exact control law (my own C code: xmav, xaamav, ff_alpha, clamp, ring 11520, 100 ppm offset, 1200 s run), last 100 s:
- 64/64: |dev| at most 65, no over/underflows.
- 128/128: 135, none.
- 64/1024: 544, none.
- 64/2048: 1056, none.
- 1024/64: 545, none.
- 256/256: dev pinned at +/-5760 (the ring edge), var 0.9865-1.0134, 3870 overflows and 1962 underflows.
- 512/512: same pinned limit cycle.
- 256/1024 (20 ppm): limit cycle with over/underflows.
- 256/2048 (20 ppm): limit cycle with over/underflows.

A 2000-sample offset at 64/1024 rings with a period of about 45 s and var swings of about +/-0.4%, decaying over several minutes.

- *theory* (confirmed): Loop model: with the feed-forward at the true ratio, d(dev)/dt = -k*avg(dev), where k = 4e-6*48000 = 0.192 s^-1 at any rate. avg is a boxcar over 16384 calls. The calls from both sides count, so the window is T = 16384/(fin/insize + fout/outsize).

Exact stability limit for an integrator plus a boxcar: phase reaches -180 deg at wT = pi, and |L| = 2kT/pi^2 there. The loop is stable only if kT < pi^2/2 = 4.93, i.e. T < 25.7 s. That means more than 638 calls/s, so symmetric 48 k blocks below about 150 samples. Results by block size (48 k in and out):
- 32: kT = 1.05, PM 61 deg
- 64: kT = 2.10, crossover 0.167 rad/s, PM 37.9 deg
- 128: kT = 4.19, PM 7.4 deg
- 256: kT = 8.39, phase -203 deg at crossover 0.090 rad/s, Nyquist real-axis crossing at -1.7 (unstable)
- 512: real-axis crossing at -3.4
- 1024: real-axis crossing at -6.8

With the legacy gain of 1e-6 the limit becomes T < 103 s, about 160 calls/s. 512-sample blocks (187.5 calls/s) are then just stable and 1024 is not, which matches the W4WMT comment at L734 ("to help Primary buffers > 512").

Time-domain simulation of the exact update law: in and out calls interleaved by real time, 100 ppm offset, the real count-ratio feed-forward (4096/262144, alpha 0.01), the +/-4% clamp, 900 s run.
- Unbounded ring, peak |dev| over the last 150 s: 64 → 65 (decayed; the residue is the block sawtooth), 128 → 139 (decaying slowly), 256 → 36,139, 512 → 78,758, 1024 → 90,353.
- With a 16384 ring and the default boxcar, over the last 300 s:
  - 256-sample blocks: about 8,100 overflow-clamped and 8,100 underflow-clamped calls, var swinging 0.980-1.019 (about +/-2%; 1500 Hz audio moves about +/-29 Hz).
  - 1024-sample blocks: 3,229 / 2,743 such calls, var 0.989-1.010.
  - 64-sample blocks: 0 / 0, var within 1e-4.
- Same gain with the boxcar replaced by a 1-pole, tau = 2.6 s, updated with dt/tau: 0 over/underflows at 64, 256 and 1024. var stays within 0.9998-1.00006 at 64 and 0.9988-1.0002 at 256. At 1024 it shows brief dips to 0.995.
- I traced those 1024 dips to aliasing between the callback phases, not to the loop. At 100 ppm with equal 1024 blocks the in/out callback phases beat with a period of about 213 s. That shifts the measured mean fill by about one block (avg dev moved 1234 → 505), and the loop follows it, giving a transient var excursion of about gain*block = 0.4%.

Design value: an integrator plus a 1-pole gives zeta = 1/(2*sqrt(k*tau)), so zeta = 0.707 needs tau = 1/(2k) ≈ 2.6 s. A fixed-time boxcar of about 2 s gives kT ≈ 0.38 and a PM of about 79 deg.

- *harness* (confirmed): Setup: real WDSP rmatch.c and varsamp.c (2.11), plus fir_bandpass copied verbatim from fir.c with the impulse cache removed. Built with clang -O2 -arch arm64 behind a POSIX comm.h shim. create_rmatchV defaults, 48k in and out, matched block sizes B, input clock +100 ppm (var_true = -100 ppm), 2 ms uniform callback jitter, seed 7. Three builds:
- orig: unmodified rmatch.
- origT: unmodified code with prop_ringmin/max scaled to time through the existing setters (4096*64/B and 16384*64/B).
- fixed: the time-based PI loop (bw 0.02 Hz, zeta 0.707, 1-pole tau 0.5 s, dt = half the block duration per call, ff count ratio removed).

S1 (900 s run, steady state t>=300 s, ring 16384):
- B=64: all three builds 0 UF/OF, peak |dev| 53 samples.
- B=128: all three builds 0 UF/OF, peak about 100.
- B=256: orig 7324 UF / 7185 OF (about 12/s each), peak |dev| 8192 (the whole half-ring), var error +/-19,100 ppm. origT and fixed: 0 UF/OF, peak 184-186, var error within -272/+158 ppm.
- B=512: orig 8896 UF / 10414 OF, var +/-15,000 ppm. origT and fixed: 0/0, peak 398/464.
- B=1024: orig 4431 UF / 5019 OF, var +/-10,500 ppm. origT and fixed: 0/0.
- Ring 4096 gives the same pattern: orig has 5900-9700 UF at B>=256; origT and fixed have 0.
- Orig at B=256, ring 16384: no clean fill-level growth; the 20 s-window swing widened from -189/+171 samples (0-20 s) to -1494/+1528 (260-300 s), then the over/underflow cycle took over.

S2 (100 ms input stall at 400 s, 4800 samples lost, ring 16384):
- Overshoot and 10% settling time:
  - B=64: orig 39% / 35 s, origT 39% / 35 s, fixed 23.5% / 29 s.
  - B=128: orig 74% overshoot and still oscillating (+/-600 samples) after 400 s, about a 60 s period. origT 37% / 36 s. fixed 23.5% / 29 s.
  - B=256 and B=512: orig is in the over/underflow cycle. origT 38-42% / 36 s. fixed 24-28% / 30-32 s.
  - B=1024: settling time is dominated by about 1000-sample block sawtooth noise for every build.
- Peak post-stall var error: orig B=64 -5417/+13396 ppm, fixed +16706 ppm.
- Small-block cost of the fix: steady var rms at B=64 is 3 ppm for orig and 7 ppm for fixed.

### #1 Musical-noise control: selective cepstral smoothing of gains, soft (not binary) zeta mask in method 3, and a stronger xi_min

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** spectral-nr · **Where:** `emnr.c:aepf (849-896); calc_gain case 3 (1216-1220); calc_emnr 365 (xi_min); calc_gain case 1 (1150-1152, no xi floor)`

**Evidence.** Harness (real WDSP 2.11 emnr.c, arm64; the fixed build is bit-identical to the original with all fixes off). aepf applies no smoothing (N=1) in 69-90% of speech frames at 10 dB SNR and 95-100% at 20 dB, but in 0% at 0 dB. (b) The method-3 sigmoid soft mask cuts gain-induced isolated peaks in noise-only frames by 13-16x (0.099 to 0.006-0.0075) and flicker by about 9x at 0 dB. SDR is unchanged or slightly better; noise attenuation falls about 5 dB. (c) xi_min at -20 dB costs 0.6-1.7 dB of attenuation and barely changes the musical-noise metrics; it has no effect on stock method 2. (a) Passband-only cepstral smoothing on stock method 2 cuts isolated peaks about 10x, but SDR collapses (15.5 to 4.3 dB at 10 dB SNR; 24.1 to 8.0 dB at 20 dB) and SA rises about 3 dB. Without aepf it is worse than the original. On method 3 it is catastrophic (SA 43-100 dB). The code and theory lenses agree on the facts. In WDSP, DD alpha is 0.98 and xi_min is -40 dB. Cappé recommends about -15 dB at alpha 0.98; the finding's "-25 dB" is a miscitation. RXA's stock path is gain_method 2, which ignores xi_min. Breithaupt 2007 shows clear wins only in nonstationary noise; for stationary noise it was a tie (18% vs 18%).

**Recommended fix.** Adopt (b) in LyraDSP. In gain method 3, replace the hard 1/0 zeta decision with p = 1/(1+exp(-(zeta_hat - zeta_thresh)/s)) and G = G_TS^p * G_min^(1-p). The harness used s≈0.5 and G_min≈0.1 (-20 dB); expose G_min. Centre the sigmoid on g.zeta_thresh in zeta_hat units. Leave bins outside the table on the two-step gain. Keep it bit-exact switchable so it can be compared against the original. For (c), add a user-adjustable xi_min with the current -40 dB as default. Optionally apply the same floor in methods 1 and 2, documented as an attenuation-vs-steadiness trade-off rather than a fix. Do not ship (a), cepstral smoothing, as a default. Only consider it as an experimental voice-only option if all of these hold: it is restricted to the passband, it runs after aepf and never on method 3's mask, it has a gain floor, it has pitch-protected quefrencies, and it has been retuned until SDR no longer regresses. In the harness it removed isolated peaks but degraded speech by 10-16 dB SDR.

**Disagreements.** The code and theory lenses marked the description inaccurate. The harness marked it accurate overall. All three agree on the facts:
- aepf is not the only control: DD smoothing at alpha 0.98, witchHat and post2 also act.
- The method-3 mask is binary only where getZeta succeeds.
- aepf's idle threshold is about 0.737, not 0.75.
- Stock method 2 is missed by part (c).

I resolved it as "core mechanism real, description overstated". The gap in speech frames is measured, but it applies only at moderate and high SNR.

On the size of the benefit, the harness outranks the theory lens:
- (b) is confirmed at a large size, but it affects only the non-default "Trained" method 3.
- (c) is marginal. The harness found a smaller effect than the theory lens's white-noise Monte Carlo (LKR 0.55 to 0.20), which ignored aepf. I weight the harness, which ran the full chain.
- (a) did not reproduce the claimed "better speech distortion at the same attenuation". It reduced musical noise but harmed speech badly.

The harness author notes that the cepstral penalty may partly come from tuning (85 ms frames, synthetic speech). That keeps (a) open as research rather than refuted outright.

The net "clearly audible improvement on weak SSB" claim is unsupported for the stock path. So the verdict is confirmed-smaller and the priority is medium: (b) and the xi_min knob are cheap and worth doing during extraction.

**Per-lens results**

- *code* (partly): From the code, at 48 kHz with RXA defaults (fsize 4096, ovrlp 4, so incr = 1024 and msize = 2049): the DD smoothing constant is tau = -128/8000/ln(0.985) = 1.059 s, giving alpha = exp(-1024/48000/1.059) = 0.980. That is a Cappe-style decision-directed smoother, and it is already active. xi_min = 1e-4 (-40 dB, line 365). aepf N = 1 whenever zeta >= 0.75. N also stays 1 for zeta just under 0.75 (0.7366 to 0.75), because round(20*(1 - zeta/0.75)) is still 0 there. The maximum is N = 41 as zeta approaches 0. method 3 multiplies the whole mask by 0.05 (-26 dB) when zetaT < 0.20. getZeta default zeta_thresh = -2.0 (line 391). post2.run defaults to 0 (line 563). Stock RXA create_emnr (RXA.c lines 323-336): run = 0, gain_method = 2, npe_method = 0, ae_run = 1.

- *theory* (partly): WDSP's DD smoothing constant, from emnr.c:360-361 (tau = -128/8000/ln 0.985 = 1.058 s; rate 48 kHz, FFT 4096, overlap 4, hop 1024), is alpha = 0.9800. That is the same value Cappé analysed.

I ran a stdlib Python Monte Carlo of WDSP gain method 0 (DD + MMSE-STSA + witchHat, q = 0.2) on white Gaussian noise only, with no aepf: 400 bins x 500 frames, assuming an ideal noise PSD.
- With xi_min = -40 dB (current): the average a-priori SNR in noise is -18.0 dB. The floor binds only 3.3% of the time. Noise attenuation is 13.2 dB. Musical-noise proxy, the log-kurtosis ratio (LKR) of output vs input power, is 0.55.
- With xi_min = -25 dB: floor binds 27.5% of the time, attenuation 13.2 dB, LKR 0.45.
- With xi_min = -20 dB: floor binds 50%, attenuation 9.9 dB, LKR 0.20.
- With xi_min = -15 dB: floor binds 77%, attenuation 6.4 dB, LKR -0.35.
So raising xi_min to -20 dB removes most of the outlier excess, at a cost of about 3.3 dB of noise attenuation.

My runs that added aepf gave non-monotonic numbers, because the pooled kurtosis mixes in frame-to-frame changes in level. I set them aside as unreliable.

Breithaupt 2007 setup: fs = 8 kHz, M = 256 (32 ms), 50% overlap, xi_min = 0.2 (about -7 dB), beta = 0.8, beta_pitch = 0.4, k_low = 4.
- Mapped to WDSP, the pitch range 70-500 Hz becomes quefrency 96-686 samples, and k_low = 4 at 8 kHz becomes about 24 samples (0.5 ms).
- SSB voice (about 300-2700 Hz) fills roughly 200 of 2049 bins. A full-band cepstrum would therefore dilute the pitch peak by about 10x, so the cepstrum must be taken over the passband only.

- *harness* (partly): Setup: real WDSP 2.11 emnr.c, built with clang -O2 -arch arm64 and FFTW3. Parameters: fs 48 kHz, fsize 4096, ovrlp 4, bsize 1024, npe 0, ae_run 1 unless stated. Input is speech-like harmonic syllables plus white noise, both band-limited to 200-2900 Hz (the nbp0 band). Timing: 0-4 s noise only, then 4 sentences of 2.5 s with 1 s pauses; 18 s total; deterministic xorshift RNG. Metrics are taken in the 300-2800 Hz bins by shadow filtering: each frame's final mask is applied to separate STFTs of the clean signal S and the noise W, aligned to EMNR's own frames (alignment error 0.0). A fixed build with all fixes off is bit-identical to the original.

Metrics:
- iso: rate of output TF cells whose power exceeds 4x the mean of their 8 neighbours. Input noise scores 0.0000, so every iso count comes from the gain.
- flicker: frame-to-frame |dG| / mean G.
- NA: noise attenuation in dB.
- SA: speech attenuation in dB.
- SDR: S/((1-G)S) in dB.
- Speech-free cells: cells inside speech frames where speech is more than 20 dB below the noise.

Premise check: aepf has N=1 (no smoothing) in this share of speech-active frames:
| SNR | Frames with N=1 |
|---|---|
| 0 dB | 0% |
| 10 dB | 69-90% |
| 20 dB | 95-100% |

(b) Sigmoid soft mask in method 3 (s=0.5, Gmin=0.1):
| Metric | Original | Soft mask |
|---|---|---|
| Noise-only iso, 0 dB | 0.0993 | 0.0060 |
| Noise-only iso, 10 dB | 0.0993 | 0.0072 |
| Noise-only iso, 20 dB | 0.0992 | 0.0075 |
| Flicker, 0 dB | 1.32 | 0.15 |
| Speech-free iso, 0 dB | 0.106 | 0.032 |
| Speech-free iso, 10 dB | 0.046 | 0.024 |
| Speech-free iso, 20 dB | 0.026 | 0.010 |
| Noise-only NA | 49.6 dB | 44.5 dB |
| SDR, 0 dB | 1.51 | 1.82 |
| SDR, 10 dB | 11.92 | 12.07 |
| SDR, 20 dB | 20.22 | 20.89 |
| dSNR, 0 dB | 7.41 | 4.97 |
| CW 700 Hz tone loss | 41.2 dB | 36.0 dB |

(c) xi_min raised to -20 dB (methods 0/1/3):
- Noise-only NA falls by 0.6-1.7 dB.
- Noise-only iso is unchanged (method 0: 0.0107 to 0.0109).
- Speech-free iso drops slightly (method 0: 0.0150 to 0.0138 at 0 dB, 0.0353 to 0.0307 at 10 dB).
- Speech-free LKR drops for method 1 (5.26 to 3.26 at 0 dB).
- SDR is essentially unchanged.
- Method 2, the RXA default, is not affected.

(a) Breithaupt 2007 cepstro-temporal gain smoothing (paper constants rescaled to fs and hop; pitch-quefrency reset):
- Full-band (2049-bin) version, method 2:
  - Noise-only iso: 0.0062 to 0.0021.
  - Speech-free iso at 10 dB: 0.0504 to 0.0148.
- Passband-only version, method 2, aepf on:
  - Noise-only iso: 0.0062 to 0.0005.
  - Noise-only flicker: 0.160 to 0.064.
  - Speech-free iso: 0.0504 to 0.0049 at 10 dB; 0.0557 to 0.0111 at 20 dB.
  - NA: +2.5 to +3 dB.
  - Speech distortion gets much worse: SDR 15.5 to 4.3 dB at 10 dB and 24.1 to 8.0 dB at 20 dB; SA 0.53 to 3.83 dB at 10 dB.
  - Clamping G to [0.01, 1] does not fix this: SDR 8.8 at 20 dB, 4.1 at 10 dB.
- Without aepf (cepstral smoothing as a replacement): noise-only iso is 0.0130, worse than the original's 0.0062.
- Combined with method 3's raw 0/1 mask: catastrophic. SA reaches 45-100 dB at 0 dB SNR and flicker reaches 314.
- All three fixes on method 3 at 0 dB: SA 43 dB vs 12.9 dB originally, because the cepstral smoothing pushes zeta below t2 and triggers aepf's x0.05.
- CW tones are lost to the noise estimator in every variant: 17-23 dB for methods 0-2. The cepstral smoothing adds about 3 dB.

### #2 SNBA: make the AR fit unconditionally stable (windowed autocorrelation, white-noise correction, bandwidth expansion, reflection guard)

**Priority:** medium · **Verdict:** confirmed · **Area:** lms-nr · **Where:** `lmath.c:asolve (lines 93-125), called from snb.c:execFrame (lines 505, 524)`

**Evidence.** Code lens: lmath.c:93-125 matches the finding. r[i] = sum_{j<xsize} x[j]x[j-i] reads xbase history, Levinson has no guard, and line 123 checks only for NaN. Theory and code harnesses: Levinson goes unstable (|k|>=1 or beta<=0) in 65-100% of frames on band-limited audio, with |k| up to 1e6 and |a| up to 1.4e5. The biased frame-only estimator never went unstable. The faithful real-SNBA harness (verbatim snb.c/asolve, files checked, results.txt read) measured three things. (1) No NaN ever reached the output: silence gave 375 NaN a-vectors and the guard zeroed all of them. (2) With the minimal fix (biased autocorrelation plus |k|/beta stop plus isfinite), output SNR with impulses rose 15-40 dB on tonal signals (pure tone 18.9->58.7 dB, carrier 18.7->47.7 dB) and peak clicks fell from 8x to 1x signal level. Noise and speech changed by only about +/-1 dB. (3) The fix has regressions when no impulses are present: CW + weak noise 44.7->26.4 dB (15% of samples rewritten) and speech-like -3.4 dB. The proposal's Hann + WNC 1e-4 + gamma 0.995 recipe lost 4-8 dB on band-limited noise.

**Recommended fix.** In LyraDSP asolve (keep it Float64), compute r as the biased autocorrelation of the current frame only: r[i] = sum_{j=i}^{N-1} x[j]x[j-i]. Do not reach into the xbase history and do not apply a taper. In the Levinson loop, stop and keep the lower-order model when beta <= 1e-9*r[0] (or r[0] <= 0) or when |k| >= 0.9999. Zero any non-finite a[i]. Do not adopt the Hann window, the 1e-4 white-noise correction or gamma=0.995 bandwidth expansion; if any expansion is wanted, use gamma >= 0.9995 and re-measure it. Ship the change together with a re-tune of the detector thresholds k1/k2, which were effectively tuned against the old garbage residual. Gate it behind regression tests that cover: no-impulse false-detection rate and output SNR on CW + weak noise, carrier, speech and band-limited noise; impulse repair on tone/carrier/CW/noise; and digital silence. The fix is acceptable only if the no-impulse CW and speech cases stay within about 1 dB of stock. Treat item (5), the covariance-method refit that excludes zeroed samples, as a separate, untested experiment. WDSP's npasses=2 refit already approximates the Janssen iteration.

**Disagreements.** All three lenses agree the code description is accurate and the defect is real. The code lens rated it confirmed; the theory and harness lenses rated it partly, because the stated benefit is wrong in kind. Instability is the normal case on band-limited audio, not a rare event. NaN/Inf poisoning never happens. Only the FIR A(z) is applied, so "unstable inverse filter" is the wrong framing. I resolved this as confirmed. The measured harm is at least as large as claimed, though through a different mechanism: a garbage whitening model, which on tonal signals produces wild xHat interpolations and over-detection. The finding's own "marginal on static crashes" matches the measured +0.7-0.9 dB on noise. All lenses agree the fix is sound only with changes: the minimal biased estimator beats the proposal's taper, WNC and gamma recipe, which the harness showed regressing. Priority is medium rather than high. The tonal/CW gains are large and audible, but the minimal fix also regresses (CW without impulses loses 18 dB, speech loses 3.4 dB) until the detector thresholds are re-tuned, so it is not a drop-in change. It belongs in the extraction work, done together with the re-tune and regression tests.

**Per-lens results**

- *code* (confirmed): My own harness (/private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/v2ct/t.c, t2.c). It uses the asolve code verbatim plus counters, 12 kHz, N=256, order 64, hop 64 (ovrlp 4), and 5000 frames of Gaussian noise band-limited with a 1025-tap Blackman FIR.

Current estimator, frames with |k|>=1 (each also had beta<=0):
- 250-5400 Hz (stock bpsnba edges): 3729/5000, max|k| 2.4e4, max|a| 7.8e3, worst in-frame invf residual/signal 7.5e6, mean residual +0.1 dB (no whitening at all).
- 250-2900 Hz (SSB-like): 4007/5000, max|k| 1.1e6, mean residual -10.3 dB.
- 250-2900 Hz plus a strong 1 kHz carrier: 5000/5000.
- 0-6000 Hz (white): 35/5000.

Biased autocorrelation (j starting at i, frame only, no taper), same data: 0 unstable frames in every case. max|k| was 0.42, 0.83 and 0.98, and mean residual -3.8, -16.0 and -26.3 dB.

I did not re-measure the xHat interpolation error myself.

- *theory* (partly): Own harness at /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/v2lit/t.c. It uses WDSP's asolve r-estimator verbatim (r[i]=sum_{j<N} x[j]x[j-i], with history reaching back into xbase) and the SNBA defaults: N=256, order 64, 12 kHz, hop 64, 3004 frames. A frame counts as unstable when any |k|>=1 or beta<=0.
- Noise band-limited to 2.9 kHz (Blackman-windowed sinc, 201 taps): WDSP 1941/3004 unstable (65%), max |a_i| about 3e3. The same holds with a white floor 37 dB down (1955/3004). Biased (zero-outside-frame) estimator: 0/3004, max |a| 14.
- 700 Hz tone plus weak band-limited noise: WDSP 3004/3004 unstable, max |a| up to 7e4. Biased: 0.
- Nearly white noise: WDSP still about 0.7% unstable (20-55 frames out of 3004). Biased: 0.
Derived: bandwidth expansion with gamma=0.995 widens each pole by about fs*(-ln gamma)/pi = 19 Hz at 12 kHz, and shrinks a_64 to 0.995^64 = 0.73. That is far heavier weighting than in G.729/AMR at order 10. Order 64 on N=256 gives p/N=0.25, a regime where the Bartlett bias of the biased estimator, and the extra loss from a Hann taper, both matter.

- *harness* (partly): Harness: the real WDSP 2.11 SNBA (create_snba, xsnba, execFrame, invf, det, scanFrame, xHat, trI, dR, median, asolve) at 12 kHz with the RXA.c defaults (xsize 256, asize 64, ovrlp 4, npasses 2, k1 8, k2 20, b 10, pre/post 2, pmultmin 0.5). bsize is 64, the resampler is bypassed (inrate = internalrate), the measured delay is D = 192, each run is 20 s, and 240 impulses of 1 to 4 samples are added at 10x or 30x the signal RMS. Builds: orig = verbatim asolve plus counters only. fix1 = biased frame-only autocorrelation, Levinson stop at |k| >= 0.9999 or beta <= 1e-9*r0 keeping the lower order, and an isfinite guard. fix2 = proposal items 1-4 (Hann window, WNC 1e-4, gamma 0.995, same stop). fix2g = fix2 with WNC 1e-9 and gamma 0.9995.

Levinson instability in orig (|k| >= 1 or beta <= 0), as a share of asolve calls: band-limited noise 67-75%, CW + noise 74-91%, carrier + weak noise 79-99.7%, speech-like 47-50%, pure tone 75-99.7%. Peak values were max|k| 9.05e5 and max|a| 1.42e5. In all fixed builds it was 0% (the guard fires only in silence) and max|a| was 10.6 or less.

Digital silence (2 s): orig produced 375 non-finite a-vectors, all zeroed by the NaN guard. Output NaN count was 0 in every build and case, and there was no latch.

Overall output SNR vs the clean reference, orig -> fix1 (fix2):
- Carrier + impulses (10x): 18.7 -> 47.7 dB (42.9). At 30x: 20.0 -> 35.4 (56.7).
- Pure tone + impulses (10x): 18.9 -> 58.7 (44.5). At 30x: 20.9 -> 37.1 (55.3).
- CW + noise + impulses (10x): 24.9 -> 25.7 (35.9).
- Band-limited noise + impulses (10x): 21.3 -> 22.2 (17.3). At 30x: 22.2 -> 22.9 (17.5).
- Speech-like + impulses (10x): 23.1 -> 22.2 (24.2). At 30x: 21.1 -> 22.8 (23.2).

Regressions with no impulses (false-detection damage):
- CW + weak noise: 44.7 -> 26.4 dB in fix1, with modified samples rising from 1.2% to 15.4%. fix2 gives 36.2 dB, fix2g 43.4 dB.
- Speech-like: 25.9 -> 22.5 dB in fix1 (fix2 25.6).
- Band-limited noise: fix2 gives 18.2 dB and fix2g 14.6 dB against 25.7 for orig, because 4.8-7.3% of samples are modified against 0.7%. fix1 gives 25.7, about the same as orig.

Worst single-impulse residual energy relative to local signal energy, orig -> fix1:
- Noise at 30x: 5.37 -> 1.00
- Carrier at 30x: 8.89 -> 0.99
- Carrier at 10x: 3.29 -> 0.0046
- Pure tone at 10x: 12.7 -> 0.0044
- Speech at 10x: 5.93 -> 0.81

fix2 on speech was worse than orig: 39.8 at 10x and 30.8 at 30x.

Peak output: on the pure tone (amplitude 0.1) with 10x impulses, max|out| was 0.80 in orig and 0.10 in fix1. On the carrier (0.3) at 30x it was 1.10 in orig and 0.30 in fix1.

Every build repaired all 240 impulses (orig missed 1 of 240 on the pure tone at 10x). Over-detection near impulses on tonal signals: orig modified 7.1-7.5% of samples, fix1 2.9-4.1%.

### #3 Detect impulses on a linear-prediction residual instead of raw |x|, so strong signals neither hide impulses nor trigger the blanker

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** noise-blankers · **Where:** `nobII.c:xnob lines 179-184 (and nob.c:xanb lines 118-123)`

**Evidence.** Harness (the real WDSP 2.11 nobII.c built for arm64, with only the detector patched to an order-8 NLMS residual): a shaped CW key-down went from 125 to 0 flags at 40 dB/T=12 and from 44 to 0 at 20 dB/T=6. SSB-envelope false flags went from 24 to 0. Noise-only P_fa is unchanged (7.17e-3 vs 7.35e-3, Rayleigh 7.4e-3). Impulses under a 40 dB carrier went from 0/15 to 15/15 detected, and with 4-16 carriers from 2/15 or 0/15 to 15/15; order 8 fails at 32 carriers. However, blanking those newly detected impulses with WDSP's existing gap fill raised window error by +3.9 to +32.7 dB (SSB case +13.8 dB, 4-16 carriers +1 to +6.8 dB), so the anti-deafness benefit is net negative for output quality. The code lens confirmed the nobII.c:179-184 and nob.c:118-123 description exactly. At stock host settings (backtau 50 ms, T≈3.3, 192 kS/s full-span input) the false-trigger case is worse than claimed: about 19 ms flagged per soft key-down. The theory lens confirmed the mechanism (Kolmogorov-Szego, a (T-1)·A_c detection floor under a carrier) and the cited literature.

**Recommended fix.** Add an optional LP-residual detector to the IQ-rate blankers (nobII xnob and nob xanb) and keep the |x| detector as the default, for backward compatibility.
- Predictor: causal complex NLMS of order 8-16, mu ~0.05, run on the in_idx sample. Detect on |e| > T·EWMA(|e|), using the existing avg/backmult recursion.
- Freeze: stop adapting on flagged samples, but cap the freeze at about 20 samples or max_imp_seq. The cap cuts hard-step and start-up transients from about 165 flags to about 47.
- Rollout: ship the false-trigger removal first. It is an unambiguous win: 0 flags on CW key edges and SSB envelopes.
- Gap fill: do not turn on blanking of impulses found under a strong signal until it fills from the predictor's output or AR interpolation. Zero, hold and linear interpolation of the raw IQ destroy more of the carrier than the impulse added. Otherwise, gate the residual detector to suppress only the false triggers.
- Recalibration: thresholds need new values, including the host's 0.165·UI mapping.
- Limits: blanks get about 5-8 samples longer from smearing, and order 8-16 nulls only a handful of strong signals.
- Cost: about 20 ns/sample, under 1% of one core at 384 kS/s.

**Disagreements.** All three lenses agree the current-behaviour description is accurate. The code lens said 'confirmed'; the theory and harness lenses said 'partly'.

1. Freeze lock-in. The first skeptic reported that an uncapped freeze locks up (10000/10000 flags). The harness's faithful build showed no lock-in: uncapped gave 167 flags, the same as the original, because the existing EWMA background includes flagged samples. Lock-in only arises with a robust scale estimator that excludes flagged samples, such as the one the proposal suggests. Resolution: keep the cap, since it also cuts transients to about 47 flags.

2. Size of the benefit. The code lens found the false-trigger effect larger at stock settings than the finding's examples. The harness measured that the second half of the claimed benefit, detecting weak impulses under a strong carrier, makes output worse with WDSP's existing gap fill (+4 to +33 dB window error). I checked the harness outputs (orig_mode0.txt and fixed_mode0.txt in /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/verify2/h3/) and they match the report. The harness exercised the claim faithfully, so its result outranks the reasoning. It also invalidates the finding's statement that the fix removes gating splatter in the under-carrier case.

Verdict: confirmed-smaller. The key-edge and envelope false-trigger fix is real at or above the claimed size. The deafness fix is real for detection but is net harmful without a companion gap-fill change. The benefit on crowded bands is limited by predictor order.

**Per-lens results**

- *code* (confirmed): Code trace: nobII.c:179-184 and nob.c:118-123 match the finding exactly. avg is updated with the current sample before the compare. backmult = exp(-1/(fs*backtau)) is set at nobII.c:45 and nob.c:47, and avg starts at 1.0.

Stock host configuration, from the Thetis-derived host in kainos-dev:
- ChannelMaster/cmaster.c:43-68 creates ANB and NOB with backtau 0.05 s and threshold 30.0, but the UI immediately overrides the threshold. setup.cs:8863 sets NBThreshold = 0.165*udDSPNB, and radio.cs defaults nb_threshold to 3.3.
- The blankers run in place on pcm->in at the receiver's input rate (xcm_inrate, the full DDC span, typically 192 kS/s). They run after xpipe and before Spectrum0 and the RXA channel (cmaster.c:350-352). WDSP itself never instantiates them; they exist only for host or EXT use.

My Python simulation of the exact recursion at stock settings (backtau 50 ms, T=3.3), using a 5 ms raised-cosine key-down:
- At 48 kS/s: 680 flagged samples over 18.9 ms at 20 dB, and 939 over 19.7 ms at 40 dB.
- At 192 kS/s: 2740 samples over 18.4 ms at 20 dB, and 3758 over 19.9 ms at 40 dB.
This is far worse than the finding's T=12 and T=6 cases (123 and 46 samples).

Steady carrier 40 dB above unit noise, T=3.3, impulses tested at 30, 100, 200 and 300 sigma:
- 192 kS/s: 0/20, 0/20, 0/20 and 11/20 detected.
- 48 kS/s: 0/20, 0/20, 1/20 and 11/20.
At 20 dB with 30-sigma impulses, 7/20 were detected at 48k and 14/20 at 192k.

Derived:
- With noise only, P_fa = exp(-pi*T^2/4) gives 1.9e-4 at the stock T=3.3.
- Under a dominant carrier of amplitude A, an impulse needs roughly |imp| > (T-1)*A to (T+1)*A depending on phase. That is about 230-430 sigma at 40 dB, which matches the simulation.

- *theory* (partly): Independent stdlib-Python simulation of the exact nobII.c:179-184 recursion (48 kHz, backtau 20 ms, complex unit-variance noise, carrier at 1.5 kHz):
- Key-down with a 5 ms raised-cosine edge, carrier 40 dB up. The raw detector at T=12 flagged 124 samples. The finding says 123 and the first skeptic got 127. An order-8 complex NLMS residual (mu=0.05, |e| > 6 x running mean|e|) flagged 0.
- Hard (unshaped) key-down, 40 dB. Raw flagged 75. LP with a 20-sample freeze cap flagged 60, all of it the transient while the predictor reconverges.
- 15 impulses 30 dB above the noise under a steady 40 dB carrier. Raw at T=4 detected 0/15. LP detected 15/15, with 28 flags in total; the extras come from the inverse filter smearing each impulse.

Derived results:
- Rayleigh false-alarm rate P_fa = exp(-pi T^2/4) on noise alone.
- Under a constant-envelope carrier of amplitude A_c, an impulse is detected only when A_i > (T-1)A_c, because |A_c + A_i| <= A_c + A_i. The finding says T x carrier; the correct factor is (T-1), a minor difference.
- Kolmogorov-Szego: the infinite-order one-step prediction error variance equals the geometric mean of the PSD, exp(integral of ln S). It therefore approaches the noise floor when strong signals fill only a small fraction of the IQ span. That is the theoretical reason the residual threshold scales with the noise floor and not with the carrier.
- An order-p predictor can null at most about p narrowband peaks.
- Inverse-filter smear is about p/fs = 16/192k, roughly 83 us, which is small next to nobII's adv/hang times (up to 2 ms each).

- *harness* (partly): I built the real WDSP 2.11 nobII.c (create_nob/flush_nob/xnob) with clang -O2 -arch arm64. Setup: 48 kS/s, backtau 20 ms, slew/adv/hang 0.1 ms, max_imp_seq 25 ms, noise E|n|^2=1, single-sample impulses with random phase. Each pair below is ORIG -> FIXED. FIXED is complex NLMS order 8, mu 0.05, freeze on flagged samples capped at 20, detection |e| > T*EWMA(|e|) using the same avg recursion.

Noise only:
- P_fa at T=2.5: 7.17e-3 -> 7.35e-3 (Rayleigh predicts 7.4e-3).
- 40 impulses at 8/15/30x rms, T=4: 40/40 hits in both. Window error -5.2/-10.7/-16.7 dB, identical in both. Behaviour is unchanged.

Shaped CW key edges (5 ms raised cosine, 10 key cycles):
- 40 dB carrier at T=12: 125 flags / 142 blanked samples -> 0 / 0.
- 20 dB carrier at T=6: 44 / 138 -> 0 / 0.

Steady 40 dB carrier plus 15 impulses, T=4:
- Detection at 10, 30, 100 and 300x noise rms: 0/15 at every level -> 15/15 at every level.
- Net window error energy after blanking: mode 0 goes from 0 dB to +31.5 / +23.2 / +13.5 / +3.9 dB. Mode 4 goes to +32.7 / +24.7 / +14.6 / +5.0 dB. The blank removes more of the carrier than the impulse added.

N carriers at 30 dB each plus impulses at 300x, T=6:
- Hits for N = 1/4/8/16/32: 15/2/0/0/0 -> 15/15/15/15/0. Order 8 stops working at 32 carriers.
- Window error once detected: -4.9 dB at N=1, then +1.0 / +4.1 / +6.8 dB at N = 4/8/16.

SSB-like 40 dB band with syllabic envelope plus impulses at 300x:
- T=6: 2/15 hits with 24 false flags -> 15/15 with 0 false flags, but window error goes from -0.5 to +13.8 dB.

Hard (unshaped) key-down or start-up with a 40 dB carrier, T=6:
- 165 flags / 173 blanked samples -> 47 / 55 with the cap. Uncapped it is 167 / 175. There is no permanent lock-in, because the EWMA of |e| includes flagged samples and catches up within about 20 ms.

Blank length per impulse: 17 -> 22-25 samples (smearing). CPU: 4.5-4.8 -> 18-20 ns/sample, about 0.7% of one core at 384 kS/s.

### #4 NOB-II slews cross-fade frozen samples instead of windowing the live signal, so the taper does nothing for signals away from IQ DC

**Priority:** medium · **Verdict:** confirmed · **Area:** noise-blankers · **Where:** `nobII.c:xnob states 1, 4, 5, 9 (lines 335-348, 383-391, 392-404, 472-484)`

**Evidence.** Harness (real nobII.c built for arm64, Lyra's mode 0, 0.1 ms / 19-sample slews at 192 kHz, 209 impulses, carrier at +30 kHz from IQ DC): splatter drops by 9 dB at +10 kHz (-41.4 to -50.5 dBc), 22 dB at +20 kHz (-49.0 to -71.2), 29 dB at +30 kHz and 37 dB at +50 kHz. The DC click at hardware centre falls from -28.8 to -82.0 dBc and the peak residual from 1.94 to 1.00. Within 5 kHz of the carrier there is no change (within about 1.5 dB). The overflow path is unchanged within noise, and no impulse leaks in. The theory lens's independent model gives matching figures, including the frozen slew being about 19 dB worse than a hard gate near DC. The code lens traced states 0, 1, 4, 5, 7, 8 and 9 and confirmed that no slew reads dline[out_idx] while ANB does. It also confirmed that create_nobEXT gives mode 0 with advslew = hangslew = 0.1 ms, and that the regions under the slews contain no flagged samples. I checked the harness diff: it is a minimal 4-site substitution with the scale indexing unchanged, so it faithfully tests the proposal.

**Recommended fix.** In nobII.c xnob, change the four slew states so they window the live delayed sample. In states 1 and 4: out = scale*dline[2*out_idx+{0,1}] + (1-scale)*I/Q. In states 5 and 9: out = scale*dline[2*out_idx+{0,1}]. Keep the existing awave ((i+1)*PI/(n+1)) and hwave (i*PI/n) index conventions exactly as they are. Ilast/Qlast and Inext/Qnext are then only needed by the slews, so they can be dropped. Add a regression test that reproduces the harness: a carrier 30 kHz off DC plus 100 Hz impulses. Assert splatter at +20 kHz of about -70 dBc, a DC band of about -80 dBc or lower, and a peak residual of 1.0 or less. Also run an overflow-burst case and check it matches the original. In the release notes, describe the benefit as large for strong signals more than about 10 kHz from IQ DC, plus removal of the DC click. Note that for carriers within a few kHz of DC the close-in result can be up to about 9 dB worse than today, because the gate spectrum becomes the same wherever the carrier sits (ANB-equivalent).

**Disagreements.** All three lenses agree the finding holds and the fix is sound. The harness lens marked the fix 'yes-with-changes', and only for the wording: its carrier-position sweep showed that when a strong carrier sits within a few kHz of IQ DC, the current frozen-sample slew happens to behave like a live window, so it beats the fix close in. The gaps were about 9 dB at +5 kHz for a 3 kHz carrier, and 3 to 11 dB for a 500 Hz carrier. I accept this as a narrow case that should be stated in the benefit text, not as a reason to downgrade. The fixed output does not depend on where the carrier sits. The usual case, a strong signal well off centre in a 96 to 192 kHz span, improves by 20 to 37 dB at 20 to 50 kHz offsets, and the DC click goes in every case. Final: confirmed. The claimed size (about 20 dB at a 20 kHz offset, little change close in) matches the measurements. Priority is medium rather than high. The gain is audible only when the blanker is running alongside strong off-centre neighbours or when tuned near hardware centre, and the blanker is off by default in Lyra (run=0).

**Per-lens results**

- *code* (confirmed): Lyra (src/wdsp_engine.cpp:1377) calls create_nobEXT(ch, run=0, mode=0, inSize, inRate, slewtime=0.0001, hangtime=0.0001, advtime=0.0001, backtau=0.020, threshold=20). create_nobEXT (nobII.c ~609-624) sets advslewtime = hangslewtime = slewtime = 0.1 ms and max_imp_seq_time = 0.025. So adv_slew_count = hang_slew_count = (int)(1e-4*fs): 19 at 192 kHz (truncated from 19.2), 9 at 96 kHz, 4 at 48 kHz. Lyra only ever calls SetEXTNOBRun and SetEXTNOBThreshold, so the mode stays 0 (zero fill), and in mode 0 states 1 and 4 reduce to Ilast*scale and Inext*scale. Window tables: awave[i] = 0.5*cos((i+1)*PI/(n+1)), so state 1's scale runs from just under 1 to just over 0. hwave[i] = 0.5*cos(i*PI/n), so state 4's scale starts at exactly 0 and ends just under 1.

- *theory* (confirmed): I simulated a stdlib Python model of the nobII mode-0 sample sequence: fs=192 kHz, unit complex tone at +30 kHz from IQ DC, 19-sample (0.1 ms) advance and hang slews built from the awave/hwave tables, 19-sample advance, a 1-sample impulse, 19-sample hang, and the blanker firing 100 times a second. I measured splatter as dBc integrated over a 2.4 kHz band at offsets from the tone, for three gates: hard / frozen (current) / live (proposed).
- 2 kHz offset: -21.3 / -21.6 / -21.6
- 5 kHz offset: -32.5 / -33.7 / -33.6
- 10 kHz offset: -38.8 / -41.1 / -50.0
- 20 kHz offset: -44.8 / -48.7 / -70.8
- 40 kHz offset: -50.4 / -56.2 / -89.3
- Passband at +1 kHz near IQ DC, tone still at +30 kHz: -47.8 / -28.4 / -79.9. The frozen slew is about 19 dB worse there than even a hard gate.
So the current slew behaves close to a hard gate. The live cross-fade gains about 9 dB at 10 kHz, 22 dB at 20 kHz and 33 dB at 40 kHz, about 18 dB/oct beyond 1/t_slew. It also removes a DC click about 50 dB stronger than the proposed version leaves.

- *harness* (confirmed): Setup: the real nobII.c create_nob/xnob, built with clang -O2 -arch arm64 against a POSIX comm.h shim. Lyra's parameters: fs=192 kHz, mode 0, slew/hang/adv 0.1 ms (19 samples), backtau 20 ms, threshold 20. Input is a unit carrier plus 100x impulses at about 100 Hz with jittered spacing (209 impulses over ~2.1 s). Metric: residual = out minus delayed clean input, Hann FFT, power in a 2.4 kHz band at an offset from the carrier, in dBc.

Carrier at +30 kHz from IQ DC (orig -> fixed):
- +1k: -16.8 -> -18.3
- +2k: -22.0 -> -21.8
- +5k: -34.1 -> -33.6
- +10k: -41.4 -> -50.5
- +15k: -45.8 -> -74.1
- +20k: -49.0 -> -71.2 (22 dB better)
- +30k: -53.4 -> -82.0
- +50k: -58.4 -> -95.4
- DC band (the click at hardware centre): -28.8 -> -82.0 dBc
- Peak residual during slews: 1.94 -> 1.00 (the frozen sample adds up to ~2x overshoot)

Other conditions:
- 4-sample impulse tail: +20k -49.0 -> -69.5; peak residual 1.00, so no impulse is windowed in.
- Mode 1 / mode 4: +20k -49.0 -> -71.1 / -70.7.
- 0.5 ms slews: +10k -41.4 -> -83.7; DC -16.0 -> -112.6.

Carrier-position sweep: the fixed build gives the same curve for any carrier frequency. The original is only good when the carrier sits near DC:
- f0=500 Hz: original better by about 3-11 dB at +10..30k.
- f0=3 kHz: original better close in (+5k: -42.8 vs -33.6; +3k: -32.9 vs -28.6). Fixed better beyond 15k (+50k: -76.2 vs -95.5).
- f0=6 kHz: +5k -39.5 vs -33.6.
- f0=10 kHz and up: fixed better beyond about 10k.

Overflow path (states 5/9; 8 trains of 1000x impulses every 30 samples for 40 ms): orig and fixed agree within 0.1-0.4 dB, residual rms 0.985 vs 0.977. Both leak a peak of 100, which is a pre-existing detector or overflow behaviour; the fix adds no leakage.

### #5 Add complex AR (LSAR) gap interpolation; the hold and linear modes only work for content near IQ DC

**Priority:** medium · **Verdict:** confirmed · **Area:** noise-blankers · **Where:** `nobII.c:xnob lines 248-319 (mode switch; fcoefs at 104-117)`

**Evidence.** Code lens: the 10-tap fcoefs give -2.97 dB at 3k/48k, -6.24 dB at 20k/192k and -11.70 dB at 48k/192k, and modes 1-4 fill with a constant or a straight line, so the description is accurate. Theory lens (Burg simulation): AR gives -45 to -74 dB of in-gap error on tones and -12 to -43 dB on narrowband modulated signals for gaps of 10-40 samples, but only -1 to -6 dB at about 1 ms; it gives 0 dB on white noise. Harness lens built the real nobII.c on arm64 with an additive mode 5 that reads only dline data, which I checked in the diff. Modes 0-4 left off-DC carriers at +0.4 to +1.3 dB in-gap error with +67 to +70 dB splatter in an empty band. Mode 5 gave -66 dB for two carriers and -52 dB for an AM carrier at a 78-sample gap, falling to -41 and -23 dB at about 440 samples, with splatter back at the floor. On noise the mode 5 fill was only -21.6 dB, so the hole stays. Hold and linear work only for a carrier exactly at DC (-79 dB).

**Recommended fix.** Add a new NOB-II mode 5 alongside the existing ones; leave modes 0-4 and the EXT API unchanged. When state 0 decides to blank, take up to about 512 unflagged context samples on each side. The left side comes from the dline history. The right side comes from the existing look-ahead up to in_idx; stop at flagged samples and leave out the adv/hang samples. Fit a complex Burg AR model of order about 16-32 on each side, with regularisation for strong carriers. Fill the gap with forward and backward extrapolation cross-faded by a raised cosine (a cheap heuristic), or with the full complex LSAR solve, which is Janssen's method and SNBA's xHat made complex. Store the fill in a per-instance buffer, not a static one, and output it during states 1-4 in place of I += deltaI. Overflow (states 5-7) still zeroes. Fall back to zero when the gap is longer than about 0.5-2 ms, scaled with bandwidth, or when either side has fewer than about 4p clean samples. No extra latency is needed: the dline already looks about 25 ms ahead (max_imp_seq). Correct the claims: complex AR order K covers K tones, not 2K; there is no noise-floor or pumping benefit; the Etter citation is for a joint least-squares solve, not the cross-fade. Lyra currently runs NOB-II in mode 0 (create_nobEXT, mode=0) and never sets the mode. Lyra therefore only benefits once a host exposes or defaults to mode 5.

**Disagreements.** All three lenses agree the description is accurate and the fix is sound with changes. Theory said "partly" because the noise-floor claim, the order-2K claim, the Etter attribution and the gap range for modulated signals were overstated. The harness confirmed each of these: the noise hole stays, and the gain falls with gap length and modulation. On latency, the first skeptic said 1-3 ms extra and the finding said it equals the maximum gap. Both are wrong: code and harness show the existing dline look-ahead (D of about 4887 samples) already holds the right-hand context. On the weak in-band tone, the skeptic expected poor reconstruction, but the harness got -42 dB. That scene had only three spectral lines, so I treat it as an optimistic case, not a refutation. I ruled "confirmed" rather than "confirmed-smaller". The headline effect, strong narrowband signals crossing the blank without gating splatter, was measured at or above the claimed 20-40 dB for short gaps, and only secondary claims failed. Priority is medium, not high: it is an additive quality feature, the stock Lyra setup uses mode 0, and the results are synthetic with ideal impulses.

**Per-lens results**

- *code* (confirmed): The fcoefs (nobII.c:108-117) sum to 0.999999999. Their |H| is -0.35 dB at 1k/48k, -2.97 dB at 3k/48k, -2.13 dB at 10k/192k, -6.24 dB at 20k/192k and -11.70 dB at 48k/192k (python, direct DFT of the 10 taps). These match the finding.

The existing NOB-II look-ahead is in_idx - out_idx = adv_slew + adv + 1 + max_imp_seq + hang + hang_slew + filterlen (flush_nob:144-145). max_imp_seq_time is 0.025 s (create_nobEXT), so that is at least 25 ms of delay, about 4800 samples at 192k. When an impulse is detected at scan_idx, roughly 25 ms minus the gap of clean samples already sits after the gap in dline.

Lyra's stock configuration (src/wdsp_engine.cpp:1377 and wdsp_engine_rx2.cpp:85) is create_nobEXT(ch, run=0, mode=0, inSize, inRate, slew=0.0001, hang=0.0001, adv=0.0001, backtau=0.020, thr=20.0), and SetEXTNOBMode is never called. At 192k that gives about 19 slew + 19 advance + up to 4800 impulse + 19 hang + 19 slew samples, so a typical single-impulse gap is roughly 60-100 samples.

- *theory* (partly): Code check (nobII.c lines 104-117, 248-319): modes 0-4 fill with zero, a 10-tap-averaged hold, or a linear ramp between I1/Q1 and I2/Q2. Every fill is a constant or a straight line in IQ. The worst blank is max_imp_seq_time = 25 ms, and adv/hang are capped at 2 ms each.

Python simulation (stdlib, complex Burg, Etter-style forward and backward extrapolation with a raised-cosine cross-fade, order p=16, 512-sample context on each side, fs=192k). Numbers are gap-error energy relative to the true signal energy in the gap, in dB; zeroing is 0 dB.

Single tone at 20 kHz offset, SNR 60/30 dB:
- G=10: hold 0.1, linear +1.3, AR -72.5/-45.4
- G=40: linear +0.6, AR -74/-41
- G=200: linear +0.8, AR -65/-43

Single tone at 2 kHz offset, G=10: hold -13, linear -17, AR -74/-44. At G=200, hold and linear are +2.4/+2.8, worse than zeroing.

Five tones (amplitudes 1 to 0.1), SNR 60/30: AR -51/-34 at G=10, -46/-33 at G=40, -32/-25 at G=200. Linear is -2.6 to +3.2.

Narrowband random signal (40 random tones in 2.4 kHz or 10 kHz bandwidth, SNR 40):
- G=10: AR -27 to -43
- G=40: AR -12 to -26
- G=200 (about 1 ms): AR only -1 to -6
- Linear is +0.4 to +2.6 in every case

White noise, G=40: AR error -0.02 to +0.16 dB, the same as zeroing. The fill power is -17 to -21 dB, so it decays to almost nothing and the hole stays.

The quantity that sets the benefit is gap duration times signal bandwidth.

- *harness* (confirmed): Test setup: the real WDSP 2.11 nobII.c built with clang -O2 -arch arm64 through a POSIX comm.h shim. Settings were fs=192 kS/s, buffsize 1024, adv/advslew/hangslew 0.1 ms, max_imp_seq 25 ms, backtau 50 ms, threshold 8. Impulses were 3-sample, amplitude 100, random phase, spaced about 1920-2320 samples apart. The blanked gap was about 78 samples (hang 0.1 ms). NB delay D = 4887 samples. In-gap error is relative to clean power in the gap. Splatter is measured in a 3.5-6.5 kHz band that should hold only the -80 dB noise floor, as the output/clean power ratio there.

Scenario 0: carriers at +20 kHz (amplitude 1) and -37 kHz (0.3), noise at -80 dB.
- mode 0 (zero): in-gap error +0.78 dB, splatter +69.9 dB, total SER -13.5 dB
- mode 1: in-gap error +1.29 dB, splatter +69.7 dB
- mode 2: in-gap error +0.82 dB, splatter +69.5 dB
- mode 3: in-gap error +1.29 dB, splatter +69.9 dB
- mode 4 (linear): in-gap error +1.19 dB, splatter +67.1 dB
- mode 5 (complex Burg AR, p=16, 512-sample context, two-sided with raised-cosine cross-fade): in-gap error -66.0 dB, splatter -0.17 dB (back at the floor), total SER -80.3 dB
- The fixed build in modes 0-4 gives output identical to the original.

Scenario 1, carrier at IQ DC:
- mode 0: in-gap error -1.5 dB, splatter +64.4 dB
- modes 1 and 4: in-gap error -79 dB, splatter +0.2 dB. Hold works only at DC.
- mode 5: in-gap error -79.7 dB

Scenario 3, AM-modulated carrier off DC:
- modes 0/1/4: in-gap error +0.8/+1.3/+1.2 dB, splatter about +67-70 dB
- mode 5: in-gap error -51.9 dB, splatter -0.18 dB

Mode 5 against gap length:

| hang | approx. gap | two carriers, in-gap error | AM carrier, in-gap error |
|---|---|---|---|
| 0.5 ms | 150 samples | -57.4 dB | -39.8 dB |
| 1 ms | 250 samples | -50.1 dB | -31.0 dB |
| 2 ms | 440 samples | -40.8 dB | -23.3 dB |

At every gap length, modes 0 and 4 stayed at +0.2 to +0.9 dB in-gap error and about +67-70 dB splatter.

Scenario 2, noise only:
- mode 5 fill power is -21.6 dB relative to the clean noise in the gap.
- in-gap error is +0.04 dB, about the same as zeroing (+0.69 dB).
- So the noise hole remains, which confirms the skeptic's correction.

Scenario 4, a weak tone at 5 kHz, -60 dBc, under the two strong carriers:
- band error: mode 0 +32.1 dB, mode 4 +29.5 dB, mode 5 -42.3 dB

Dense impulse trains (spacing about 400 / 200 samples):
- mode 5 in-gap error -66.7 / -57.3 dB
- mode 5 band error -7.6 / -4.1 dB, against +74 to +80 dB for modes 0 and 4
- So the gain shrinks as the context gets contaminated or short, but is still very large.

### #6 NOB-II always adds about 25.6 ms of receive latency because of a fixed 25 ms look-ahead; zero mode needs almost none of it

**Priority:** medium · **Verdict:** confirmed · **Area:** noise-blankers · **Where:** `nobII.c:flush_nob lines 143-145; create_nobEXT line 623`

**Evidence.** The code and theory lenses both derive the delay as in_idx - out_idx = adv_slew + adv + 1 + max_imp_seq + hang + hang_slew + filterlen. That is 1227 samples (25.56 ms) at 48k and 4887 samples (25.45 ms) at 192k, because create_nobEXT hard-codes max_imp_seq_time = 0.025 and no setter changes it. In mode 0, the forward scan only sets blank_count and Inext. The harness built the real nobII.c with Lyra's parameters and measured exactly those delays. Setting max_imp_seq = 0 in mode 0 cut the delay to 27 samples at 48k and 87 at 192k (0.56 / 0.45 ms). On its own, that change gated about 60% more signal at 48k (about 2 dB worse SER). Also dropping the filterlen pad in overflow states 5/6 for mode 0 gave the same gated-sample counts as the original in every scenario, with no impulse leakage. The saving is about 25 ms at every sample rate, which is the size the finding claimed.

**Recommended fix.** For mode 0 in LyraDSP's NOB-II:
- Set max_imp_seq = 0 in init_nob so every detection goes through the existing causal overflow path (states 5-9). State 7's staydown check already extends the gate online while impulses keep arriving.
- In the overflow branches (nobII.c around lines 329 and 401), use blank_count += adv_count, without + filterlen. Without this change, blanking quality drops by about 2 dB at 48k.
- Expect a remaining delay of adv_slew + adv + 1 + hang + hang_slew + filterlen, about 27 samples (0.56 ms) at 48k and 87 (0.45 ms) at 192k. The 0.2 ms floor in the finding is only reachable with a new ANB-style state machine that runs the hang slew online, and that is not needed.
- Expose max_imp_seq_time as a parameter or setter instead of changing the create_nobEXT default, so other hosts keep their current behaviour.
- Call init_nob (re-flush) from SetEXTNOBMode/pSetRCVRNOBMode, because the delay now depends on the mode. Expect a brief glitch on a mode change.
- Optionally cap the look-ahead in fill modes (1-4) at a few ms; this does not matter for Lyra.
- Check that nothing in Lyra assumes a fixed NB delay, for example when aligning the panadapter, capture or zero-beat feeds.

**Disagreements.** The lenses agree on the core claim and on the current-behaviour description. They differ on two details of the proposed fix, and the harness settles both:
(1) The minimum delay. The finding gives about 0.2 ms. Reusing states 5-9 actually leaves 0.45-0.56 ms, as the code and theory lenses both predicted and the harness measured. The saving is still about 25 ms, so this is a correction to the fix, not to the size of the effect.
(2) The finding's claim of "no change in blanking quality". The harness showed it is false for the simple fix, which gates about 60% more signal at 48k. It becomes true once the filterlen pad in states 5/6 is also skipped in mode 0 (the harness's fixed2 build, which I checked against the diff).
The leakage on the 60 ms train at 48k appears in every build, including the original, so it is a detector limit and not something the fix causes.
The finding's QSK benefit is real but only partly verified. The harness measured the 25 ms saving; whether the delayed gap audio is actually lost depends on how Lyra mutes RX around key-down, which no lens checked.
Priority is medium rather than high: the delay applies only while NB2 is on, and the RXA chain already adds tens of ms of its own.

**Per-lens results**

- *code* (confirmed): The delay in_idx - out_idx comes from nobII.c:144-145 and init_nob:40-44. Counts are (int)(t*fs), and Lyra's slew, hang and advance are all 0.0001 s, with max_imp_seq_time = 0.025 and filterlen = 10.
Current delay: 48k = 1227 samples (25.56 ms); 96k = 2447 (25.49 ms); 192k = 4887 (25.45 ms); 384k = 9763 (25.42 ms).
Delay with only the max_imp_seq term removed, which is enough for the existing overflow states 5-9 (adv_slew+adv+1+hang+hang_slew+filterlen): 48k = 27 samples (0.56 ms); 96k = 47 (0.49 ms); 192k = 87 (0.45 ms).
Delay with an ANB-style causal design (adv_slew+adv+1 only): 48k = 9 samples (0.19 ms).
deskHPSDR uses the same stock parameters: receiver.c:1092 calls create_nobEXT(id,1,0,...,0.0001,0.0001,0.0001,0.05,20) with mode 0 and only changes the mode through SetEXTNOBMode. A stock configuration of a non-Lyra host therefore also has the ~25.5 ms delay.

- *theory* (confirmed): I derived the delay from flush_nob, which sets the delay to in_idx - out_idx = adv_slew + adv + 1 + max_imp_seq + hang + hang_slew + filterlen. Inputs: filterlen = 10 (nobII.c:104), max_imp_seq_time = 0.025 hard-coded (nobII.c:623), Lyra's 0.1 ms slew/hang/advance. At 48 kS/s: 4+4+1+1200+4+4+10 = 1227 samples = 25.56 ms. At 192 kS/s: 19*4+1+4800+10 = 4887 samples = 25.45 ms. In mode 0, the smallest look-ahead that still lets the advance (pre-impulse) blanking stay causal is adv_slew + adv + 1 = 9 samples (0.19 ms) at 48k. That only works if the hang and hang slew run online, ANB-style, windowing the live signal. If the existing overflow states 7-9 are reused, they read imp/Inext up to scan_idx + hang + hang_slew, so the look-ahead is about 17 samples (0.35 ms), or about 27 (0.56 ms) with the filterlen margin kept. Net saving: about 25.0-25.4 ms at any sample rate. For scale: a CW dit or element space is 1200/WPM ms, i.e. 30 ms at 40 WPM. The removable delay is therefore about one element space at high QSK speeds.

- *harness* (confirmed): I used Lyra's parameters: create_nobEXT(mode 0, slew/hang/adv 0.0001 s, backtau 0.020, threshold 20), 1024-sample buffers, a 1 kHz complex carrier at amplitude 1 plus Gaussian noise at 0.02, damped-ring impulses at amplitude 100, and a deterministic xorshift RNG. I measured the delay as the lag at which out[n] equals in[n-d] exactly.

Delay:
- Original: 1227 samples (25.56 ms) at 48k and 4887 samples (25.45 ms) at 192k, the same in every scenario.
- Simple fix (max_imp_seq = 0 in mode 0): 27 samples (0.56 ms) at 48k and 87 samples (0.45 ms) at 192k. That removes 25.0 ms.

Blanking quality, as gated samples and SER (dB) against the delayed clean reference, original vs simple fix:
- At 48k, isolated impulses: 1657 → 2659 gated, SER 20.75 → 18.64. Bursts of 10 every 0.8 ms: 5477 → 8936, 15.59 → 13.38. Bursts of 5 every 4 ms: 2756 → 4467, 18.56 → 16.38. Dense 1 kHz-rate train: 50704 → 88188, 5.94 → 3.43.
- At 192k: isolated 6926 → 7471, 20.58 → 20.26. Bursts of 10: 22614 → 26033, 15.46 → 14.84. Dense train: 223197 → 256956, 5.52 → 4.89.
- So the simple fix gates about 60% more signal at 48k (about 2.1-2.5 dB SER loss) and about 8-15% more at 192k.

Fix plus dropping the filterlen zero-pad in mode 0 (fixed2): the delay stays 27 / 87 samples. Gated counts are identical to the original in every 48k and 192k scenario (1657, 5477, 2756, 50704; 6926, 22614, 11298, 173091, 223197), and SER is +0.03 dB better.

Impulse leakage: none in the original or either fixed build, except the 60 ms train at 48k. There the averaging detector saturates in all three builds (about 8000 leaked samples each) because of the detector itself, not the look-ahead.

### #8 WBFM: de-emphasis setter never reaches the filters, and the noise-squelch 'Butterworth' bandpass is really two identical resonators

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** demod · **Where:** `wbfm.c:SetRXAWBFMdmph (797-807), create_dmph (170-182), calc_wbfm (627-628); wbfm.c:calc_bqs (240-294), init_nopwr (302)`

**Evidence.** (a) All three lenses confirm it. In the harness built from the original wbfm.c, Set(50 us), Set(off) and Set(75 us) all leave the output at 10k = -12.80 dB and 15k = -16.44 dB relative to 1 kHz, and dmphL->tau stays at 75 us. With the fix, each setting takes effect immediately. The 50/75 us difference is 3.29 dB at 10 kHz and 3.41 dB at 15 kHz, not the 3.6 dB claimed. (b) The filter alone behaves as described. Both biquads are identical: they peak at +6.02 dB at 66.2 kHz, the band is about 7.7 kHz wide, and the ENBW is 37.8 kHz against 18.8 kHz for a true Butterworth. In the real pipeline, though, nopwrRun memcpys `size` doubles from disc_out, which holds interleaved (re, 0) complex values (wbfm.c:329, 516-517, 586). The filter therefore sees zero-stuffed data from half of each block, so its band lands near 116-150 kHz at fs = 384k and near 42-76 kHz (mirrored) at 192k. The harness measured SCA and RDS each adding under 0.001 to pwrNoise at 384k. The main effect of fixing only the filter is to halve the noise reading (0.49-0.50x).

**Recommended fix.** (a) Adopt the fix. In SetRXAWBFMdmph, under csDSP, set run on dmphL and dmphR, set tau from the type (75 or 50 us), and recompute the coefficients. Keep x_z1/y_z1 rather than zeroing them, because calc_dmph's state reset caused a click of 0.11-0.21 against a steady-state step of 0.0106. Keeping the state brought the 75-to-50 us switch down to 0.0125. If the on/off click matters, add a short crossfade.

(b) Fix it in this order:
1. Make nopwr read disc_out[2*i] for all `size` samples. This stride bug is the larger defect.
2. Replace calc_bqs with a true LP-to-BP transform: take the roots of s^2 - p*BW*s + W0^2, pair them into two stagger-tuned biquads, then apply the bilinear transform.
3. Validate the band against Nyquist. Today 116k < fs < 150k gives NaN coefficients and a squelch stuck at gain_min, and fs = 96k aliases. Below the limit, disable the squelch or fall back.
4. Retune noise_high_thresh and noise_low_thresh to about half their values, and recheck pilot_good_thresh. At 384k, a 10% pilot measured mag19 = 0.055, below the 0.06 threshold, so the squelch stays shut.

Do not adopt the guard-band estimator as proposed. BS.450 allows sub-carriers at 15-23 kHz, and above threshold-level noise is not f^2-shaped. Consider estimating noise out of band, around 100-150 kHz, when fs allows.

**Disagreements.** All three lenses agree that (a) is real and that its dB figure is slightly overstated: 3.4 dB at 15 kHz, not 3.6. On (b), the code and harness lenses judged the finding's current-behaviour description accurate for the filter alone. The theory lens judged it inaccurate because of the disc_out stride bug. I checked the code: disc_out is allocated as size*sizeof(complex), filled as (2*out, 0), and nopwrRun memcpys only size*sizeof(double). The harness measurements confirm the effect. So the filter-shape claim is true in isolation, but the claimed SCA/RDS impact does not describe the running code. Fixing calc_bqs alone would mainly rescale the noise reading. That reduces (b)'s stated benefit and leaves the result as confirmed-smaller. (a) is an audible, user-visible control bug in WBFM. WBFM is broadcast reception rather than core use, so priority is medium. The stride bug and the NaN at mid sample rates should be carried into the LyraDSP extraction alongside this fix.

**Per-lens results**

- *code* (partly): Squelch filter, computed from calc_bqs's own formulas (python, coefficients match the skeptic's numbers at 384 kHz: b=(0.12738,0,-0.12738), a1=-0.85295, a2=0.81986, both sections identical).
At fs=384k: peak +6.02 dB at 66.19 kHz. -3 dB relative to the peak: 62.38-70.13 kHz. -3 dB absolute: 58.35-74.59 kHz. 57k: -4.99 dB, 58k/75k: -3.52 dB, 67k: +5.87 dB, 19k: -42.1 dB.
fs=192k / 768k / 1536k: same shape (peak +6.02 dB at 67.35 / 66.01 / 65.97 kHz).
A true 4th-order Butterworth BP (LP-to-BP pole mapping, then bilinear) at 384k: 57k -4.20 dB, 58k/75k -3.01 dB, 67k 0.00 dB.
Noise power integral of |H|^2: code 37,702 Hz, Butterworth 18,699 Hz (ratio about 2.0, about 3 dB). With f^2 weighting: 38,587 vs 19,467.
fs=144k: f_high is above Nyquist, so tan() goes negative, W0 = sqrt(negative) gives NaN coefficients. fs=96k: aliased filter peaking near 30 kHz (+5.97 dB).
De-emphasis 75 vs 50 us (analog): 3.29 dB at 10 kHz, 3.42 dB at 15 kHz.

- *theory* (partly): De-emphasis, from the code's own bilinear coefficients at fs=192k and 384k (the analog values agree): 75 us gives -13.7 dB at 10 kHz and -17.1/-17.2 dB at 15 kHz; 50 us gives -10.4 dB and -13.7/-13.8 dB. The difference is 3.30 dB at 10 kHz and 3.42 dB at 15 kHz. The asymptotic limit is 20log10(75/50) = 3.52 dB, so the finding's '3.6 dB at 15 kHz' cannot be right; the correct figure is about 3.4 dB.

calc_bqs response, evaluated as a standalone filter at fs=384k: both sections are identical; the cascade peaks at +6.02 dB at 66.19 kHz; the -3 dB band relative to peak is 62.38-70.13 kHz (7.75 kHz wide); 57 kHz is -11.0 dB relative to peak. These reproduce the finding.

A true LP-to-BP 4th-order Butterworth gives 0 dB peak, -3 dB band 58.01-74.98 kHz, -4.2 dB at 57 kHz and 0.0 dB at 67 kHz. Its noise-equivalent power integral is 18.7 kHz against 37.7 kHz for the code's cascade, a factor of 2 (3 dB).

Simulating the actual code path matters here. nopwrRun memcpys `size` doubles from disc_out, and disc_out is interleaved (re, 0). The filter therefore sees a zero-stuffed copy of the first half of each block. Tone response at fs=384k, size=1024, normalised to the peak: 132 kHz 0.0 dB, 120 kHz -6.5 dB, 140 kHz -2.8 dB, 92 kHz -23 dB, 67 kHz (SCA) -31.7 dB, 57 kHz (RDS) -39.2 dB, 50 kHz -34.9 dB. At fs=192k: 57 kHz 0.0 dB, 50 kHz -2.8 dB, 67 kHz -3.8 dB, 38 kHz -12.9 dB. Reading with stride 2 reproduces the finding's standalone response: 67 kHz +5.9 dB, 57 kHz -5.0 dB.

- *harness* (partly): Harness: the real WDSP wbfm.c, fir.c and firmin.c, plus the core of wcpAGC.c (lines 1-367), built with clang -O2 -arch arm64 against FFTW3. A POSIX shim comm.h stands in for the original. Block size 1024. The fix copy has (a) the setter writing run and tau and calling calc_dmph, and (b) calc_bqs doing a true LP-to-BP transform.

(a) De-emphasis. Input is mono FM with 1 kHz, 10 kHz and 15 kHz tones at 10 kHz deviation each, fs = 384 kHz. Settings are switched mid-stream with SetRXAWBFMdmph.
- ORIG: every phase reads 10k = -12.80 dB and 15k = -16.44 dB relative to 1k, and dmphL tau stays at 75 us after Set(50 us), Set(off) and Set(75 us). The setter has no effect.
- FIXED: 50 us gives 10k = -9.97 dB and 15k = -13.48 dB (theory -9.95 / -13.25). Off gives 0.00 / -0.20 dB. 75 us returns to -12.80 / -16.44 dB.
- 50 us vs 75 us absolute level: +3.29 dB at 10 kHz, +3.41 dB at 15 kHz (the claim said about 3.6 dB at 15 kHz).
- Click from the proposed calc_dmph call, which zeroes the filter state. Steady-state max |dy| is 0.0106. Right after a switch it is 0.113 (75 to 50 us) and 0.215 (off to on). A variant that keeps x_z1/y_z1 gives 0.0125 and 0.091.

(b) Filter alone, measured with sines and white noise through the real bqsecRun.
- ORIG at 384 kHz: both sections identical (b0 = 0.127376, a1 = -0.852954, a2 = 0.819863). Peak +6.02 dB at 66.2 kHz. The -3 dB band relative to peak is 62.4-70.1 kHz (7.7 kHz wide). 57 kHz is at -4.99 dB (11.0 dB below peak); 67 kHz is at +5.87 dB. ENBW is 37.8 kHz.
- FIXED: -3.01 dB at exactly 58 and 75 kHz, 0.00 dB from 62 to 70 kHz, ENBW 18.8 kHz.
- Results at 192 kHz are the same.

(b) In the full pipeline (xwbfm), there is a new adjacent bug. nopwr is given disc_out, which is interleaved complex (re, 0), and it reads 'size' doubles. So it sees zero-stuffed data from only half of each block. The 58-75 kHz filter therefore lands on different discriminator frequencies:
- At fs = 384 kHz it covers about 116-150 kHz. A probe tone at 10% deviation reads +1.75 dB (rel. its power) at 130 kHz, but -24.9 dB at 67 kHz and -36.9 dB at 57 kHz.
- At fs = 192 kHz it covers about 42-76 kHz, mirrored. A probe at 57 kHz reads +2.1 dB in orig and -3.9 dB in fixed.

Squelch noise reading (pwrNoise; open threshold < 0.15, close threshold > 0.50):

| Case | ORIG | FIXED |
|---|---|---|
| 384k, SCA 30% | 0.00078 | 0.00046 |
| 384k, RDS 20% | 0.00056 | 0.00030 |
| 384k, AWGN only, CNR 6 dB | 0.330 | 0.165 |
| 384k, AWGN only, CNR 10 dB | 0.113 | 0.056 |
| 192k, SCA 10% | 0.019 | 0.0077 |
| 192k, SCA 20% | 0.076 | 0.030 |
| 192k, SCA 30% | 0.171 | 0.067 |
| 192k, RDS 5% | 0.0076 | 0.0022 |
| 192k, RDS 20% | 0.114 | 0.029 |
| 192k, noise, CNR 10 dB | 0.049 | 0.024 |
| 192k, noise, CNR 6 dB | 0.144 | 0.072 |

So the fixed filter reads 0.49-0.50 times the noise, a 3 dB shift in where the squelch opens. SCA or RDS energy relative to noise improves by only about 0.9 dB (SCA) and 2.8 dB (RDS) at 192 kHz, and by nothing that matters at 384 kHz.

Second adjacent bug: at fs = 384 kHz, a 10% pilot gives mag19 = 0.055, which is below pilot_good = 0.06. The squelch stays shut at gain 0.05 even on a clean stereo signal. At 192 kHz the same pilot gives mag19 = 0.0998. magComp_fil19 = 1.495 appears tuned for 192 kHz.

### #10 make_nbp band-deletion loop shifts bands but not the del[] flags, so it deletes the wrong sub-band; also min_notch_width integer-division edge

**Priority:** medium · **Verdict:** confirmed · **Area:** filtering · **Where:** `nbp.c:make_nbp (lines 100-182, deletion loop 163-177); nbp.c:min_notch_width (82-98)`

**Evidence.** The harness built WDSP 2.11's own nbp.c, fir.c and firmin.c without changes and ran them through the real xfircore. I checked its outputs myself. In the finding's example (notches 1000/200, then 2000/200, then 925/2050), the original code leaves [1100,1900]. A 1500 Hz tone that should be notched passes at 0 dB, and the real 2500 and 2800 Hz passband drops by about 150 dB. The fixed code leaves [2100,3000] and gives the correct response. Over 400,000 random make_nbp calls, the original was wrong 2.9% of the time with notches in arbitrary order and 1.0% with notches sorted by centre. The fixed code matched an independent interval-subtraction reference in every call, so it does not change any case that works today. The bug depends on notch order: the same notches with the wide one first come out correct. ASan confirms the del[1024] read at nbp.c:166 when all 1024 notches are active, which is theoretical. With nc<256, min_notch_width becomes inf and the output goes silent (numpb=0, -300 dB). The code and theory lenses reached the same result by their own traces and harnesses.

**Recommended fix.** In make_nbp, replace the deletion loop with a one-pass stable compaction: w=0; for i<nbp { if(!del[i]){bplow[w]=bplow[i]; bphigh[w]=bphigh[i]; w++;} del[i]=0; } nbp=w. Add a maxpb parameter to make_nbp and pass a->maxpb from both callers, calc_nbp_impulse and calc_nbp_lightweight. Allocate del with maxpb entries, and skip the split if nbp+adds >= maxpb. In min_notch_width, use (double)a->nc/256.0. This only changes behaviour for nc values that are not multiples of 256. Better still, reject nc values that are below 256 or not a power of two in the NC setters. Do not combine this fix with the Kaiser-derived width change. Add a regression test with the finding's three-notch case in both insertion orders.

**Disagreements.** There is no disagreement on substance: all three lenses confirmed the bug. The code lens rated the fix "yes-with-changes" and the other two rated it "yes". The difference is that the bound check needs maxpb added to make_nbp's signature, and (double) nc/256 changes the reported minimum width for nc values that are not multiples of 256 (384 goes from 1600 to 1067 Hz). The harness implemented exactly those changes and found no regressions, so I accept the fix with them included. A few smaller points: the finding cites the maxpb=1025 line as RXA.c:103, but it is actually at lines 101 and 122. The bplow[nbp+adds] overflow cannot be reached, so that check is only defensive. Using double division at nc<256 replaces the silence with a very wide finite notch, which is still unusable, so input validation is the real fix there. I rated priority medium rather than high. The main bug causes a large audible error, but it only appears when manual notches are enabled and one notch fully covers two or more existing sub-bands. That is uncommon, though the random test hits it in 1 to 3% of multi-notch setups, and the fix is small and safe to include in the extraction.

**Per-lens results**

- *code* (confirmed): I copied nbp.c:100-182 verbatim into a harness (clang arm64) and compared it with the proposed write-index compaction, using passband 0-3000, autoincr off and notches listed in database order.
(A) Notches 900-1100, 1900-2100, then -100..1950. Current code leaves [1100,1900]. Fixed code leaves [2100,3000], which is the correct result.
(F) Notches 500-600, 1000-1100, 1500-1550, then 550-1525. Current code leaves [0,500] [1100,1500]. Fixed code leaves [0,500] [1550,3000]: the current code keeps a band that should be notched and drops the real passband.
(B, C, D, E, G) No deletion, or one deletion per notch. Current and fixed output are identical.
min_notch_width: stock nc = max(2048, dsp_size) at 48 kHz with wintype 0 gives 1600/8 = 200 Hz, and wintype 1 gives 275 Hz. With nc < 256, nc/256 = 0, so the width is 1600.0/0 = +inf. Every active notch then gets nl = -inf and nh = +inf, passes the `nh>flow && nl<fhigh` test wherever it sits, and deletes every band, so numpb = 0 and the output is silent.
del is malloc'd as 1024 ints. nbp can reach 1025 only after all 1024 notches (maxnotches, RXA.c:83) have each split a band, and that leads to one out-of-bounds read of del[1024].
The maximum passband count of 1025 is at RXA.c:101 and :122, not :103 as the finding says.

- *theory* (confirmed): I copied make_nbp verbatim from nbp.c (lines 100-182) into a scratchpad harness, built it with clang on arm64, and compared it with the proposed one-pass write-index compaction. Passband 0-3000 Hz, autoincr off.
- Notches 900-1100, 1900-2100, then -100 to 1950: original gives [1100,1900] (should be notched); fixed gives [2100,3000] (correct).
- Notches 1000-1100, 2000-2100, 600-700, then -10 to 2500 (one notch covering three sub-bands): original gives [1100,2000]; fixed gives [2500,3000].
- Single notch; one notch deleting one middle band; a notch deleting two bands whose indices are not consecutive and the second of which is the last slot (indices 0 and 2 of 3); autoincr at 200 Hz with three narrow notches 50-150 Hz apart: original and fixed give the same output.
Only a single notch that fully covers two or more sub-bands fails. It fails when the deleted indices are consecutive, or when a later flagged index is not the last slot.
Size of the error when it fails: the region that should be notched passes at about 0 dB instead of the stopband. BH4 sidelobes are about -92 dB, so the error is about 90 dB. The real passband region is removed by the same amount.
min_notch_width: 1600 Hz / (nc/256) at 48 kHz works out to 8.53*fs/nc, close to the 8-bin full main lobe of a 4-term Blackman-Harris. 2200 Hz works out to 11.7 bins for the 7-term window, whose main lobe is about 14 bins. With nc < 256, nc/256 is the integer 0, so minwidth = +inf, autoincr sets nl=-inf and nh=+inf, every band is deleted, nbp=0, and fir_mbandpass returns an all-zero impulse (silence). Default nc = max(2048, dsp_size), so this only happens through RXANBPSetNC.
del is malloc'd at 1024 ints while maxpb = 1025, and nbp can reach 1025 with 1024 splitting notches. That reads del[1024], one int past the end.

- *harness* (confirmed): All numbers come from the real WDSP 2.11 nbp.c, fir.c and firmin.c (fircore built with FFTW), compiled with clang -O2 -arch arm64. Settings: 48 kHz, wintype 0, autoincr 1, gain 1.0, nc=2048, size=1024, unless a test says otherwise.

[A] Finding's example, run through RXANBPAddNotch and xfircore. Passband 0-3000 Hz. Notches added in order 1000/200, 2000/200, then 925/2050.
- ORIG: bands become [1100,1900]. Tone gains: 450 Hz -157.4 dB, 1500 Hz -0.00 dB (passes, should be notched), 2500 Hz -151.1 dB, 2800 Hz -148.1 dB (both should be passband). The real passband drops by about 150 dB.
- FIXED: bands become [2100,3000]. 450 Hz -143.4 dB, 1500 Hz -145.6 dB, 2500 and 2800 Hz -0.00 dB.

[A2] Same notches, but with the wide notch at database index 0. Both builds give [2100,3000], so the bug depends on notch order.

[B] 200,000 random make_nbp calls per order setting (deterministic xorshift RNG, 2-8 notches, passband 0-3000). Each result was compared with an independently written interval-subtraction reference.
- Arbitrary notch order: ORIG wrong in 5888 calls (2.94%), with the wrong band count in 1510 of them. When wrong, the mean mis-assigned spectrum is 760 Hz, worst 2559 Hz of the 3000 Hz passband. FIXED: 0 wrong.
- Notches sorted by center: ORIG wrong in 2090 calls (1.05%), mean 606 Hz, worst 2262 Hz. FIXED: 0 wrong.
- These rates depend on the random notch distribution I chose. They are not field rates.

[C] min_notch_width, ORIG vs FIXED (wintype 0):
- nc=128 and nc=255: inf vs 3200 and 1606 Hz
- nc=384: 1600 vs 1067 Hz
- nc=640: 800 vs 640 Hz
- nc=256, 2048, 3072: identical (1600, 200, 133.3 Hz)

[C2] nc=128, size=128, one 50 Hz notch at 1000 Hz, autoincr on.
- ORIG: numpb=0, output -300 dB (total silence).
- FIXED: numpb=1, band [2600,3000] (the notch is auto-widened to 3200 Hz). Tones: 500 Hz -114.9 dB, 1000 Hz -108.5 dB, 2000 Hz -23.5 dB. Still unusable.

[D] 1024 active non-overlapping notches, built with ASan.
- ORIG: heap-buffer-overflow, a 4-byte read at nbp.c:166 (del[1024]), 0 bytes past the 4096-byte del allocation. nbp reaches 1025.
- FIXED: clean, nbp=1025.

### #11 Impulse/min-phase cache LRU list is mutated without a lock

**Priority:** medium · **Verdict:** confirmed · **Area:** filtering · **Where:** `fir.c:fir_bandpass (239-241, 311) and fir.c:mp_imp (401-411, 465) -> impulse_cache.c:get_impulse_cache_entry (128-162), add_impulse_to_cache (164-185), remove_impulse_cache_tail (93-111)`

**Evidence.** Harness test (real fir.c + impulse_cache.c, arm64): with the original code at the default 4096 cap, 2 threads x 20000 calls hung in 10 of 10 runs, and `sample` showed both threads spinning in the list walk at impulse_cache.c:144-145, so the list had a cycle. With the cap forced to 8, 2 threads x 1000 failed 40 of 40 runs (34 SIGABRT). ASan reported a heap-use-after-free in remove_impulse_cache_tail (106/107), and TSan reported races. The locked version was clean in every configuration, with 0 mismatches. The code lens got the same result on its own: 5 of 5 hangs at 1000 keys, 5 of 5 heap aborts at 6000 keys, 10 of 10 clean with a lock. The theory lens confirmed the code trace: only the `_use_cache` flag is locked, csDSP is per channel, and SetRXABandpassFreqs/RXANBPSetFreqs design without csDSP. It also measured the cost of an uncached fir_bandpass design at about 6-30 us, against about 3 s cold for the min-phase FFTW_PATIENT path. Lyra turns the cache on (wdsp_native.cpp:1195), so the unlocked path runs there.

**Recommended fix.** In LyraDSP's impulse cache, hold one mutex across the whole get (flag check, walk, move to head, copy) and the whole add (flag check, evict, insert). Use the existing cross-platform CRITICAL_SECTION/pthread shim rather than os_unfair_lock, because production also targets Linux. Make sure remove_impulse_cache_tail does not take a non-recursive lock a second time. Take the same lock in save_impulse_cache, read_impulse_cache (including its free_impulse_cache call) and destroy_impulse_cache. Optionally, re-check for the key inside add so concurrent misses do not insert duplicates; the duplicates are harmless, so this is only about wasted slots. This lock also covers the fcurve.c fc_impulse (FC_CACHE) user. Note that in 2.11 mp_imp has no callers, so the MP_CACHE path is dead code. Separately, the cache lock alone does not make concurrent filter design safe, because the design paths also call FFTW's planner, which is not thread-safe. LyraDSP should either run all design-triggering setters through one design thread or a global design mutex, or call fftw_make_planner_thread_safe. Dropping the cache for fir_bandpass (6-30 us uncached) is a reasonable separate simplification, not part of this fix.

**Disagreements.** On the core claim all three lenses agree: confirmed, and the fix is right but needs additions. There are two differences in how they describe the failure, neither of which reduces it. (1) The finding mentions a 'garbage impulse'. The harnesses saw 0 wrong impulses; the failures were permanent hangs from a cycle in the list and heap-corruption aborts. That is a worse effect than claimed, not a smaller one. (2) The finding calls the race 'rare'. Under sustained concurrent design it hung every time; under short bursts at the default cap it never appeared in 80 runs. Whether Lyra actually calls WDSP setters from more than one thread was not established; wdspcalls.cpp shows no threading. That makes the race latent in Lyra today but real in the library. So the priority is medium (fix during extraction) rather than high. Citation corrections: mp_imp is dead code in 2.11, and fc_impulse is a live user the finding leaves out. Only the theory lens raised the FFTW planner thread-safety gap. I adopted it as an accompanying requirement, because a cache lock alone does not make concurrent design safe.

**Per-lens results**

- *code* (confirmed): I tested a scratch copy of impulse_cache.c (WDSP 2.11, unmodified apart from a pthread CRITICAL_SECTION shim), built with clang on arm64 macOS. Two threads each made 300k get/add calls on bucket 0 with N=64. There was a 20 s alarm watchdog.
- Original code, 1000 distinct keys (below MAX_CACHE_ENTRIES=4096, so no eviction): 5 of 5 runs hung (killed by SIGALRM, exit 142). A stack sample showed both threads spinning in the get_impulse_cache_entry walk loop (lines 144-145), so the list had a cycle.
- Original code, 6000 distinct keys (eviction active): 5 of 5 runs aborted within 1 s (exit 133 or 134, a heap error from free).
- Same code with one pthread mutex held across the whole get and the whole add: 10 of 10 runs clean. Final list length was 1000-1003 at 1000 keys (benign duplicates from the gap between a miss and the add) and capped at 4096 at 6000 keys. bad-impulse count was 0.
- ThreadSanitizer on the original (2000 iterations, 500 keys) reported data races at lines 145/149/150/151 (get) against 175/178/182/183/184 (add). The locked version had 0 TSan warnings.
This is a synthetic stress test, far above a real GUI's filter-change rate.

- *theory* (confirmed): Microbenchmark (clang -O2 arm64, M-series, my reimplementation of the fir_bandpass loop with the 7-term Blackman-Harris window and complex output, rtype=1): N=1024: 11.7 us, N=2048: 19.2 us, N=4096: 30.5 us, N=16384: 123 us per design. The loop runs N/2 iterations of about 6 libm trig calls, about 3N calls in all. Walking a 4096-entry list (MAX_CACHE_ENTRIES=4096): about 4.7 us when the nodes are allocated in order, so a cache hit saves little for fir_bandpass. The min-phase path (mp_imp, pfactor 16 for N=2048, so FFT size 32768) cold-plans with FFTW_PATIENT: 3.26 s for the first plan (no wisdom) and 127 us per execute. That is where the cache pays off. Lock hold time on a hit is a memcpy of N complex doubles (32 KB at N=2048), well under 10 us.

- *harness* (confirmed): All builds: clang -O2 -arch arm64, the real WDSP fir.c + impulse_cache.c, FFTW 3. Workload: N=1024 complex fir_bandpass, 64 distinct keys picked by a per-thread xorshift RNG, each result compared bit-exactly with a reference built with the cache off.

ORIGINAL code:
- 4096-entry cap (WDSP default), 2 threads x 20000 calls: 10 of 10 runs hung (timeout). `sample` shows both threads spinning in the get_impulse_cache_entry walk loop (impulse_cache.c:144-145), meaning the bucket list became a cycle.
- 4096 cap, 4 threads x 2000: 9 of 10 hung. With 4 or 8 threads x 20000: hung.
- 4096 cap, 2 threads x 100 or x 1000: 0 of 80 failed. So at the default cap it needs sustained overlap to show.
- Cap forced to 8 so eviction happens: with 2 threads x 100, 9 of 40 runs failed (7 crashed with SIGABRT, 2 hung). With 2 threads x 1000, 40 of 40 failed (34 SIGABRT, 6 hung).
- ASan, cap 8, 4 threads x 3000: heap-use-after-free. Thread T2 reads (*pp)->impulse in remove_impulse_cache_tail (impulse_cache.c:106) after T1 freed that entry (line 107).
- TSan, 2 threads x 300: 3 data-race warnings in get_impulse_cache_entry at the 4096 cap, 6 at cap 8.
- In runs that did finish, the result mismatch count was 0. So the failure looks like a hang or crash, not a silently wrong impulse.

FIXED code (one lock held over the whole get and the whole add):
- Every configuration ran clean: 1, 2, 4 and 8 threads, caps 4096 and 8, plus 160 two-thread trials.
- 0 hangs, 0 crashes, 0 mismatches, no cycles, no corrupt entries. ASan clean, TSan 0 warnings.
- Leftover gap: the fixed run still leaves 4-10 duplicate entries. A miss in get and the later add are not atomic, so two threads can both add the same key. This only wastes slots.

Cost of the fix and of the cache (single thread):
- 8 threads x 20000 with the lock: 0.40 s. The original hangs on the same workload, so there is no direct comparison.
- fir_bandpass with the cache off: 6.4 us at N=1024, 8.0 us at N=2048, 16.0 us at N=4096.
- A cache hit: 0.38, 0.63 and 1.74 us.

### #12 Click-free filter exchange in fircore: crossfade old and new mask outputs

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** filtering · **Where:** `firmin.c:calc_fircore (323-347), setUpdate_fircore (485-494), xfircore (412-440)`

**Evidence.** Harness (real WDSP fir.c/firmin.c, arm64, size 64, nc 2048): when a 0 dBFS carrier crosses a moved edge or a notch lands on it, the current hard swap puts out-of-band splatter at -21 to -22 dB, against a steady floor of -131 dB, and the peak second difference is about 60x its steady value. A one-block raised-cosine crossfade brings out-of-band splatter to about -46 dB and the far in-band splatter (more than 1 kHz from the tone) down by about 27 dB. Splatter within 300 Hz of the tone drops only about 4 dB, and CW narrowing next to a strong tone improves only 1-5 dB. With noise only, the click is small (7.8 dB above steady) and the fix recovers 1.6 dB. Fade length scales at about 12 dB per doubling (128 samples -61 dB, 256 samples -74 dB, 1024 samples -98 dB). An exchange block costs about 20 us against a 1333 us budget. The code lens and the theory lens confirm that the description matches firmin.c 323-347, 412-440 and 485-494. Their independent simulations give the same picture: the one-block fade removes the broadband tick but leaves a near-carrier thump, and fades of 5-10 ms (256-480 samples) are needed for about 25-35 dB near-in.

**Recommended fix.** In fircore, crossfade the outputs of the old and new masks after each exchange.

**Crossfade**
- On a flip, keep the previous mask set readable. Run a second spectral MAC over the same FDL with the old masks, then a second IFFT.
- Crossfade the two time-domain outputs with a complementary raised cosine where g_old + g_new = 1. Do not use equal-power: the two outputs are coherent, so equal-power gives a +3 dB bump.
- Never interpolate the masks in the frequency domain.

**Fade length**
- Set the fade length in time, defaulting to about 5 ms (256 samples at 48 kHz). Let it span several blocks when the block is small.
- Do not use the finding's one-block default. At size 64 it only partly suppresses near-carrier splatter.

**Concurrency**
- Add a third mask set, or hold off calc and flip until the fade completes. calc_fircore currently writes fmask[1-cset] without a lock, and that is the set being faded from.
- Handle continuous drags or nbp retunes by coalescing to the latest pending impulse once the current fade finishes. In the harness, a naive multi-block fade under per-block updates measured worse than the original.
- An atomic generation counter alone is not enough.

**Paths that skip the fade**
- Skip the fade on re-plan paths: create, setNc, setSize and setBuffers. They zero the masks and FDL, so fading would fade in from silence.
- Accept a brief comb on setMp, where linear and minimum phase are not time-aligned, or skip the fade there.

**Verification**
- Check that output is bit-identical to the current code outside fade blocks.

**Out of scope**
- This does not fix the separate nbp issue where the tune shift and the mask flip land on different samples.

**Disagreements.** All three lenses agree that the current behaviour is described accurately and that the fix is sound with changes. They differ only on how much the fix helps.
- **Code lens:** marked the finding confirmed.
- **Theory and harness lenses:** marked it partly confirmed. Their reason is that the claim of "removes audible ticks" and "the most audible improvement" is overstated: the proposed one-block fade at size 64 leaves near-carrier splatter almost unchanged, and noise-only edge moves barely click at all.

**Resolution:** I went with the harness. It ran the real WDSP code, and its numbers match both independent simulations. The defect is real and audible when a strong carrier crosses an edge or a notch. The benefit of the fix as proposed is materially smaller and more situational than the finding claims, so the verdict is confirmed-smaller.

**Priority:** medium, not high. The improvement is audible but only in some situations, and it needs real concurrency work: a third mask set or a hold-off, plus coalescing.

**Point all three raised against the finding:** they converge on the concurrency race. The finding's "atomic generation counter" is not sufficient.

**Per-lens results**

- *code* (confirmed): Splatter model: a 1 kHz carrier at 48 kHz switched off at a block boundary, which is what (h_new-h_old)*x looks like when a carrier crosses a moved edge or a notch lands on it. Analysis used a 4096-point DFT with a Blackman-Harris window centred on the switch. Energy beyond the given offset from the carrier, relative to total:
- Hard switch (current code): -18.3 dB beyond 300 Hz, -26.8 dB beyond 1 kHz, -29.6 dB beyond 2 kHz, -32.4 dB beyond 4 kHz.
- Raised-cosine fade over 64 samples (one block at size 64): -23.6 / -55.5 / -67.4 / -83.1 dB.
- Fade over 256 samples: -48.7 / -79.0 / -93.0 / -106.6 dB.
- Fade over 1024 samples: -77.3 / -104.7 / -111.0 / -113.9 dB.
- Ungated reference (window floor): about -103 to -112 dB.
So a one-block fade at size 64 cuts the broadband tick (beyond 1 kHz) by about 29 dB but leaves a short thump near the carrier (only 5 dB better beyond 300 Hz). A fade of 256 samples or more takes it about 30 dB lower at 300 Hz.
Cost of the second MAC pass: nfor = nc/size. With the stock nbp0 (nc = max(2048, dsp_size)) and size 64, nfor = 32. With nc = 4096 (RXASetNC), nfor = 64.
Script: /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/verify2/f12_gate.py

- *theory* (partly): Simulation (clang arm64 + FFTW). I filtered a complex 1 kHz tone at 48 kHz through windowed-sinc BH4 complex bandpass filters (N = 1024, 2048 and 4096, all giving the same result), then switched the output from h_old*x to h_new*x at one sample, which is exactly what flipping cset over a full FDL does. Splatter is the peak level in a 2048-pt Hann frame centred on the switch, in dB relative to the tone. Case 1: the carrier leaves the passband (200-3000 Hz to 1500-3000 Hz, or a notch removes it). Hard switch: -32.4 dBc at |f-f0| >= 300 Hz and -42.5 dBc at >= 1 kHz. Raised-cosine complementary fade of 64 samples (one block, 1.33 ms): -33.9 / -64.2 dBc. 128 samples: -38.6 / -74.0. 256 samples (5.3 ms): -56.7 / -86.8. 480 samples (10 ms): -66.0 / -95.2. 1024 samples: -80.5 / -111.4. Case 2: the carrier stays inside both passbands (200-3000 Hz to 200-1500 Hz). Every fade length gives -78.6 / -109 dBc, which is the analysis-window floor, so there is no click. Derived: the hard switch is a full-amplitude step, y jumping from A*e^{jwn} to 0, equivalent to rectangular gating of the carrier. Moving an edge through noise only switches in a band of noise about df/BW of the passband power (for example 100/2800, about -14.5 dB), spread under the existing noise floor, so it is hard to hear. Extra cost on a fade block: one more full MAC over nfor = nc/size partitions (64 x 128 complex MACs at nc=4096, size=64) plus one IFFT of 2*size.

- *harness* (partly): Real WDSP fir.c and firmin.c (fircore, fir_bandpass, minphase), built with clang -O2 -arch arm64 and FFTW3. Settings: 48 kHz, nc=2048, wintype 1, linear phase unless noted. Input is a complex tone or noise. Metric is a BH7-windowed (L=2048) spectrum centred on the exchange sample, with power summed per region and normalised so a full-window 0 dBFS tone = 0 dB. Out-of-band (oob) means outside the union of both passbands, more than 50 Hz beyond the edges.

S1, low edge moved 200 to 1500 Hz across a 0 dBFS carrier at 1000 Hz (SetRXABandpassFreqs path), size 64:
- orig: oob -21.1 dB (steady -131.3); in-band >300 Hz from the tone -16.3 dB; in-band >1 kHz from the tone -26.2 dB; max|2nd diff| 1.017 (steady 0.017). The envelope goes from 1.0 to 0.0 between two adjacent samples.
- fixed, 1-block raised-cosine fade: oob -45.7; in-band >300 Hz -20.5; >1 kHz -53.1; max|d2| 0.018. The envelope ramps 1.0, 0.845, 0.488, 0.138, 0.0 over 64 samples.

S2, notch inserted on the carrier (nbp setImpulse(...,1) path): orig oob -22.5, in-band >300 Hz -17.7, d2 0.875. Fixed: -47.0, -21.8, d2 0.018.

S3, CW narrowing 300-1300 to 600-800 Hz, strong tone at 1100 Hz: orig oob -16.1, in-band -15.0. Fixed (1 block of 64): -21.4, -16.1. Close-in splatter is barely reduced.

S4, edge moved 3000 to 2800 Hz in noise only: orig oob -54.8 vs steady -62.6. Fixed -56.4. In-band is unchanged at -32.4.

S5, continuous drag with a 10 Hz step every block, size 64: orig oob -51.0, d2 0.019. Fixed (1 block) -75.1.

S6, notch walking off the carrier, nbp path, every block: orig oob -35.9, d2 0.124. Fixed -61.1, d2 0.015.

Fade length sweep for S1 oob: 64 samples -45.7, 128 -61.1, 256 -73.7, 512 -85.5, 1024 -97.8, against orig -21.1 at every block size. With mp=1 the orig and fixed numbers are essentially the same.

Naive multi-block fade under per-block updates gets worse (S5 at 4 blocks: -50.2; S6 at 4 blocks: -37.3) because calc_fircore overwrites the set being faded from.

Output identity: fixed equals orig to within 9e-16 outside the single fade block.

Cost per xfircore at size 64, nc 2048, M-series: about 7-8 us normally. On an exchange block, orig takes about 7-8.6 us and fixed about 20-21.6 us (2.5-2.9x), against a 1333 us block budget.

### #13 Run the doublepole CW filter as an exact recursive complex one-pole instead of an nc-tap FIR (up to 16384 taps)

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** filtering · **Where:** `doublepole.c:build_doublepole_1eff (142-162), calc_dpole_nc (30-43), create_doublepole/CalcDoublepoleFilter (164-185, 261-277)`

**Evidence.** All three lenses confirm the FIR is exactly a causal, zero-delay, truncated complex one-pole. Python, C and the real-WDSP harness all match the recursion to 1e-14 to 1e-16, differing only by the tail exp(-alpha*nc). That tail is -68.5 dB at the default 100 Hz but only about -46 to -48 dB just above each nc threshold (68, 34 and 17 Hz), not the claimed -90 dB. It works out to a multiplicative ripple of at most 0.037 dB, which is inaudible. Measured speed-up at 48 kHz is 5x to 143x: the FIR is 23x slower at block 64 and bw 100, and 4.9x at block 1024. The FIR never uses more than 1.7% of a core at 48 kHz. Savings of hundreds of times appear only at 192 kHz with small blocks (557x, 26.6% of a core). The harness confirmed the real user-visible defect. When bandwidth crosses an nc threshold, setNc_fircore zeroes the state: a steady tone collapses to |y|=0.003-0.007 with a full-scale one-sample step, and takes up to 5111 samples to settle. The recursion shows no transient there. Warm re-plan under csDSP takes 0.76-1.4 ms at block 64, about one block period. Same-nc changes behave identically in both.

**Recommended fix.** Replace the fircore path in doublepole with a per-channel complex one-pole: y[n] = g*x[n] + p*y[n-1], with g = gain*alpha and p = exp(-alpha)*e^{+j*2*pi*fc/rate} (alpha = pi*(bw/1.7)/rate, matching build_doublepole_1eff where omega = -2*pi*fc/rate). Keep y and p in double, and write the complex multiply-add as explicit real arithmetic so it avoids the C99 complex NaN/Inf checks.
- Drop the 1/(2*size) normalisation, calc_dpole_nc and every setNc/setImpulse call.
- CalcDoublepoleFilter, setSamplerate and setGain should only recompute alpha, p and g. setSize needs no coefficient change.
- Coefficient changes keep y[n-1]; no ramp is needed.
- flush_doublepole must zero y.
- Keep the CWU sign flip, the mode-2 Q=I input copy, run/position gating and in-place midbuff use unchanged.
- Add a flush-to-zero threshold on |y| (or rely on FTZ) so exactly-zero input never decays into subnormals on x86 builds. Apple Silicon has no penalty.
- Leave the unused 1sided/2sided builders out of the extraction.
- Regression test: impulse match to the old FIR within exp(-alpha*nc), and no envelope dip on a steady tone when bandwidth sweeps across 68/34/17 Hz.

**Disagreements.** The lenses agree on substance. The code lens said "confirmed"; theory and harness said "partly". The difference is only how heavily each weighed the overstated benefit claims, and all three independently found the same corrections:
- The tail is -46 to -48 dB, not -90 dB.
- The cost ratio is about 5x to 140x at 48 kHz, not 100x to 1000x.

I resolved it as confirmed-smaller. The equivalence and the fix hold exactly, but both the claimed accuracy gain and the CPU gain at normal 48 kHz settings are materially overstated.

The dropout claim was the one point the reasoning lenses could not settle, because wisdom makes re-planning fast. The harness decided it with measurements: the state-reset discontinuity at nc-threshold crossings is real, a near-zero output dip plus a full-scale step that takes up to about 0.1 s to settle. That is an audible artifact whenever the operator moves the APF/CW bandwidth across 68, 34 or 17 Hz. It also removes allocation and re-planning under the DSP lock.

I rated it medium rather than high for three reasons. The APF defaults to off. The glitch fires only on threshold crossings. Steady-state CPU is negligible at 48 kHz. It is still a cheap, low-risk simplification worth folding into the extraction.

On the side notes, theory correctly points out that "cascade two poles for a true 2-pole" misreads the design: this is deliberately a one-sided analytic resonator. Code and theory add the flush and denormal handling, which I included in the fix.

**Per-lens results**

- *code* (confirmed): Python simulation of fircore's partitioned overlap-save (size=8, nc=64, fc=600, bw=100, gain=2, rate=48000, mode-2 input). The FIR output matches the truncated recursion sum_{k<nc} gain*alpha*p^k*x[n-k] to 3.1e-16, with p = exp(-alpha + j*2*pi*fc/rate) and alpha = pi*(bw/1.7)/rate. That makes the FIR exactly a truncated complex one-pole: causal, zero added delay, and the 1/(2*size) only cancels the unnormalised FFT. Script: /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/v13/sim.py.

nc from calc_dpole_nc at 48 kHz: 2048 for bw>=68 Hz (bw>=136 gives 1024, clamped to 2048), 4096 for 34<=bw<68, 8192 for 17<=bw<34, 16384 for bw<17. It scales with rate_mult: 32768 at 96k and 65536 at 192k.

Truncation tail exp(-alpha*nc): -46.6 dB at bw=68, 34 and 17 Hz (the worst case), -68.5 dB at the default 100 Hz, -93 dB just below each threshold. Because H_trunc = H*(1 - p^nc z^-nc), this is a multiplicative ripple of only +/-0.04 dB in the worst case, not an additive error floor.

FIR cost per output sample: 2*nc/size complex MACs plus two 2*size-point FFTs per block. At the default nc=2048 and size=64 that is about 64 CMAC plus about 140 FFT flops, roughly 1/60 to 1/100 of a one-CMAC recursion. At nc=16384 and size=64 it is 512 CMAC per sample, about 1/500. The ratio shrinks at large dsp_size: nc=2048 with size=1024 gives about 4 CMAC per sample plus the FFTs.

setNc_fircore re-plans 3*nfor+1 PATIENT plans of size 2*size (769 plans at nc=16384, size=64) plus 4 minphase plans of size 4*nc (65536 points). It also allocates about 7 MB of minphase buffers even though mp=0, and it zeroes all filter history. All of this happens under ch.csDSP, the same lock the DSP thread holds around xrxa (main.c:40-58).

- *theory* (partly): I tested this with an arm64 clang -O2 harness that copies xfircore's partitioned overlap-save logic, using FFTW_MEASURE and the exact build_doublepole_1eff impulse with fc=600 and gain=2. I ran 10 s of complex white noise through it and compared the output with y[n]=gain*alpha*x[n]+p*y[n-1], where p=e^{-alpha}e^{+j2*pi*fc/rate}.

The relative error of the FIR output against the recursion equals the truncation tail e^{-alpha*nc} at every setting tested, to 0.1 dB:
- 100 Hz bandwidth: -68.5 dB
- 70, 35 and 18 Hz bandwidth, just inside each threshold: -47.9 to -48.0 dB
- 10 Hz bandwidth: -54.8 dB

So the FIR is exactly a causal, zero-delay convolution with a truncated complex one-pole, and the finding's sign convention for p is correct. Because H_trunc = H*(1 - p^N z^-N), the truncation only changes the magnitude response by a factor between 1 - e^{-alpha*nc} and 1 + e^{-alpha*nc}. At worst that is about +/-0.04 dB. It is not -90 dB as the finding says, and it is inaudible either way.

FIR CPU cost per second of audio at 48 kHz, against about 0.15 ms for the recursion:

| DSP block size | nc 2048 to 16384 | speed-up |
|---|---|---|
| 64 | 2.2 to 15.5 ms | 14x to 102x |
| 256 | 0.9 to 4.3 ms | 6x to 28x |
| 1024 | 0.66 to 1.5 ms | 5x to 10x |

At 192 kHz with a 64-sample block and nc=65536, the FIR takes 573 ms against 1.08 ms, about 531x. That is roughly 57% of one core.

Bandwidth: the 3 dB full width of the pole is 2*alpha rad/sample, which is bandwidth/1.7 in Hz. A 100 Hz setting therefore gives a 58.8 Hz -3 dB width. This is existing behaviour and the recursion keeps it.

Pole radius at a 10 Hz setting at 48 kHz: 1 - 3.85e-4.

- *harness* (partly): I built the real WDSP code with clang -O2 -arch arm64 and FFTW3 on macOS. I used doublepole.c as is, plus the fircore section (firmin.c 289-494) and the minphase and analytic sections from fir.c. The buffer is in place and twice the block size, as RXA midbuff is. Defaults are fc 600 Hz and gain 2, at 48 kHz unless noted.

(1) Impulse equivalence, block size 64. For the first nc samples, the original and the recursion differ by at most 2e-15 to 2e-14 relative to the peak. Both start at the same sample, so there is no latency difference. The original's truncated tail relative to the peak is the error energy below:
- bw 100: nc 2048, -68.5 dB
- bw 69: nc 2048, -47.3 dB
- bw 60: nc 4096, -82.2 dB
- bw 35: nc 4096, -47.9 dB
- bw 20: nc 8192, -54.8 dB
- bw 16: nc 16384, -87.7 dB
Each matches exp(-alpha*nc). The worst case is about -47 dB, not -90 dB. Frequency response differs by at most 0.037 dB (bw 69, at 600 Hz: 5.994 vs 6.032 dB; at 634 Hz: 0.170 vs 0.133 dB).

(2) Gaussian noise in mode 2, 262144 samples. Output difference relative to output power: -68.5 dB at bw 100, -47.3 dB at bw 69, -48.0 dB at bw 35.

(3) Bandwidth change mid-stream on a steady 600 Hz tone, steady amplitude 1.414:
- 70 to 60 Hz (nc 2048 to 4096, setNc): the original drops to |y| = 0.0065 and steps by 1.403 in one sample. The recursion's minimum is 1.395, and its step is 0.111, the tone's normal per-sample rotation. Envelope-deviation energy is 217 vs 2.2.
- 36 to 30 Hz (nc 4096 to 8192): the original drops to 0.0033 with a 1.406 step, and takes 5111 samples to settle within 1%. The recursion steps 0.111, settles immediately, and its deviation energy is 432 vs 0.5.
- 60 to 50 Hz (same nc, setImpulse): the two are identical (deviation 1.5 vs 1.5).

(4) Time for CalcDoublepoleFilter when the bandwidth crosses a threshold:
- Cold, with no FFTW wisdom: 3395 ms (to nc 4096) and 6378 ms (to nc 8192).
- Warm, standing in for WDSP's wisdom file: 0.76 to 1.39 ms at block size 64. One block lasts 1.33 ms at 48 kHz. At block size 1024 it is 0.18 to 0.41 ms.
- Recursion: about 0 ms.

(5) Steady-state cost in ns per sample, original vs recursion:
- 48k, block 64: bw 100 55.2 vs 2.44 (23x); bw 30 186 vs 2.47 (75x); bw 12 350 vs 2.44 (143x)
- 48k, block 1024: bw 100 11.9 vs 2.41 (4.9x); bw 30 25.5 vs 2.64 (9.7x); bw 12 31.4 vs 2.54 (12.4x)
- 192k, block 64: bw 100 165 vs 2.45 (68x); bw 30 693 vs 2.49 (278x); bw 12 1388 vs 2.49 (557x)
- 192k, block 1024: bw 100 19.4 vs 2.51 (7.7x)
The original's worst case is 26.6% of one core in real time (192k, block 64, bw 12). At 48k it is 0.06% to 1.7%.

### #15 xaamav divides by zero after an input stall and latches feed_forward at +inf

**Priority:** medium · **Verdict:** confirmed · **Area:** resampling · **Where:** `rmatch.c:xaamav (L101-126, division at L117), control (L260-262, L269-271)`

**Evidence.** All three lenses confirm the finding. The harness built verbatim WDSP 2.11 rmatch.c and varsamp.c on arm64; I diffed orig against the source and the only changes in fixed/ are the minimal fix. With input stalled and output still calling, ffmav pos reaches 0 after exactly 262144 output calls: 349.5 s at 64-sample blocks and 1398 s at 256. feed_forward then goes to +inf and stays there; var was still clamped at 1.04 after 900 s of resumed input. In that state there are 750 overflows per second, the ring stays pinned full at about twice normal latency, and amplitude dips to 0.21. At 64/256 the median tone falls to 976 Hz. The fixed build never goes inf and returns to var of about 1.000 with 0 overflows. Runs that never hit pos==0 give byte-identical output from both builds. The code and theory lenses' simulations agree, and add a derived bias of S/131072 for a stall of S output calls.

**Recommended fix.** Adopt the guard in the LyraDSP rmatch (VAC path) and pair it with re-acquisition on resume:
(1) Add a `last` field to AAMAV, initialised to nom_ratio in create and flush. In the steady-state branch do `if (pos > 0) last = neg/pos; *output = last;`. Skipping the write alone is not enough, because control()'s current_ratio is an uninitialised local.
(2) In control(), only update the feed_forward EMA when isfinite(current_ratio).
(3) Also detect a one-sided stall: N consecutive same-sign control() calls, or an xrmatchOUT underflow with no xrmatchIN since the last call. Freeze the feed-forward and P state during the stall. On resume, call flush_aamav(ffmav) and flush_mav(propmav) and restore the last good feed_forward. Without this, any input stall longer than about 7 s (64-sample blocks) leaves var pinned at 1.04 with continuous overflows for about 3 to 5 minutes after resume. That happens in the original code as well as with steps 1 and 2. The theory lens's simulation of this step gave 0 s pinned.
Optionally, widen pos/neg to int64 or double: neg reaches 262144*outsize and overflows int at outsize >= 8192. A neg==0 guard is not needed, because an output stall gives a finite ratio of 0.

**Disagreements.** The lenses agree on the mechanism, the trigger time and the fix. They differ only on how big the benefit is. The harness lens showed the symptom depends on configuration: at 64/64 block sizes, overflow dropping keeps the mean pitch near 1000 Hz and the damage is continuous overflows and crossfades; at 64/256 there is a real pitch error. So the finding's "4% fast, pitch shift" is partly overstated, while "continuous overflows and glitches until reset" holds everywhere.
All three note that the minimal guard turns a permanent latch into a transient of about 3 to 5 minutes. They also note the same transient already follows much shorter stalls, so the freeze/flush-on-resume step is what fixes most of what users would hear. I folded that into the recommended fix instead of leaving it optional.
I kept "confirmed" rather than "confirmed-smaller" because the latch, its timing and its consequences match the claim exactly. I set priority to medium rather than high for two reasons. First, rmatch is reached only through the host VAC path. Second, with Lyra's default vacSize of 2048, the latch needs about 3.1 h of continuous input stall; at the minimum vacSize of 64 it takes about 6 minutes. The fix is nearly free, and the related short-stall transient is more common, so it is worth doing during extraction.

**Per-lens results**

- *code* (confirmed): I transcribed xaamav and the control() EMA into a C harness at /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/v15/sim.c, using equal 48k nominal rates, ringmin 4096, ringmax 262144, alpha 0.01, and 2M balanced calls before the stall.
(1) Output blocks of 64, output-only stall: after 200000 calls (266.7 s), pos is still above 0 and ff=7.42. After exactly 262144 calls (349.5 s), pos=0 and ff=inf. ff stays inf through 4M later calls once input resumes, so it never recovers.
(2) Same test with the fix (hold the last ratio when pos==0, plus an isfinite guard): ff ends the stall at 2.6e4 to 2.6e5, which is finite. It still stays at or above 1.04 for 257102 calls (171 s) after input resumes, and reaches |ff-1|<1e-3 after 175 s. Without the fix, a 200000-call stall that never reaches pos=0 shows the same 171 s transient.
(3) insize 1024, outsize 256: pos=0 takes 262144*256/48000 = 1398 s (23 min). With the fix, ff stays at or above 1.04 for about 1084 s after resume.
(4) Lyra's default vacSize is 2048, and vac_size is the outsize of rmatchOUT. That gives 262144*2048/48000 = 11185 s (about 3.1 h) of stall before the latch. The minimum, 64, gives 350 s.

- *theory* (confirmed): I copied xaamav, xmav and control from rmatch.c into a C simulation, using the create_rmatchV parameters (ff window 4096 to 262144, ff_alpha 0.01, pr_gain 4e-6, clamp 0.96 to 1.04) and 64-sample blocks at 48 kHz. The P-loop ring deviation is held at 0, so only the feed-forward path is modelled.
(a) Without the fix: after 262143 to 262144 output-only calls (349.5 s), pos=0, neg=16777216, ff=inf and var=1.04. After 2,000,000 balanced in/out pairs (2667 s), ff is still inf and var is still 1.04. The latch is permanent.
(b) With a pos==0 hold: ff peaks at about 2.6e4 to 2.6e5 (finite) during the stall. After resume, var stays pinned at 1.04 for 128,557 pairs (171 s), then returns to 1.000000.
(c) The same 171 s pin happens with the original code after any shorter stall: I tested 13 s, 67 s, 175 s and 267 s, and every one gave 171 s. The stall's negative entries stay in the 262144-entry count window until it refills. Derived: the feed-forward bias is S/131072 for a stall of S output calls. It exceeds the 4% clamp for S > about 5243 calls (about 7 s at 64-sample blocks). A 1 s stall gives about 0.57% ratio error for about 3 minutes.
(d) Flushing ffmav and restoring the last good feed_forward on resume gives 0 s pinned and var=1.000000 at once, for both stall lengths.
P-loop authority: pr_gain times a deviation of about rsize/2 (for example 4e-6 × 2048 ≈ 0.008) cannot cancel a feed-forward error above 4%. While var is pinned, the ring overflows and blends.
Int overflow aside: neg can reach 262144 × outsize, which overflows int at outsize ≥ 8192.

- *harness* (confirmed): Setup: real WDSP 2.11 rmatch.c and varsamp.c, using the create_rmatchV defaults (ffmav 4096/262144, ff_alpha 0.01, prop_gain 4e-6, varmode 1, ringsize 4096, so rsize is 4032). Input block 64 at 48 kHz +20 ppm with a complex 1 kHz tone at amplitude 0.5. Output block 64 or 256 at 48 kHz. Event-driven two-clock simulation; the input makes no calls during the stall.

(A) 64/64, 400 s stall. ORIG: ffmav pos reaches 0 and feed_forward is inf from t=409.5 s, which is 349.5 s after the stall began (262144*64/48000 = 349.5 s predicted). After input resumes, feed_forward stays inf and var stays at 1.040000 for the remaining 900 s. Every input call overflows (15000 per 20 s, 673470 overflows in total), n_ring stays pinned at 4032 (full ring, about 84 ms, versus about 2020 normally), and tone amplitude ripple has sd 0.0018 with dips to 0.21 (clean is sd 0.0000). FIXED: largest finite feed_forward is 262143. After resume, var stays at 1.04 for about 180 s while the 262144-entry window refills, then recovers: var 1.000060, ff 0.999977, 0 overflows per window, amplitude sd 0.0000, n_ring about 2010. Total overflows 128548.

(B) 64/256, 1450 s stall. ORIG: inf at t=1458.1 s, 1398 s into the stall (23.3 min predicted). Latched state: 9376 overflows per 50 s, median instantaneous tone frequency 976.3 Hz (mean 993.4 Hz), 2,024,998 samples per 50 s window more than 20 Hz off 1 kHz, amplitude minimum 0.09. FIXED: recovers about 290 s after resume (var 0.99928, 0 overflows, amplitude sd 0). A 1350 s stall in ORIG (no pos==0) recovers normally.

(C) Controls. 300 s and 10 s stalls give byte-identical output from ORIG and FIXED (fix inert when pos>0). No stall: 0 overflows and 0 underflows. A 10 s stall in ORIG still causes about 180 s of var=1.04 with 750 overflows/s (128548 overflows), a pre-existing transient the minimal fix does not address.

### #16 CFC latency of fsize-bsize samples: decouple time smoothing from frame length

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** tx-processing · **Where:** `cfcomp.c:calc_cfcomp (264-326), calc_mask (440-481), xcfcomp (483-534); TXA.c create_cfcomp (202-223: fsize=max(16384,dsp_size), ovrlp=4)`

**Evidence.** All three lenses agree on how the code behaves now, and the harness confirms it by running the real cfcomp.c. Method 0 is a memoryless per-bin hard clip. mmult/dmult only feed the meter and display. Latency is exactly fsize-bsize when fsize >= 4*bsize, and fsize-fsize/4 when fsize <= bsize. Measured figures: 340 ms at 48k/bsize 64, 160-170 ms at 96k, and 128 ms (12288 samples) at Lyra's real TX setting of 96k/dsp_size 4096. So the headline "170-340 ms" overstates the Thetis/Lyra case. Short frames cut latency to 8-16 ms at Lyra's setting (8-16x) and to 8-20 ms at 48k. They also remove a large pre-echo artifact the finding did not mention: the 16k frame produces output up to about 200 ms before a burst onset, at -5 to -28 dB. On the other side, the "less warble" claim fails against the current processor. With 47-94 Hz bins method 1 cannot resolve harmonics, and it measured 4-39 dB more interharmonic distortion than the 16k original. It does beat a plain short-frame hard clip by 4-16 dB. The 1/3-ERB smoothing is narrower than one bin below about 1-2 kHz, so it does almost nothing. The FBE "2-5 ms" figure was not tested and ignores gain lag. One more limit: Lyra does not enable CFC today; the only mention is a comment at src/hl2_stream.h:454.

**Recommended fix.** In LyraDSP, keep comp_method 0 with fsize 16384 as the default so output stays bit-identical (the harness confirmed it does). Then do the following.

(1) Cheapest step first: add an fsize/ovrlp setter for CFC. It must decalc/calc under the DSP lock, as setSize_cfcomp does. It must also validate or fix the pre-existing indexing constraint in calc_cfcomp. The oasize/oainidx setup breaks reconstruction (identity SNR 25 dB) whenever fsize/ovrlp < bsize < fsize. Either allow only fsize >= 4*bsize or fsize <= bsize, or fix the oasize/oainidx math. At Lyra's TX bsize of 4096, fsize 1024 or 2048 is valid and gives 8 or 16 ms. fsize 4096 (32 ms) is also valid. fsize 8192 is broken.

(2) Rewrite GetTXACFCOMPDisplayCompression for short frames. Its step = (msize-1)/1024 becomes 0 when fsize < 2048.

(3) If a smoothed method 1 is added later, make it opt-in. Add a default case to the calc_mask switch so the mask is never left stale. Use separate attack/release parameters instead of reusing mtau/dtau, which are the meter and display time constants. Feed a->gain and a->delta from method 1 as well. Use about 1-ERB or 2-3-bin frequency smoothing rather than 1/3-ERB. Document method 1 as a different multiband compressor that does not resolve harmonics, not a low-latency version of the current CFC.

(4) Treat FBE and asymmetric analysis/synthesis windows as later research items. They need gain-lag and crossfade handling.

**Disagreements.** There was no disagreement on whether the effect exists: all three lenses returned "partly", the current-behaviour description was accurate, and the fix was judged sound with changes. They differed on detail, and I resolved it as follows.

- Latency baseline: the finding gave 170-340 ms. The code lens's trace and the harness agree that Thetis/Lyra TX runs at 96 kHz. I checked src/wdsp_engine.cpp: kRateTx is 96000 and kBlockTx is 4096. The measured 128 ms therefore governs for Lyra, and 160-170 ms applies with small buffers.
- Quality: the theory lens predicted, and the harness measured, that method 1 gives more interharmonic distortion than the 16k original. The harness also measured a pre-echo improvement much larger than the finding claimed, and found no loss of talk-power on synthetic speech. Net quality is mixed. I take the harness numbers over reasoning here, while noting its limits: synthetic speech and no listening tests.
- New issue: only the harness found the indexing bug that breaks reconstruction when fsize/4 < bsize < fsize. I checked the logic against cfcomp.c:276-283, and it matches what lat.sh reproduces (8192/4096 gives 25 dB SNR). It is a constraint any fsize setter must enforce.

Verdict and priority: I rated it confirmed-smaller because the baseline delay is 128-170 ms, not up to 340, and the quality benefit is partly reversed. Latency reduction itself is roughly the claimed size. I set priority to medium, not high, because CFC is opt-in and Lyra does not enable it yet. Still, the fsize setter plus the indexing fix is cheap to do during extraction, and it removes an audible 128 ms MON delay whenever CFC is used.

**Per-lens results**

- *code* (partly): I simulated the exact xcfcomp indexing in pure Python: an impulse at several offsets, an identity mask, and the real sqrt-BH4 window normalisation from calc_cfcwindow. That chain reconstructs the impulse exactly (peak 1.0, sum 1.0), and the delay is constant, so it does not depend on where the impulse falls in a block.
- When fsize > bsize, the delay is exactly fsize - bsize. At fsize 16384 it is 16320 / 16256 / 16128 / 15872 / 15360 / 14336 / 12288 samples for bsize 64 / 128 / 256 / 512 / 1024 / 2048 / 4096.
- When fsize <= bsize, the code takes the other branch (cfcomp.c:280-284) and the delay is fsize - incr. Examples: 768 for 1024/1024, 1024/4096 and 1024/256; 384 for 512/1024; 960 for 1024/64.
- Thetis-style TX channel: OpenChannel with dsp_rate 96000 and dsp_size 4096 (cmaster.c:177-190 as documented in the Lyra notes), so fsize = max(16384, 4096) = 16384. CFC delay is 12288 samples = 128 ms at 96 kHz. After the Thetis Setup Phone TX buffer setting (64-1024) is applied through SetDSPBuffsize, setSize_cfcomp changes only bsize, so the delay becomes 15360-16320 samples = 160-170 ms. The 340 ms figure applies only if a host runs TXA at a 48 kHz dsp_rate, which Thetis does not.
- Bin width is 5.86 Hz at 96 kHz and 2.93 Hz at 48 kHz. The hop is 4096 samples (42.7 ms at 96 kHz).
- The window polynomial 0.21747 / -0.45325 / 0.28256 / -0.04672 is BH4 (0.35875, 0.48829, 0.14128, 0.01168) rewritten as powers of cos. So the analysis window is sqrt(BH4) and window^2 is constant-overlap-add at hop N/4.

- *theory* (partly): I wrote my own pure-Python replica of the xcfcomp inaccum/outaccum/save indexing, using the code's own sqrt-BH4 window, pregain and postgain. I fed it a mid-stream impulse through an identity mask (scratchpad/f16/lat.py). The output is the impulse with gain 1.000 in every case, so reconstruction is perfect. The delay always equals fsize - bsize:
- 16384/64: 16320 samples, 340.0 ms at 48 kHz or 170.0 ms at 96 kHz
- 16384/1024: 15360 samples, 320 or 160 ms
- 2048/64: 1984 samples, 41.3 or 20.7 ms
- 1024/64: 960 samples, 20.0 or 10.0 ms
- 512/64: 448 samples, 9.3 or 4.7 ms
The proposed 512-1024 frames therefore cut CFC delay by about 16-36x. Without CFC, the TX bandpass filters (nc = max(2048, dsp_size), linear phase) add roughly 10 ms each, so CFC dominates TX latency when it is on.

Derived results:
1. A causal WOLA's delay is about one frame, roughly 1/delta-f. So 47 Hz bins cost about 21 ms whatever the sample rate. At 96 kHz, fsize 1024 gives 94 Hz bins, not 47 Hz.
2. Resolving harmonics needs the BH4 main lobe (about 8 bins wide) to be narrower than F0. For a 100 Hz male voice that means bins of 12.5 Hz or less, i.e. N of 3840 or more at 48 kHz (about 80 ms). The proposed method 1 therefore cannot resolve harmonics at all.
3. The current 341 ms frame resolves harmonics only for the low partials of steady voiced speech. A ±5% F0 drift over 340 ms moves the 10th harmonic of a 100 Hz voice by ±50 Hz, which spans about 17 bins of 2.9 Hz. In practice the long frame mostly buys slow time averaging, not per-harmonic limiting.
4. 1/3 ERB is 0.108f + 8.2 Hz: about 44 Hz at 1 kHz and 116 Hz at 3 kHz. That is narrower than one 47-94 Hz bin below about 1-2 kHz, so the proposed 1/3-ERB frequency smoothing does almost nothing over most of the SSB passband.
5. BH4 (the product of the sqrt-BH4 analysis and synthesis windows) has cosine terms up to order 3, so it is exactly COLA at R=4. The 'R>=4' risk statement is correct.

- *harness* (partly): All numbers are from the real WDSP 2.11 cfcomp.c, built with clang -O2 -arch arm64 and FFTW3. The block was run standalone, with ovrlp 4, wintype 1 (sqrt-BH4) and the default G curve.

LATENCY. Measured from the impulse peak through identity gain. Identity reconstruction SNR is about 300 dB unless stated otherwise.
- Original method 0, fsize 16384 at 48 kHz: 16320 samples at bsize 64 (340 ms), 16128 at bsize 256 (336 ms), 15360 at bsize 1024 (320 ms).
- Same at 96 kHz: 16320 samples (170 ms) at bsize 64, 15360 (160 ms) at bsize 1024, 14336 (149 ms) at bsize 2048.
- Lyra's TX setting is 96 kHz with dsp_size 4096 (src/wdsp_engine.cpp:1148). There fsize 16384 gives 12288 samples = 128 ms.
- Short frames: 1024 at 48 kHz gives 960, 896 and 768 samples at bsize 64, 128 and 256 (20, 18.7 and 16 ms). 512 at 48 kHz gives 448 or 384 samples (9.3 or 8 ms). At 96 kHz with bsize 4096: 2048 gives 1536 samples (16 ms) and 1024 gives 768 (8 ms).
- Reduction: 17-21x at 48 kHz with fsize 1024, and 8x (fsize 2048) or 16x (fsize 1024) at Lyra's TX setting.

INDEXING CONSTRAINT. WDSP's existing indexing breaks whenever fsize/ovrlp < bsize < fsize: identity SNR drops to 25 dB. Broken cases measured: 512/256, 1024/512, 2048/1024, 4096/2048, 8192/4096. Valid cases are fsize >= 4*bsize (latency = fsize - bsize) or fsize <= bsize (latency = fsize - fsize/4).

REGRESSION CHECK. The fixed build run with method 0 is bit-identical to the original (cmp of the outputs at precomp 20, 30 and 40).

QUALITY (48 kHz, bsize 256). Columns are: original 16k (A), original method 0 at 1024 (the cheap interim fix, B), proposed method 1 at 1024 with R=20, knee 6 dB, attack 1 ms, release 60 ms and 1/3-ERB smoothing (D).
- Pre-echo, 50 ms window before a 0.6 s vowel burst:
  - precomp 20: A -27.5 dB, B -108, D -108
  - precomp 30: A -11.5 dB, B -93, D -94
  - precomp 40: A -4.9 dB, B -75, D -77
- Earliest output at -60 dB relative to burst onset: A -116 to -204 ms, short frames -4 to -11 ms.
- Interharmonic distortion, steady 150 Hz vowel (input -94 dB):
  - precomp 20: A -62.4, B -53.4, D -61.4
  - precomp 30: A -55.5, B -33.3, D -48.9
  - precomp 40: A -47.7, B -27.4, D -43.6
- Interharmonic distortion, 4 Hz AM vowel (input -127 dB):
  - precomp 20: A -82.9, B -37.0, D -41.7
  - precomp 30: A -71.9, B -29.0, D -32.7
  - precomp 40: A -60.1, B -20.9, D -27.0
- At 96 kHz/4096, AM vowel, precomp 30: A -46.0, B -28.3, D(2048) -31.9. Pre-echo 50 ms: A -18.4, B -92.7, D -94.5.
- Band-level SD reduction on synthetic speech, at the same precomp:
  - precomp 30: A 0.15 dB, B 1.16, D 1.27
  - precomp 40: A 0.76 dB, B 3.29, D 3.07
- PAPR increase on speech: A +5.2 to +5.8 dB, D +2.0 to +3.3 dB.

### #17 DEXP cannot re-trigger during DECAY, and its setters reset state and zero the delay ring

**Priority:** medium · **Verdict:** confirmed · **Area:** tx-processing · **Where:** `dexp.c:xdexp (305-381, specifically the DEXP_DECAY case 373-379)`

**Evidence.** The harness built the real WDSP 2.11 dexp.c on arm64 in two versions, unmodified and fixed. Setter dropout: each call to SetDEXPAttackThreshold, ReleaseTime, DetectorTau or ExpansionRatio outputs exactly 2880 zero samples (60.0 ms) with the audio delay on, and ten slider-style calls give 600 ms of zeros. The fixed build outputs none. Retrigger: with release 1 s, syllables losing more than 1 dB at onset drop from 34/99 to 0, and from 45/99 to 0 at a 20 dB ratio. Onsets lose 7-18 dB. At the default 100 ms release only pauses of about 530-650 ms are affected, and 4/99 syllables lose more than 1 dB. Code and theory both trace the same cause at dexp.c 373-379: DECAY has no threshold test, and the gain is applied before xdelring, so there is no look-ahead. I confirmed this in the source.

**Recommended fix.** 1) In DEXP_DECAY, retrigger into DEXP_ATTACK on the same detector test that HOLD uses (choose avsig or the antivox-adjusted asig on purpose; keeping it consistent with HOLD is preferred). Continue from the current gain with the exact index map k = round(nattack*(1 - j/ndecay)), where j = ndecay - count; both tables are the same raised cosine. A single gain state slewed toward a target is a cleaner alternative in the float32 port. 2) Split coefficient recalculation out of calc_dexp, for example into recalc_dexp_coefs, so the DetectorTau, AttackTime, ReleaseTime, HoldTime, ExpansionRatio, HysteresisRatio and AttackThreshold setters keep state, count, avsig, vox_count and audring. When nattack or ndecay changes mid-ramp, rescale or clamp count proportionally; otherwise cattack[nattack-count] or cdecay[ndecay-count] reads out of bounds. Reallocate a table only when its length changes. AudioDelay should move inptr relative to outptr rather than rebuilding a zeroed ring (a small skip or repeat is unavoidable there). Size and IOBuffers must update the ring's size and in/out fields. Rate may still rebuild everything. 3) Document that VOX behaviour changes: the key holds while signal keeps returning within hold + release. In the harness VOX unkeys fell, for example from 14 to 1. This is arguably correct, but it is not "unaffected" as the finding claims.

**Disagreements.** The three lenses agree on the substance: both defects are real and the fix is yes-with-changes. The differences are in emphasis.
- Benefit size: all three say the retrigger effect is narrow at the defaults (release 100 ms, hold 500 ms, about 3 dB on rare 550-650 ms pauses) and large with long releases. That matches the finding's "for anyone using long release times" wording, so I rated it confirmed rather than confirmed-smaller. The setter dropout matches the finding exactly: 60.0 ms of zeros, and it is reachable in stock Thetis through the VOX slider and SetDEXPAttackThreshold.
- Omissions in the proposal, raised by the verifiers and folded into the fix: the out-of-bounds risk in the count rescaling (all three), the special handling the AudioDelay, Size and IOBuffers setters need (code lens), the asig vs avsig inconsistency (code and theory lenses), and the change in VOX timing that contradicts the finding's "VOX unaffected" risk text (harness). The code and theory lenses also note an existing side effect: a setter reset re-arms vox_count, so VOX can unkey early.
- "Every parameter setter" is slightly too broad: the Run* flags and the AntiVOX setters do not reset. This does not change the verdict.
- Priority is medium, not high. DEXP is off by default, and the dropout needs a control to be changed while transmitting. It is still worth fixing during extraction, because the in-place setter design is easiest to get right while the port is being written.

**Per-lens results**

- *code* (confirmed): I ported the xdexp state machine to Python, with no side-channel filter: rate 48 kHz, attack 2 ms, hold 500 ms, 10 dB ratio, dettau 20 ms, hysteresis 0.75. The test signal is 300 ms of tone, a gap, then 300 ms of tone. Each line gives how long the second burst sits below unity gain, and its lowest gain.

- Release 100 ms (the Thetis UI default). Gap 560 ms: stock 93.7 ms, down to -10 dB; with retrigger 2.2 ms, down to -0.2 dB. Gap 600 ms: stock 53.8 ms at -10 dB; retrigger 3.0 ms at -3.7 dB. Gap 520 ms or 800 ms: the two are about the same.
- Release 300 ms, gap 560 ms: stock 278.7 ms at -10 dB; retrigger 0 ms.
- Release 1000 ms, gap 600 to 800 ms: stock keeps fading the speech that has resumed for the whole 300 ms window, which ends with the gain still falling; retrigger needs at most 2.5 ms to recover.

At the default settings, only pauses of about 550 to 650 ms are exposed: the hold time, plus about 50 ms for avsig to fall below hold_thresh, plus the release. The audio delay ring defaults to 60 ms (audelay 0.060, which is 2880 samples at 48 kHz). Every setter rebuilds that ring zeroed, so when the delay is on the output is silent for 60 ms.

- *theory* (confirmed): Derived from dexp.c with release T, attack Ta and low_gain L = 1/exp_ratio.

(1) Speech that resumes a fraction f of the way into the release keeps fading along the raised cosine g = L + (1-L)*0.5*(1+cos(pi*t/T)) down to L. It stays exposed for (1-f)*T + Ta. It then jumps back to full gain over Ta, which is a +20*log10(exp_ratio) dB step within about 2 ms in the middle of a syllable. With a 10 dB ratio (L = 0.316), the floor is -10 dB. Across the whole ramp the mean amplitude gain is (1+L)/2 = 0.658 (-3.6 dB) and the mean power gain is L^2 + L(1-L) + 3/8*(1-L)^2 = 0.491 (-3.1 dB). A 20 dB ratio gives a -20 dB floor and a -4.9 dB mean.

(2) The failure window is any pause whose length is between hold + detector lag and hold + T. With the assumed Thetis-like defaults (hold 0.5 s, release 0.1 s; I could not check these locally), only pauses of about 0.5–0.6 s are affected. With T = 1 s, any pause of 0.5–1.5 s is affected, and that covers a large share of normal phrase breaks in conversational speech.

(3) Setters: every timing, ratio, threshold or delay setter calls calc_dexp. That sets state = LOW, count = 0 and avsig = 0, and rebuilds audring with malloc0, inptr = rdelay and outptr = 0. With audio delay on, the output is therefore exactly round(audelay*rate) zero samples. The gain also falls immediately to L and stays there until avsig, restarting from 0 and climbing with time constant dettau, crosses attack_thresh again.

- *harness* (confirmed): Real WDSP 2.11 dexp.c built with clang -O2 -arch arm64 against a POSIX shim. Settings: 48 kHz, block 256, attack_thresh 0.05, hysteresis 0.5, attack 2 ms, hold 500 ms, detector tau 10 ms, side-channel filter off. Input is a complex tone, so per-sample gain = |out|/|in|.

TEST A: 600 ms burst at 0.3, then a gap, then a 400 ms burst. Values are orig -> fixed.
- Release 100 ms, ratio 10 dB:
  - gap 550 ms: first 50 ms -3.43 -> -0.04 dB. Minimum gain -10.0 -> -1.06 dB. Time to reach gain 0.99: 76.8 -> 2.2 ms.
  - gap 600 ms: first 50 ms -2.66 -> -0.19 dB. Time to 0.99: 26.8 -> 3.2 ms.
  - Gaps up to 520 ms and from 700 ms on are identical in both builds. The exposure window is only about 530-650 ms of gap.
- Release 1 s, ratio 10 dB:
  - gap 900 ms: whole 400 ms burst -4.51 -> -0.01 dB. The original never reaches gain 0.99 inside the burst.
  - gap 1200 ms: first 50 ms -6.79 -> -0.17 dB. Whole burst -5.23 -> -0.02 dB. Time to 0.99: 326.8 -> 3.0 ms.
  - gap 1400 ms: first 50 ms -9.54 -> -0.22 dB.
- Release 1 s, ratio 20 dB:
  - gap 1400 ms: first 50 ms -18.23 -> -0.25 dB.
  - gap 1200 ms: whole burst -6.72 -> -0.02 dB.
- With the 60 ms audio delay on, the numbers are identical after alignment. The gain is applied before the delay ring, so the delay does not hide the loss.
- Largest per-sample gain step: the same in both builds (0.0112 at ratio 10 dB, 0.0147 at ratio 20 dB). The retrigger adds no click.

TEST S: 60 s of speech-like input, 99 syllables, deterministic pauses of 30 ms to 1.5 s. Orig -> fixed:
- Release 0.1 s: syllables losing more than 1 dB in their first 60 ms: 4 -> 0.
- Release 0.5 s: 15 -> 0.
- Release 1.0 s: 34 -> 0. Voiced energy -1.13 -> -0.01 dB.
- Release 1.0 s, hold 0.1 s, ratio 20 dB: 45 -> 0. Voiced energy -2.20 -> -0.02 dB.

TEST B: steady tone, 60 ms audio delay on, one setter call at t = 1 s.
- Each of SetDEXPAttackThreshold, ReleaseTime, DetectorTau and ExpansionRatio: original outputs 2880 samples (exactly 60.0 ms) of exact zeros, and 63.7-65.5 ms with gain below 0.99. Fixed: 0 samples.
- Ten threshold calls 100 ms apart (slider drag): original 28800 zero samples (600 ms of zeros in 1 s). Fixed: 0.

TEST C: complex noise wandering about ±10 dB around the threshold, hold 0.1 s.
- Total gain variation is lower with the fix: 19.1 -> 4.9 and 17.8 -> 12.9 at release 1 s; 41.0 -> 35.0 at release 0.1 s.
- VOX unkey count drops: 9 -> 1 and 10 -> 3 at release 1 s.

### #18 Phase-rotator auto-tuner: paired (shadow-chain) evaluation, no state zeroing, and a crest-factor objective

**Priority:** medium · **Verdict:** confirmed-smaller · **Area:** tx-processing · **Where:** `phrot.c:recalc_fc (102-116), optimizer_step (152-219), xphrot (266-315)`

**Evidence.** All three lenses confirm the code facts. recalc_fc zeroes x0/x1/y0/y1 on every optimizer step, which runs every 15 s; on an accept the coefficients do not even change. The A/B test compares 1 s EMAs read 15 s apart on different audio. The objective is real-waveform asymmetry. The harness compiled the real phrot.c, and its output matched the emulation exactly (maxdiff 0). The zeroed-state click measured +1 dB re talker peak above 3 kHz on a tone. On speech the worst case was -4 to -13 dB band-limited, with 4-9 events per 5 min above -40 dB. Keeping the state cuts this by 30-45 dB, and a 10 ms crossfade removes it completely. Paired evaluation cuts per-decision variance 2-76x but did not converge in seconds: it took 137-428 s against 270-300 s for the original, because the asymmetry landscape is rugged and multimodal. The SSB envelope-crest gain was only 0.4-1.4 dB across the harness and theory runs, below the claimed 1-2 dB, and the 338 Hz default is already within about 0.1 dB of the envelope optimum. The path only runs when a host enables both Run and AutoMode, and the stock create sets both to 0.

**Recommended fix.** In LyraDSP's phrot:
(a) Never memset the allpass state in recalc_fc. When fc is unchanged (accept, convergence or AutoReset onto the same fc), just skip the recompute. That removes those clicks completely at no cost.
(b) When fc does change during TX, run the old and new coefficient sets in parallel for about 10 ms and fade between them with a raised cosine. Do not just keep the state, and do not copy a shadow chain's state: both leave a hard jump between two waveforms that differ by roughly signal RMS, which measured -4.7 to +1.2 dB HF on a tone for the copy. The user-driven Corner, Nstages and rate changes can keep their current reset behaviour.
(c) Optional, low value: if auto-tune is kept, evaluate fc±step in shadow chains on the same voiced blocks. Do not expect seconds-scale or globally optimal convergence. For SSB, either use a local-Hilbert envelope peak-to-RMS proxy with the mode passed into phrot, or simply hold fc fixed at about 338-400 Hz. Keep asymmetry as the objective for AM.
Drop the float32 risk note, because WDSP itself is double. For LyraDSP float32, the first-order allpass with a shared coefficient stays exactly allpass.

**Disagreements.** Code and harness say keeping the state is only partly sufficient, because a residual click remains on a real fc change (-30 to -42 dB HF, and band-limited no better than zeroing at 100->50 Hz). Theory called keeping the state much better and called a shadow-state copy seamless. The harness measured the copy as nearly as bad as zeroing (worst -5.8 dB HF on speech). Measured results win, so the recommended fix is a crossfade for real fc changes and skipping the recompute when fc is unchanged.
On overall verdict, code said confirmed while theory and harness said partly. The defects are real at the claimed size (the clicks reach roughly signal level), but two benefits were overstated. Seconds-scale convergence was not reproduced, and the SSB crest gain is sub-dB to 1.4 dB, not 1-2 dB. Hence confirmed-smaller.
I rated priority medium rather than high because the path only runs when a host enables auto mode, which is off by default.

**Per-lens results**

- *code* (confirmed): Code facts, from phrot.c in WDSP 2.11:
- PHROT_OPTIM_SECS=15 (l.54) gives optim_interval = 15*rate (l.69). The A/B threshold is relative: diff > asym_A*0.005 (l.182/190). asym_fast is a 1 s EMA (l.52, 75) of the per-block |env_pos-env_neg|/(env_pos+env_neg) (l.147). The envelopes use 10 ms attack and 200 ms decay.
- recalc_fc (l.102-116) memsets x0/x1/y0/y1. It is called at l.176, 212, 216 and also at l.423 (AutoReset).
- One decision takes two optimizer_steps, so 30 s of continuous TX.
- Convergence: 50*0.75^8 = 5.005 is still above 5, so it takes 9 shrinks, at least 270 s (4.5 min) of TX in overs longer than 15 s.
- flush_phrot (l.99) resets optim_samp_count. TX state 0 triggers flush_main and then flush_txa, so overs shorter than 15 s never advance the tuner.

Transient simulation (python, 48 kHz and 96 kHz gave identical results). Setup: 8 stages, synthetic voiced signal with f0 130 or 210 Hz and 1/k harmonics to about 3 kHz. The error is taken after a 200-3000 Hz band-pass, against a reference that crossfades the old and new filter outputs over 10 ms.
- Zeroing state with fc unchanged (the accept path at l.216, where auto_fc==fc_B), peak error relative to signal RMS:

| fc | f0 = 130 Hz | f0 = 210 Hz | Settles to 1% in |
|---|---|---|---|
| 338 Hz | -3.7 dB | -0.1 dB | 10 ms |
| 1000 Hz | -3.6 dB | +0.3 dB | 3 ms |
| 50 Hz | +1.8 dB | -5.7 dB | 60 ms |

  Keeping state in this case gives exactly 0 error.
- A real 50 Hz corner step: the old and new steady-state outputs differ by |A-B|rms = 0.8-1.7x the signal RMS at fc 50-388 Hz, and 0.2-0.25x at 1000 Hz. In-band error peak and energy for f0=130, 338->288 Hz:

| Switch method | Peak | Energy (ms*rms^2) |
|---|---|---|
| Zero the state | -1.2 dB | 1.03 |
| Keep the state | -3.2 dB | 0.56 |
| Hard-copy the shadow-chain state | -0.8 dB | 0.96 |

- At 100->50 Hz, keeping the state is worse than zeroing: +4.2 dB and E 2.43, against +3.2 dB and E 1.93.
- At 1000->950 Hz, keeping the state is good: -12.6 dB and E 0.07, against -3.9 dB and E 0.59 for zeroing.

- *theory* (partly): Measured on a 48 kHz synthetic voiced vowel: a Rosenberg glottal pulse with a lip-radiation derivative and formants at 700, 1220 and 2600 Hz. The rotator is WDSP's default 8-stage first-order allpass. The SSB proxy is an analytic 300-2700 Hz band computed with FFTW. Source: /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/f18/sim.c and sim2.c.

(1) State zeroing at an fc change (338 to 388 Hz) mid-vowel. With zeroing, the band-limited error peak is 0.87-1.05x the signal RMS, which is -1.2 to +0.4 dB. Error energy over the next 10 ms is -9 to -15 dB relative to the signal. If the state is kept instead, the peak falls to 0.29x (-10.5 dB) and the error energy to -22 to -26 dB. At 50 to 55 Hz, zeroing gives +3.4 dB peak and -11 dB energy, against -25.6 dB and -41 dB with the state kept. The transient lasts about 3.5-39 ms depending on fc. That is audible.

(2) Analytic-envelope crest factor against fc, 8 stages. For F0 = 110 Hz, bypass is 8.27 dB and the best value is 7.55 dB at 400 Hz, a gain of 0.7 dB. With a sharper glottal closure the gain is 1.4 dB, from 8.30 to 6.83 dB. For F0 = 210 Hz the gain is 0.45-0.75 dB. The real-waveform (band-passed) crest-factor gain is 1.3-2 dB. The envelope-crest-factor curve is smooth and unimodal, flat within about 0.1 dB from 338 to 500 Hz. WDSP's fixed 338 Hz default is therefore already within about 0.1 dB of the optimum.

(3) The asymmetry metric against fc is jagged. Neighbouring fc values swing from 0.03 to 0.18 (250 vs 200 Hz) and from 0.04 to 0.27. Its minima fall at different places, such as 250, 1500 and 2000 Hz. At 1500-2000 Hz the envelope crest factor is 0.5-1.0 dB worse than at its own optimum.

The first-order allpass group delay at low frequency is about 1/(pi*fc), roughly 0.94 ms per stage at 338 Hz, or about 7.5 ms for 8 stages. That is comparable to a pitch period.

- *harness* (partly): All runs: real WDSP 2.11 phrot.c compiled with clang -O2 -arch arm64, 48 kHz, block size 256, 8 stages. Click metric: peak of (output minus a 10 ms raised-cosine crossfade between the old-fc and new-fc steady outputs), in dB re the 0.5 talker peak. "HF" means that error after a 4th-order 3 kHz high-pass; "BL" means after a 300-3000 Hz band-pass.

E1, single switch, tone (0.5 at 200 Hz + 0.3 at 700 Hz), HF splatter in the 50 ms after the switch (baseline before the switch -55.3 dB):
- 338->288 Hz: orig (state zeroed) +1.1 dB; keep-state -41.6 dB; hard copy of a shadow chain's state -4.7 dB; crossfade -55.3 dB.
- 338->338 Hz (no fc change): orig +0.9 dB; keep -55.3 dB.
- 100->50 Hz: orig +1.7 dB; keep -29.7 dB; shadow copy +1.2 dB; crossfade -55.1 dB.

E1, speech, 46 voiced switch instants, HF click median/worst:
- 338->288: orig -31.0/-9.4; keep -61.9/-40.4; shadow copy -40.4/-5.8.
- 338->338: orig -31.1/-9.3; keep and copy below -299 (no change).
- 100->50: orig -36.3/-4.2; keep -53.7/-29.7; shadow copy -30.5/-10.3.
- The real phrot output matched the emulated zero-state and keep-state chains exactly (max difference 0).

E2, tuner running on 300 s of speech, 4 talkers:
- orig: 18 recalc events each. BL clicks worst -4.2 to -13 dB; 4-9 events per talker above -40 dB. HF worst -10 to -23 dB.
- keep-state (original tuner unchanged): HF worst -42 to -56 dB.
- fixed (paired tuner + 10 ms crossfade): 12-32 live changes per talker, worst click -141 dB (numerically zero).

E4, decision noise over 1800 s per talker, 6 fc pairs x 4 talkers:
- Original unpaired A/B (1 s EMA readings 15 s apart): relative SD 21-104%, wrong-sign decisions 15-59% (often about 50%), 30 s per decision.
- Paired, same 2 voiced seconds: SD 3-55%, wrong-sign 8-48%, 4.7-6.4 s per decision.
- Per-decision variance shrinks 2.2-5.3x for 50-60 Hz steps and 14-76x for 10 Hz steps.

E3, convergence, 8 seeds x 4 talkers, start at 338 Hz:
- orig: 270-300 s to converge; mean objective excess over the 60 s grid optimum 34.7 / 125.9 / 20.5 / 40.6% (worst 57.7 / 175.7 / 31.8 / 70.0%).
- paired: 137-428 s (means 184-258 s); mean excess 28.0 / 82.1 / 16.9 / 39.7% (worst 34.4 / 116.6 / 28.5 / 57.6%).
- The landscape is rugged and multimodal: about 5% change in J per 10 Hz step, a 5-8% SD between independent 60 s segments, and the argmin moves by up to 140 Hz between segments.

Landscape, SSB 300-2700 Hz analytic-envelope crest (max, 60 s), 12 synthetic talkers:
- Moving fc changes the crest by only 0.1-1.1 dB.
- The asymmetry-optimal fc changes crest by -0.2 to +1.1 dB vs no rotator, so it does not reliably lower SSB crest.
- The crest-optimal fc beats no rotator by at most 0.44 dB, and beats the asymmetry-optimal fc by 0.0-0.9 dB.

### #19 Rejected fits still update the control-point and pin EMA state; the table clip only applies on the first cycle

**Priority:** medium · **Verdict:** confirmed · **Area:** puresignal · **Where:** `calcc.c:calc (pin commit 1452-1459, ctrl EMA 1461-1572, later rejections 1575-1661); nurbs_spline.c:curve_ema_update (901-905)`

**Evidence.** Harness: the real calc() was built on arm64 with pscc's bs_count>=3 LRESET rule, 6 seeds per scenario.
- A single capture rejected by the sin/cos identity check (feedback phase jump of 45 deg or more) made the next 2 good captures fail on all 6/6 seeds. That reached 3 strikes and forced LRESET, so PS correction dropped and the phase table was 87.8 deg off. The fixed build had 0 follow-on rejections, 0 resets and at most 0.155 deg deviation.
- An AM/PM-transient rejection left a 2.6 deg table error that was still about 1.4 deg after 15 cycles, against 0.08 deg fixed.
- Steady state was byte-identical in both builds. A persistent step behaved identically, because both builds reset through bs_count.
- The n_ctrl mismatch and clip violations were never observed.
Code lens: the ordering and the no-rollback cleanup are confirmed line by line. It also found that m_ctrl_n is overwritten with 20 every cycle, and that the cold-start gates are dead code because the splines are always NULL there.
Theory lens: the leak peaks at about 5.7% of the deviation in calavg; fault-only, no steady-state IMD change. The claim that RLS tracks faster is refuted: at equal noise a single-stage filter has 11.7 cycles mean delay against 11.3 for the current cascade.

**Recommended fix.** 1. Build all three ctrl-EMA blends in scratch buffers (cos, sin and magnitude). Stage the pin EMAs and their valid flags the same way, along with m/c/s_pin_cycle and m_fold_prev.
2. Run the full candidate through the checks: ns_build, accuracy, extrema, sin_cos_identity_check and scheck.
3. Copy the scratch state into the persistent state only after every check passes, just before curve_ema_update.
4. Remove the per-cycle m/c/s_ctrl_n = config->n_ctrl assignments (calcc.c 1280/1358/1436). Record the EMA's own nc only at commit.
5. When nc differs from the committed ctrl_n, never blend index by index. Re-seed that curve's ctrl EMA from the raw fit, or skip the blend for that cycle.
6. Apply y_clip on every curve_ema_update, not only when count==0.
7. Keep scheck updating prev_sol on failure, as it does today.
8. Liveness after a real persistent step already comes from the bs_count>=3 LRESET path, and the harness confirmed it. Optionally add a re-seed from the raw fit after K consecutive identity rejections to avoid a full reset.
9. Leave out the RLS/normal-equation redesign.
10. Port these as LyraDSP tests: the one-shot phase-glitch scenario must cause no follow-on rejections and no LRESET, and steady-state output must stay bit-identical.

**Disagreements.** 1. Theory vs harness on the scratch commit stalling (deadlock). The theory lens predicted that committing only on success would stall after a large real phase step, because the identity check would fail every cycle. The harness ran persistent 30 and 60 deg steps, and both builds recovered the same way: after 3 failures, bs_count forces LRESET and a cold start, which reseeds from scratch. So no deadlock occurs in practice. A K-rejection reseed stays optional, as a gentler path.
2. Size of the effect. The finding, the skeptic and the theory lens expected a small, roughly 3% residue that decays over about 10 cycles. The harness confirmed that size for the AM/PM rejection. For identity-check rejections it found a larger effect: the contaminated EMA fails the next two good captures, which forces LRESET. That costs a full PS dropout and re-convergence. The measured result outranks the reasoning, so the verdict is confirmed rather than confirmed-smaller.
3. Cold-start partial commit (first skeptic). The code lens showed the cold-start gates are dead code, because the splines are NULL there, so that particular path cannot happen. The finding's main claims do not depend on it.
4. n_ctrl mismatch and clipping. Neither was reproduced in the harness. Both are real by code reading and cheap to guard, so they stay in the fix.
5. Priority. I set medium rather than high. The harness model is open loop and synthetic. The trigger, a single capture with a phase glitch of 45 deg or more, is plausible but its real-world frequency is unknown. It is still worth doing during extraction, because the failure (PS correction dropping out after one glitch) is visible to the user.

**Per-lens results**

- *code* (confirmed): Line numbers checked against calcc.c, nurbs_spline.c and nurbs_fit.c in WDSP 2.11.
- Pin commit: calcc.c 1452-1459.
- m/c/s ctrl EMA blocks: 1461-1572, alpha 0.10. Write-back loops at 1492-1496, 1530-1534 and 1567-1571.
- m_ctrl_n is written at 1280, 1358 and 1436 (every cycle, to n_ctrl=20) and at 1479, 1517 and 1555. Nothing ever reads it to compare.
- Later rejections: ns_build NULL (1576), accuracy check at 50x noise (1584), count_extrema > 2 (1597), sin_cos_identity_check (1650, tolerance 0.05) and scheck (1656, tolerance 0.10). Each does goto cleanup (1725). Cleanup only frees the nurbs and splines and sets scOK.
- curve_ema_update clips only when count==0 (nurbs_spline.c 901-902). Clip ranges are mag [0.1, 2.0] and cos/sin [-1.1, 1.1] (calcc.c 913-915). Nothing clips on read (get_*_correction_ema).
- Mag fit bounds check is off: PS_NF_MAG_YMIN = YMAX = 0.0, and nurbs_fit only checks bounds when y_min < y_max. So only extrema/scheck limit how large the magnitude can get.
- Fold shrink: nurbs_fit.c 1444-1446 drops n_refit by 2 when fold_relative > 0.05 and cond > 200, up to 5 passes, down to a floor of p+2=5. 1473-1474 then sets c->n_ctrl to that value. Stock config makes this path live: PS_NF_FOLD_DETECT=1, PS_NF_UNIFORM_KNOTS=1, PS_NF_N_CTRL=20, adaptive_iters=0.
- Stacked EMA time constant: -1/ln(0.9) + -1/ln(0.7) = 9.49 + 2.80 = 12.3 cycles. Mean delay is 9 + 2.33 = 11.3 cycles. The finding's "about 13" is roughly right.
- Bounding: the LCALC state (calcc.c 2038-2039) sends three consecutive !scOK results to LRESET, which clears ctrl EMA, pin EMA, calavg and scheck_valid (1905-1914).

- *theory* (partly): Calculations in python3 (stdlib):
- The stacked EMAs (ctrl alpha=0.10 feeding the table EMA alpha=0.30) reach 63% of a step response in 13 cycles and 90% in 25. Mean delay is 11.33 cycles and the noise-variance gain is 0.0409.
- A single EMA with the same noise variance (alpha=0.0786) has a mean delay of 11.72 cycles and a 63% point of about 12.2 cycles. At equal noise, a single-stage or RLS-style forgetting filter is therefore no faster.
- After a rejected cycle with deviation D, the share left in the ctrl EMA peaks at 0.057*D in the applied table (calavg), assuming every later cycle is accepted. For the blend to fail at all, 0.1*D must exceed SCHECK_TOL=0.10 or SC_IDENTITY_TOL=0.05, which means D of roughly 0.5 to 1 or more. The leak is therefore an error of roughly 3 to 6% in the applied correction, lasting about 10 to 25 cycles.
- Blending unit phasors 0.9/0.1 puts the sin^2+cos^2 error at 0.18*(1-cos(theta)): 0.024 at 30 degrees, 0.042 at 40, 0.053 at 45, 0.09 at 60 and 0.18 at 90. The SC_IDENTITY_TOL=0.05 gate trips once the committed and new phase curves differ by about 44 degrees or more, and earlier when the fits carry their own identity error.

- *harness* (confirmed): Setup: the real WDSP 2.11 calc() (calcc.c lines 1-1022 and 1126-1741, copied verbatim) built with the real nurbs_fit.c, nurbs_spline.c and extrapolate.c using clang -O2 -arch arm64. The driver mirrors pscc's bs_count>=3 -> LRESET handling. Synthetic PA: F(a)=a(1-0.25a^2), AM/PM 0.35a^2 rad, feedback noise 2e-3, 16x256-sample collections. 60 cycles, one bad capture at cycle 20, compared against a reference run on the same RNG stream with no bad capture. 6 seeds per scenario.

Bad capture = feedback phase jump of 45, 60, 90 or 180 deg, rejected by sin/cos identity (binfo 0x10):
- ORIG: on all 6/6 seeds the next 2 good captures were also rejected (identity check on the contaminated ctrl EMA). That made 3 consecutive failures, which triggered LRESET: 6 resets in 6 runs, with the table wiped and correction turned off. The max phase-table deviation from the reference was 87.8 deg (reset table). After re-cold-start it was still about 1.6 deg off and decayed over about 25 cycles.
- FIXED: 0 extra rejections, 0 resets. Max deviation 0.08 deg median, 0.155 deg max. Max |ds| 0.0027 vs 1.68.

Bad capture = AM/PM transient (kpm x4), rejected:
- ORIG: 1 extra rejection. On the next accepted cycles the phase table drifted, peaking at 2.61 deg from the reference about 5 cycles later. It was still about 1.4 deg off 15 cycles later. Max |dc| 0.049.
- FIXED: 0 extra rejections. Max deviation 0.08 deg.

Not rejected (30-deg phase jump, compression transient): orig and fixed identical, 1.9 deg and 0.53 deg.

Persistent step change (60 deg, 30 deg): orig and fixed identical. Both reset after 3 failures and re-converge to 1.66 deg and 0.27 deg. The fix therefore does not deadlock tracking, because the bs_count reset covers this case.

Steady state (no bad capture): orig and fixed outputs byte-identical over 60 cycles.

Overdriven PA (c3=0.6, intermittent marginal identity failures, seed 1): ORIG had 12 rejections and 2 LRESETs. FIXED had 8 rejections, 0 LRESETs, max 2 consecutive.

n_ctrl mismatch: not reproduced. n_ctrl_final=20 in every cycle of every run, including c3 up to 0.6 and noise up to 0.03.

y_clip: 0 clip-range violations of calavg in any run, orig or fixed.

### #20 Boxcar averaging (av_mode 2) never clears its running sum, so old frames stay in the display permanently

**Priority:** medium · **Verdict:** confirmed · **Area:** analyzer · **Where:** `analyzer.c:avenger (512-539), SetDisplayNumAverage (1816-1828), SetDisplayAverageMode case 2 (1798-1802), ResetPixelBuffers case 2 (1122-1127)`

**Evidence.** Harness: the unmodified WDSP 2.11 analyzer.c was built on arm64 and run end to end through stitch, detector, avenger and GetPixels. Each fault was permanent, and each was still there 3000 frames later:
- N 10->5 lifted the floor +4.88 dB (theory 4.77).
- N 30->2 lifted it +12.4 to 12.8 dB (theory 12.0).
- A removed carrier left a ghost +78 to 92 dB above where it should be after: an N change, peak-hold->2, mode 1->2, and ResetPixelBuffers.
- Mode 3->2 froze the trace at a flat -49 dB (+79 dB error). 511 of 512 pixels had a negative av_sum, and a +20 dB floor step had no effect.
The two controls (mode 2 with no change, and mode 0->2) were exact. With the fix, all nine scenarios showed 0.000 dB error.
Code trace: every cited line was confirmed, and none of the three reset paths touches av_sum. Theory simulation: the closed forms 10log10(1+N_old/N_new) and ghost = P*N_old/N_new matched the measurements. A float32 running sum leaves a permanent -4.5 dB bias after a carrier 100 dB above the floor disappears, and the sum goes negative at 160 dB. WDSP's double sum stays exact to about 130 dB.

**Recommended fix.** Make these changes in LyraDSP's analyzer averager:
1. Zero av_sum unconditionally in SetDisplayAverageMode case 2 and in ResetPixelBuffers case 2.
2. In SetDisplayNumAverage, zero av_sum only when av_mode == 2. Mode 1 and mode 3 (which holds dB values) share av_sum, and hosts call this setter on every change of the averaging time constant.
3. Clamp num_average to [1, dMAX_AVERAGE], which is 60. This also removes the divide-by-zero when num is 0.
4. In the float32 port, keep the case-2 accumulator in double, or recompute the sum from the ring with vDSP. Do not use a float32 add-and-subtract running sum.

**Disagreements.** The three verifiers agreed on the substance and differed only on details of the fix:
- **Where to zero av_sum.** The harness fix zeroed it unconditionally in SetDisplayNumAverage. The code and theory verifiers both pointed out that this would reset the mode-1 EMA and the mode-3 log average, because Thetis-style hosts call that setter on every tau change. The harness only tested mode-2 paths, so it could not catch this. I adopted the conditional zeroing (only when av_mode == 2).

Small corrections to the finding's description, none of which change its size:
- With N > 60 the sum does not go negative. It permanently keeps a frozen part of the old ring and leaves a ghost, which the harness measured at +88 dB.
- Mode 3->2 freezes the weak bins on a flat pedestal, but strong carriers still show through.
- The pedestal does not last "until the mode changes". It lasts until av_sum is overwritten, which happens on a switch to mode 0, 1 or 3.
- In the float32 measurement the bias came out as a deficit (-4.5 dB), not the "fake floor" the finding describes. The sign of the bias can go either way.

Why priority is medium rather than high:
- The effects are large and plainly visible on screen.
- Lyra's current engine uses kAnAvgMode = 0 and clamps the count to [2, 60], so today's build does not hit the bug.
- The fix is trivial and should land during the extraction, before any Window-averaging control is exposed.

**Per-lens results**

- *code* (confirmed): I checked every cited line in WDSP 2.11 analyzer.c and all are correct. avenger case 2 runs from line 512 to 539, with the fill-phase add at 519 and the steady-phase add-minus-oldest at 529. SetDisplayAverageMode case 2 is at 1798-1802 and resets only avail_frames, av_in_idx and av_out_idx. SetDisplayNumAverage (1816-1828) resets the same three fields, does not clamp num, and does nothing when num is unchanged. ResetPixelBuffers case 2 is an empty "//done below" at 1122-1127: it zeroes av_buff, and the indices are reset at 1136-1138. av_sum is never touched in any of these. dMAX_AVERAGE is 60 (comm.h:119). mlog10 (meterlog10.c:547-553) masks (N>>52)&2047, so it drops the sign bit.

I ran the exact case-2 index and sum logic in Python with a constant input power of 1.0. The results were:
- 200 frames at N=10, then a reset to N=5: the floor settles 4.77 dB high.
- N=30, then N=2: +12.04 dB.
- ResetPixelBuffers with N unchanged at 10: +3.01 dB permanently.
- N=70: the input drops to zero after frame 300, but the sum stays at 60 and the display shows 60/70 = 0.857 permanently.

Derived: the permanent lift is 10*log10(1 + S_old/(N_new*P)). Going from mode 1 to mode 2 lifts the floor by about 10*log10(1+1/N), which is +1.76 dB at N=2.

Derived: num_average starts at 0 (the struct is malloc0'd at line 1329). If a host selects mode 2 without ever calling SetDisplayNumAverage, the steady branch computes factor = scale/0, which is infinite, and the display shows garbage.

- *theory* (confirmed): Simulated WDSP's case-2 logic in Python, at /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/av20.py, with exponential noise of mean F.
- Changing N with no clear lifts the floor permanently by 10*log10(1+N_old/N_new). Measured: 30->2 gave +12.01 dB (predicted +12.04), 5->10 gave +1.73 dB (predicted +1.76), 10->5 gave +5.5 dB (predicted +4.8, the difference is noise).
- Ghost peaks: a carrier of power P that was present for all N_old frames and then leaves stays on the display at P*N_old/N_new. For 30->10 the ghost sits 4.8 dB ABOVE the original carrier, for ever.
- Mode 3 to mode 2, with av_sum stuck near -130 (dB values), FFT size 16384 (scale 1/size^2) and a true floor of -130 dB: the floor displays at about -73 dB, a flat pedestal about 57 dB too high. That level depends on FFT size and N. A -30 dBFS carrier still displays correctly at -30.0.
- N=80 (above the ring size of 60): after the fill phase, out lags in by 20 slots. The sum becomes frames 0..59 frozen for ever plus the latest 20, so 75% of the average is a permanent snapshot. It is a frozen ghost, not drift to a negative value.
- float32 running sum, with a carrier P=1 leaving a window of 10 over noise 1e-7: residual 1.19e-7 against a true 1e-6, about -79 dB relative to the carrier, so of the order the finding claims. WDSP uses double, so this does not apply to WDSP.

- *harness* (confirmed): Real WDSP 2.11 analyzer.c built unmodified (orig) and with the fix (fixed), clang -O2 -arch arm64 + FFTW3. Signal path: real XCreateAnalyzer/SetAnalyzer (complex, size 1024, 512 pixels, peak detector), synthetic per-bin power written into a->result[0], then the real stitch() -> detector -> avenger -> GetPixels. Noise floor is exponential per bin, about -128.6 dB displayed; carrier about -40 dB; deterministic xorshift RNG. Error is output dB minus the exact double boxcar mean over the frames since the reset (same mlog10). Control runs (mode 2 with no change, and mode 0 -> 2) gave 0.000 dB error in both builds.
ORIG:
- N 10->5: floor +4.88 dB, still there at +3000 frames (theory 10log10(3)=4.77).
- N 30->2: +12.4 to +12.8 dB permanent (theory 10log10(16)=12.0).
- N 20->10 with the carrier removed: floor +4.87 dB, and a ghost carrier at -36.98 dB where it should be -128 dB (+89 to +92 dB), permanent.
- Mode 3 -> 2: the trace freezes at -49.08 dB flat (+79.5 dB error), av_sum<0 in 511 of 512 pixels. After a +20 dB floor step the output stays at -49.08 dB (ideal -108.6).
- Peak-hold -> 2: floor +1.74 dB, ghost at -49.99 dB (+78 to +80 dB).
- Mode 1 -> 2: floor +0.44 dB, ghost at -49.99 dB (+78 dB).
- ResetPixelBuffers in mode 2: floor +3.0 dB, ghost at -39.99 dB (+87 to +89 dB).
- N=70 (>60): stored as 70. Floor err +0.01 dB (max per-pixel 1.7 dB). After the carrier is removed, a permanent ghost at -40.66 dB (+88 dB). av_sum never went negative.
FIXED: every scenario 0.000 dB error, ghost gone, and the mode 3->2 trace follows the +20 dB step exactly. N=70 is clamped to 60.
Float32 running sum (separate recurrence sim, no resets; WDSP itself uses double):
- Carrier 100 dB above the per-bin floor, then removed: float gives a permanent -4.48 dB floor bias, double 0.0000 dB.
- At 130 dB: float -4.48 dB, double +0.018 dB.
- At 160 dB: float sum goes negative (-512), double -4.48 dB.

### #21 Rosenfell detector's next-pixel test omits det_offset and the clamp, so pixels are finalised early and overwritten by a single bin

**Priority:** medium · **Verdict:** confirmed · **Area:** analyzer · **Where:** `analyzer.c:detector case 1 (322-366), line 335`

**Evidence.** The harness compiled the real analyzer.c twice: as shipped, and with line 335 fixed. It ran detector(det_type=1) with SetAnalyzer's geometry. Both builds left 0 stale pixels in every run. The shipped build differed from a reference Rosenfell on up to 80-92% of pixels per frame at frac(fsclipL) near 1, and lost 3247/8000 single-bin carriers at 16384/1500 and 4192/8000 at 65536/2560. While panning, the displayed carrier peak was off by a mean of 1.4-9 dB, worst 30 dB. The fixed build was bit-exact with the reference. The code and theory simulations agree: about frac*N pixels are written twice, none is ever left unwritten, and the fix brings that to 0. The theory lens's BH4 model at about 2.7 bins/px measured smaller dips of 6-7 dB max. That fits the harness, where the loss grows with bins per pixel.

**Recommended fix.** In detector() case 1 only, change analyzer.c:335 to next_pix_count = (int)(det_offset + (double)(i + 1) * pix_per_bin), and add the same clamp line 333 uses (if (next_pix_count >= num_pixels) next_pix_count = num_pixels - 1). Rosenfell then groups bins exactly as detectors 0, 2, 3 and 4 do. With frac = 0 the only change is the last-pixel clamp edge. Add a regression test in LyraDSP with a fractional fsclipL and several bins per pixel: Rosenfell's per-pixel grouping must match the det_offset assignment, and no pixel may be written twice. Leave the precomputed start[] and re-centred bucket refactor out of this change. It alters every detector's output and calibration alignment, so it is not risk-free and belongs in a separate change.

**Disagreements.** On the main mechanism all three lenses agree, and the harness results confirm it. Because det_offset is never positive, the test can only fire early. The pixel's last bin then re-finalises and overwrites it, and prev_maxi is corrupted. All three also refute the finding's second failure mode, where pixels are never finalised, stale t_pixels persist and min/max leaks into the neighbour: the harness's sentinel showed 0 stale pixels. The lenses differed on effect size. Theory measured 6-7 dB worst-case dips at about 2.7 bins/px. The harness measured up to 30 dB and 75-90% carrier loss at 4-10 bins/px. I accept the harness, since it ran the real compiled code. The two results agree once you allow for the error growing with bins per pixel. Measured where it applies, the visible effect (dropped peaks and flicker while tuning) is at least as large as the finding claims, so I rate it confirmed rather than smaller. The finding's scope claims are wrong, though. Rosenfell is not the Thetis default: kainos setup.cs defaults to Peak and WDSP defaults to det_type 0. The bug needs pix_per_bin <= 1, a fractional fsclipL and Rosenfell selected. Current Lyra uses detector 0 with fsclipL 0, so it is unaffected today. Its "risk: none" claim is also wrong for the broader refactor. That reach is why I rate it medium, not high: a one-line fix to make during extraction, before LyraDSP exposes Rosenfell or fractional span edges.

**Per-lens results**

- *code* (partly): Sim harness: /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/f21/sim.c. It is a verbatim copy of detector case 1, with m, ppb and det_offset computed as SetAnalyzer does. Each run used fft 4096, clip 163 (Thetis CLIP_FRACTION 0.04), 1500 pixels, ppb about 0.398.
Pixels written more than once, current code: fsclipL frac 0 -> 1 (the clamp edge at the last pixel); 0.3 -> 450; 0.5 -> 750; 0.9 -> 1350. That is about frac*N.
Same runs with det_offset and the clamp added to next_pix_count: 0 in every case. Unwritten (stale) pixels: 0 in every case for both versions.
Single-bin carrier (x1000 on random 1-2 background) missing from the whole output: current 763/1241/1519/2117 of 3767 positions for frac 0/0.3/0.5/0.9. Fixed: 760/784/770/732.
Second case, fft 16384, 1920 pixels, fsclipL 2000.25 (ppb 0.19): current 3580/10071 lost, fixed 70/10071.
The roughly 20% residual loss at ppb 0.4 after the fix is the Rosenfell rule itself, not this bug. An even pixel with both rise and fall outputs its min, and the next odd pixel recovers prev_maxi only if that pixel also has both rise and fall.

- *theory* (partly): Derivation: det_offset d = -p*frac(fsclipL), so d is in (-p, 0], with p = pix_per_bin <= 1 on this path. The test value floor((i+1)p) is always >= the true pixel floor(d+(i+1)p). So the boundary test can only fire early, never late. The early zone is exactly frac(fsclipL) bins wide, which is less than 1 bin. At each pixel boundary it therefore catches at most one bin, with probability about frac(fsclipL). That bin then runs a second, single-bin finalisation and overwrites pixels[pc].

Simulation: a Python port of case 1 against the minimal fix. I added det_offset and the clamp to next_pix_count.
- m=4096 bins, N=1500 pixels, p=0.368. Pixels written more than once by the current code: 145, 451, 747 and 1347 for frac = 0.1, 0.3, 0.5 and 0.9. The fixed code gave 0 in every case. With frac = 0 the current code gave 1, the clamp edge case.
- m=16384, N=1920 gave 193, 962 and 1728 for frac = 0.1, 0.5 and 0.9.
- Pixels never written: 0 in every configuration, current and fixed.

Carrier test: a Blackman-Harris 4-term window (the model reproduces the textbook -0.83 dB scallop loss), a carrier 70 dB above the noise, 400 random carrier positions. Loss in the displayed carrier peak versus the fix:
- frac=0.1: mean 0.15 dB, max 6.3 dB; 6% of positions lost more than 0.5 dB.
- frac=0.5: mean 0.94 dB, 90th percentile 4.9 dB, max 6.9 dB; 27% lost more than 0.5 dB.
- frac=0.9: mean 1.34 dB, 90th percentile 5.5 dB, max 6.7 dB; 44% lost more than 0.5 dB.

The loss is bounded by the window response 1-2 bins off peak (-3.3 dB at 1 bin, -7.7 dB at 1.5 bins). The carrier is attenuated, not erased.

- *harness* (partly): Real analyzer.c, built twice (orig and fixed) with clang -O2 -arch arm64 against a POSIX comm.h shim. The driver calls the real detector(det_type=1) with geometry from SetAnalyzer's own formulas (real FFT, 1 stitch). Each geometry ran 50 frames at each frac(fsclipL) in {0, .1, .25, .3, .5, .75, .9, .99}. Each frame had exponential noise plus 20 single-bin carriers 60 dB above the noise. Before every call t_pixels was filled with a sentinel, so a pixel the detector never wrote would show up as stale.

Stale (never-written) pixels: 0 in every run, orig and fixed, across all geometries and fracs.

Pixels that differ from an independent reference Rosenfell using the det_offset bin-to-pixel assignment, per frame:
- 16384 FFT, 1500 px (4.1 bins/px): orig 154/frame at frac 0.1, 631 at 0.5 and 1198 at 0.99 (80%). Fixed: 0 at every frac.
- 65536 FFT, 2560 px (9.6 bins/px): orig 1445/frame at 0.5 and 2345 at 0.99 (92%). Fixed: 0.
- With an integer edge (frac 0), orig still gives about 0.8/frame, all at the clamped last pixel. Verified: 0 differences anywhere else.

Single-bin carriers lost, counted when no pixel within ±1 shows at least -3 dB of the carrier (out of 1000 per frac):
- 16384/1500: orig 36 at frac 0, 182 at 0.1, 436 at 0.5, 754 at 0.99. Fixed: 26–36 at every frac, which is the reference's own even-pixel min-rule rate.
- 65536/2560: orig 0, 663, 898 at frac 0, 0.5, 0.99. Fixed: 0.
- 8192 FFT with clip 16, 1000 px: orig 121, 387, 642. Fixed: 93–120.
- 16384/4000 (1.54 bins/px): orig 0, 325, 343. Fixed: 0.

Pan test: one carrier with a window-shaped main lobe (0/-3/-12/-30 dB), span edge panned in 0.01-bin steps over 400 frames. Displayed peak error versus the reference:
- 16384/1500: orig mean 4.22 dB, worst 30 dB, 253/400 frames more than 3 dB low. Fixed: 0.00 dB.
- 65536/2560: orig mean 9.12 dB, worst 30 dB, 243/400 frames more than 3 dB low. Fixed: 0.
- 8192/1000/clip16: orig mean 1.37 dB, worst 12 dB, 170 frames more than 3 dB low. Fixed: 0.
- 16384/4000: orig mean 0.61 dB, worst 3 dB, 81 frames more than 3 dB low. Fixed: 0.

### #9 SAM PLL: arm-filtered, sideband-aware phase detector with carrier-fade flywheel and FFT-aided acquisition

**Priority:** low · **Verdict:** confirmed-smaller · **Area:** demod · **Where:** `amd.c:xamd SAM branch (150-232), especially 191-192 and 222-231`

**Evidence.** All three lenses confirm the code description. amd.c 191-192 and 222-231 feed the unfiltered counter-rotated input into atan2, sbmode 1/2 changes only the audio path, and the PLL has no lock, fade or acquisition logic. The pull-in figures are overstated about 5-7x. Measured lock times on the real loop at 48 kHz are 0.04-0.05 s at 500 Hz, 0.21 s at 1000 Hz and 0.50 s at 1500 Hz, against the claimed 0.3, 2.8 and 5 s. Above roughly 1.5-1.85 kHz the loop does not lock at all.

The harness ran the real amd.c. At CNR 25 the 300 Hz arm filter cut two-path selective-fading phase error 4-8x and recovered 3-5 dB of audio SNR (sb2, beta 0.97: 9.57 to 14.42 dB). It also held lock with an interferer on the rejected sideband up to about 5-10 dB more interferer power. On white noise it gave nothing, and near threshold (CNR -9 dB or below, or C/N0 around 31 dB-Hz or less) it made slips 4-16x worse; the theory lens's sim agrees. The 2-pole arm filter alone failed to pull in from 500 Hz or more. FFT acquisition locked in about 85-90 ms at every offset. The omega flywheel as proposed made slips worse and cost 3-10 dB under two-path fading.

**Recommended fix.** Keep stock WDSP behaviour as the default and bit-exact path. Add an optional, SAM-only enhancement, used for the PLL path only, with audio and levelfade still taken from unfiltered corr:
(a) A 1-pole arm filter at about 300 Hz on corr[0] and corr[1] before atan2. Switch it in only while a robust lock detector reports lock and the carrier is not near threshold, judged by carrier power against total in-band power. Bypass it while unlocked or at low CNR.
(b) FFT coarse acquisition, triggered only on loss of lock. Use a preallocated 4096-point Hann FFT with interpolated peak, a 10 dB peak gate, and a search limited to the nbp0 passband intersected with ±fmax. Add lock-detector hysteresis so it cannot re-trigger under strong interference.
(c) Drop the omega flywheel.
Initialise all new state in init_amd and clear it in flush_amd. Validate against the h9 harness scenarios: pull-in, rejected-sideband interferer, carrier dips, two-path fading, and low-CNR slips.

**Disagreements.** All three lenses agree that the structure is right, the pull-in numbers are overstated, and the fix needs changes. They disagree on whether the arm filter helps under fading.

- The theory lens says it doubles slips in carrier dips and hurts at low SNR, so the core claim is refuted.
- The harness says it sharply improves dips and two-path fading.

I checked h9/out2 (orig_S3/S4 against fix_2_300_0_0_S3/S4). The two results do not contradict each other; they ran at different operating points.

- The harness ran at CNR 25 over about 10 kHz, which is roughly 65 dB-Hz. There the arm filter clearly wins.
- The theory lens ran its fade test at 45 dB-Hz, which is about 5 dB CNR. The harness's own CNR 15 dip case and its CNR -9/-12 runs also show the arm filter adding slips there.

So the arm filter helps on strong, fading or interfered signals and hurts near threshold. That is why it must be gated by a lock and CNR detector rather than always on.

- On the flywheel, the harness refuted it as specified and the theory lens found only modest gains with a different hold rule. I side with the harness, which measured the real code, and drop it.
- The skeptic's "10-15 dB detector SNR gain" is wrong for a transmitted-carrier atan2 limiter detector. Both the theory sim and the harness noise runs show no gain on white noise.
- The benefit is real but materially smaller and narrower than claimed. It needs extra gating not in the proposal, and it is an enhancement over WDSP rather than a defect. Hence confirmed-smaller, low priority.

**Per-lens results**

- *code* (partly): Derived from code (RXA.c:171-185 create_amd: fmin/fmax ±2000 Hz, zeta 1, omegaN 250; no setter for these exists anywhere in WDSP): g1=0.0103626, g2=2.69859e-5 at 48 kHz, so K1≈497 s^-1 and K2≈62176 s^-2 (2ζωn and ωn²). Open-loop crossover is 81.9 Hz with 76.3° phase margin. The closed-loop -3 dB point is 98.8 Hz (the '99 Hz'). A 1-pole 300 Hz arm filter costs atan(81.9/300)=15.3° at crossover, not 18° (18° is at 99 Hz). Gardner sinusoidal-PD pull-in formula: 0.316 s at 500 Hz, 2.84 s at 1500 Hz, 5.0 s at 2000 Hz (the finding's numbers). Measured by bit-exact re-implementation of the amd.c:150-231 loop, clean carrier, omega starting at 0, settle = |omega-offset|<5 Hz: at fs=48k, 0.023 s at 250 Hz, 0.049 s at 500 Hz, 0.209 s at 1000 Hz, 0.503 s at 1500 Hz, 0.787 s at 1800 Hz. At 1850-2000 Hz it never locks in 20 s; omega wanders near 0-50 Hz. At fs=96k: 0.050 s at 500 Hz, 0.458 s at 1500 Hz, 0.844 s at 2000 Hz. At fs=192k: 0.80 s at 2000 Hz. Interference sim (carrier at 0 Hz plus CW interferer of relative amplitude r, 10 s at 48k): with the interferer at 300 Hz, the current loop is captured at r=1.5 (~3000 cycles slipped, 103° rms); a 300 Hz 1-pole arm filter holds to r=1.5 (16.8° rms), and a 150 Hz one holds to r=3 (31°). With the interferer at 1200 Hz, the current loop holds to r=3 (14.3° rms) and is captured at r=6; a 300 Hz arm filter gives 2.2° rms at r=3 and stays locked at r=6 (6.1° rms). Scratch code: /private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/v9/pull.c, pull2.c, pull3.c, intf.c

- *theory* (partly): I simulated the WDSP SAM loop as written (amd.c gains, omegaN 250, zeta 1, fs 48 kHz, clamp at +/-2 kHz) in C. The input went through a +/-4.5 kHz FIR standing in for the RX filter, and I compared the stock wideband atan2 detector with a 300 Hz one-pole arm filter in front of it.

Derived: K1 = 2*zeta*wn*T, K2 = (wn*T)^2, so wn is 250 rad/s and the noise bandwidth B_L = (wn/2)(zeta + 1/(4 zeta)) = 156 Hz. At C/N0 = 42 dB-Hz, linear theory gives sigma = sqrt(B_L/(C/N0)) = 0.099 rad. The sim gave 0.115 rad wideband and 0.104 rad with the arm filter.

1) Carrier plus AWGN, 120 s per point, RMS phase error and cycle slips (wideband vs arm-filtered):
- 50 dB-Hz: 0.040/0.041 rad
- 40 dB-Hz: 0.148/0.131 rad
- 31 dB-Hz: 0 slips vs 26
- 28 dB-Hz: 54 vs 316 slips
- 25 dB-Hz: 725 vs 2222 slips
- 22 dB-Hz: 4936 vs 81277 slips
AM with 80% two-tone modulation looks the same (28 dB-Hz: 28 vs 331 slips). The arm filter gives no 10-15 dB gain. At low SNR it is worse.

2) CW interferer, C/N0 40 dB-Hz:
- At +2 kHz the wideband detector holds up to I/A = +12 dB (0.30 rad) and fails at +20 dB (118k slips). The arm filter stays at 0.13 rad throughout.
- At +500 Hz the wideband detector fails from +6 dB; the arm filter holds to +12 dB (0.42 rad) and fails at +20 dB.

3) Pull-in, noise-free, stock loop: 500 Hz in 0.054 s (finding says 0.3 s), 1000 Hz in 0.21 s, 1500 Hz in 0.51 s (finding says 2.8 s). From 1550 Hz up to 1950 Hz it never locks within 40 s, even with the clamp widened to 4 kHz. With the arm filter: 500 Hz in 0.081 s, 1000 Hz in 0.43 s, and no lock at 1500 Hz.

4) Selective-fade model: a 300 ms raised-cosine carrier dip with asymmetric sideband tones, C/N0 45 dB-Hz, 40 trials. Trials with a slip, wideband vs arm-filtered:
- 20 dB dip: 1 vs 0
- 30 dB dip: 19 vs 30
- 40 dB dip: 16 vs 32
A crude flywheel (hold when the 50 Hz-filtered magnitude falls 12 dB below a 1 s average) brought the 40 dB case to 16 wideband and 12 arm-filtered, and the arm-filtered 30 dB case from 30 to 13.

- *harness* (partly): Setup: real WDSP 2.11 amd.c xamd case 1, run with the RXA defaults (48 kHz, omegaN 250, zeta 1, fmin/fmax ±2000, tauR 0.02, tauI 1.4, levelfade on), fed one sample at a time. Metrics are the VCO phase error against the true or composite carrier phase, slips (unwrapped error crossing ±1.5π, with hysteresis), and audio SNR against a genie demod whose phs is forced to the true phase on the clean signal. "Deficit" is genie-on-noisy SNR minus PLL SNR.

Pull-in (CNR 30 dB, 50% speech-like modulation). Original lock time: 0.042 s at 500 Hz, 0.207 s at 1000 Hz, 0.50 s at 1500 Hz, 0.878 s at 1900 Hz. The finding claims 0.3 / 2.8 / 5 s, so it overstates by about 5-7x.
- Arm filter only, 1-pole 300 Hz: 0.064 s, 0.406 s, 2.2 s, and never locks at 1900 Hz (runs to the clamp).
- Arm filter only, 2-pole 300 Hz: never locks at any offset of 500 Hz or more (omega goes to the ±2000 Hz clamp).
- With FFT acquisition (any arm setting): 0.085-0.094 s at every offset from 500 to 1900 Hz. At 20-300 Hz nothing changes (about 0.01-0.02 s).

Interferer on the rejected sideband (sbmode 2, on frequency, CNR 30, noise-like interferer at 300-3000 Hz on the side sbmode 2 rejects). Audio deficit, original / 1-pole arm / 2-pole arm:
- I/C 0 dB: 5.95 / 3.51 / 2.65 dB
- I/C +6 dB: 9.89 / 8.07 / 6.49 dB
- I/C +10 dB: 12.79 / 12.04 / 10.60 dB
- I/C +15 dB: original loses lock (27565 slips, VCO 1609 Hz off). Both arm settings hold with 0 slips.
- I/C +20 dB: original and 1-pole lose lock. 2-pole holds with 9 slips.
- I/C +25 dB: all lose lock.
- RMS phase error at 0 / +10 dB: 0.067 / 0.260 rad original, 0.030 / 0.103 rad 2-pole.

Carrier-only dips (300 ms every 1.5 s, sidebands intact, CNR 25):
- -40 dB dip: rms_e 0.228 rad original, 0.105 (1-pole), 0.092 (2-pole). Deficit 0.49 dB original vs 0.07 dB arm with sb0; 1.24 vs 0.27 dB with sb2.

Two-path selective fading (0.5 ms delay, beta 0.9 / 0.97, fd 0.3 Hz, sb0):
- Original: rms_e 0.188 / 0.306 rad, deficit 3.3 / 2.9 dB.
- 2-pole arm: 0.025 / 0.050 rad, deficit 0.1 / 0.5 dB.

Flywheel, as proposed (freeze the instantaneous omega and drop g1), without arm filter:
- Carrier dips: slips go from 0 to 3-11, audio SNR 2.5-3 dB worse.
- Two-path: up to 7 dB worse.
- With a 200 ms smoothed-omega flywheel instead: no gain over the arm filter alone on carrier dips. On two-path it is 3-10 dB worse than the original (for example sb2, beta 0.97, fd 1 Hz: 14.01 dB original vs 4.76 dB).

White noise on frequency, CNR 0 to 20 dB over 10 kHz: no slips in any build and audio within ±0.1 dB. At CNR -9 / -12 dB, slips were 0 / 3 original, 3 / 27 with the 1-pole arm, 9 / 73 with the 2-pole arm.

Clean signal at CNR 60: 44.34 dB original vs 44.30 dB fixed.

FFT false triggers with a simple (I²-Q²)/(I²+Q²) lock detector: 234 FFTs in 20 s at CNR ≤ 3 dB. With the full fix and 1-pole arm, interferer at +10 / +15 dB gave 124 / 13194 slips, against 0 / 0 for the arm filter alone.

## Pass 1: other surviving proposals (low priority, not re-verified)

These held up against one skeptic only.

### agc

- **The look-ahead window drops the sample being output before its gain is computed, so the peak guarantee is not strict** (`wcpAGC.c:xwcpagc lines 197-210 (rescan), 215-334 (state update), 336-341 (gain applied)`, bug, small). The off-by-one is real. Because the outgoing sample leaves the window before its gain is set, the ALC can overshoot by up to a factor of 1/(1-c). In a simulation of the actual TX ALC parameters, the worst case (an isolated large peak after silence) gave 1.0035 to 1.0038 full scale, about +0.03 dB. Speech-like envelopes gave about 0.02% or less. Computing mult from the pre-update volts brings every case back under out_targ*0.9999. This is a cheap, harmless correctness tidy-up that makes the ALC's intended bound hold exactly. It brings no measurable on-air benefit, because the stages after the ALC (iqc, cfir, the output resampler) and the host's drive scaling decide the real peak level, and they move it by more than this.

- **Ring-buffer handling: changing parameters or toggling run replays stale audio, and nothing stops attack_buffsize exceeding RB_SIZE** (`wcpAGC.c:loadWcpAGC line 119-120; flush_wcpagc 154-159; SetTXALevelerSt 616-621; RXA.c mode switch 887/905; wcpAGC.h:33 RB_SIZE`, bug, small). Clamp attack_buffsize to ring_buffsize-1, or size the ring from fs*n_tau*tau_attack. This removes a latent heap overflow that stock WDSP settings never reach, but that LyraDSP could reach if it exposes attack times above about 13-20 ms at 384 kHz or DSP rates above 384 kHz. When tau_attack changes, zero the skipped slots and rescan ring_max. That removes a few milliseconds of 0.3-0.6 s-old audio when attack is increased. It also fixes a rarer case the proposal missed: when attack is decreased, ring_max can stick at a peak that was overwritten, which holds the gain down until an equally loud sample arrives. Clearing the ring when run goes from 0 to 1 removes a short dropout or old-audio blip of about 4-8 ms when the TX leveler is toggled or the radio leaves FM. Resetting volts, state and hang on flush is optional and changes how the AGC behaves; it fixes no bug.

- **Look-ahead limiter with a sliding max and FIR gain smoothing instead of a one-pole attack plus the (1-e^-n_tau) derating: lower latency and smoother gain** (`wcpAGC.c:loadWcpAGC lines 119-127; xwcpagc attack branches 219-221, 250-253, 286-290, 304-308, 318-322`, algorithmic-quality, medium). A look-ahead limiter with a sliding minimum and Hann (or cascaded-boxcar) FIR smoothing gives a smoother gain trajectory for the same look-ahead delay than WDSP's one-pole attack: there is no derivative discontinuity, so the gain-modulation sidebands fall off faster. It also guarantees no overshoot exactly, without needing the fixed (1 - e^-n_tau) derating. A single boxcar does not give the smoothness benefit.

In practice the gains are modest:
- RX AGC delay could drop from about 4 ms to about 2 ms, which is small next to the filter and buffer latency.
- TX leveler plus ALC could drop from about 12 ms to about 4 ms, but only when the leveler is on.
- A similar latency cut is already possible by lowering the hard-coded n_tau (or tau_attack) and compensating the target as wbfm.c already does, at the cost of a less smooth onset.
- The QSK benefit is negligible, because CW keying is usually generated in the radio firmware.
- The TX splatter benefit is small, because the ALC usually acts only lightly.
- An O(1) monotonic-deque sliding max/min would be a small CPU win over the current O(L) rescan.

- **The gain meter reports the inverse of the applied gain, ignores slope, and goes stale in AGC OFF** (`wcpAGC.c:xwcpagc lines 167-175, 338-339; meter.c:xmeter line 99`, robustness, small). This is an RX-only, cosmetic meter fix that keeps the existing sign convention. In mode 0, set a->gain = 1/fixed_gain, which uses the same reciprocal convention, so RXA_AGC_GAIN stops showing a stale value with AGC OFF. Optionally, report a->gain = 1/mult so the RX AGC meter includes the slope term, which can be up to about 3.5 dB at var_gain 1.5. Do not invert the sign or change the TX leveler or ALC gain export: their slope term is zero, they never run in mode 0, and Thetis and Lyra both depend on the current convention.

### spectral-nr

- **Minimum-statistics noise update deviates from Martin (2001): sigma2N only refreshed on bins with a new running minimum; alpha_min floor applied before the alpha_max*alpha_c scaling** (`emnr.c:LambdaD lines 786-799 (sigma update) and 710-718 (alpha_min)`, bug, small). This makes the MS noise estimator (npe_method 0) match Martin (2001) and VOICEBOX estnoisem. sigma2N then follows the boundary-recomputed pmin_u every mid-subwindow frame, so upward tracking no longer stalls while a bin's smoothed power rises steadily: slow QSB rises and gradual band-noise increases. Under fluctuating noise the current code already catches up at the next in-subwindow dip, so the gain is mostly on smooth or monotonic rises. Expect somewhat less residual noise "breathing" after the noise level goes up. Moving the alpha_min floor after the alphaMax*alphaC scaling is a correctness alignment with a negligible audible effect. A/B test on a noise step and a slow ramp before adopting.

- **Float32 port hazards: variance cancellation with no lower clamp in MS, double-only sentinel constants and exp clamps, double-bit-layout log, and absolute-scale constants** (`emnr.c:LambdaD 724-741; calc_emnr 363, 436, 472, 480-483; e1xb 132; calc_gain 1131/1154/1189/1206; getZeta 1079-1080 (mlog10, meterlog10.h:547); calc_emnr 311; post2 960`, numerical, small). In today's double build:
- Fixing the gain normalisation removes a constant +1.03 dB pass-through error from sqrt-Hamming coherent-gain normalisation, which matters only at the post-AGC position.
- Making post2's comfort-noise level independent of ogain/(fsize*ovrlp) only matters if FFT size or overlap become configurable.
- Clamping invQeq at 0 from below, or using a centred (West/Welford) variance recursion, is cheap hardening.

For any future float32 port, this is a valid checklist:
- Replace the 1e300/1e-300 sentinels.
- Re-derive the exp(700) clamps (about 88 for expf), or use exponentially scaled Bessel forms.
- Write a float version of mlog10.
- Guard against p2bar - pbar^2 cancellation. This only bites at per-bin SNRs around 75 dB or more, during the 1.5-2 s minimum-tracking window after a very strong carrier appears, not at the ~31-60 dB the proposal claims, because the carrier-noise cross term keeps the true variance large.

- **Seed noise estimators from the first frames and hand state across npe_method switches (instead of absolute 0.5 / zero init)** (`emnr.c:calc_emnr lines 472-485 (np), 511-515 (nps), 522-526 (npl uses malloc0 zeros); calc_gain 1104-1115; calc_emnr 376-381`, robustness, small). The change removes wrong-level noise estimates after the EMNR is created, after a sample-rate or buffer-size change (calc_emnr is re-run), and after a runtime npe_method switch. It does not help on band changes, mode changes or flushes, because those never reset the estimators.

How long the wrong suppression lasts today, per method:
- **Default MS (method 0):** about 0.2 s if the noise is above the 0.5 start value, and about 0.5 s of over-suppression if it is below. Below is the usual case pre-AGC, where 0.5 sits roughly 40 dB above the noise.
- **SPP (method 1):** about 1 s of muting when the noise is far below 0.5, and several seconds of too little reduction when it is about 10 dB above.
- **npl (method 2):** roughly 1.5 to 4.5 s with almost no noise reduction in the speech band. D starts near zero and Pmin climbs with a time constant of about 6.4 s.

Seeding every estimator (MS p, pbar, p2bar, sigma2N and pmin_u; SPP sigma2N; npl P, Pmin and D) from a low quantile of the first 5-10 frames, and copying lambda_d into the new estimator on a method switch, removes these transients. It is cheap and adds no latency.

The calculus point is minor. WDSP already embeds GG and GGS and falls back to them when the file is missing. The only remaining risk is a truncated "calculus" file in the working directory, so the fix is to check fread's return value or to ignore the file.

- **Replace fixed q = 0.2 with an adaptive speech-presence probability (OM-LSA / IMCRA) and use the conditional gain G_H1 in the decision-directed recursion** (`emnr.c:calc_gain cases 0-3 (lines 1124-1136, 1150-1157, 1167-1171, 1182-1197); calc_emnr 364-366`, algorithmic-quality, medium). A new gain method could add OM-LSA: a per-bin adaptive speech-absence probability (Cohen & Berdugo 2001, optionally IMCRA), conditional-gain feedback in the decision-directed recursion, one consistent conditional xi in both v and Lambda, and an explicit G_min depth control. That would probably keep weak SSB syllables and onsets somewhat better than the fixed q = 0.2 in methods 0, 1 and 3. Expect small to moderate gains, likely less than Cohen's +0.1-0.3 PESQ, because HF noise is mostly stationary. G_H1 has to be computed (for example by a new LSA table or the E1 closed form). GG is a super-Gaussian (generalized-Gamma) table, not LSA, so it cannot be reused. The improvement over method 2 and over the neural nnr path is uncertain and needs listening tests on real HF recordings.

### lms-nr

- **SNBA: SetRXASNBAasize can overflow the Levinson work buffers (heap overrun)** (`snb.c:create_snba (lines 115-116), snb.c:SetRXASNBAasize (lines 605-610), lmath.c:asolve (lines 93-125)`, bug, small). This is a real but latent heap overrun. If anything calls SetRXASNBAasize with a size above the creation value of 64, it writes past asolve_r and asolve_z on every frame, and past the xHat work arrays (A1, A2, P1) whenever a repair uses p > 64. Nothing in Lyra calls the setter today, so the fix is defensive hardening that only matters if the AR order is ever exposed. Two acceptable fixes: clamp asize to the allocated maximum (keeping it at or below about xsize/2), or reallocate the work arrays under csDSP when asize changes. The scanFrame-at-k==0 change only alters the order in which gaps are repaired on passes after the first. Any audible effect would be marginal at best.

- **NLMS regulariser 1e-10 is absolute, so ANR/ANF behaviour depends on signal level pre-AGC** (`anr.c:xanr line 103 (and lines 109-110, 121-122); anf.c:xanf same lines`, numerical, small). The 1e-10 absolute regulariser makes pre-AGC (position 0) ANR and ANF adapt more slowly and leak relatively harder when in-passband input power is below about -115 dBFS. That level is about -115 dBm on ANAN-class radios at 0 dB attenuation, and is reached on quiet high bands or with narrow CW filters. On an HL2 with LNA gain it is rarely reached. A relative regulariser (or just a much smaller absolute floor) would make tracking speed independent of level, so weak signals would track QSB and changing tones as fast as strong ones. The output level loss is not a real problem pre-AGC, because AGC restores it. The heavier relative leak on weak input also gives somewhat stronger noise suppression, so a level-invariant version may sound noisier on weak signals. The audible net benefit is unproven and needs A/B listening. Post-AGC (position 1) is unaffected.

- **SNBA latency: emit each hop one frame earlier, with bit-identical output** (`snb.c:xsnba (lines 551-566), snb.c:det (lines 337-401), snb.c:execFrame (lines 504-536)`, latency, small). Copying xaux[k*incr..(k+1)*incr), with k = floor(asize/incr), instead of xaux[0..incr) cuts SNBA's frame delay from 3*incr = 192 to 128 samples with the defaults. That saves 64 samples, 5.33 ms at 12 kHz, and the audio is bit-identical, just shifted earlier. The output-accumulator offset (init_oaoutidx) must stay as it is; only the source slice changes. It is worth an assertion that det, xHat and the restore never write below asize. The benefit is real but small compared with the full RX chain latency.

### noise-blankers

- **Run toggle leaves a stale delay line and changes latency, so 25 ms of old IQ is replayed or current IQ is dropped** (`nobII.c:xnob lines 173/490-492 and pSetRCVRNOBRun/SetEXTNOBRun lines 521-526, 649-655; nob.c:xanb lines 113/185-186 and pSetRCVRANBRun/SetEXTANBRun lines 233-238, 348-354`, bug, small). Each time NB is turned on (after the first time), about 25 ms of stale IQ from the last time the blanker ran is no longer replayed, so no brief burst of old or wrong-frequency signal and no click. Each time NB is turned off, about 25 ms of signal is no longer skipped with a hard splice. The delay is about 25 ms at any sample rate (4887 samples at Lyra's 192 kHz default), because create_nobEXT fixes max_imp_seq_time at 25 ms. The same fix pattern applies to ANB, which has a shorter delay. The simplest fix is flush-on-enable (in the WDSP run setter, or Lyra calling flush_nobEXT when NB is enabled), which turns the stale burst into ~25 ms of silence. Running the delay line while bypassed makes toggling seamless but costs a constant 25 ms of latency. Lyra's nbEnabled_ guard does not make this worse, because WDSP's run==0 path never touches the blanker state anyway. The xanb run read outside the lock is a formal data race with no practical effect. The impact is limited to a glitch on each toggle; steady-state reception is unaffected.

- **Small timing off-by-ones: ANB's effective advance is one sample short (lets impulses through when advtime=0), and NOB-II over-counts one sample per merged burst** (`nob.c:initBlanker line 41 and xanb lines 127-146; nobII.c:xnob lines 212-241`, bug, small). Two real off-by-one timing bugs; fixing them is a correctness cleanup, not an audible gain at normal settings. ANB: the zero-gain region starts one sample late, so the first above-threshold sample passes at sin^2(pi/2T) gain (-6 dB for T=2), but only when advtime*fs < 1 (adv_count=0); at typical advtime (about 19 samples at 192 kHz) nothing leaks. Prefer indexing the ramp from the detection sample. Setting in_idx = D+1 instead needs dline_size increased by 1, or it overflows at max tau/advtime at 1.536 MHz. NOB-II: blank_count is one sample too long per merged impulse, so Inext, the ff-buffer start and the mode-4 slope are latched m samples early. The resulting phase step is masked by the hold and slew discontinuities already present on off-DC signals and is tiny near DC. Worth fixing with exact-coverage unit tests during the port, low user-visible impact.

- **Memory safety and float32 hazards when porting: unclamped time parameters overrun fixed buffers, the IIR average and AR fits need care in float32** (`nob.c:initBlanker lines 36-50, create_anb 80-82; nobII.c:init_nob lines 40-57, create_nob 94-102, flush_nob 144-145`, numerical, small). This is defensive hardening for a reimplementation, not a fix to anything Lyra does today. Lyra passes fixed 0.1 ms times to the double-precision WDSP blanker and only changes threshold and run, so nothing reaches the overflow now.

In any port, size the NOB/ANB rings and windows from the configured parameters, including the +1 and +filterlen terms, and reallocate outside the audio thread. Clamping to the MAX_* constants is not enough for nobII. At 1.536 MS/s with every time parameter at its maximum, WDSP's own flush_nob puts in_idx at 50699 when dline_size is 50690, so the write overflows.

Also bound the forward-filter scan to in_idx (a minor stale-data read). Put a floor under the background average so a stretch of digital silence does not leave avg at 0 and blank everything afterwards. This happens in double as well.

The float32 timing concern only matters for extreme time constants. The Burg / double-precision / diagonal-loading advice applies only if an AR interpolation stage is added later.

### nnr

- **Deep-filter gain clamp/floor/smoothing is referenced to the wrong frame when lookahead=1** (`nnet.c:run_dfhead (lines 601-605 set cur_re/cur_im to the newest ring slot; lines 629-683 compute g=|y|/|x_cur|, the gmax/gmin clamps, the knee and the smoothing; lines 679-680 set the floor fallback y=gmin*x_cur); nnet.c:nnet_build 1193-1196 and create_nnet_slot 1277 (lookahead is stored and then never used)`, bug, small). There is a real code inconsistency. n->lookahead (1 in every built-in model) is counted in the reported latency, but run_dfhead never uses it. Either the gain reference is one frame off or the latency report is one hop too high. If the models were trained with a one-frame target delay, which the delay accounting implies but no training code in the repo confirms, the default +12 dB gmax clamp compares the frame t-1 estimate against frame t input. On strong signals with sharp offsets (high-SNR CW key-up), that attenuates the last partial frame of each element by roughly (per-bin SNR - 12) dB, trimming up to ~16 ms of the tail. Referencing the clamp and floor to ring[head-L] removes this. With the knee and smoother off by default, the steady-state effect is nil. The audible gain is probably subtle, limited to tails and onsets of strong keyed signals, and needs an A/B to confirm. If training turns out not to delay the target, the correct fix is instead dropping lookahead*hop from the reported delay, and the reference shift must not be applied.

- **Use the minimum safe FIFO prime H - gcd(size, H) instead of a full hop** (`nnr.c:nnr_build_stft line 215 (t->prime = a->decim * hop); nnr.c:nnr_reset_state line 396; delay formula line 216`, latency, small). The NNR output delay drops by gcd(dsp_size, H) samples with no change in sound and no FIFO underrun, as long as whole fixed-size blocks are processed. That is 256 samples (5.3 ms) at 48 kHz with the hop-256 slot when dsp_size >= 256. At 96 kHz it is 5.3 ms only when dsp_size >= 512, and 2.7 ms at dsp_size 256. The hop-128 slot saves 2.7 ms at 48 kHz. Smaller block sizes save less. With power-of-two block sizes the full prime never goes away.

- **Cut algorithmic latency with hop 128 and an asymmetric analysis/synthesis window pair (retrain)** (`nnr.c:nnr_design_windows (lines 167-178, symmetric sqrt-Hann), nnr_build_stft delay (line 216); model geometry from nnet_probe_slot`, latency, large). Moving the voice models to hop 128 (with retraining, and roughly doubling the deep-filter order to keep the same time span) cuts NNR algorithmic latency from about 51 ms to about 43 ms at the cost of about 2x inference. Adding a retrained asymmetric pair (long analysis window N=512, short synthesis window of 256 samples, with olascale/COLA generalised) brings it to about 27 ms with lookahead 1, or about 19 ms with lookahead 0. Analysis-side resolution stays at 31.25 Hz, but there is a risk of time-aliasing and quality loss with the multi-frame deep filter. It needs the external training pipeline. The benefit is a smaller NR-on/off timing shift and snappier RX audio. It is not decisive for CW QSK, and NNR is already lower-latency than WDSP's NR2 (about 85 ms).

- **Pre-AGC level normaliser adapts too slowly to level steps (tau = 2 s, symmetric)** (`nnet.c:run_cond lines 815-823; NNET_TAU_DEFAULT line 46; calc_cond line 752`, robustness, medium). When the bypass is on, NNR runs before the AGC. Its symmetric 2 s EMA normaliser then takes about 1.3 s to settle after a 40 dB upward step and about 5.4 s after a 40 dB downward step (strong station gone). During that time the network sees inputs up to 12 dB too hot or too cold. A cheap, low-mismatch fix is to re-seed pstate/wstate when the broadband level stays shifted for several consecutive frames, and to flush the normaliser on retune or mode change. Steady-state behaviour stays the same, so the existing weights stay in distribution. Do not add a 100-200 ms fast attack without retraining, because it would track syllables and impulses and bias the features. The audible benefit is unproven and needs an A/B test on recorded band changes and QSB.

- **Rate mismatch permanently latches run=0; rebuild also resets test/tuning parameters** (`nnr.c:calc_nnr lines 416-424; setSamplerate_nnr 624-631; setSize_nnr 633-640; nnet.c:create_nnet_slot 1271-1288`, robustness, small). This is a defensive fix only, and it does not change audio. It separates the user's requested run state from an effective run = user_run && rate_ok in calc_nnr. That stops a bad-then-good dsp_rate change from silently latching NNR off, and stops the block from running at a mismatched rate if run=1 is re-sent while the rate is invalid. Optionally, it caches the test-only tunables (tau, gmax, alpha, knee, smoothing, test mode) in the NNR struct and re-applies them after rebuilds. Neither bug can be reached at the 48k/96k/192k/384k dsp rates real hosts use, and not at all in Lyra, which fixes RX dsp_rate at 48 kHz and never changes it. Drop the rational-resampler part; it adds complexity and latency to support rates nobody uses.

### demod

- **APF/matched filter: FFTW_PATIENT replanning while holding the DSP lock, and filter swaps that are neither atomic nor crossfaded** (`matchedCW.c:SetRXAMatchedFreqs (255-261), CalcMatchedFilter (221-237), calc_size (30-43); firmin.c:setNc_fircore (465-477), plan_fircore (313-318); apfshadow.c:SetRXASPCWSelection (45-90)`, bug, medium). This does not remove long dropouts, because there are none to remove: the FFT size is 2*dsp_size, which does not change, and FFTW wisdom already covers it, so replanning is cheap. What it would remove is small transients. One is the dip or click when an APF bandwidth change crosses a power of two in nc, because setNc_fircore restarts the partition history from zero. Others are the brief unfiltered block and gain step when the APF type changes, and the click when masks swap with no crossfade. For LyraDSP the useful lesson is to keep the partition history and swap state atomically. Pre-planning FFTs for 1024 to 8192 is unnecessary, because the transform length does not depend on nc.

- **WBFM: SNR-driven stereo blend with sample-accurate crossfades, and PLL pilot recovery in place of the 8192-tap pilot filter** (`wbfm.c:xindy (96-135), xwbsquelch (381-414), mx (556-570), dsb_demod (540-554), calc_wbfm (609-673)`, algorithmic-quality, medium). An SNR-driven stereo blend, with an optional high-cut, would let weak broadcast FM stations fade smoothly toward mono instead of staying in full stereo with about 20 dB more hiss until squelch. Ramping the squelch gain and blend factor per sample removes the 5 ms, roughly 10% zipper steps. The noise estimate driving the blend should be the quadrature arm of the 38 kHz demodulator, or a band free of RDS and SCA, not the existing 58-75 kHz nopwr band. Replacing the pilot filter with a PLL is optional. It saves about 15 ms and one large FIR, which is of little practical value, and adds lock and acquisition risk. The whole proposal applies only to WBFM broadcast reception, not to amateur modes.

- **NFM: merge the cascaded de-emphasis and audio-bandpass FIRs into one design to halve their latency** (`fmd.c:create_fmd (166-179), xfmd (235-238), setSamplerate_fmd/setSize_fmd/SetRXAFMAFFilter; RXA.c:212-215 (nc_de, mp_de, nc_aud, mp_aud defaults)`, latency, small). If the de-emphasis response (with fcimp's ctfmode=0 skirts) and the 0.8*f_low to 1.1*f_high bandpass are combined into one frequency-sampled impulse, one linear-phase fircore of max(2048, dsp_size) taps can replace two. That cuts the default NFM demodulator's added group delay from about 2047 to about 1023.5 samples, about 21 ms less at 48 kHz. It also halves this stage's FIR convolution cost, and the magnitude response stays the same to within window and design error. The scale has to become a single afgain/(2*size). It also removes FMSQ's roughly 21 ms of incidental lookahead, because the squelch's own 2048-tap noise filter already absorbs half of the current delay. Squelch-close behaviour needs testing, or the FMSQ noise filter can be made minimum phase. Setting the existing mp flags (SetRXAFMMPde and SetRXAFMMPaud) already gives larger latency savings, so this mainly improves the linear-phase default.

- **Squelch decisions: make FMSQ deviation-independent, fix SSQL's rate-dependent window, and consider an SPP-based voice squelch** (`fmsq.c:xfmsq (150-204) with fmd.c:xfmd (232) and SetRXAFMDeviation (323-331); ssql.c:calc_ssql (139), setSamplerate_ssql (310-315), xftov (70-107), xssql (230-300)`, algorithmic-quality, medium). SSQL: tie the FTOV ring to time with rsize = round(0.05*rate), and scale or replace the sample-difference gate eps (it is also rate-dependent). The syllabic squelch then behaves the same at 48, 96 and 192 kHz DSP rates. It is a small, real consistency fix that only matters when the RX DSP rate is not 48 kHz. FMSQ: normalising noise by again makes the threshold track RF CNR rather than post-detection audio SNR. That is a matter of preference, not a bug fix. The current design arguably holds SINAD constant across deviations, and it changes the meaning of the user's slider. A speech-presence-probability (SPP) squelch built on EMNR's PH1y is feasible because of the processing order, but whether it beats SSQL on real HF SSB is unproven.

- **CW matched filter: match a shaped keying envelope instead of a rectangle** (`matchedCW.c:build_matched (55-87, the coef = 1.0 envelope), calc_size (30-43)`, algorithmic-quality, small). Replacing the rect template with rect convolved with a short raised-cosine edge keeps the matched filter's near-zero mismatch loss (about 0.04 dB against a hard-keyed element) and cuts its sinc sidelobes. In practice that matters only for interferers inside the main nbp0 passband, because the matched filter runs after nbp0 and the AGC. There the improvement is about 1-3 dB at 100-150 Hz offset and about 6 dB at 200 Hz. The 15-60+ dB gains at 300 Hz to 1 kHz are mostly redundant with the main Blackman-Harris RX filter at normal CW widths, and the 1 kHz figure is overstated (about -95 dB, not -109.5). The cost is about 2.5 ms of added delay. It is a modest refinement that sits between the existing rect-matched and Gaussian filters, not a significant pileup or contest improvement.

### filtering

- **SetRXAmpeakNpeaks changes npeaks without reallocating: out-of-bounds read/crash** (`iir.c:SetRXAmpeakNpeaks (lines 499-505); create_mpeak (395-417); xmpeak (438-459); decalc_mpeak (386-393)`, bug, small). This hardens an exported API that is currently unused. If a host calls SetRXAmpeakNpeaks with a value above the created count (2), the code reads past the end of enable[] and pfil[] and calls xspeak on an invalid pointer. If a host lowers the count, the extra SPEAK filters leak and later raising it again would use freed memory. No current WDSP or Lyra code path calls this setter, so there is no observed crash today. The fix prevents misuse by future callers. Allocating a fixed maximum and clamping npeaks (including bounds checks on the per-filter setters' fil index) is the simplest safe fix.

- **Kaiser window sized to a target attenuation in fir_bandpass/nbp, for sharper skirts or fewer taps (lower linear-phase delay)** (`fir.c:fir_bandpass (215-314, window switch 273-293); fir.c:get_fsamp_window (59-109); nbp.c:min_notch_width (82-98)`, algorithmic-quality, small). A Kaiser window with beta = 0.1102(A - 8.7), sized to the stopband attenuation actually needed, gives a transition about 17% narrower than BH4 at the same -92 dB level, and about 29% narrower than BH7 at the -120 to -130 dB levels that matter in practice. At nc=2048 and 48 kHz that is roughly 260 Hz down to 190 Hz to reach -130 dB. Equivalently, the same skirts need about 20-30% fewer taps, with proportionally lower compute and linear-phase delay. It also gives fir_bandpass a real wintype 2 (today it silently falls back to BH7) and a min_notch_width derived from a formula instead of a table. The gain is modest because users can already raise nc or turn on minimum phase, so it improves efficiency, not capability.

- **Non-uniform partitioned convolution for the long (16384-tap) EQ and other long kernels, so small blocks are affordable** (`firmin.c:plan_fircore/xfircore (290-321, 412-440); eq.c:create_eqp (255-284) with nc = max(16384, dsp_size) (RXA.c:269, TXA.c:118)`, performance, large). Non-uniform partitioned convolution, or the simpler minimum-phase head/tail split, would cut the spectral work of the fixed 16384-tap RX/TX EQ by about 3-5x at B = 64 with no added latency. It would give little for the 2048-tap bandpass, nbp and cfir kernels (about 1.5-2x). It helps only when the EQ is turned on, and the current cost (about 200-400 MFLOP/s per EQ) is already affordable on Apple Silicon. Its only real use is cutting CPU when many receivers run EQ at once, or making very small blocks affordable. Small blocks would not noticeably cut end-to-end latency, because the default linear-phase 2048-tap bandpasses add about 21 ms of group delay each.

### resampling

- **varsamp timing accumulators: replace the bit-truncation trick with one 64-bit fixed-point phase (needed for the float32 port; removes undefined behaviour)** (`varsamp.c:xvarsamp (L126-181, esp. L150-154, L160-162, L172-174), hshift (L114-124)`, numerical, small). varsamp.c:151-153 has a strict-aliasing UB that is real but in practice benign. The minimal fix is memcpy, which keeps today's behaviour bit for bit. A single high-resolution phase accumulator would also remove the duplicate h_offset/isamps bookkeeping. To be worthwhile it needs a Q0.64 fraction, or a 64-bit step with at least about 40 fractional bits; Q32.32 is too coarse for the ~1e-11 per-sample varmode ramp. It would also fix a defect the proposal did not mention: the mask truncates the ramp toward zero, so the ramp overshoots negative var changes by about 50% and undershoots positive ones by about 25% within each buffer when the per-buffer change is around 1e-8. That adds a small, sign-dependent error to the rmatch loop; it is not audible jitter. The result will not be bit-identical to the current code. The float32 benefit only matters if someone ports WDSP to float32.

- **HB cascade: unsupported rate pairs silently pass unresampled data and can overflow the output buffer** (`reshb.c:calc_HBResampler default case (L338-343), xHBResampler (L166-177); RXA.c create_rxa (L35, L48-53); channel.c pre_main_build (L39-42)`, bug, small). This is defensive hardening for a latent problem. No normal Thetis, HL2 or Lyra RX setup triggers it. If an RX input-rate/DSP-rate pair is missing from the table, two things can happen today: a ratio of 3 or more writes past midbuff, and upsampling silently produces audio at the wrong sample rate.

The minimal, correct fix keeps the 17 tuned cascades exactly as they are. Any pair outside the table falls back to the general RESAMPLE that RX used before 2.11 (TXA still uses it). As an alternative, the pair can be rejected with an assert or error. Do not regenerate the tap table from Kaiser's formula. That formula does not reproduce the table: the same 1536k stage feeding a 192k output uses 27 taps in one entry and 23 in another, and the window is Dolph-Chebyshev, not Kaiser. Regenerating would change the audio for supported pairs. Non-integer ratios still need channel.c's integer truncation of dsp_insize fixed separately.

- **delay.c: incomplete flush and no bounds on the requested delay (stale data, out-of-bounds reads)** (`delay.c:flush_delay (L65-69), create_delay (L45-51), xdelay (L84-87), SetDelayValue (L114-126)`, bug, small). This is defensive hardening with small real-world impact.

- **Flush:** clearing the whole ring (rsize) removes a stale tail after a flush. With real PS/EER delays that tail is only about snum samples (a few samples, not 1024), and PureSignal already throws it away during moxdelay. EER may lose a few-sample glitch at the start of TX.
- **Clamping:** limiting tdelay to [0, max] in create_delay/SetDelayValue and returning the actual delay stops out-of-bounds reads of h[] and ring[] from negative or very large delays. Those reads are not memory corruption.
- **Negative delays:** the concrete path is calcc.c SetPSFeedbackRate, which passes a negative txdel straight into create_delay. That function should get the same sign handling as SetPSTXDelay, so the delay goes to rxdelay instead of being dropped by the clamp.
- **Not needed:** a power-of-two ring with masking adds nothing once tdelay is clamped.

Valid inputs behave the same.

- **rmatch reconfiguration uses Sleep(10) instead of synchronisation, a use-after-free race** (`rmatch.c:reset_rmatch (L247-254), setRMatchInsize/Outsize/NomInrate/NomOutrate/Ringsize/SlewTime/SlewTime1/PropRing*/FFRing*/FFAlpha (L537-697), xrmatchIN/xrmatchOUT run checks (L304, L431)`, bug, medium). This closes a real but low-probability use-after-free / destroyed-mutex race in rmatch reconfiguration. Lyra triggers it on every ASIO stream through ivacRecenterRings → setRMatchRingsize while the PortAudio callback and the DSP thread are both live, and also through the UI slew/MAV setters. It only goes wrong if an I/O thread is descheduled for more than 10 ms between the run check and finishing the call, which is most plausible for the non-real-time DSP thread under load or in a debugger. A full RCU/epoch swap is not needed. An in-flight counter that the setter waits on instead of Sleep(10), or a non-freeing re-centre under cs_ring for the Lyra case, is enough. Reading n_ring under the right lock only affects diagnostics. There is no effect on audio quality.

### tx-processing

- **Keep the clipper complex for SSB (drop the Re{} fold-over)** (`compress.c:xcompressor (59-75); TXA.c:TXASetupBPFilters (836-839) and bp1 creation (262-274, gain 2.0)`, algorithmic-quality, small). For one-sided modes (USB/LSB/DIGx/CW/SPEC/DRM, AM_USB/AM_LSB), keeping the clipper output complex makes WDSP's COMP exactly equivalent to an RF clipper followed by an SSB filter. It removes the opposite-sideband intermod that the Re{} plus gain-2 bp1 path folds back into the passband. Expect roughly 0.5-1 dB better in-band distortion-to-signal at a given drive, and 0.1-0.5 dB lower peak regrowth after bp1, at no extra cost or latency. DSB/AM/SAM/FM must keep the real-part path. The benefit is modest and needs confirming with real speech and the actual bp1 filter.

- **CESSB overshoot control: smooth the gain trajectory, track the real bandwidth, optionally iterate** (`osctrl.c:calc_osctrl (33-44), create_osctrl (67: bw=3000.0), xosctrl (84-114)`, algorithmic-quality, medium). The one confirmed, low-risk fix is to set osctrl bw from the TX passband (f_high - f_low) in TXASetupBPFilters and recalculate pn. Today pn is sized for 3 kHz regardless of filter width, which is wrong for ESSB and narrow filters. The effect is small. Smoothing the gain trajectory is plausible but unproven. Its upside is capped by CESSB's already-small residual overshoot after bp2, about 0.1-0.2 dB rather than up to 1 dB, plus whatever in-band distortion is saved by lowering osgain. It should only be adopted after a CCDF and distortion measurement. Do not add an extra osctrl+bp2 pass: the chain already clips and filters twice, and another 2048-tap pass costs about 10 ms of TX latency for marginal gain.

- **EER constant-envelope path divides by zero on digital silence** (`eer.c:xeer (86-122, case 0 lines 101-104); also create_eer/destroy_eer (63-64, 70-76), xeerEXTF (367-392)`, bug, small). In amiq==0 (constant-envelope) EER mode, any exact-zero I/Q sample makes NaN on the phase-drive output. When the fractional delays are on, xdelay spreads that NaN to the neighbouring samples. A zero-magnitude guard that holds the last unit phasor removes this, with no audible or RF downside, because the envelope output is zero at those instants. The same patch fixes two more problems in the external legacy wrapper. It adds a bounds check (size <= 2048, or allocation sized to the maximum) to close a latent heap overflow in xeerEXTF, and it frees legacy and legacyM with _aligned_free in destroy_eer to close a small leak. All of this affects only the external EER interface, which TXA never uses internally.

- **Small state/edge-case defects: osctrl flush, CFC Nyquist NaN, CFC display step, emphasis skirt** (`osctrl.c:flush_osctrl (78-82); cfcomp.c:calc_compG (126-133, 142-157), calc_compE (214-220, 229-242), GetTXACFCOMPDisplayCompression (708-709); fcurve.c:exec_fcimp/fc_impulse (127-142, 274-288)`, bug, small). Two cheap hardening fixes are worth taking.

1. In flush_osctrl, clear all pn complex samples of dl and reset max_env to 0. This stops a stale peak from the previous over from adding about 2-4 dB of overshoot-control attenuation at the start of the next COMP-on over. The duck usually lasts only until the first comparable peak arrives.
2. In calc_compG/calc_compE, guard the zero-width last segment (frac = 0 when the denominator is 0, or clamp Fg/Fe to just below rate/2), and bound the spline-edge loops. A profile frequency >= rate/2 sent through the API can currently NaN the whole CFC output.

Drop the display-step change: fsize is always >= 16384, so step is never 0. Drop the fcurve/eq skirt change: the steep cumulative roll-off is a defensible design choice, and switching to 24 dB/oct would loosen out-of-band rejection with no shown benefit.

### puresignal

- **IRLS reweighting uses w instead of sqrt(w), so it fits near an L0 objective and the conditioning is never checked** (`nurbs_fit.c:nf_fit (IRLS loop 1341-1354), fit_pass (row weighting 612-630), ls_solve_with_cond (563-577)`, bug, small). nf_fit's IRLS weights rows by w = 1/(|r|+1e-6) instead of sqrt(w), so it effectively minimises sum (r/r_prev)^2 (p=0) rather than L1 or Huber. Switching to Huber weights (MAD scale, k=1.345s) applied as sqrt(w) has two effects in simulation: on clean data the per-fit RMS error falls by about 3-6% (back close to plain least squares), and on data with 5% outliers it falls by about 30-50% compared with the current scheme. cond(A'A) drops from about 1e6-1e8 back to about 1e1-1e2. Since cond_out=NULL is passed during IRLS, the condition number and CV score now describe the pre-IRLS fit; they should be recomputed after IRLS, and a Cholesky failure should set a quality flag. At the PureSignal output the effect is probably small because of the 2.5-sigma pre-masking and the 0.10/0.30 control-point EMAs. This is mainly a correctness and diagnostics fix with a modest gain in fit variance, and it needs validation on recorded captures.

- **Cold-start sanity check reads a NULL spline and never fires** (`calcc.c:calc lines 1466-1473 (mag), 1505-1511 (cos), 1543-1549 (sin)`, bug, small). The cold-start check is dead code because the splines it reads are always NULL. The fix: on a cold start, run the check on the new spline after ns_build, comparing it against the physical bounds (mag in [0.1, 2.0], cos/sin within ±1.1). Also set ctrl_ema_valid only after the whole calc succeeds, or clear it on any failure in that calc. Today any first fit seeds the control-point EMA, including one that later checks reject. The identity check, the extrema check and the bounded extension already catch most bad first fits before they reach iqc. What the fix mainly stops is a bad seed slowing convergence for about 10-20 calcs after a reset.

- **Apply phase correction as a unit phasor: fit unwrapped phase (or renormalise cos/sin) and use one complex table** (`calcc.c:calc (separate c/s fits 1297-1450, sin_cos_identity_check 803-822), nurbs_spline.c:curve_ema_update, iqc.c:xiqc 103-107`, algorithmic-quality, small). After the CurveEMA update, renormalise the blended cos/sin tables to unit magnitude, or build one complex table G = ym*u/|u|, and have xiqc use it. This removes a real AM/AM error in the correction table that is not monitored, because the identity check only looks at the new spline. The error comes mainly from phase-noise bias at low drive and from temporary EMA averaging after sudden phase steps. In steady state it is typically well under 0.05 dB, and a phase shift that is the same at every amplitude only changes overall gain, not IMD. 0.2 dB is the rejection limit, not a typical value. The change costs essentially nothing and saves a little per-sample work. Expect at most a marginal IMD improvement, not a confirmed 1-3 dB. The full unwrapped-phase refit is not justified by the evidence.

- **Automatic sub-sample TX/RX time alignment each calibration cycle** (`calcc.c:pscc lines 1882-1888 (manual delay), SetPSTXDelay 2217-2236; new alignment step before putSample`, robustness, small). It would remove the manual "amp delay" setting (default 150 ns, in 20 ns steps) by estimating the analog PA-chain delay automatically, which mainly helps users with external amplifiers or unusual PA and filter chains, where a wrong setting can reach a meaningful fraction of a sample. On typical radios the default residual delay is about 0.03 of a sample at 192 kHz. The resulting AM/PM measurement error is about -50 to -65 dB at speech or two-tone bandwidths, so the gain there is marginal. The setting is already given in seconds and does not depend on the sample rate. Cable lengths are negligible. Implementing it needs a separate contiguous TX/RX capture, because the existing collection is bucketed by amplitude. It is also a prerequisite for any future memory-polynomial model.

### analyzer

- **Torn frames: stitch() reads result[] and pre_av_out after the next frame's FFT workers have been released** (`analyzer.c:spectra (652-660), Cspectra (901-909), stitch (563-570)`, bug, small). This removes a real but rarely triggered data race in WDSP's spectrum analyzer. Today stitch() can copy result[] after the next frame's workers have been released. With num_fft > 1, a new frame's LO0 values can then overwrite min-eliminated bins, so a suppressed spur can flash up for one frame. Two stitch() calls can also overlap on pre_av_out. Triggering it needs the stitch thread to be preempted in a window of a few microseconds while the next frame's samples are already buffered, so users would see it only as an occasional one-frame display glitch.

The main value is for the LyraDSP port. There the fix makes the code correct under the memory model and keeps ThreadSanitizer quiet. Snapshot or memcpy result[] into the frame buffer before clearing input_busy, then hand the buffer to a single display consumer, or hold one lock around the copy and detection. The cost is negligible.

- **DetectMaxBin decays at a rate that depends on level and runs once per FFT, not per frame; replace with a linear-domain release and interpolated peak** (`analyzer.c:DetectMaxBin (786-816), calc_dmb (705-747), SetupDetectMaxBin (766-783)`, bug, small). DetectMaxBin's release is a real bug. Applying a multiplicative decay to a dB value makes the fall rate depend on the reference level: about 200 dB/s and speeding up at -100 dBFS, and almost no fall near 0 dBFS. So the tau parameter does not deliver the 0.5 s time constant it documents. Holding the peak in linear power and decaying by exp(-T_fft/tau), with T_fft = incr/fs, gives a constant release in dB/s that matches tau. Also take cs_dmb when writing the indices. Optionally, quadratic log-magnitude peak interpolation removes up to about 0.8 dB of scalloping error (less with the default 7-term BH window) on carriers between bins. The other parts add little. ENBW correction would be wrong for a peak reading because the window is already coherent-gain normalised. Thetis already sets overlap so the FFT rate is about fps. The real-input path is not used for the receive panadapter. Impact is limited to an optional meter, and Thetis's own meter ballistics partly hide it.

- **The 'rms' detector computes sqrt(mean(P^2)) on power bins; true RMS detection is mean power** (`analyzer.c:detector case 4 (417-441)`, bug, small). The 'rms' detector (case 4) computes sqrt(mean(P^2)) over power bins, which is not a standard RMS/power detector. On noise it reads high compared with the correctly calibrated 'average' detector. The offset depends on how many bins fall in each pixel: about 0.6 dB at 2 bins, 1.0 dB at 4 and 1.35 dB at 16, approaching 1.5 dB. As a result the noise floor and the carrier-to-noise ratio it shows change with zoom. Making case 4 output mean(P), or documenting what it actually computes, removes that inconsistency. The 'average' detector already gives correct readings, so this is a small display-calibration cleanup. Redefining 'average' as a log average is a separate, optional behaviour change and not part of the fix.

- **Zoom by discarding bins and linearly interpolating power: use a chirp-z transform or zoom-FFT for narrow spans** (`analyzer.c:detector interpolation branch (444-460); span/zoom set-up in SetAnalyzer (1266-1285); eliminate/Celiminate clipping (180-281)`, algorithmic-quality, large). Decouple the FFT length from the window length and zero-pad by about ceil(pix_per_bin) when the display has more pixels than bins. This matters for Lyra's 4096-point RX analyzer at 96-384 kHz when zoomed to a few kHz to tens of kHz. Peaks then show their real windowed-mainlobe shape instead of power-interpolated kinks and flat tops, scalloping falls from about 0.8-1.4 dB (BH4/Hann) to a small fraction of a dB, and carrier frequency/amplitude readouts improve. There is no change in RBW, selectivity or time resolution, at the cost of a K-times-larger FFT. The fsclip bin maths in WDSP and in the caller must be rescaled. CZT is unnecessary, and zoom-FFT adds little because the radio's DDC already decimates and full-band FFTs at ≤384 kHz are cheap.

- **Scaling inconsistencies: real-input +3 dB, ENBW applied per detector, uncorrected min-of-K and log-average biases, and float32-unsafe constants** (`analyzer.c:SetAnalyzer scale (1255-1264); detector inv_enb usage (383, 407, 432, 455); avenger norm (551-553) and case 3 (540-549); eliminate/Celiminate min (201, 208, 255, 270); constants 1.0e-60 (491, 499, 508, 521, 531, 545) and ±1.0e300 (311, 325-327)`, numerical, small). Small consistency gains in narrow cases:
- Applying inv_enb when 'normalize' (dB/Hz) is on with a peak or rosenfell detector removes a window-dependent offset of 1.8 to 5.8 dB. Peak-detector density stays biased by the max-of-bins-per-pixel effect, so the better fix is to document, or enforce, the sample or average detector for density readings.
- With spur elimination using num_fft = K > 1, the noise floor reads 10log10(K) dB low. A documented correction, or a median when K >= 3, would fix that. It has no effect at K = 1.
- Log-average mode (av_mode 3) could offer an optional +2.51 dB noise correction.
- Real-input noise density with 'normalize' reads 3 dB above the one-sided PSD, and the DC bin reads 6 dB high. Signal levels are already consistent between real and complex input under the full-scale-sine = 0 dBFS convention, so they should not be changed.
- The float32 points apply only to a port that computes the log argument in float, not to WDSP as it stands.

- **Calibration spline: wrong system for 3 points, out-of-bounds read for fewer than 3, unbounded cubic extrapolation; use clamped PCHIP** (`analyzer.c:build_interpolants (974-1056), interpolate (920-972), SetCalibration (1570-1599)`, robustness, small). This is a defensive fix in a calibration path that no current client uses: Thetis and Lyra pass fmin=fmax=0 and never call SetCalibration. Today the fix changes nothing anyone can see.

If a client ever supplies a calibration table, the fix would prevent:
- an out-of-bounds read with 0 or 1 points;
- stale or zero coefficients with 2 points, or with duplicate or too-close frequencies, because the error code is ignored;
- an overflow of the stack and heap arrays above 100 points;
- an unbounded quadratic (not cubic) extrapolation outside the table range, which is then squared.

It would also correct the slightly wrong spline for 3 points (the middle row uses 3dx0+2dx1 instead of 3dx0+3dx1, so there is a slope mismatch at the middle knot).

The minimal change is to check n, cap it at dMAX_N, propagate the return value, and hold the end values outside the range. Switching to PCHIP is optional and has no demonstrated benefit on the panadapter.

## Pass 1: refuted proposals

### agc

- **O(1) sliding-window maximum (monotonic wedge) instead of the O(N) rescan**. The mechanism is described correctly. In wcpAGC.c:197-210, when abs_out_sample >= ring_max and > 0, the code rescans abs_ring[out_index+1 .. in_index], which is attack_buffsize samples, and then checks the new sample. That does compute an exact sliding maximum, so a Lemire wedge could reproduce the same ring_max values. One caveat: loadWcpAGC resets in_index and attack_buffsize without rebuilding state, so a deque would also need rebuilding there. The claimed cost and real-time benefit do not hold up.

(1) Wrong rate. The AGC is created at ch[channel].dsp_rate (RXA.c:362-372: tau_attack 1 ms, n_tau 4), not at the radio's input rate. 384 kHz IQ is resampled down before the AGC runs. Lyra opens RX with dspRate = 48000 (src/wdsp_engine.h:98), and the TXA leveler/ALC run at 96 kHz. So attack_buffsize is 192 for RX and 384 for TX. The "1536 compares, 590 M/s" scenario does not happen.

(2) Wrong frequency. A rescan only happens when the sample leaving the window is the window maximum. I simulated the exact loop in C (-O2, Apple Silicon) with realistic envelopes at 48 kHz, N=192:
- Band-limited noise: 2.8 compares/sample.
- Noise-free pure tone in pmode=1, the claimed bad case: 11/sample, because rounding ties are rare.
- Tone at 30 dB SNR: 1.0/sample.
So for CW the rescan does not run "on many samples". Only a noise-free, strictly falling envelope reaches the full 191 compares/sample. Real receiver signals always carry noise, so that case does not occur.

(3) Even the worst case is cheap. With repeating noise-free decays at 48 kHz, the loop used 0.082 s of CPU per 20 s of audio, about 0.4% of one core. For a 1024-sample block that is about 100 us against a 21 ms period. At 96 kHz TX it is about 1.6% worst case and about 0.03% for realistic signals. No audio-callback deadline is at risk.

The cited paper is real and the method is correct, but it fixes a cost that is not significant at the rates WDSP actually runs. It adds deque state that must be rebuilt in loadWcpAGC/flush_wcpagc, in code that is otherwise bit-exact. The point about the deque also giving a sliding minimum for another proposal does not justify this change on its own.

- **Float32 risk: long-time-constant one-pole recursions stall or misrate at high sample rates; keep detector state in double**. The description of the code is accurate, but it shows there is nothing to fix. In wcpAGC.c, loadWcpAGC (lines ~121-145) computes every coefficient as 1 - exp(-1/(fs*tau)) in double, and stores onemfast_backmult and onemhang_backmult as 1 - c in double. In xwcpagc, the back-averages (~lines 194-195) and every volts update are double. In meter.c, calc_meter and xmeter keep avg and peak in double. So WDSP already does what the proposal asks for: detector state and coefficients are in double.

The fix only applies to a Float32 "LyraDSP" port, and that port does not exist. Lyra calls native WDSP (src/wdsp_native.cpp, src/wdsp_engine.cpp), which is all double. No Float32 copy of the AGC or meter turns up in the tree.

The 384 kHz figures are also wrong. RXA.c builds the AGC and the meters at ch.dsp_rate, not the input rate. Lyra sets dspRate to 48000 for RX (wdsp_engine.h:98) and uses 96 kHz for TX sip1. At 48 kHz the coefficients are:
- LONG decay (tau 2 s): c = 1.04e-5
- hang back-average (tau 0.5 s): c = 4.2e-5

Even in a hypothetical Float32 build, the stall band would be about 2^-24/c, roughly 0.6% (about 0.05 dB) for LONG. Rounding 1-c to float would give a time-constant error of about 0.1-0.3%. Both are well below anything you could hear, and small next to the dB-scale fluctuation of ring_max on real signals.

The dead-band arithmetic itself, and the generic advice (expm1, the y += c(x-y) form), are textbook-correct. That makes this a design note for a port that might never be written. It is not an improvement to WDSP 2.11, and not a defect in the current Lyra path.

- **Hang-level and AGC-threshold calibration constants assume a real sinusoid, but the RX detector measures complex envelope peaks**. The proposal reads the code correctly but draws the wrong conclusions from it.

What the code actually does:
- wcpAGC.c:138-140 scales hang_level by 0.637, and line 449 divides by 0.637 for the bandscope.
- RXA.c:365 creates the RX AGC with peakmode = 1. With pmode 1, abs_ring holds sqrt(I^2+Q^2) (lines 189-192).
- Line 195 makes hang_backaverage a 0.5 s exponential moving average of the envelope. Line 231 compares it with hang_level.
- The threshold line (lines 497-518) converts min_volts to bin power using only a bandwidth/bin-width offset.
- The arithmetic holds: a steady carrier's average converges to its peak, so it would pass the hang test about 3.9 dB below the line. Mean of max(|cos|,|sin|) is 0.900.

Why the hang half fails:
- Hang is only considered in state 0 when ring_max < volts, that is, when the signal falls. For a steady carrier, hang never matters.
- Hang matters for intermittent signals: SSB speech and CW. Their 0.5 s average envelope is well below the peak. CW at about 50% duty averages roughly 0.5 x peak, and speech has a 10-15 dB peak-to-average ratio.
- So the 0.637 factor, whether by design or by accident, partly compensates for the average-to-peak ratio of the signals hang is meant for. The rectified-sine reading is just one interpretation.
- Changing it to 1.0 (or 0.90) would stop hang from engaging on speech and CW peaks that sit well above the displayed line. The "fix" makes behaviour worse in exactly the cases that matter.
- The alternative, calibrating to the Rayleigh mean, contradicts the stated goal of a line that marks where signals get hang.

Why the threshold half is not established:
- The idea that the AGC's peak detector reads noise above its RMS is sound, but the size of the offset is wrong. Expected max of about 11-12 independent envelope samples (2.8 kHz x 4 ms) is about RMS x sqrt(ln N + 0.577), roughly +4.9 dB. Because volts attacks in 1 ms and decays over 250 ms, it rides the upper envelope of ring_max, so the effective excess is somewhat larger.
- The proposal ignores the spectrum analyzer's calibration. analyzer.c normalizes every window to coherent gain (inv_coherent_gain, lines 61-175). Displayed noise per bin is therefore raised by the window's equivalent noise bandwidth: about +1.8 to +4.2 dB depending on window type.
- Log-domain display averaging lowers the displayed noise by about 2.5 dB. There is also an optional 1 Hz normalization (SetDisplayNormOneHz).
- Net offset between the displayed noise floor at the AGC knee and the line is therefore roughly -1 to -5 dB, depending on display settings that the AGC code cannot see. A fixed sqrt(ln(BT)+gamma) correction inside wcpAGC.c would be wrong in several of those configurations, and in some it would add to an existing error.
- The knee is soft anyway (var_gain slope), and Thetis operators set the threshold empirically against what they see and hear. A remap would also shift every saved setting.

Literature: the extreme-value and Rayleigh results are real textbook facts, but they do not support either "fix".

Net: the code description is accurate, the hang change would be a regression, and the threshold change would trade one display-dependent error for another. Cosmetic value at best.

- **MED/FAST overwrite the operator's hang threshold, and it is not restored for LONG/SLOW**. The description of the code is correct. In wcpAGC.c:SetRXAAGCMode, MED (line 398) and FAST (line 405) set hang_thresh = 1.0, and LONG and SLOW (lines 384-395) set only hangtime and tau_decay. With hang_thresh = 1, loadWcpAGC gives tmp = 1, so hang_level = 0.637*max_input, which is 0.637 at the default max_input of 1.0. The hang entry test is `hang_enable && hang_backaverage > hang_level` in state 0. When hangtime = 0, a signal that passes it goes state 2 -> state 4 on the next sample, so it decays at tau_hang_decay (0.100 s), not tau_decay.

It still fails as a real bug with realistic parameters:

1. WDSP's API is designed for the host to push hang parameters after a mode change. SetRXAAGCMode is a preset, and the hang setters (SetRXAAGCHang, SetRXAAGCHangThreshold, SetRXAAGCHangLevel) are separate exported calls the host uses to re-apply its settings. Lyra, the host here, does exactly this. WdspEngine::pushAgcMode (src/wdsp_engine.cpp, around line 3979, and the worktree copy at ~3185-3205) calls SetRXAAGCMode and then always calls SetRXAAGCDecay, SetRXAAGCHang and SetRXAAGCHangThreshold for every non-OFF mode: FAST 50/0/100, MED 250/0/100, SLOW 500/1000/0. Lyra never selects LONG. So the "FAST -> LONG leaves hang disabled" case never happens in this application. The stored hang_thresh is always the host's value.

2. The FAST/MED side effect (hang decay instead of the mode's decay) only applies when the 500 ms back-average of the pre-AGC envelope is above about 0.637 of max_input, which is within about 4 dB of full scale at the AGC input. A real HF/VHF receive chain sits far below that unless the front end is already overloaded. Even then it gives 100 ms vs 50 ms decay in FAST, and a faster release than MED's 250 ms. That is an edge case, not audible misbehaviour.

3. The proposed fix (`hang_enable && hangtime > 0`) would also stop GetRXAAGCHangThreshold and GetRXAAGCHangLevel from reflecting the MED/FAST "hang off" state. Hosts use those for the setup slider and the bandscope hang line, so the change has its own compatibility cost for a benefit that never shows up when the host re-sends settings, as Lyra does.

At most this is an API-hygiene note: WDSP mode presets have side effects on hang_thresh that persist. It does not cause misbehaviour in this codebase.

### spectral-nr

- **Cut the ~64-85 ms processing delay with a low-delay filter-bank equalizer or asymmetric windows while keeping fine frequency resolution**. The description of the current code is mostly right. RXA.c:323-337 creates EMNR with fsize=4096 and ovrlp=4 at ch[channel].dsp_rate. No exported setter changes fsize or ovrlp; the SetRXAEMNR* functions cover only run, gain/NPE method, AE, position, psi, train and post2. calc_window builds a normalised sqrt-Hamming window over fsize samples. I traced xemnr and calc_emnr with a typical bsize of 64. oainidx = (4096-64-1024) % 1024 = 960, and an output sample leaves roughly fsize-bsize ≈ 4032 samples after it came in, about 84 ms at 48 kHz. The upper end of the 64-85 ms claim is the accurate one. The pipeline adds two more linear-phase 2048-tap bandpass filters by default (nbp0 and bp1, mp=0), about 21 ms each, so EMNR is the largest single source of delay but not the only one. ae.psi=20 is fixed in bins, as claimed. The proposal is wrong on npl, though: delta_LF and delta_MF are computed as 1000 Hz and 3000 Hz over (rate/2) times msize (emnr.c:547-548), so they track the sample rate correctly. The claim about monitoring your own audio while transmitting is also wrong: EMNR is created only in RXA, and the TX monitor path never goes through it. WDSP has no low-delay EMNR variant. NNR is a separate neural NR with its own 512-point STFT at 16 kHz.

The headline benefit cannot be achieved. "5-15 ms delay with the same 11.7 Hz analysis resolution" conflates the resolution of the gain estimate with the resolution of the filter actually applied. In a filter-bank equalizer the applied filter is an L-tap FIR. A 5-15 ms FIR resolves roughly 70-200 Hz, not 11.7 Hz, so the 2049-bin gain vector is smoothed down to a few tens of effective bands. The same limit applies to Mauler-Martin asymmetric windows, where the short synthesis window sets both the delay and the effective resolution. This is the basic trade-off between time and frequency resolution, and no implementation trick removes it. Minimum-phase conversion lowers the average delay, but sharp spectral detail still means long ringing and large group delay near those features. The proposal's own risk section concedes that sharp gain detail is lost.

For amateur use, that fine resolution is most of why EMNR works on weak SSB and CW signals: it separates voice harmonics and single carriers from noise between them. A 5-15 ms filter turns it into a coarse short-window suppressor. There is a second problem. The gains still come from an 85 ms sqrt-Hamming frame in which the newest samples carry almost no weight, so gain decisions trail the audio by tens of milliseconds. The filter-bank equalizer would apply late gains to current audio and clip syllable and CW element onsets. A dit at 30 WPM lasts 40 ms, so CW, the mode the proposal is meant to help, would suffer most. Going to 8x overlap shortens the hop but not the window's centre-of-mass lag.

The cited papers are real: Löllmann & Vary in Speech Communication 49(7-8), 2007, and Mauler & Martin at EUSIPCO 2007. Both are designed around 8-16 kHz speech with roughly 256-512-point DFTs, not 4096-point narrowband analysis. The Apple Silicon point does not matter, because WDSP is cross-platform C.

A cheaper and more honest low-latency option exists. Expose fsize, ideally specified in milliseconds, through a setter, accepting coarser bins in exchange for less delay. Separately, enable the existing minimum-phase option (RXASetMP) on the bandpass filters. That was not the proposal, and the proposal's claimed benefit as stated is refuted.

- **Hybrid neural a-priori SNR / speech-presence estimation feeding the existing MMSE-LSA gain (Deep Xi-style), run on Core ML/ANE**. Inside emnr.c the description is roughly right. calc_gain (emnr.c ~1100-1240) gets xi from the decision-directed recursion in all four gain methods, with alpha derived from tau = -128/8000/ln(0.985). Noise comes from LambdaD (Martin minimum statistics, the default npe_method 0 set in RXA.c:323), LambdaDs (SPP) or LambdaDl (an MCRA-2-style estimator with delta_LF/delta_MF thresholds). Several of the specifics are wrong or overstated, though:
(1) The DD one-frame onset bias is already addressed in method 3. After the DD estimate it computes a two-step refinement, xi_ts = mask^2 * gamma (the TSNR of Plapous et al.), and recomputes the gain from it.
(2) An OM-LSA-style speech-presence floor already exists. Method 0 multiplies the gain by the speech-presence term witchHat/(1+witchHat) with q=0.2. The default method 2 uses GG(gamma, xi) * GGS(gamma, xi/(1-q)), which is the LSA gain combined with a speech-presence gain. So "add an OM-LSA-style floor" is not new.
(3) The zeta table is trained, not hand-crafted. readZetaHat/zetaHat.c is a learned 60x60 table, and train setters (SetRXAEMNRtrainZetaThresh/T2) exist.

The decisive point is that WDSP 2.11 already ships neural noise reduction as its own RXA block. nnr.c and nnet.c (about 2,650 lines, NR0V 2026) are created in RXA.c:339 next to EMNR, with an nnrbypass partner. They implement GRU, Conv2d/ConvTranspose2d, PReLU, a DPRNN (dual-path RNN) block, a DeepFilterNet-style deep-filtering head (dfhead with order, gain limits and attack/release smoothing), a conditioning stage, loadable model slots (NNET_NSLOTS=4) with per-model sample-rate, hop and lookahead checks, and a per-model training band used to configure the bypass filter for USB/LSB. In other words, a causal recurrent network trained on band-limited speech is already in this library. It uses a more modern architecture than Deep Xi (DPRNN plus a deep filter rather than a ResLSTM a-priori SNR estimator). So "the largest available gain is a neural estimator" has already been taken in this DSP block, just as a separate module rather than grafted onto EMNR. Feeding a second network's xi into EMNR's GG/GGS back end would duplicate NNR's training-data and maintenance burden, and in the literature since 2019 hybrid Deep Xi/MMSE generally scores below end-to-end mask or deep-filter models of similar size. The main remaining argument is interpretability: a bounded, closed-form gain fed by the network. NNR already bounds its output with a mask floor and a maximum gain (setFloor/setMaxGain).

The citations are real: Nicolson & Paliwal, Speech Communication 111 (2019) 44-55, and Valin, MMSP 2018. But the cited PESQ/segSNR gains are measured against a DD/MS baseline on general noise corpora, not against an existing neural NR on HF audio. Nothing here shows a benefit over what WDSP 2.11 already provides. For CW and digital modes, EMNR and spectral-gain NR are usually bypassed anyway, and a speech-trained xi estimator would likely damage carriers and tones. On the stated criteria (already done in another module of the same library, and parts of the current-behaviour claim inaccurate), the proposal is refuted.

### lms-nr

- **ANR/ANF: no validation of delay and taps, so a degenerate predictor can see the current sample**. The code reading is right. In anr.c:99/126, idx = (in_idx + j + delay) & mask, with mask = dline_size - 1 = 2047 (anr.c:57, ANR_DLINE_SIZE 2048 at anr.h:30). d[] and w[] are fixed at 2048 entries (anr.h:45-46). SetRXAANRVals, SetRXAANRTaps and SetRXAANRDelay (anr.c:183-211) store the values with no bounds check, and anf.c does the same (lines 185-209). in_idx counts down (line 129), so offsets j+delay > 0 point at older samples. With delay == 0, tap 0 reads the sample being predicted, NLMS drives w[0] toward 1, ANR (output y) becomes a pass-through, and ANF (output error) goes near-silent. The analysis is also right that n_taps > 2048 writes past w[], and that n_taps + delay - 1 >= 2048 wraps back onto d[in_idx].

The claimed benefit does not hold up, though. The proposal says these settings are "easy to hit from a UI slider or a saved profile", and in this product they cannot be reached. Lyra calls only SetRXAANFVals(ch, 64, 16, 1e-3, 1e-7) and SetRXAANRVals(ch, taps, 16, gain, 1e-7) (src/wdsp_engine.cpp:4282, 4301). Delay is always 16, and taps are computed as 32 + round(96*s) with s clamped to [0,1], so 32 to 128. Lyra never calls SetRXAANRTaps, SetRXAANRDelay or the ANF equivalents. WDSP's own create defaults (RXA.c, 64 taps, delay 16) are also safe. No realistic parameter path in Lyra gives delay 0, taps over 2048, or taps + delay over 2048.

What remains is defensive API hardening for configurations nobody sends. It would cost little but would not fix any observed or reachable failure. The second part, taps and delay in milliseconds scaled by sample rate, is a separate feature and is not justified by this bug. ANR/ANF run at the fixed RXA DSP rate, and the current hardcoded values are sensible there.

- **Float32 hazards in the leaky NLMS: leak quantisation to exactly 1.0 and weight-update stalling**. The description of the code is correct. anr.c and anf.c (xanr/xanf, lines 83-130) keep d[], w[], sigma, c0, c1, lidx and ngamma in double. The leak is multiplicative: c0 = 1 - two_mu*ngamma and w = c0*w + c1*d. ngamma = gamma*lidx^4*den_mult. The RXA.c defaults (lines 281-317) match the proposal. Both blocks use two_mu 1e-4, gamma 0.1 and den_mult 6.25e-10. ANR has lidx in [120,200] and ANF has lidx in [0,200]. I checked the arithmetic and it holds. For ANR, two_mu*ngamma runs from 1.30e-6 to 1.0e-5, which gives about 22-168 float32 steps below 1.0. For ANF, two_mu*ngamma = 6.25e-15*lidx^4, which is below 2^-25 when lidx is under about 46.7. Caraiscos & Liu (IEEE Trans. ASSP 32(1), 1984) is a real paper on LMS roundoff and stalling, and it is relevant.

It still fails as an improvement to WDSP 2.11, for three reasons.
(1) WDSP already does what it proposes. Everything is double, and the proposal is to keep it double. It does not change WDSP's algorithm. It is a warning about a hypothetical float32 port. I searched the Lyra checkout for any ANR/ANF port (two_mu, ngamma, lidx) and found none, so there is no float32 code that it applies to.
(2) The 'ANF never forgets' hazard does not matter in practice. Even in double, two_mu*ngamma < 3e-8 means a leak time constant above about 3.4e7 samples, which is roughly 12 minutes at 48 kHz. That is effectively no leak already, so rounding it to exactly 1.0 makes no audible difference. lidx is also a control variable that moves by +1 or -3 every sample. It passes through that region rather than sitting in it.
(3) The stalling claim is overstated. With 64 taps, the normalised step two_mu*e*d/sigma is about 1e-4/64 of the input scale, about 1.5e-6 relative. That is still about 10 float32 ulps (eps 1.19e-7), not below one. The ANR leak term of 1.3e-6 to 1e-5 relative is also tens to hundreds of ulps. Precision would degrade a little but would not freeze.
Even for a port, the expected effect is small and unproven by any measurement. As a change to WDSP itself there is nothing to change.

- **ANR/ANF: run the line enhancer at a decimated rate, or scale taps and delay with sample rate**. The description of the code is mostly correct. ANR and ANF run per sample at ch[].dsp_rate. RXA.c:282-319 creates them with 64 taps, delay 16, two_mu 1e-4, and setSamplerate_anr/anf (anr.c:149-152, anf.c:149-152) only flush and never rescale. SNBA does resample to 12 kHz internally (RXA.c:246, snb.c calc_snba).

"Fixed 64 taps" overstates it, though. Those are only the create-time defaults. Taps, delay, gain and leakage can all be changed at runtime through SetRXAANRVals/Taps/Delay/Gain/Leakage and the matching SetRXAANF* calls (anr.c:184-230, anf.c:185-230), which is how Thetis's setup page drives them. The delay line is ANR_DLINE_SIZE = ANF_DLINE_SIZE = 2048, so taps plus delay can reach about 2000 samples, roughly 40 ms at 48 kHz.

The main benefit claimed is a longer predictor span, giving finer frequency resolution and a narrower ALE line or ANF notch. That is already available at the native rate by setting taps to 256-512 and delay to about 64. This adds no resampler group delay and no extra band-limiting. The cost is about 2 x 512 x 48000, roughly 50 M MAC/s, which is trivial on Apple Silicon. So the Accelerate polyphase resample, extra latency and AM band-limit tradeoff buy nothing the existing parameters can't already give.

The convergence argument doesn't hold for this setup. Oversampled, band-limited input does give a large eigenvalue spread, but the small eigenvalues belong to stopband directions that carry essentially no input energy. Their weights don't affect the output, and the leakage term (gamma/ngamma) pulls them toward zero. In-band modes converge on in-band eigenvalues, and NLMS normalises by the total power (sigma), so decimating does not meaningfully speed up convergence of the components that matter.

The suggestion of 10-20 ms spans at 12 kHz for CW also skips the tracking-versus-resolution tradeoff. A long, slow predictor smears keying transients and fading, and a dit at 30 WPM is only 40 ms, so "separate CW tones properly" is not established.

The citations are real. Widrow et al., Proc. IEEE 1975 covers the ALE, and Widrow & Stearns 1985 covers eigenvalue spread. They are just not evidence that decimation beats a longer predictor at full rate.

What survives is a minor point. Defining taps and delay in milliseconds and converting them in setSamplerate_anr/anf would make the behaviour independent of sample rate. That matters only if the host changes dsp_rate, and a host that pins dsp_rate at 48 kHz can do the same conversion itself when it calls SetRXAANRVals. Since decimation is the core of the proposal and it is not better than what the existing parameters already allow, I treat the proposal as refuted.

- **ANR/ANF: add variable step size (VSS-NLMS) for fast capture with low steady-state misadjustment**. The description of the current code is correct. In anr.c and anf.c, lines 109-122 of xanr/xanf are identical. They implement NLMS, w = c0*w + two_mu*e*x/(||x||^2+1e-10). The Kamenetsky-Widrow nel/nev comparison adapts only the leak, through lidx and ngamma. two_mu is fixed, and RXA.c:291 and RXA.c:311 set it to 1e-4 by default. No variable-step mode exists anywhere in the source. With NLMS, a mode's time constant is about 1/(two_mu * the fraction of input power in it). That gives about 1e4 samples (about 0.2 s at 48 kHz) for a dominant carrier, and seconds for a weak one. The five citations are real and correctly attributed.

The claimed benefit does not hold up, for these reasons:

1. **The Aboulnasr-Mayyas robustness does not apply here.** The rule is robust only when the measurement noise is close to white, so that E[e(n)e(n-1)] is about 0. ANF/ANR run after the receive passband filter (nbp0), on real audio at the DSP rate. That audio is roughly a 2.7 kHz band sampled at 48 kHz, about 8x oversampled. Its normalised lag-1 autocorrelation is around 0.95. Speech is also strongly correlated from sample to sample. So e(n)e(n-1) is close to e(n)^2, and the method collapses into a Kwong-Johnston power-driven step. That step rises at every speech onset and noise burst. In ANF that notches voiced harmonics; in ANR it gives watery artefacts. Those are the two failure modes the proposal says it avoids.

2. **NPVSS needs a noise-power estimate that is hard to get here.** For ANF, the "noise" is the wanted speech plus band noise, which is non-stationary. This is the double-talk problem from echo cancellation. Getting it right needs a detector or extra tracking machinery, not one or two tuning constants.

3. **A VSS statistic cannot speed up capture of weak tones.** A tone 10 dB below speech and noise leaves a residual in e(n) that is buried in the non-predictable part. Any statistic of e(n) that could reliably detect it is essentially the predictor itself. So the claim of capturing weak heterodynes faster while keeping the same steady state is not supported.

4. **The step size is already a user setting, and the tradeoff is the normal one.** two_mu is exposed through SetRXAANFVals and SetRXAANFGain, which clients use. This project's own engine (the Lyra worktree, src/wdsp_engine.cpp:3437) calls SetRXAANFVals with gain 1e-3. That captures a dominant carrier in about 1e3 samples, roughly 20 ms at 48 kHz, which is already the "tens of ms" the proposal promises. Glover's result (notch bandwidth proportional to mu) is the tradeoff users already choose by setting the gain.

5. **The benefit is unmeasured.** The proposal itself says it needs listening tests, and no simulation or measurement backs the claimed depth and speed.

A possible but unproven variant: a time-based step schedule (high mu for a short time after flush or retune, then decaying to two_mu), or a statistic taken at a long lag beyond the speech correlation time. Neither is what was proposed, and both are of marginal value given that the gain is already adjustable.

I am refuting because the specific methods proposed are ill-suited to oversampled, band-limited audio that contains speech, and the claimed gain cannot be confirmed.

### nnr

- **Implement the attenuation floor as a noisy-signal mix, not a per-bin magnitude clamp of the DF output**. Checked against nnet.c:584-684 (run_dfhead), nnet.c:686 (setGains_dfhead), nnet.c:1708 (setFloor_nnet) and nnr.c:792.

What the proposal gets right: the floor is a per-bin, per-frame magnitude clamp. When g < gmin, y is rescaled to magnitude gmin*|x_cur| and keeps y's own phase. Only when |y| <= 1e-30 is it replaced by gmin*x. The reference is also misaligned. cur_re/cur_im is the newest frame x_t, while every shipped model has lookahead 1 (nnr_model_*.c headers; nnr.c:216 adds lookahead*hop to the delay). So the output describes frame t-1 but the floor magnitude comes from x_t. That one-frame misalignment is a real, minor defect. It belongs to the earlier proposal, though.

Where the description of current behaviour is wrong:
1. There is no switch between "network output" and "residual with arbitrary phase". The phase always comes from y, above the floor and below it. The magnitude is continuous at the threshold: max(g, gmin) times |x|. The x-phase branch needs |y| <= 1e-30, which essentially never happens with real band noise. The claimed flip-flop is therefore not how the code behaves. At most there is a kink in the gain curve, not a jump.
2. The floor already has "the same spectral shape as the band noise", because its magnitude is exactly gmin*|x|. The proposal lists this as a gain of the mix, but the current code already has it.
3. The literature is misused. Berouti, Schwartz and Makhoul's 1979 spectral floor is exactly a per-bin max() clamp, max(|X|^2 - a|N|^2, b|N|^2). It was introduced to reduce musical noise. So Berouti supports the current design, not the mix. Cappé 1994 explains how decision-directed smoothing in Ephraim-Malah suppresses musical noise. It does not compare clamp floors with noisy-mix floors. The DeepFilterNet citation is real: enhance.py atten_lim_db does compute noisy*lim + enhanced*(1-lim). But it is offered there as a user-level limit, not as a fix for musical noise, and there is no published comparison of it against a gain clamp.

What actually changes with the mix:
- The floor component would carry the true noisy phase instead of y's phase.
- The floor would become a soft knee. With incoherent phases the magnitude is about sqrt(lim^2 + g^2), instead of a hard max().
Neither has shown an audible benefit. y is itself a linear combination of recent noisy frames, so its phase is noise-like, as is the noise's own phase.

The mix also has costs:
- It is not a guaranteed floor. If y is anti-phase with x, the two can cancel below lim*|x|, so the claim that its depth is "exactly the user's floor setting" is false.
- It would have to be reconciled with the existing alpha/knee shaping and attack/release gain smoothing (nnet.c:638-660), which already target frame-to-frame gain fluctuation.

The audible benefit claimed for HF speech and CW is speculative, and the mechanism given for it misdescribes the code. Hence refuted.

The one part worth keeping is to use the lookahead-aligned frame (x_{t-L}, already in the ring buffer) as the floor reference. That is a separate, small fix.

- **float32 / Core ML partition: put only the normalised core on the ANE; keep cond, DF head and post-processing in f32 on CPU, and rescale the tiny-value thresholds**. The cited code matches the description. nnet.c:43-44 define DF_TINY 1e-30 and COND_TINY 1e-20. run_dfhead (line 632-633) computes ax = sqrt(xr*xr+xi*xi) and does `continue` when ax <= DF_TINY, so the gmax/gmin clamp is skipped and gprev[k] is not updated. run_cond (line 801-802) gates on mag > COND_TINY. nnio.c reads f32 or f64 blobs and widens everything to double (lines 164-194). run_nnet (1562-1570) runs cond, then the core, then dfhead on the raw xre/xim. I did not re-count the 154,176 f32-inexact values, but nothing in the code contradicts that count.

It still fails as an improvement to WDSP, for four reasons.

(a) There is no bug in WDSP. The whole path runs in double, so the "level-dependent silent failure on weak pre-AGC signals" cannot happen there. The hazard only exists in a float32 or FP16 port. No such port exists in WDSP or in the Lyra tree: a grep found no Core ML, mlmodel or nnet code there, only an onnxruntime notices file.

(b) The float32 numerics are wrong for the levels the proposal itself gives. Pre-AGC bin magnitudes of 1e-6 to 1e-4 square to 1e-12 to 1e-8. That is about 26 orders of magnitude above the smallest f32 normal (1.2e-38). In f32, xr*xr only underflows when |xr| is below about 1e-19, roughly -380 dBFS. A real receiver never gets there: the ADC/FFT noise floor is somewhere near 1e-7 to 1e-9. Only exact digital zeros reach it, and those are treated the same way in f32 and f64. The cond path also stays well inside f32 range: s = mag^-0.7 stays within roughly 1e13 even at mag = 1e-19, and pfloor = 1e-9 (create_cond at line 1288) bounds the gain. So point (3), hypotf or a relative threshold, fixes nothing real. "Float32 on CPU is safe" (point 1) is true, but it is ordinary porting hygiene, not an improvement.

(c) The gprev/clamp `continue` only fires for bins at or below 1e-30 in double, which in practice means exactly-zero input, such as start-up or no-signal zeros. Holding gprev through digital silence is arguably intended. Leaving the DF prediction unclamped there is negligible, because it is a small sum of coefficients times the last few frames. This has no audible effect on real HF/VHF signals.

(d) Points (2) and (4) are generic design advice for a hypothetical Core ML/ANE port. Keep FP16 away from raw spectra, partition at the normalised cond output, and validate GRU drift. They are sensible if such a port is ever built, but they change nothing for speech, CW or digital-mode reception in WDSP. The "near-zero CPU" benefit depends on other proposals and was not measured here.

Net: the description of the current code is accurate, but the claimed defect does not happen in WDSP, and the float32 underflow argument is off by many orders of magnitude for realistic signal levels.

- **Spend Apple Silicon headroom on capacity: default to the larger model and consider an 8 kHz geometry for 200-3000 Hz modes**. Parts of the description check out. In the nnr_model_0.c and nnr_model_1.c headers, slot 0 is chans 16/32/48/64, hid 32, order 5, val_si_sdr 7.674. Slot 1 is chans 24/48/72/96, hid 48, val_si_sdr 8.244. Both use 257 bins. nnet_probe_slot does read `geom` and `band`. The nnr prototype cutoff is 0.45*nrate (nnr.c:149). The load-bearing claims fail, though.

(1) "Default to the larger model" is effectively already there. SetRXANNRModel chooses the slot at runtime (nnr.c:649, 802). Lyra already offers it as a user setting: Lyra/src/wdsp_engine.cpp:3906-3909 nnrSlotFor uses nnrModel_ 0=Standard / 1=Premium, saved as dsp/nnrModel. Changing the default is a one-line host preference, not a WDSP algorithm improvement. The +0.57 dB is also not a clean capacity measurement. The two checkpoints come from different runs (nnr_la1_sw1 at step 64000, nnr_big48_la1 at step 96000), so training length and recipe are confounded with model size. The "well under 1% of a core on the ANE" argument does not apply to this code. nnet.c is portable scalar C in double precision, with no Accelerate/BNNS/CoreML path, so the ANE is never used. A port would be a separate, large project.

(2) The claim that "nnet_probe_slot already reads geom, so no framework change is needed" is false. In calc_nnr (nnr.c:400-416), the first loadable slot sets a single channel-wide nrate, decimation factor and resampler prototype. Any later slot with a different rate is rejected: "model slot %d rejected - it wants %d Hz and the channel resamples to %d" (nnr.c:452-457). A mixed setup, with an 8 kHz SSB/CW model next to 16 kHz models in other slots, cannot coexist in a channel as WDSP stands. The proposal names exactly that setup ("needs separate slots, as the band mechanism already allows"). Supporting it would need per-slot resamplers, or a rebuild of the decimator on every model switch. Lyra switches models automatically on CW and voice mode changes (wdsp_engine.cpp:2652, 3934), so that rebuild would land in a hot path.

(3) Separate CW models already exist. Slots 2 and 3 are CW models with deep-filter order 12 and 24, reaching val SI-SDR 10.8 and 12.0 dB. The DFN-style split proposes extra deep filtering for the CW tone, which the current design already covers with dedicated, higher-order CW models.

The literature cited (DPCRN Interspeech 2021, DeepFilterNet, GTCRN ICASSP 2024) is real. The proposal itself concedes that the gains are a few tenths of a dB and that training data matters more. What is left is a default flip that Lyra users can already make themselves, an 8 kHz geometry that the current framework would reject in mixed-slot use, and a speculative architecture change with no measured benefit.

### demod

- **Float32 hazards in the scalar PLL and leaky-integrator state (SAM, NFM PLL, fade leveler)**. The "current behaviour" in the proposal does not describe WDSP 2.11. Every quantity it names is already double. In amd.c the parameters and state, including phs, omega, fil_out, g1, g2, dc, dc_insert, mtauR and mtauI, are all double, and init_amd uses double exp and cos (lines 77-78). The fmd struct declares phs, omega, fil_out, g1, g2, fmdc, mtau and onem_mtau as double (fmd.c:30-60). xfmd uses double det and corr, and xfmsq uses double noise for avnoise and longnoise. comm.h:141 makes complex a double[2]. So "keep the scalar PLL and leveler state in double" is exactly what WDSP already does. The proposal itself says "In double, every one of these is harmless." The float32 hazards only appear in a hypothetical float32 port. I found none in the Lyra repo: no grep hits for omegaN, fil_out, dc_insert or g2*det.

I recomputed g1 = 0.0103626 and g2 = 2.6986e-5 for omegaN 250, zeta 1 and 48 kHz, and they match. The cancellation is real but costs nothing in double: about 13 significant digits remain.

The zeta > 1 NaN cannot happen. RXA.c:182 and :207 hard-code zeta = 1.0 for both AMD and FMD, no setter for zeta exists anywhere in the source, and sqrt(1 - 1) = 0. The fmd.c:45 comment already documents the limit.

The leaky-integrator bias of about 0.1-0.4% is a float32-only effect. In double, with a 1/(1-a) amplification of about 6.7e4, it is around 1e-11. It is also inaudible either way, because a level offset is not an audible artefact.

Setting FPCR.FZ is unrelated to correctness here. It is about denormal performance, and nothing shows a problem with it.

The cited literature (Higham on expm1 and cancellation, the Arm ARM on FPCR.FZ) is real but irrelevant to WDSP as written. At most this is a porting caution: "don't downcast these scalar recurrences to Float in a Swift port". It is not an improvement to WDSP's algorithms.

### filtering

- **Numerical hazards for the float32 port: cepstral min-phase floor, Direct Form I IIR at low frequency, half-bin frequency-sampling grid**. I read the cited code. Most of the line references are correct, but the proposal's main premise does not apply to how WDSP is actually used.

(a) and (b) only matter for a float32 port, and none exists. WDSP 2.11 does all filter design and all IIR state in double: fir.c mp_imp/mp_imp_exec, fsamp_exec, eq_impulse and the snotch/speak biquads in iir.c. Lyra links WDSP/FFTW unchanged. Its specs say audio leaves WDSP as "interleaved stereo double" and that WDSP/FFTW are "unchanged". So the proposed fix, "do design in double, keep IIR state in double", is what WDSP already does. The proposal itself says that in double the CTCSS-notch round-off is inaudible and the min-phase change is "marginal". The NaN from log(1e-300f) only happens if someone writes a naive float port. It is not a WDSP defect.

The detail in (a) is also partly wrong. The 1e-100 floor in eq_impulse applies to the target magnitude A[k]. A[k] then goes through fsamp_exec: c2r, then a Blackman-Harris window. firmin.c's mp_imp_exec takes the log of the FFT of that windowed, zero-padded impulse, not of A[k]. The stopband magnitudes the log sees are therefore set by window leakage, not by the 1e-100 floor, so the floor does not produce "-2000 dB spikes" in the cepstrum. Exact zero bins (the log(1e-300) branch) are practically never hit for a windowed double FIR. Clamping at about -150 dB relative is a reasonable textbook refinement, but nothing shows an audible effect for amateur-radio speech, CW or digital modes.

(c) is the one accurate observation. fsamp_exec, like the original fir_fsamp even-N branch, places A[k] on integer bins k*fs/N (phase -2*pi*((N-1)/2)*k/N). But eq_impulse's even-N branch samples the curve at (i+0.5)/mid, and cfir_impulse/icfir_impulse use offset = 0.5 for even N. The designed curve is therefore shifted down by fs/(2N): about 1.5 Hz for the 16384-tap EQ (RXA.c/TXA.c use max(16384, dsp_size)) and about 12 Hz for a 2048-tap CFIR. The EQ curve is a smooth user curve and the CFIR is a smooth CIC-droop compensator, so this changes the response by hundredths of a dB or less. It is a cosmetic consistency fix that would also break bit-exactness with the reference, not a meaningful improvement.

The cited literature is real and generally relevant: Damera-Venkata et al. 2000, Oppenheim & Schafer on cepstral aliasing, Jackson on DF-I round-off, and Simper's SVF note. However, it supports concerns about a float port that the project does not have.

Net: no actionable benefit for the existing double-precision WDSP in Lyra. The only real finding, the half-bin grid offset in (c), is negligible.

### resampling

- **shift.c NCO: recursive rotation and float phase are unsafe in float32 at high input rates; use an integer-phase DDS**. The description of shift.c is accurate. calc_shift (L29-34) computes delta, cos_delta and sin_delta in double. xshift seeds each buffer with cos/sin(a->phase) (L66-67), advances the phasor with an unnormalised complex rotation (L74-77), and keeps a separate double phase accumulator wrapped at 2*pi (L78-80). In RXA it runs in place on inbuff at in_rate with size dsp_insize (RXA.c L706-709).

The proposal does not show a real problem in WDSP 2.11, though:
1. Everything is double. shift.h declares double shift/phase/delta, and create_shift takes double* buffers. Only the external channel I/O buffers (INREAL/OUTREAL in comm.h) are float, and they are converted before shift runs.
2. The rotator drift cannot build up past one buffer, because xshift reseeds from the exact cos/sin of a->phase at every call. In double, per-sample rounding is about 1e-16, so even a worst-case linear growth over 8192 samples is about 1e-12 (about -240 dBc). That is far below the float32 input quantisation and below the 140 dB HB cascade.
3. The double phase accumulator has an ulp of about 9e-16 near 2*pi. A typical delta is about 4e-3 rad (1 kHz at 1.536 MHz), so the systematic frequency bias is about 1e-13 relative. That is sub-microhertz and has no audible or measurable effect.
4. The seam between the rotator and the accumulator at each buffer boundary is a phase step of about 1e-12 rad, also negligible.

The proposer admits the double-precision benefit is 'marginal'. The whole case rests on a hypothetical float32 port, and none exists. A grep of the Lyra repo found no float NCO or port of shift.c. The float32 figures (about N*6e-8 is a worst-case linear bound; a random walk gives about sqrt(N)*6e-8, about 5e-6) and the cited literature (Turner 2003, Lyons on quadrature-oscillator AGC, Tierney/Rader/Gold 1971) are real and correct as general design guidance. They do not describe a defect or a meaningful improvement for the code as it stands. Swapping in a LUT DDS would also add its own spur floor, which has to be engineered to beat what is already about -240 dBc. As an improvement to WDSP 2.11 it is refuted, and is at most a design note for any future single-precision or SIMD rewrite.

- **Resampler filter design: BH7 windowed sinc spends about 35% more taps (latency) than a Kaiser or equiripple design for the same spec**. The structural description is right. resample.c calc_resample (fc = 0.45*min_rate, ncoef = 140*full_rate/min_rate, fir_bandpass wintype 1) and varsamp.c calc_varsamp (fc = 0.95*0.45*min_rate, rsize = 140*norm_rate/min_rate, wintype 1) do this, and fir.c case 1 is the 7-term Blackman-Harris window. create_resampleF and delay.c use ncoef = 60/fc_norm with fc = 0.45, which works out to about 133*full_rate/min_rate, so they are the same design.

The quantitative premise is wrong, and the whole benefit rests on it. I rebuilt the exact WDSP impulse (same BH7 coefficients, same sinc and centring) for 48k to 192k (L = 4, N = 564) and computed the response directly:
- BH7 measured: 0.1 dB passband edge 0.427*min_rate, -6 dB at 0.450, below -140 dB from 0.495, below -160 dB from 0.497, peak sidelobe past 0.5*min_rate about -197 dB. The effective transition for a 0.1 dB / 140 dB spec is D = N*df of about 9.6, not the claimed 14/N. The proposal's "flat only to 0.40*min_rate" (19 kHz at 48k, +/-72 kHz at 192k) is too pessimistic; the real figures are about 20.5 kHz and about +/-82 kHz.
- Kaiser beta = 14 at the same N and fc: 0.1 dB edge 0.4315, -140 dB only from about 0.5035, so D is about 10.2 and it misses 140 dB at 0.5*min_rate. Kaiser's own estimate for 140 dB, (A - 7.95)/14.36, gives D of about 9.2, the same as BH7's 9.6 to within a few percent.

So the headline "Kaiser narrows the transition from 14/N to 9.2/N, about 35% fewer taps" is false. BH7 already sits at Kaiser efficiency for this attenuation, and it gives roughly 160 to 190 dB at no extra width. The passband gain from Kaiser at fixed N is about 0.005*min_rate (about 240 Hz at 48k), not about 2 kHz.

Parks-McClellan can genuinely save taps, but only by trading passband ripple. With matched near-zero ripple, the Herrmann/Kaiser estimates give D of about 8.7, roughly 10% fewer taps. The roughly 40% saving appears only with about ±0.05 dB equiripple passband, and that ripple adds up across WDSP's cascaded resamplers (rmatch/VAC/varsamp in series with resample). Equiripple also gives up BH7's decaying stopband, which matters for images at large L.

Even the best case saves about 0.5 ms at 48 kHz, which is negligible next to WDSP's FFT bandpass and NB/AGC latency, as the proposal itself admits. For speech, CW and digital modes, a few hundred Hz to 2 kHz of extra flat band near 0.45*fs is inaudible and irrelevant: SSB/CW/digital passbands are 3 kHz or less, far inside the flat region. For 192k I/Q VAC display use, the passband is already flat to about +/-82 kHz.

The cited literature is real: Kaiser 1974, Parks-McClellan 1972, Oppenheim & Schafer, Crochiere & Rabiner. But the proposal misapplies it by treating main-lobe width as the transition width for a windowed sinc.

### tx-processing

- **AM: guard against carrier pinch-off and allow asymmetric real-waveform peak control**. The line-level facts are correct. ammod.c:62 computes out = mult*(c + (1-c)*x) with I=Q, and SetTXAAMCarrierLevel (103-110) accepts any c_level. The default is 0.5 (TXA.c:343). The ALC runs in envelope mode with a 1.0 target (TXA.c:313-336), which bounds |z|, and |Re z| <= |z|, so x >= -1. That means c < 0.5 can drive c + a*x negative.

The bug claim fails on the physics. In WDSP the AM modulator is a linear I/Q operation. x is band-limited to 0..f_high by bp0/bp1/bp2, so c + a*x is just carrier plus DSB sidebands, and its spectrum is the carrier plus a*X(f) mirrored. When the sum goes below zero you get a sign reversal of a linear signal. That is reduced-carrier DSB with modulation index a/c > 1. It adds no bandwidth and causes no splatter. Overmodulation splatters in a plate- or collector-modulated transmitter because the modulator physically cannot go below zero and hard-clips. A linear SDR exciter has no such limit. The only real effect is envelope-detector distortion in receivers that lack synchronous AM (SAM handles it fine). That is a consequence of the operator choosing a carrier level below 0.5, and front ends map their carrier-level control onto this setter for exactly that reason. It is not a WDSP defect.

The proposed fix is worse than the problem. Part (1) says "always clamp c + a*x >= 0" and calls it risk-free. That hard clamp is a memoryless nonlinearity, so it would create the very wideband splatter the proposal says it removes. The softer variant (a look-ahead negative-peak limiter at -c/a followed by the 0..f_high lowpass) only trades a linear sideband for a nonlinear one, and it silently overrides a carrier level the user picked. The filter's overshoot also means it cannot guarantee a hard bound.

Part (2), asymmetric peak control of the real waveform with +125% positive peaks, is a real broadcast technique. 47 CFR 73.1570(b)(1) is a real rule and the Orban/Optimod work is a real reference. But it is a new optional feature, not a fix, and its benefit here is small:
- In a linear exciter, PEP is fixed by full scale. Allowing +125% means dropping the carrier to about 0.444, so the gain in sideband-to-carrier loudness is about 1 dB, not 1-2 dB.
- It would need a separate real-waveform processing path. COMP, CESSB and ALC all work on the symmetric analytic envelope, which can never produce asymmetric peaks.
- phrot's reverse switch already exists (phrot.c:387), so the polarity half of the idea is already supported.
- 125% positive modulation is a broadcast norm. For amateur HF it is niche at best and discouraged by many operators.

Neither part is a confirmed improvement worth prioritizing.

### puresignal

- **Estimate the forward AM/AM and AM/PM conditioned on the noise-free DAC amplitude, then invert (removes indirect-learning bias)**. The description of the current code is accurate. In calcc.c calc() (around lines 1161-1174), x = rx_scale*rx_c, which is the clamped, noisy feedback magnitude. ym = hw_scale*|tx| / (rx_scale*rx_c), and yc/ys are the cos and sin of the tx-rx phase difference. equalize_density bins on a->x (the rx regressor), uses means, and switches to medians in the low bins. This is classic indirect learning: tx is the post-predistortion DAC stream, and the post-inverse is used directly as the predistorter. Sample collection (putSample) already buckets on the noise-free normTX. Only the regressor used for fitting is rx-based. I found no forward-model, direct-learning or ILC path in calcc.c or iqc.c, so WDSP does not already do this.

The cited papers are real and on topic: Zhou and DeBrunner (IEEE TSP 2007), Paaso and Mammela (ISWCS 2008), Chani-Cahuana et al. (TMTT 2016) and Cavers (complex-gain lookup table). But the benefit claimed for this code does not hold up:

(1) The noise-bias mechanism is quantitatively negligible here. With PS feedback noise about 60-70 dB below peak, sigma is about 3e-4 to 1e-3. At the lowest fitted amplitudes (EQ_XMIN 0.02, prefilter 0.04), the relative noise is about 1-3%. The Jensen/ratio bias of averaging |tx|/|rx| scales as (sigma/a)^2, which is about 1e-4 to 1e-3 relative, roughly -60 dB or lower. Regression dilution is just as small, because the noise in x is much smaller than the 0.01 bin width and the inverse curve is nearly flat near 1 at low amplitude. The proposal itself admits the pure-noise bias is marginal.

(2) The main scatter source it cites, PA memory/hysteresis and residual delay, is not estimation bias. It is mismatch from fitting a memoryless model. Inverting E[rx | tx] is also a memoryless compromise, not an 'unbiased' predistorter. Neither ILA nor forward-inversion can correct memory, and memory is what actually limits PureSignal IMD on real HF amplifiers. The DLA-over-ILA results in the literature come mostly from memory-polynomial setups under specific noise and mismatch conditions. They do not show 2-5 dB for a static AM/AM-AM/PM lookup table at 60-70 dB feedback SNR.

(3) The claim that the change would remove the need for the x=0 pin and the prefilter is wrong. The variance of the complex forward-gain estimate rx*conj(tx)/|tx|^2 scales as sigma^2/|tx|^2, so it blows up at small r. Collection also already discards samples below SAMPLE_MIN_X = 0.005. Low-amplitude extrapolation and pinning would still be needed.

(4) Errors below about 0.1 of peak contribute little to the low-order IMD3/IMD5 that dominates amateur SSB/digital splatter specs. So the claimed 2-5 dB on low-order IMD is in the wrong amplitude region and is unsupported.

(5) The cost and risk are large. It changes curve semantics, the display and the correction-file format, and it has to re-create the fold, end-pin and saturation clamp behaviour, where mistakes over-drive peaks.

Net: the proposal is a legitimate alternative architecture, but for this application its benefit is unconfirmed and likely near zero. Refuted under the default-to-refute rule.

- **Add an optional memory stage: a small generalized memory polynomial on the residual after the static table**. The description of the current code is accurate. In xiqc (iqc.c:99-107), env is computed only from the current I and Q. ym, yc and ys come from get_mag_correction_ema and get_phase_correction_ema, which explicitly ignore prev_y ("(void)prev_y;" in nurbs_spline.c:957-970) and simply interpolate a static curve. So the predistorter is strictly memoryless (AM/AM plus AM/PM). Nothing else in WDSP 2.11 does memory DPD: a search for memory polynomial, Volterra or GMP finds nothing. The citations are real and correctly attributed: Kim and Konstantinou, Electron. Lett. 37(23), 2001; Morgan et al., IEEE TSP 54(10), 2006; Ding et al., IEEE Trans. Commun. 52(1), 2004.

I still refute the proposal as specified, for these reasons.

(1) The memory depth is scaled wrongly for SSB. The PS feedback and correction run at ch.in_rate / dsp_rate, typically 192 kS/s (TXA.c:407-422). A 3 kHz SSB envelope is about 60x oversampled there. M=2..4 taps spans only about 10-20 µs, and over that span |x(n-m)| is almost identical to |x(n)|. The delayed GMP regressors are therefore nearly collinear with the static terms. The least-squares problem is badly conditioned for any signal, not only a steady tone. With ridge regularisation, the only thing it can fit is a small first-derivative term. That term mostly soaks up residual fractional time misalignment between TX and feedback, which is a capture artefact, not PA memory.

(2) The memory mechanisms the proposal names cannot be reached by 20 µs of taps. Electrothermal and supply-sag effects work on millisecond-to-second scales. Bias-network resonances at envelope rates of a few kHz work on hundreds of microseconds. Slow thermal drift is already tracked, roughly, because calcc recalibrates continuously and swaps tables (the SWAP state in xiqc). Fast envelope-rate memory would need sparse, decimated delays or an IIR/low-pass envelope branch (for example a Wiener-Hammerstein or thermal sub-model), not a GMP with M=2..4 at the feedback rate.

(3) The calcc data path does not support it. psCollection (calcc.c:310-372, 411-422) stores isolated TX/RX sample pairs in 16 amplitude buckets of 256 each, ring-indexed per bucket, with no time history. You cannot form x(n-m) from it. A memory stage would need a new contiguous, sub-sample-aligned capture path and a new solver/validation pipeline. That is far more than "a new least-squares stage after the curves pass".

(4) The benefit is speculative even in the proposal's own words: "perhaps 0-6 dB", "may be about zero", "unproven on HF ham amplifiers". For ham use, PS correction is usually limited by feedback SNR and coupler or ADC dynamic range, and voice gives poor excitation diversity. Neither point favours a 20-40 coefficient adaptive model. It also adds a real instability and regression risk to a live transmit path.

Given the default-to-refute rule and no evidence that this configuration helps on HF SSB, I refute it. A narrower idea might be worth measuring: first check two-tone IMD asymmetry versus tone spacing on a real amplifier, then, if memory is confirmed, use a slow envelope-filtered branch. That would be a different proposal.

- **Keep the fit in double (or use QR) when porting to float32, and simplify to a direct penalised B-spline y(x)**. The description of the current code is mostly accurate. ls_solve_with_cond (nurbs_fit.c:534-591) builds A'A and Atb, factors with cholesky() (505-520), and adds a 1e-8*trace ridge if that fails. The cond_out value is (max/min of the Cholesky diagonal)^2. That estimates cond(A'A), so it is already the squared figure. The 1e8 NF_FIT_BAD_CONDNUM threshold (1355, 1743) therefore applies to cond(A'A), and comparing it with float32's 1/eps of about 1.7e7 is the right comparison. The IRLS loop (1341-1353) calls fit_pass with cond_out=NULL, so those passes are not condition-checked. Its weights are 1/(res+1e-6) applied to the rows, which can widen the spread of A'A by a lot. lowess (extrapolate.c:280-332) and wls_poly (251-278) do accumulate raw moments without centring. PS config is as described: calcc.c sets PS_NF_UNIFORM_KNOTS 1, ADAPTIVE_ITERS 0 and ORDERING_MODE NF_ORDER_BY_X, and parameterise_dispatch (416-429) sets t=x. B-splines reproduce linear functions exactly, so x(t)=t and the curve is in effect y(x). The parametric and fold machinery is therefore largely inert. calcc.c does call nf_fit, then ns_build, then ns_accuracy_check (1282-1635).

Why this is refuted as an improvement to WDSP:
(a) Every routine involved (nurbs_fit.c, extrapolate.c, calcc.c) is written entirely in double. There is no float in the fit path. In Lyra the WDSP C source is built directly (CMakeLists) and is not ported. "Keep calc() and extrapolate in double" is exactly what WDSP already does. The claimed collapse happens only in a float32 port that does not exist and that nobody has proposed, so it is a caveat for porting, not a fix. In double, eps*cond(A'A) is about 2e-16*1e8, roughly 2e-8, which is harmless.
(b) The proposal admits the quality gain is "about the same or marginally better". The extra resampling stages are checked by ns_accuracy_check and add error far below PA predistortion needs, which are about 40-60 dB IMD improvement. What remains is a rewrite for maintainability. It would replace a fitter whose many PS thresholds were tuned against its current behaviour. It would need a new QP or active-set solver and GCV. The benefit to amateur PureSignal operation (SSB, CW and digital linearity) is unquantified and possibly negative until re-tuned. As stated, it is not a demonstrated algorithmic improvement.

The literature is real and relevant in general: Golub and Van Loan sec. 5.3; Eilers and Marx 1996, Stat. Sci. 11(2); Pya and Wood 2015, Stat. Comput. None of it shows a problem in the current double-precision code.

A minor real observation that the proposal did not make its main point: the IRLS refits are not cond-checked and use weights of 1/(r+1e-6). Even in double that could inflate A'A conditioning. It is a small robustness note, not the claimed benefit.

## Current-algorithm summaries (pass 1)

### agc

xwcpagc (wcpAGC.c:161-346) delays the complex signal through a ring of RB_SIZE=30721 samples (wcpAGC.h:33) by attack_buffsize = ceil(fs*n_tau*tau_attack) samples (line 119). It also keeps a window peak, ring_max, of |x|: the envelope when pmode=1, or max(|I|,|Q|) when pmode=0 (lines 189-192). ring_max is updated incrementally and fully rescanned whenever the outgoing sample was the max (lines 197-210). A 5-state machine moves a one-pole 'volts' detector toward ring_max: 0=attack, 1=fast 'pop' decay when volts > pop_ratio*fast_backaverage, 2=hang hold (entered only if a 0.5 s back-average exceeds hang_level), 3=normal decay, 4=post-hang decay (lines 215-334). Because the look-ahead is n_tau attack time constants, out_target is derated by (1-e^-n_tau)*0.9999 (line 127), which guarantees peaks do not exceed out_targ. The per-sample gain is (out_target - slope_constant*min(0,log10(volts/max_input)))/volts (line 339), so the 'slope' control makes output amplitude a linear function of log input. The same code runs the RX AGC (RXA.c:362, n_tau 4, envelope), the TX leveler (TXA.c:158, n_tau 6, max(|I|,|Q|)), the always-on TX ALC (TXA.c:313, n_tau 6, envelope) and the FM limiter (fmd.c). meter.c reports one-pole averaged and peak power per block, plus 20log10(*pgain) of the AGC's 'gain' field.

### spectral-nr

EMNR processes only the real (I) audio stream through a WOLA STFT. The frame is a fixed 4096 points with 4x overlap (RXA.c:329-330) and a sqrt-Hamming analysis/synthesis window normalised by coherent gain (calc_window, emnr.c:167-186). The FFT size does not depend on the DSP rate, so at 48 kHz that is about 11.7 Hz bins and an 85 ms window. The noise PSD comes from one of three estimators, picked by npe_method (calc_gain, 1104-1115): Martin (2001) minimum statistics with optimal smoothing and bias compensation (LambdaD, 680-803, the default); the Gerkmann-Hendriks (2012) unbiased MMSE/SPP estimator with xi_H1 = 15 dB and stagnation guard (LambdaDs, 805-818); or Rangachari-Loizou (2006) continuous-minimum/MCRA-2 with band-dependent thresholds (LambdaDl, 820-843). All time constants are rescaled from a 128-sample/8 kHz reference hop to the actual hop. The a-priori SNR is decision-directed (alpha ~0.98, with the a-posteriori SNR clamped to gamma_max = 40). The gain is chosen by gain_method. Method 0 is Ephraim-Malah STSA times a fixed-q (0.2) speech-presence factor. Method 1 is MMSE-LSA via E1(x). Method 2, the default, multiplies two 241x241 0.25-dB tables from calculus.c (GG*GGS, bilinear interpolation in dB, getKey 1029-1073); GG[0] = 0.7257 at -30/-30 dB matches the LSA gain. Method 3 is STSA+SPP followed by a TSNR-style second pass, then a hard 0/1 decision from a trained 60x60 zeta table (getZeta 1075-1095, 1216-1220). After the gain, an optional Esch-Vary (2009) adaptive frequency moving-average 'AE' filter runs (aepf 849-896, on by default). An optional post2 stage then injects comfort noise from the removed residual plus random-phase white noise, and tapers/brick-walls bins above taper*Nyquist (post2 939-977, off by default).

### lms-nr

ANR and ANF (anr.c / anf.c xanr/xanf lines 82-134) share one engine: a real-valued adaptive line enhancer on the I channel of the post-demod audio. A 64-tap normalised LMS predictor (RXA.c defaults: delay 16, two_mu 1e-4, gamma 0.1) predicts d[n] from d[n-delay-j]. Both regularise the NLMS step with 1/(sigma+1e-10) (line 103). Both apply Kamenetsky-Widrow variable leakage: they compare a-posteriori errors with and without leak (nel/nev, lines 109-110), step lidx up or down, and map it through a 4th power, ngamma = gamma*lidx^4*den_mult (line 119). ANR outputs the prediction y (line 106). ANF outputs the error, the same filter used as a notch. They run pre-AGC at position 0 or post-AGC at position 1 (RXA.c lines 674-684). SNBA (snb.c) is a Vaseghi/Rayner-Janssen style AR impulse restorer. It resamples to 12 kHz, takes 256-sample frames with 4x overlap (hop 64), fits an order-64 AR model by autocorrelation and Levinson (lmath.c asolve), and inverse-filters to a two-sided residual (invf). It thresholds residual power against k2 times a median-anchored robust mean (det), bridges gaps, extends pre and post, and zeroes the hits. It then repairs each burst in merit order by least-squares AR interpolation (xHat via the Trench Toeplitz inverse trI), refitting the AR model per gap, over npasses=2.

### noise-blankers

Both blankers run on the raw wideband IQ, before any channel filtering. They flag a sample as an impulse when |x| > threshold * avg, where avg is a one-pole IIR mean of |x| (time constant backtau). avg is updated with the current sample before the test, and that includes the impulse itself (nob.c:118-122, nobII.c:179-184). avg is initialised to 1.0 (nob.c:45, nobII.c:148). ANB (xanb, nob.c:108-187) runs a 5-state gate over a delay line of trans_count+adv_count samples. It multiplies the live delayed signal by a raised-cosine ramp down, zeroes for the advance and hang periods, then ramps the live signal back up. NOB-II (xnob, nobII.c:158-494) keeps a much longer look-ahead delay line: out->scan is adv_slew+adv+1 samples and scan->in is max_imp_seq+hang+hang_slew+filterlen samples, with max_imp_seq hard-coded to 25 ms in create_nobEXT (nobII.c:623). At each detection it scans forward to measure the whole impulse sequence and merges bursts that fall within hang+adv of each other. It then fills the gap with zero (mode 0, Lyra's mode), a held 10-tap exponentially weighted average of the samples before (mode 1) or after (mode 3) the gap, their mean (mode 2), or a straight line between them (mode 4). Sequences longer than max_imp_seq fall back to a zero-and-stay-down path (states 5-9). NOB-II's raised-cosine slews (states 1, 4, 5, 9) cross-fade between frozen sample values (Ilast, Inext) and the fill value; they do not window the live signal. slew.c (xuslew) applies a one-shot 0.5(1-cos) ramp to the TX signal on its first non-zero sample after an optional delay.

### nnr

The NNR block takes the real channel at dsp_rate and decimates it by an integer factor to the model rate (16 kHz in every built-in model). The decimator is a Kaiser-windowed sinc, beta 7.857 (about 80 dB stopband), cutoff 0.45*nrate, 51 taps per phase (nnr_design_proto, nnr_push_input). It then runs a sqrt-Hann WOLA STFT: N=512, hop 256 (hop 128 for slot 3), 257 bins (nnr_frame). Each frame is compressed to |X|^0.3 with phase kept and scaled by one broadband EMA power normaliser with tau 2 s and bias correction (run_cond). It then goes through a causal DPCRN-style U-net with 4 Conv2d encoders (kt=2, kf=5, frequency stride 2, 257->129->65->33->17), 2 DPRNN blocks (a bidirectional GRU across the 17 bands, then a per-band GRU across time) and 4 ConvTranspose2d decoders with skips. The output is 2*order channels of complex deep-filter coefficients (DeepFilterNet-style), applied to the raw, un-normalised STFT over the last `order` frames (5/5/12/24 for slots 0-3) in run_dfhead. After that come per-bin post-processing steps: an optional expander knee, optional attack/release smoothing, a gmax clamp (+12 dB) and a gmin floor (the mask_floor, -25 dB in RXA.c). The output is inverse-FFT'd, overlap-added, polyphase-interpolated back to the original rate and buffered in a FIFO pre-filled with `prime = decim*hop` zeros. The models carry `lookahead`=1 (I parsed it from the built-in blobs), but no runtime code consumes it except the delay formula (nnr.c:216). The lookahead is therefore implicit in training: the frame-t output estimates frame t-1. The total is about 51 ms at 48 kHz for slots 0-2 and about 43 ms for slot 3. For models that declare a training band (slots 2 and 3, 200-3000 Hz), setNNRbypassRun moves NNR before the AGC (position 0). It feeds NNR from a 2048-tap minimum-phase bandpass and skips bpsnba/snba/eqp/anf/anr/emnr. Inference is hand-written scalar double C. Model 0 costs about 6.3 MMAC per frame (about 0.39 GMAC/s), and model 1 about 2.2 times that. Weights are stored as f64.

### demod

AM (amd.c xamd mode 0, lines 133-145) is a plain envelope detector, sqrt(I^2+Q^2), with an optional "fade leveler" that swaps the fast-tracked carrier DC (tauR 20 ms) for a slow one (tauI 1.4 s). SAM (mode 1, lines 150-232) is a second-order type-2 PLL. Its NCO counter-rotates the input, an atan2 phase detector runs on the whole correlator output (lines 222-223) with gains g1/g2 from init_amd lines 77-78 (omegaN 250, zeta 1, about 99 Hz loop pole, lock clamped to ±2 kHz). Sideband selection comes from a 7+7-stage polyphase allpass Hilbert pair (lines 160-189); I measured it at roughly 60 dB opposite-sideband rejection from 20 Hz to 23.9 kHz at 48 kHz, in both double and float32. NFM (fmd.c xfmd, lines 206-250) uses the same PLL structure set very wide (omegaN 20000, pole about 7.9 kHz), then a one-pole DC block, then two cascaded 2048-tap linear-phase FIRs (fcimp -6 dB/oct de-emphasis, then a 240-3300 Hz bandpass), a CTCSS notch and an optional limiter. FMSQ uses the 5-20 kHz noise in the pre-de-emphasis audio with absolute thresholds; AMSQ uses a 10 ms average of the pre-demod IQ magnitude; SSQL is a zero-crossing-rate syllabic-modulation detector. WBFM (wbfm.c xwbfm, lines 744-766) is a quadricorrelator plus a fixed DC block. It splits the MPX into 0-15.2k, a 50 Hz-wide 19k pilot (8192 taps) and 22.8-53.2k bands, regenerates 38 kHz by squaring the AGC-normalised pilot, and hard-switches mono/stereo from pilot magnitude only. It then applies a bilinear one-pole de-emphasis and a 58-75 kHz noise-power squelch. The CW matched filter (matchedCW.c build_matched, lines 45-114) is a rectangular-envelope complex tone of length 1.2067*rate/FWHM, so its sinc response has a -6 dB width equal to FWHM. apfshadow.c only routes the APF controls to one of four filter blocks.

### filtering

Almost every FIR filter in WDSP (bandpass, nbp, eqp, cfir/icfir, doublepole) runs through fircore (firmin.c:290-440). fircore is uniformly partitioned overlap-save: the partition size equals the I/O block, the FFT is 2*size, there is a frequency-domain delay line of past input spectra (fftout ring, idxmask = nfor-1), and two mask sets (fmask[0/1]) are switched by cset under a critical section. Filter design is a windowed sinc. fir_bandpass (fir.c:215-314) uses only a 4-term or 7-term Blackman-Harris window (wintype 2 falls through to the 7-term default) and is cached in a hash-keyed LRU. EQ and CIC compensation use frequency sampling (fsamp_exec, fir.c:653-681, a c2r FFT followed by a BH4/BH7/Kaiser beta=8 window). Minimum phase is cepstral: log|H| on a grid zero-padded by pfactor (16 or 4), then a Hilbert transform via analytic(), with log(1e-300) as the floor (fir.c:385-466, 561-597). Notches in nbp are made by splitting the passband into sub-bands (make_nbp) and summing windowed-sinc bandpasses (fir_mbandpass). The IIR blocks in iir.c are Direct Form I biquads and one-pole filters in double, with RBJ-style designs.

### resampling

resample.c is a classic rational L/M polyphase FIR (calc_resample L35-78): GCD-reduced L/M, a Blackman-Harris-7 windowed sinc from fir_bandpass (wintype 1) with ncoef = 140*full_rate/min_rate (L64) and a -6 dB cutoff at 0.45*min_rate (L57), giving about 0.1*min_rate of transition band centred on fc. reshb.c (new in 2.11) is a cascade of decimate-by-2 half-band FIRs with Dolph-Chebyshev windows (140 dB design, L345-382) and folded symmetric taps (xhbres L134-164). The stage lengths come from a hard-coded table of rate pairs (L179-344), and they agree closely with Kaiser's length estimate for protecting a 0-24 kHz final passband. Those stages are well designed and float32-safe. varsamp.c is an arbitrary-ratio resampler. It linearly interpolates coefficients from a table oversampled by R=1024 (hshift L114-124, about -120 dB coefficient error), and it tracks output timing with two double accumulators (isamps, h_offset) that stay exactly consistent only because inv_cvar is truncated to 36 mantissa bits by type-punning (L151-153). rmatch.c wraps varsamp in a ring buffer: var = feed_forward(count ratio, 262144-call window, EMA 0.01) - pr_gain * boxcar_mean(fill deviation, 16384 calls), clamped to +/-4% (control L256-273), with raised-cosine fades on under- and overflow. shift.c is a recursive complex-rotation NCO reseeded from a double phase every buffer. delay.c is a fixed polyphase windowed-sinc fractional delay (20 ns step) plus up to 1024 whole samples.

### tx-processing

The TXA chain (TXA.c:551-583) is: panel, then phase rotator (phrot.c: a cascade of first-order allpass sections, 8 stages at 338 Hz by default, with an optional A/B pattern-search auto-tuner), then the AM-squelch expander, pre-EQ and optional FM pre-emphasis (emph.c: a frequency-sampled FIR from fcurve.c), then leveler, then CFC (cfcomp.c: an STFT with sqrt-window WOLA, fsize=max(16384,dsp_size), overlap 4, a per-bin hard clip mask = min(cfc_gain, 1/|X|) and an optional post-EQ), then bp0 (a complex analytic bandpass, gain 2). Next comes the speech compressor (compress.c, G3PLX: hard-clips the analytic envelope to 1 and keeps only the real part, Q=0), then bp1 (analytic bandpass, gain 2), then CESSB overshoot control (osctrl.c, Hershberger 2014: a centred look-ahead window of about 0.3/3000 s takes the windowed envelope peak, divides by 1+osgain*(peak-1) with osgain=1.95, and the result goes through bp2), then ALC, then AM/DSB/SSB+carrier (ammod.c: c + (1-c)*x) or FM (fmmod.c: phase accumulator, CTCSS, Carson-rule bandpass dev+f_high). dexp.c is the external DEXP/VOX block: a one-pole |x| detector, a LOW/ATTACK/HIGH/HOLD/DECAY state machine with raised-cosine gain ramps, a look-ahead audio delay ring and anti-VOX subtraction. eer.c splits I/Q into a magnitude path and a constant-envelope phase path with fractional delays. Most blocks are sound. The main issues: the real-part-only clipper, CFC latency (an impulse simulation of the xcfcomp indexing gives exactly fsize-bsize samples, about 16k), the decay state of the expander, and a few unguarded edge cases. Float32 conversion is low-risk everywhere I checked; the notes are inside each proposal.

### puresignal

PureSignal in WDSP 2.11 is a memoryless predistorter learned by indirect learning, with no memory terms. pscc() collects pairs of DAC samples (after predistortion) and feedback samples into 16 equal-width TX-amplitude buckets of 256 samples each (calcc.c:337-423). calc() normalises the feedback with a LOWESS-plus-polynomial extrapolation of |rx| at tx=1 (extrapolate.c:340-410). It then forms the post-inverse in three parts as functions of the normalised output amplitude x=|rx|: ym=|tx|/|rx|, yc=cos(angle tx - angle rx) and ys=sin(angle tx - angle rx) (calcc.c:1161-1174). These are binned into at most 100 x-bins (equalize_density, 542-611). Each part is fitted separately by nf_fit as a 20-control-point cubic B-spline, set up as a NURBS, with an extrapolated start pin, outlier passes, CV checks and 2 IRLS passes (nurbs_fit.c:995-1478). In PS's configuration (ORDER_BY_X, uniform_knots=1 so t=x, adaptive_iters=0) this reduces to plain B-spline regression y(x). The control points are smoothed by an EMA (alpha 0.1, calcc.c:1461-1572), resampled to a 160-point not-a-knot cubic spline (ns_build), checked (accuracy, extrema, sin^2+cos^2, solution deviation), then blended into a 256-point CurveEMA lookup table (alpha 0.3, nurbs_spline.c:870-909). xiqc() reads the three tables per sample at the input envelope with Catmull-Rom Hermite interpolation and computes out = ym*(I+jQ)*(yc+j*ys), with a raised-cosine crossfade between table sets (iqc.c:91-171). TX/RX alignment is a manual delay (SetPSTXDelay, calcc.c:2217). lmath.c (xbuilder etc.) is no longer used by this path; PS now uses the nurbs_* files.

### analyzer

new_window() (lines 52-177) builds one of seven symmetric windows (denominator N-1): rectangular, 4-term Blackman-Harris, Hann, 5-term flat-top, Hamming, Kaiser (with the Abramowitz and Stegun/Numerical Recipes bessi0 approximation) and a 7-term Blackman-Harris in Horner form. Each window is scaled to unity coherent gain, and inv_enb = 1/ENBW is stored. Worker threads (spectra/Cspectra, 603-669 and 837-918) window an overlapped block from a ring buffer and run an FFTW r2c or c2c FFT. eliminate()/Celiminate() (180-281) take |X|^2, drop `clip` bins from each sub-span edge plus fractional fsclipL/H at the span ends (this is how zoom works: bins are thrown away, not re-resolved), and keep the minimum across num_fft LO positions to suppress spurs. stitch() (556-601) joins the sub-spans. detector() (283-462) maps bins to pixels with peak, rosenfell, average, sample or 'rms' when there are more bins than pixels, and interpolates linearly in the power domain when there are more pixels than bins. avenger() (464-554) then applies peak-hold, an exponential IIR on linear power, a boxcar running sum over up to dMAX_AVERAGE=60 frames, or an IIR on dB values, and converts to dB with the table-based mlog10. The calibration term cd[] comes from a cubic spline (build_interpolants/interpolate, 920-1056), and 1-Hz normalisation adds 10log10(N/fs). A separate DetectMaxBin path (705-816) reports a decaying peak over a frequency range for metering.
