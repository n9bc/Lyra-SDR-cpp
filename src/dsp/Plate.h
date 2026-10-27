// Lyra — native TX Plate Reverb (Schroeder-Moorer).  Task #52.
//
// The last operator-toggleable native rack stage: a plate-class reverb for
// the ESSB "broadcast air" sound.  Chain: EQ -> Combinator -> Plate -> ALC
// (Plate BEFORE the always-on limiter so reverb-tail peaks are caught and a
// future PureSignal predistorter isn't confused).  Lyra-native DSP
// (standard Schroeder-Moorer comb/allpass topology — NOT a port; the
// reference unit's algorithm is reproduced from its documented param set,
// not copied).  See docs/architecture/plate_design.md + the locked presets
// in tx1_ssb_design.md §11.
//
// Topology: pre-delay -> 6 parallel Moorer combs (each delay + one-pole
// LPF-damped feedback) -> 4 series allpass diffusers -> wet tone (BASS
// low-shelf + TREB high-shelf) -> MIX wet/dry.
//
// Signal: mono mic on the real (I) channel of {I=mic, Q=0} doubles — same
// processInterleaved(double*, int) contract as the other rack stages.
//
// Threading: operator/UI thread calls the setters (atomic scalars); the
// audio thread calls processInterleaved(), which reads the atomics once at
// block start and derives the per-comb/allpass/shelf coefficients there (no
// locks — derivation is a handful of cheap ops).  Delay/filter STATE is
// audio-thread-owned.

#pragma once

#include <array>
#include <atomic>
#include <vector>

namespace lyra::dsp {

class Plate {
public:
    static constexpr int kNumCombs   = 6;
    static constexpr int kNumAllpass = 4;

    Plate();

    void setSampleRate(double fs);   // (re)allocates the delay buffers
    void setBypass(bool on);         // whole-stage skip (true = pass-through)

    void setPreDelayS(double s);     // 0..0.100 s
    void setDecayS(double s);        // 0.1..5.0 s (RT60)
    void setDamp(double v);          // 1..100 (HF damping in the comb feedback)
    void setSize(double v);          // 1..100 (scales the delay lengths)
    void setDensity(double v);       // 1..100 (allpass coefficient)
    void setDiff(double v);          // 1..100 (allpass diffusion / delay spread)
    void setBassDb(double db);       // wet low-shelf, +/-18 dB
    void setTrebDb(double db);       // wet high-shelf, +/-18 dB
    void setMix(double frac);        // 0..1 wet/dry

    void processInterleaved(double *iqPairs, int nPairs);
    void reset();                    // clear all delay + filter state
    // Ask the audio thread to reset() at the start of its next
    // processInterleaved() call (eSSB practice loop: drop the clip's reverb
    // tail before it can reach TXA).  One atomic store — safe from any
    // thread, including the cm TX thread; the state itself is only ever
    // cleared on the audio thread.  Consumed even while bypassed.
    void requestReset() noexcept { resetReq_.store(true, std::memory_order_release); }

private:
    struct Shelf { double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0; double z1 = 0, z2 = 0; };
    static void designLowShelf(Shelf &s, double fs, double f0, double gainDb);
    static void designHighShelf(Shelf &s, double fs, double f0, double gainDb);
    static inline double runShelf(Shelf &s, double x) {
        const double y = s.b0 * x + s.z1;
        s.z1 = s.b1 * x - s.a1 * y + s.z2;
        s.z2 = s.b2 * x - s.a2 * y;
        return y;
    }

    double fs_ = 48000.0;
    std::atomic<bool> bypass_{false};
    std::atomic<bool> resetReq_{false};   // requestReset() -> next process call

    std::atomic<double> preDelayS_{0.010};
    std::atomic<double> decayS_{1.542};
    std::atomic<double> damp_{15.0};
    std::atomic<double> size_{10.0};
    std::atomic<double> density_{20.0};
    std::atomic<double> diff_{20.0};
    std::atomic<double> bassDb_{-16.0};
    std::atomic<double> trebDb_{16.0};
    std::atomic<double> mix_{0.15};

    // Base delay lengths (samples @ 48 kHz), mutually-prime-ish; scaled by SIZE.
    std::array<int, kNumCombs>   baseComb_{ {1214, 1293, 1390, 1476, 1548, 1623} };
    std::array<int, kNumAllpass> baseAp_  { {245, 371, 480, 605} };

    // Delay buffers (allocated for the max SIZE scale at setSampleRate).
    std::array<std::vector<double>, kNumCombs>   combBuf_;
    std::array<int, kNumCombs>    combWrite_{};
    std::array<double, kNumCombs> combLp_{};       // one-pole LPF store per comb
    std::array<std::vector<double>, kNumAllpass> apBuf_;
    std::array<int, kNumAllpass>  apWrite_{};
    std::vector<double> preBuf_;
    int preWrite_ = 0;

    Shelf bass_{}, treb_{};
    // Cached shelf params so coeffs recompute only when BASS/TREB change.
    double bassCached_ = 1e9, trebCached_ = 1e9;
};

}  // namespace lyra::dsp
