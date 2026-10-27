// eSSB Coach analyzer — turns the post-AGC RX1 audio into the 1/6-octave
// band curves the advisor compares against a target: a smoothed live trace
// plus equal-weight running means for the Baseline and Re-check recordings.
//
// Pipeline: 4096-point Hann FFT, hop 2048.  Band power = bin power over
// [loHz, hiHz) of makeBands(40, 12000), edge bins weighted by their fractional
// overlap.  The bands are fixed: the advisor masks bands outside the RX passband, so a filter change never
// re-prepares the analyzer.
//
// SPEECH GATE (CoachEnvelope.h): every sample also goes through the 10 ms
// envelope, AGC-corrected.  Once all the 10 ms blocks a frame covers are
// decided (at most one block later), the frame is classified:
//   speech : >= 70 % of its samples in speech blocks -> baseline / re-check
//            band means, speechSec;
//   noise  : every block a noise block (at the floor; never before the
//            floor is valid) -> per-band noise means;
//   else   : dropped (word edges: half speech, half gap; frames touching a
//            no-information block: digital silence, or a block fed with a
//            non-finite AGC gain, which is how the engine marks unknown gain,
//            our own transmit and non-voice modes).
// The live trace is not gated.  Baseline/re-check curves are
// max(speech - noise, speech * 10^(kNoiseSubFloorDb/10)) per band, where
// noise is that recording's own noise mean, or, before it has a noise
// frame, a 2 s running average of all noise frames.  bandSnrDb /
// medianSnrDb (median over bands centred in 100-5000 Hz) come from the
// baseline; NaN / empty while the baseline has no speech or no noise
// estimate.  comp / recheckComp are the envelope metrics over blocks fed
// while that recording ran.
//
// LAP: whenever a running re-check ends -- a stop, or a start that overtakes
// it (including a stop+start that coalesced) -- its curve, speech time and
// compression are kept as the lap, tagged with the id startRecheck() returned
// when it began.  The lap survives the next start and is replaced only by the
// next ended re-check; reset() clears it.  The eSSB practice loop uses it to
// capture each loop pass without a gap between passes.
//
// THREADING
//   audio thread : feed()                                  (no allocation)
//   GUI thread   : snapshot(), reset(), startBaseline(), stopBaseline(),
//                  startRecheck(), stopRecheck(), freeze()
//   The GUI-thread calls only post a request into an atomic; feed() applies
//   it at its start, so they never touch audio-thread state.  Requests take
//   effect in the order they were issued: a reset() discards every
//   start/stop issued before it and not yet applied, and start/stop issued
//   after it apply after it ("startBaseline(); reset();" ends Idle,
//   "reset(); startBaseline();" ends Running).  Per channel the newest
//   start/stop wins, so "stopRecheck(); startRecheck();" posted between two
//   feed() calls is just a start; the re-check it ends is still kept as the
//   LAP below.  Call them from one GUI thread only.  snapshot()
//   copies the published curves under a short mutex that feed() holds only
//   for the copy into the publish buffers, never for FFT math.
//   prepare() must be called once (before audio starts) and sizes everything.
//
// Qt-free + dependency-free so it unit-tests standalone.
#pragma once

#include <atomic>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <vector>

#include "dsp/coach/CoachEnvelope.h"
#include "dsp/coach/CoachTarget.h"

namespace lyra::dsp::coach {

enum class AvgState { Idle, Running, Stopped };

struct CoachSnapshot {
    BandLayout bands;
    // Normalised (mid-band mean = 0) dB curves; an empty vector means
    // "no data yet".
    std::vector<double> liveDb, baselineDb, recheckDb;
    AvgState baseline = AvgState::Idle;
    AvgState recheck = AvgState::Idle;
    // Gated speech seconds since the baseline / re-check started.
    double speechSec = 0.0, recheckSpeechSec = 0.0;
    // Baseline in-band SNR: per band (empty = unknown) and the median over
    // bands centred in 100-5000 Hz (NaN = unknown, e.g. no speech yet).
    double medianSnrDb = NAN;
    std::vector<double> bandSnrDb;
    // Envelope metrics of the baseline / re-check (NaN fields = no data).
    CompressionMetrics comp, recheckComp;
    bool frozen = false;
    // The last re-check that ended (see LAP).  lapId = the id startRecheck()
    // returned for it, 0 = none; lapDb empty = it gated no speech.
    std::uint64_t lapId = 0;
    std::vector<double> lapDb;
    double lapSpeechSec = 0.0;
    CompressionMetrics lapComp;
};

class CoachAnalyzer {
public:
    static constexpr int kFftSize = 4096;
    static constexpr int kHop = 2048;
    static constexpr int kBins = kFftSize / 2 + 1;   // DC .. Nyquist

    explicit CoachAnalyzer(double fs = 48000.0);

    // Allocate every buffer.  Call before feed() starts; not realtime-safe.
    void prepare();

    // AUDIO THREAD.  `mono` = n post-AGC samples; blocks of any size are
    // consumed in chunks of at most kFftSize.  agcGainDb is our AGC's gain
    // for these samples; it is removed from the envelope before the speech
    // gate and the compression metrics (spectral shape needs no correction).
    // n == 0 just applies pending requests.
    void feed(const double *mono, int n, double agcGainDb);

    // GUI THREAD.  Copies the latest published state into `out`; returns true
    // iff something new was published since the previous snapshot.
    bool snapshot(CoachSnapshot &out);

    // GUI THREAD: requests, applied at the start of the next feed(), in the
    // order issued (see THREADING).
    void reset();                // clears live, baseline, re-check, gate, noise
    void startBaseline();        // clears and starts the baseline mean
    void stopBaseline();
    // Returns this re-check's id (nonzero, increasing), the lapId it will
    // carry once it ends.
    std::uint64_t startRecheck();
    void stopRecheck();
    void freeze(bool on);        // holds the displayed live trace

private:
    enum Cmd { kNone = 0, kStart = 1, kStop = 2 };

    std::uint64_t post(std::atomic<std::uint64_t> &slot, int cmd);   // GUI thread; returns the seq
    void applyRequests();                       // audio thread
    void doReset();                             // audio thread
    void forwardBlocks();                       // audio thread
    void processFrame();                        // audio thread
    void classifyPending(bool force);           // audio thread
    void publish();                             // audio thread
    void captureLap();                          // audio thread: running re-check -> lap
    // Per-band noise power for a recording (its own mean, else the running
    // average); nullptr when there is no noise estimate yet.
    const double *noisePowFor(const std::vector<double> &noiseSum, long noiseFrames);
    // Noise-subtracted speech mean of one recording into stagePow_.
    void speechPow(const std::vector<double> &sum, long frames,
                   const std::vector<double> &noiseSum, long noiseFrames);
    void curveDb(const std::vector<double> &pow, double scale,
                 std::vector<double> &dbOut);   // audio thread, no allocation
    static void fft(double *re, double *im);

    double fs_;
    bool prepared_ = false;

    BandLayout bands_;
    std::vector<double> win_;
    double winPowNorm_ = 1.0;
    // Per band: bins [firstBin, endBin) with fractional edge weights (the
    // share of each bin's frequency interval that lies inside the band).
    std::vector<int> firstBin_, endBin_;
    std::vector<std::vector<double>> bandWeights_;

    // Audio-thread state.
    std::vector<double> buf_, re_, im_, binPow_;
    int fill_ = 0;
    double alpha_ = 1.0;                         // live smoothing per hop
    std::vector<double> livePow_;
    bool liveSeeded_ = false;
    std::vector<double> basePow_, recPow_;       // sums of speech-frame power
    long baseFrames_ = 0, recFrames_ = 0;
    std::vector<double> baseNoise_, recNoise_;   // sums of noise-frame power
    long baseNoiseFrames_ = 0, recNoiseFrames_ = 0;
    std::vector<double> noiseAvg_;               // running noise, all frames
    bool noiseSeeded_ = false;
    double noiseAlpha_ = 1.0;
    AvgState baseState_ = AvgState::Idle, recState_ = AvgState::Idle;
    bool frozenA_ = false;
    // Speech gate: the envelope sees every sample; a finished frame waits in
    // pendingPow_ until the blocks it covers are decided.
    CoachEnvelope env_;
    EnvelopeStats baseStats_, recStats_;
    long long fwdBlocks_ = 0;                    // envelope blocks forwarded
    std::vector<double> pendingPow_;
    long long pendingEnd_ = 0;                   // envelope sample index
    bool pending_ = false;
    std::uint64_t lastResetSeq_ = 0;
    std::uint64_t recStartSeq_ = 0;              // seq of the start that began the re-check
    std::uint64_t lapId_ = 0;                    // lap (audio thread)
    bool lapHas_ = false;
    double lapSpeechSec_ = 0.0;
    CompressionMetrics lapComp_;
    std::vector<double> stageLap_;
    std::vector<double> stageLive_, stageBase_, stageRec_, stagePow_, stageNoise_,
        stageSnr_, snrScratch_;                             // publish staging

    // GUI -> audio requests: (sequence << 2) | Cmd, 0 = none.  The sequence
    // orders them against reset (see THREADING).
    std::atomic<std::uint64_t> seq_{0};
    std::atomic<std::uint64_t> baseReq_{0}, recReq_{0}, resetReq_{0};
    std::atomic<bool> frozenReq_{false};

    // Published to the GUI under mtx_.
    std::mutex mtx_;
    CoachSnapshot pub_;
    bool pubHasLive_ = false, pubHasBase_ = false, pubHasRec_ = false, pubHasSnr_ = false,
         pubHasLap_ = false;
    std::vector<double> pubLive_, pubBase_, pubRec_, pubSnr_, pubLap_;
    bool dirty_ = false;
};

}  // namespace lyra::dsp::coach
