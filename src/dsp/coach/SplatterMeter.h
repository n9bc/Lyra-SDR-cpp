// eSSB Coach splatter meter — measures the received station's out-of-channel
// energy from the RX1 IQ (demodulated audio cannot show energy beyond our own
// RX filter).  It
// compares the strongest 100 Hz band in a window just outside the station's
// channel with the strongest 100 Hz band inside it, at equal bandwidth.
//
// Pipeline: 16 384-point complex FFT of the IQ, Hann window, hop 8192; bin
// power is averaged with tau = 1 s.  Bands are 100 Hz wide (the same whole
// number of bins for both regions) and slide bin by bin.
//
// SIDEBAND CONVENTION (offsets in the complex baseband, taken as given):
//   USB : channel     [shiftHz,              shiftHz + edge]
//         out window  [shiftHz + edge + 500, shiftHz + edge + 3000]
//   LSB : mirrored to negative offsets
//         channel     [shiftHz - edge,       shiftHz]
//         out window  [shiftHz - edge - 3000, shiftHz - edge - 500]
// Any real-radio sign inversion (spectral inversion in the RX path, a swapped
// I/Q) is the caller's problem: this class takes the offset and sideband
// exactly as passed to setChannel().
//
// RESULT: peakDb = max in-channel 100 Hz band power, outDb = max out-window
// band power (both dB re full scale, power averaged), marginDb = peakDb -
// outDb, noiseDb = noise floor = median 100 Hz band power over the whole IQ
// span (the signal fills a small part of it, so the median is the floor).
//   valid : 3 s of IQ since prepare() / restart() / a channel change, the
//           out window fits (shiftHz +- (edge + 3000) inside +-iqRate/2),
//           and peakDb >= noiseDb + 10 dB (a real signal is present: silence
//           and noise-only input are never valid).
//   alert : valid && marginDb < 35 dB && outDb >= noiseDb + 6 dB (real
//           energy above the noise, not the noise itself).
// RE-ARMING: a channel change that alters shiftHz, edge or sideband clears
// the averaged spectrum and restarts the 3 s validity timer, and so does
// restart().  A VFO retune moves the DDC centre but may leave shiftHz
// unchanged, so the caller must call restart() on every frequency change.
// The result is invalid (not stale) from the next feed() on.
//
// THREADING
//   RX worker thread : feed()   (no allocation after prepare(); FFT and
//                      band maths run outside the publish lock)
//   GUI thread       : setChannel(), snapshot()
//   setChannel() writes a small seqlock-guarded parameter block (atomics
//   only); feed() applies it at its start, so the GUI never touches
//   worker-thread state.  Call setChannel() from one thread only.
//   snapshot() copies the published result under a short mutex that feed()
//   holds only for that copy.  prepare() must be called once, before IQ
//   starts, and is not realtime-safe.
//
// Qt-free + dependency-free so it unit-tests standalone.
#pragma once

#include <atomic>
#include <cmath>
#include <mutex>
#include <vector>

namespace lyra::dsp::coach {

struct SplatterResult {
    bool valid = false;
    double peakDb = NAN, outDb = NAN, marginDb = NAN, noiseDb = NAN;
    bool alert = false;   // see RESULT in the file header
};

class SplatterMeter {
public:
    static constexpr int kFftSize = 16384;
    static constexpr int kHop = 8192;
    static constexpr double kBandHz = 100.0;
    static constexpr double kOutNearHz = 500.0, kOutFarHz = 3000.0;
    static constexpr double kTauSec = 1.0;
    static constexpr double kMinDataSec = 3.0;
    static constexpr double kAlertMarginDb = 35.0;
    static constexpr double kPresentAboveNoiseDb = 10.0;   // peak vs floor, for valid
    static constexpr double kOutAboveNoiseDb = 6.0;        // out vs floor, for alert

    // Allocate every buffer and restart the averaging.  Not realtime-safe.
    void prepare(int iqRate);

    // GUI THREAD.  Channel offset and edge in Hz in the complex baseband;
    // see the sideband convention above.  Applied at the next feed().
    void setChannel(double shiftHz, bool upperSideband, double channelEdgeHz);

    // RX WORKER THREAD.  `iqInterleaved` = `frames` I,Q pairs in [-1, 1).
    // Any frame count; frames == 0 just applies a pending channel.
    void feed(const double *iqInterleaved, int frames);

    // GUI THREAD.  The IQ rate changed (after prepare()): feed() applies the
    // new rate on its own thread (bin width, band size, smoothing), drops the
    // averaged spectrum and re-arms the 3 s validity timer.  No allocation:
    // prepare() sized every buffer for the largest case.  Rates <= 0 are
    // ignored.
    void setRate(int iqRate);

    // GUI THREAD.  Drops the averaged spectrum and re-arms the 3 s validity
    // timer, applied at the next feed().  Call on every VFO / DDC retune.
    void restart();

    // GUI THREAD.  Copies the latest result into `out`; returns true iff
    // something new was published since the previous snapshot.
    bool snapshot(SplatterResult &out);

private:
    struct Channel { double shiftHz, edgeHz; bool usb; };

    bool applyChannel();                 // worker thread; true = re-arm needed
    bool applyRate();                    // worker thread; true = re-arm needed
    void setRateDerived(int rate);       // worker thread / prepare()
    void rearm();                        // worker thread
    void processFrame();                 // worker thread
    SplatterResult measure() const;      // worker thread, outside the lock
    static void fft(double *re, double *im, const std::vector<int> &rev,
                    const std::vector<double> &cs, const std::vector<double> &sn);

    int rate_ = 0;
    bool prepared_ = false;
    double binHz_ = 1.0, alpha_ = 1.0, winNorm_ = 1.0;
    int bandBins_ = 1;
    std::vector<double> win_, cs_, sn_;
    std::vector<int> rev_;

    // Worker-thread state.
    std::vector<double> ring_;           // 2 * kFftSize interleaved IQ
    int fill_ = 0;                       // frames in ring_
    std::vector<double> re_, im_;
    std::vector<double> avg_;            // averaged bin power, FFT order
    mutable std::vector<double> pre_;    // prefix sums, centred order
    mutable std::vector<double> floorScratch_;   // per-band powers for the median
    bool seeded_ = false;
    long long framesSeen_ = 0;
    Channel ch_{0.0, 6000.0, true};

    // GUI -> worker: seqlock (odd seq = write in progress).
    std::atomic<unsigned> chSeq_{0};
    std::atomic<double> reqShift_{0.0}, reqEdge_{6000.0};
    std::atomic<bool> reqUsb_{true};
    unsigned chSeen_ = 0, lastPubSeq_ = 0;   // worker-side
    std::atomic<int> reqRate_{0};
    std::atomic<unsigned> restartReq_{0};
    unsigned restartSeen_ = 0;

    std::mutex mtx_;
    SplatterResult pub_;
    bool dirty_ = false;
};

}  // namespace lyra::dsp::coach
