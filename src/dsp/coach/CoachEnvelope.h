// eSSB Coach envelope — the speech gate, noise floor and compression metrics.
//
// The coach taps our RX audio AFTER our own AGC, so the AGC's gain is removed
// first; otherwise our AGC swelling up between words would read as the other
// station's pumping and noise.  The gain is removed per sample, before the
// band filter (each push()'s gain scales that call's samples), so a block
// straddling two calls is corrected exactly.
//
// Per 10 ms block (480 samples at 48 kHz):
//   level   = RMS in dB of the audio band-limited to 100-5000 Hz
//             (2nd-order Butterworth high-pass + low-pass), AGC-corrected.
//   no-info = level <= kSilenceDb (digital silence: squelch, mute, buffer
//             underrun).  Such a block is skipped entirely: it does not
//             enter the floor window, the speech reference, the hangover or
//             the metrics, and is neither speech nor noise.
//   floor   = minimum of `level` over the last 2 s, plus kFloorBiasDb (the
//             minimum of 200 noise blocks sits ~1.5 dB under their mean).
//             It falls at once.  Once valid, a rise toward a SPEECH-LIKE
//             target (within kSpeechBelowRefDb of speechRef) is capped at
//             kFloorRiseDbPerSec, so flat (heavily compressed) speech longer
//             than the window does not drag it up; a rise toward a
//             noise-like target is free, so a floor knocked low by a
//             partial dropout or a quiet prefix recovers as soon as that
//             block leaves the window.  Before it is valid it follows the
//             window minimum freely (cold start).
//   valid   = an active block has been seen since reset (so the floor has
//             been seen from below speech at least once).
//   speechRef = running level of active blocks (one-pole in dB, tau
//             kSpeechRefTauSec of active blocks); decays kSpeechRefDecayDbPerSec
//             while blocks are not active, never below floor + 10 dB.
//   active  = level >= floor + kSpeechAboveFloorDb
//             AND level >= speechRef - kSpeechBelowRefDb (before speechRef
//             exists, the loudest level in the floor window stands in).  The second condition keeps pumped
//             noise, which climbs well above the floor but stays well under
//             the speech, from opening the gate.
//   speech  = active, or within kHangoverSec after the last active block.
//   noise   = valid, not speech, and level <= floor + kNoiseNearFloorDb (a
//             positive test: it really sits at the floor).
//
// Compression metrics (per accumulation, from histograms so a recording of
// any length costs no allocation).  "Speech level" uses the ACTIVE blocks
// only: hangover blocks are word tails at gap level, and counting them would
// drag the speech median down and falsely flag noise between short words.
// "Gap" blocks are the non-speech blocks (hangover excluded from both).
//   gapToSpeechDb = median speech-level block - median gap block.
//   gapRiseDb     = median over pauses >= 800 ms of
//                   mean(level 650-800 ms after speech end)
//                   - mean(level 0-150 ms after speech end).
//                   "Speech end" is the last active block, so the hangover
//                   is inside the pause for this metric.
//   crestDb       = 99th-percentile speech-level block - median speech-level
//                   block.
//                   If the gate re-opens before 800 ms on a smooth ramp
//                   (level up < kOnsetStepDb over the last kOnsetSpanSec,
//                   unlike a word onset) after the early window, that is
//                   pumping strong enough to reach speech level: the pause
//                   is scored as max(recent - early, kSpeechAboveFloorDb).
//   pauses        = pauses scored.
//   Any metric with no data is NaN.
//
// LIMITATION: pumped noise that climbs to within kSpeechBelowRefDb of the
// speech level counts as speech.  Syllables more than kSpeechBelowRefDb
// under the running speech level count as speech only through the hangover.
//
// Audio thread only; prepare() allocates, nothing else does.  Qt-free.
#pragma once

#include <cmath>
#include <cstdint>
#include <vector>

namespace lyra::dsp::coach {

// ---- gate / floor ----------------------------------------------------------
inline constexpr double kBlockSec = 0.010;
inline constexpr double kEnvLoHz = 100.0;
inline constexpr double kEnvHiHz = 5000.0;
inline constexpr double kFloorWindowSec = 2.0;
inline constexpr double kFloorBiasDb = 1.5;
inline constexpr double kSpeechAboveFloorDb = 10.0;
inline constexpr double kSilenceDb = -120.0;
inline constexpr double kFloorRiseDbPerSec = 2.0;
inline constexpr double kSpeechBelowRefDb = 15.0;
inline constexpr double kSpeechRefTauSec = 1.0;
inline constexpr double kSpeechRefDecayDbPerSec = 1.0;
inline constexpr double kNoiseNearFloorDb = 6.0;
inline constexpr double kHangoverSec = 0.200;
// An FFT frame is speech when this share of its samples lies in speech
// blocks; it is noise only when every one of its blocks is a noise block
// (frames in between are dropped).
inline constexpr double kSpeechFrameFraction = 0.70;
// Noise is subtracted from speech band power as power, floored here
// (relative to the speech power).
inline constexpr double kNoiseSubFloorDb = -60.0;

// ---- compression metrics ---------------------------------------------------
inline constexpr double kMinPauseSec = 0.800;
inline constexpr double kRiseEarlyFromSec = 0.0, kRiseEarlyToSec = 0.150;
inline constexpr double kRiseLateFromSec = 0.650, kRiseLateToSec = 0.800;
inline constexpr double kCrestPercentile = 0.99;
inline constexpr double kOnsetStepDb = 8.0;     // smooth re-open: rise below this...
inline constexpr double kOnsetSpanSec = 0.050;  // ...over this span

// ---- advisor flag defaults (Task 5; editable in Settings) ------------------
inline constexpr double kGapToSpeechFlagDb = 25.0;  // gap-to-speech below: noise between words
inline constexpr double kGapRiseFlagDb = 6.0;       // gap rise above: compressor pumping
inline constexpr double kCrestFlagDb = 8.0;         // crest below: over-squashed

struct CompressionMetrics {
    double gapToSpeechDb = NAN, gapRiseDb = NAN, crestDb = NAN;
    int pauses = 0;
};

// Fixed-range histogram of dB values; quantiles to within one step.
class LevelHistogram {
public:
    void init(double loDb, double hiDb, double stepDb);   // allocates
    void clear();
    void add(double db);                                  // clamps into range
    long long count() const { return total_; }
    double quantile(double q) const;                      // NaN when empty

private:
    std::vector<std::uint32_t> bins_;
    double lo_ = 0.0, step_ = 1.0;
    long long total_ = 0;
};

// Accumulates the compression metrics from a stream of gated blocks.
class EnvelopeStats {
public:
    void prepare(double blockSec);   // allocates
    void reset();
    void add(double levelDb, bool active, bool speech);
    CompressionMetrics metrics() const;

private:
    static constexpr int kRing = 16;   // recent levels, for the onset test
    LevelHistogram speech_, gap_, rise_;
    int earlyFrom_ = 0, earlyTo_ = 0, lateFrom_ = 0, lateTo_ = 0, recordAt_ = 0;
    int onsetSpan_ = 5;
    double ring_[kRing] = {};
    long long nRing_ = 0;
    long sinceActive_ = -1;   // blocks since the last active one; -1 = none yet
    double earlySum_ = 0.0, lateSum_ = 0.0;
    int earlyN_ = 0, lateN_ = 0, pauses_ = 0;
};

class CoachEnvelope {
public:
    struct Block {
        double levelDb = 0.0;   // AGC-corrected
        bool active = false, speech = false, noise = false;
        bool noInfo = false;    // digital silence / unknown AGC gain: ignored by everything
    };
    static constexpr int kHistory = 64;   // blocks kept for block()

    explicit CoachEnvelope(double fs);
    void prepare();

    // Consumes n samples (any n); returns true iff the newest completed
    // 10 ms block is speech.  agcGainDb is our AGC's gain for these n
    // samples; it is removed from them before they enter the block power.
    // NaN / inf = unknown: no correction, and the blocks they land in are
    // noInfo (kept out of the floor, the gate and the compression metrics).
    bool push(const double *mono, int n, double agcGainDb);

    double noiseFloorDb() const;          // NaN before the first block
    double speechRefDb() const { return ref_; }   // NaN before speech
    bool floorValid() const { return valid_; }
    CompressionMetrics metrics() const;   // since prepare()/reset()
    void reset();

    int blockSize() const { return blockN_; }
    long long samplesPushed() const { return samples_; }
    long long blocksDone() const { return blocks_; }
    // Block idx; valid for blocksDone()-kHistory <= idx < blocksDone().
    const Block &block(long long idx) const { return hist_[idx % kHistory]; }

private:
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
        double run(double x) {
            const double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
    };
    void endBlock();

    double fs_;
    int blockN_ = 480, hangBlocks_ = 20;
    double riseCap_ = 0.0, refAlpha_ = 0.0, refDecay_ = 0.0;   // per block
    Biquad hp_, lp_;
    double acc_ = 0.0;
    int accN_ = 0;
    bool gainUnknown_ = false;   // the open block holds an unknown-gain sample
    long long samples_ = 0, blocks_ = 0;
    std::vector<double> win_;   // floor window ring of corrected levels
    int winPos_ = 0, winFill_ = 0;
    double floor_ = NAN, ref_ = NAN;
    bool valid_ = false;
    int hang_ = 0;
    bool lastSpeech_ = false;
    Block hist_[kHistory];
    EnvelopeStats stats_;
};

}  // namespace lyra::dsp::coach
