// Lyra — eSSB Coach: RXA post-AGC latency + applied-AGC-gain model.
// Line numbers refer to WDSP 2.00 Source (build/wdsp-macos/OpenHPSDR-wdsp).

#include "dsp/coach/RxaAgcModel.h"

#include <algorithm>
#include <cmath>

namespace lyra::dsp::coach {

double rxaPostAgcLatencySamples(const RxaState &s)
{
    // xrxa runs, after xwcpagc (RXA.c:650):
    //   xanf(1), xanr(1), xemnr(1), xbandpass(bp1,1), [agcmeter], xsiphon,
    //   xcbl, xdoublepole, xmatched, xgaussian, xspeak, xmpeak, xssql,
    //   xpanel, xamsq, xresample(rsmpout)                    (RXA.c:651-666)
    // agcmeter/siphon only read the buffer.  xssql (ssql.c:230-290),
    // xpanel and xamsq (amsq.c:117-170) output sample i from input sample
    // i: no latency.  They only scale it.
    if (s.nnrRun) return NAN;                     // not in the in-tree source
    if (s.dspRate != s.outRate) return NAN;       // rsmpout runs (RXAResCheck, RXA.c:887-893)
    if (s.cblRun || s.doublepoleRun || s.matchedRun || s.gaussianRun || s.mpeakRun)
        return NAN;                               // not analysed; Lyra never runs them
    if (s.speakRun) return NAN;                   // IIR bi-quad: frequency-dependent delay
    // ANF / ANR after the AGC: LMS predictors, not analysed.
    if ((s.anfRun && s.anfPosition == 1) || (s.anrRun && s.anrPosition == 1)) return NAN;
    // SNBA in AM/SAM/DSB/FM runs bpsnba at position 1 (RXA.c:998-1007).
    if (s.snbaRun) return NAN;

    double d = 0.0;
    // EMNR at position 1 (xemnr, emnr.c:1199-1252): with fsize <= bsize,
    // oasize = bsize and the output index starts fsize - incr ahead
    // (emnr.c:309-328), with incr = fsize/ovrlp.  Frame f's overlap-added
    // first quarter, input time f*incr, lands at oainidx = init + f*incr, and
    // each call reads bsize samples from oaoutidx = 0.  So the output lags
    // the input by fsize - incr samples (3072 with the 4096 / 4 create
    // args, RXA.c:323-336).
    if (s.emnrRun && s.emnrPosition == 1) {
        if (s.emnrOvrlp <= 0 || s.emnrFsize > s.dspSize) return NAN;
        d += s.emnrFsize - s.emnrFsize / s.emnrOvrlp;
    }
    // bp1: runs if AM/SAM demod, SNBA, EMNR, ANF or ANR runs (RXAbp1Set,
    // RXA.c:910-922; AM/SAM set amd.run, RXA.c:842-861), at bp1.position
    // (xbandpass, bandpass.c:319-325).  The filter has nc = max(2048, dsp_size)
    // taps (RXA.c:381-393).  xfircore is overlap-save with the impulse
    // right-justified and the output taken from the left (firmin.c:323-346,
    // 412-440), i.e. a causal linear convolution with no extra block delay.
    // fir_bandpass is symmetric about m = (N-1)/2 (fir.c:249), so the linear-
    // phase group delay is (nc-1)/2.  Minimum phase (RXASetMP ->
    // SetRXABandpassMP, bandpass.c:448-457) has a frequency-dependent delay.
    const bool amd = s.mode == kRxaAm || s.mode == kRxaSam;
    const bool bp1Run = amd || s.snbaRun || s.emnrRun || s.anfRun || s.anrRun;
    if (bp1Run && s.bp1Position == 1) {
        if (s.bp1MinPhase) return NAN;
        const int nc = std::max(2048, s.dspSize);
        d += 0.5 * (nc - 1);
    }
    return d;
}

double rxaAgcAppliedGainDb(double meterDb, const RxaState &s)
{
    // FM / WBFM: SetRXAMode clears agc.run (RXA.c:866-874); xwcpagc then
    // copies the input through (wcpAGC.c:344-345), i.e. unity gain.
    if (s.mode == kRxaFm || s.mode == kRxaWbfm) return 0.0;
    // FIXD: out = fixed_gain * in, and the gain the meter reads is not
    // updated (wcpAGC.c:166-174; SetRXAAGCFixed, wcpAGC.c:546-551).
    if (s.agcMode == 0) return s.fixedGainDb;
    if (!std::isfinite(meterDb)) return NAN;
    // loadWcpAGC (wcpAGC.c:127-136):
    const double T = s.outTarg * (1.0 - std::exp(-static_cast<double>(s.nTau))) * 0.9999;
    const double maxGain = std::pow(10.0, s.maxGainDb / 20.0);
    const double var = s.varGain;
    const double minVolts = T / (var * maxGain);
    double tmp = std::log10(T / (s.maxInput * var * maxGain));
    if (tmp == 0.0) tmp = 1e-16;
    const double slopeK = (T * (1.0 - 1.0 / var)) / tmp;
    // The meter (meter.c:98-99, pointer to agc.gain, RXA.c:364-378) reads
    // 20*log10(gain), gain = volts / out_target (wcpAGC.c:338).
    double volts = T * std::pow(10.0, meterDb / 20.0);
    volts = std::max(volts, minVolts);            // wcpAGC.c:335-336
    // The applied multiplier (wcpAGC.c:339-341):
    const double mult =
        (T - slopeK * std::min(0.0, std::log10(volts / s.maxInput))) / volts;
    return 20.0 * std::log10(mult);
}

}  // namespace lyra::dsp::coach
