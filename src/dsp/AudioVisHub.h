// Lyra — audio visualizer hub (sample rings + GUI-thread FFT analysis).
//
// The data path between the audio taps and the dock visualizer.  Two SPSC
// rings (lyra::dsp::MonitorRing, 16384 samples each): the RX ring is fed by
// the audio thread (post-RX-EQ, pre-volume tap, mixed to mono with
// vis::mixSample); the TX ring is fed by the cm_main TX pump (post-rack mic).
// The consumer is the GUI thread calling frame(), which drains the ring that
// setSource() selected into a 4096-sample sliding window, then runs the
// Hann window + radix-2 FFT there — never on the audio/TX threads.
//
// pushRx()/pushTx() are allocation-free and lock-free, and cost one relaxed
// atomic load while no consumer holds acquire() (hidden dock + closed
// Settings).  pushTx() also copies nothing unless the source is TX (MOX up on
// a voice/digital mode), so the TX pump pays one more relaxed load while the
// dock shows RX.  Non-finite samples (NaN / Inf from upstream DSP) are stored
// as 0 so one bad sample can never blank or saturate the whole spectrum.
// Overflow drops the newest samples (MonitorRing behaviour), so a stalled GUI
// can never block a real-time thread; frame() then discards the stale ring
// rather than show it as live (see frame()).
//
// Qt-free so it unit-tests standalone (scratch/test_audio_vis_hub.cpp).
// Fixed analysis rate: the RX tap and the TX mic rack both run at 48 kHz.

#pragma once

#include "dsp/MonitorRing.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <vector>

namespace lyra::dsp::vis {

// One analysed display frame.  dB values: 0 = full-scale sine, -200 = silence
// (a finite floor — never NaN / -inf).
struct Frame {
    float  lineDb[256];        // linear points across 0..spanHz (point i covers
                               //   [i, i+1) * spanHz / 256), peak-preserving
    float  bandsDb25[25];      // log-spaced bands, kLowHz..spanHz
    float  bandsDbRadial[24];  // log-spaced bands, kLowHz..spanHz
    float  scope[512];         // raw samples from the last rising zero-crossing
    double spanHz;             // the span actually used (clamped)
    bool   tx;                 // source shown is TX mic audio
    bool   live;               // samples arrived within the last 250 ms
};

class AudioVisHub {
public:
    static constexpr int    kFftSize    = 4096;
    static constexpr double kSampleRate = 48000.0;
    static constexpr double kLowHz      = 50.0;     // lowest band edge (bars/radial)
    static constexpr int    kLiveMs     = 250;

    static AudioVisHub &instance();

    // Consumer ref-count (GUI thread): the dock when visible, a Settings
    // thumbnail, ...  Taps are live while the count is > 0.  The 0 -> 1
    // transition discards stale ring contents and the analysis window.
    void acquire();
    void release();
    bool active() const noexcept { return consumers_.load(std::memory_order_relaxed) > 0; }

    // Audio thread.  `interleavedLR` = nframes L/R pairs.  Mixed to mono with
    // vis::mixSample.  Returns immediately when !active().
    void pushRx(const double *interleavedLR, int nframes,
                bool sub, bool muteRx1, bool muteRx2) noexcept;

    // TX pump thread.  n mono samples.  Returns immediately unless wantsTx().
    void pushTx(const double *mono, int n) noexcept;

    // Which ring frame() analyses (true = TX).  Any thread.
    void setSource(bool tx) noexcept { tx_.store(tx, std::memory_order_relaxed); }
    // True while a consumer is active AND the source is TX: the TX tap's
    // "worth copying" check (two relaxed loads, no lock).
    bool wantsTx() const noexcept {
        return active() && tx_.load(std::memory_order_relaxed);
    }

    // GUI thread only.  Drains the rings, analyses, fills `out` for `spanHz`
    // (clamped to 100 Hz .. Nyquist).  Returns false (out untouched) when the
    // hub is inactive; otherwise true.  When no samples arrived within the
    // last 250 ms, out.live == false and the frame is analysed from silence
    // (every dB value at the -200 floor, scope zero) — never a frozen last
    // spectrum.  A ring found full (the GUI stalled for longer than the
    // ring holds, so the newest audio was dropped and what is queued is
    // stale) is discarded and the window restarts from silence.
    bool frame(double spanHz, Frame &out);

    // GUI thread only.  Analyse caller-supplied mono samples (the latest
    // kFftSize are used; fewer are zero-padded in front) with the exact same
    // window/FFT/band/scope code as frame(), without touching the rings or
    // the ring window — works whether or not the hub is active (DemoSignal on
    // the idle dock, Settings thumbnails, remote desk).  Sets out.live = true,
    // out.tx = false.  Returns false (out untouched) only for null/empty input.
    bool analyse(const float *samples, int n, double spanHz, Frame &out);

    // Diagnostics: samples queued in each ring (unit tests, ring-untouched check).
    std::size_t rxPending() const noexcept { return rx_.available(); }
    std::size_t txPending() const noexcept { return tx_ring_.available(); }

    // Test support: back to the freshly constructed state (no consumers, both
    // rings and the window cleared, source RX).  GUI thread, with no producer
    // running concurrently.
    void reset();

private:
    AudioVisHub();
    AudioVisHub(const AudioVisHub &) = delete;
    AudioVisHub &operator=(const AudioVisHub &) = delete;

    void clearConsumerState();
    void fft();   // in-place radix-2 on re_/im_
    // kFftSize-sample window -> Frame; shared by frame() and analyse().
    void build(const double *win, double spanHz, bool tx, bool live, Frame &out);

    static constexpr std::size_t kRingSize = 16384;   // 341 ms at 48 k

    std::atomic<int>  consumers_{0};
    std::atomic<bool> tx_{false};
    MonitorRing       rx_{kRingSize};
    MonitorRing       tx_ring_{kRingSize};

    // ---- GUI-thread-only state (frame() / analyse()) ----
    std::vector<double> window_;       // kFftSize sliding sample window
    std::vector<double> anaWindow_;    // analyse() scratch window
    std::vector<double> hann_;         // analysis window
    double              hannSum_ = 1.0;
    std::vector<double> re_, im_;      // FFT work
    std::vector<double> cosT_, sinT_;  // twiddles, kFftSize/2
    std::vector<int>    rev_;          // bit-reversal permutation
    std::vector<float>  magDb_;        // kFftSize/2 + 1 bins, dB
    bool                lastTx_ = false;
    bool                haveData_ = false;
    std::chrono::steady_clock::time_point lastData_{};
};

// Voice-like formant signal for when no real audio is flowing (the dock's idle
// look, Settings thumbnails): a vibrato glottal source through three moving
// formant resonators under a syllable envelope.  Stateful — successive fill()
// calls continue the same signal.  Output within [-1, 1].
class DemoSignal {
public:
    void fill(float *dst, int n, double fs);

private:
    double t_ = 0.0;        // seconds
    double phase_ = 0.0;    // glottal phase 0..1
    double y1_[3] = {0, 0, 0}, y2_[3] = {0, 0, 0};
    double a1_[3] = {0, 0, 0}, a2_[3] = {0, 0, 0}, b0_[3] = {0, 0, 0};
    int    untilCoeff_ = 0;
};

}  // namespace lyra::dsp::vis
