// Lyra — eSSB Coach: model of what WDSP's RXA chain does to the AGC gain
// between the AGC stage and the channel's audio output.  No Qt, no WDSP calls:
// pure functions over a mirror of the RXA state, so they can be unit-tested.
//
// Derived from WDSP 2.00 (the engine tools/build_wdsp_macos.sh builds);
// source lines are cited in RxaAgcModel.cpp.  Two questions:
//
//   rxaPostAgcLatencySamples(): how many samples (dsp rate) the RXA output
//     lags the AGC stage's output, from the stages after xwcpagc in xrxa.
//     NaN when a stage that may run there has no latency derivable from source.
//
//   rxaAgcAppliedGainDb(): the gain (dB) the AGC actually applies to a sample,
//     given the RXA_AGC_GAIN meter reading.  The meter is NOT the applied gain:
//     it reads 20*log10(volts / out_target), the AGC's envelope relative to its
//     target, and the applied multiplier is a function of volts.

#pragma once

namespace lyra::dsp::coach {

// RXA mode numbers (RXA.h rxaMode).
inline constexpr int kRxaLsb = 0, kRxaUsb = 1, kRxaFm = 5, kRxaAm = 6, kRxaSam = 10,
                     kRxaWbfm = 12;

// Mirror of the RXA state that matters.  Defaults = WDSP create_rxa defaults.
struct RxaState {
    int dspSize = 4096;      // ch dsp_size
    int dspRate = 48000;
    int outRate = 48000;
    int mode = kRxaLsb;      // rxa.mode (create default RXA_LSB)

    // AGC (wcpagc) — create_wcpagc defaults (RXA.c create_rxa).
    int agcMode = 3;               // 0 = FIXD (fixed gain)
    double fixedGainDb = 60.0;     // fixed_gain 1000.0
    double maxGainDb = 80.0;       // max_gain 10000.0 (GetRXAAGCTop reads it)
    double varGain = 1.5;          // var_gain (SetRXAAGCSlope: 10^(slope/200))
    double outTarg = 1.0;
    int nTau = 4;
    double maxInput = 1.0;

    // Stages that can sit after the AGC.
    bool emnrRun = false;
    int emnrPosition = 0;
    int emnrFsize = 4096, emnrOvrlp = 4;   // create_emnr fixed args
    bool anfRun = false;
    int anfPosition = 0;
    bool anrRun = false;
    int anrPosition = 0;
    bool snbaRun = false;
    int bp1Position = 0;       // set by SetRXAEMNRPosition / SetRXAANFPosition
    bool bp1MinPhase = false;  // RXASetMP -> SetRXABandpassMP
    bool speakRun = false;     // bi-quad peaking filter (SetRXABiQuadRun, CW APF)
    bool mpeakRun = false, cblRun = false, doublepoleRun = false,
         matchedRun = false, gaussianRun = false;
    bool nnrRun = false;       // neural NR: not part of the WDSP 2.00 source
};

// Samples (at dsp rate) by which the RXA output lags the AGC output; NaN
// when not derivable from the WDSP source.
double rxaPostAgcLatencySamples(const RxaState &s);

// The AGC gain (dB) applied at the sample whose RXA_AGC_GAIN meter reading is
// `meterDb`.  NaN for a non-finite reading.
double rxaAgcAppliedGainDb(double meterDb, const RxaState &s);

}  // namespace lyra::dsp::coach
