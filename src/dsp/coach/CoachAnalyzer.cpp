// eSSB Coach analyzer.  See CoachAnalyzer.h for the threading contract.

#include "dsp/coach/CoachAnalyzer.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace lyra::dsp::coach {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kLiveTauSec = 0.3;
constexpr double kNoiseTauSec = 2.0;   // running noise average (fallback)
constexpr double kSnrLoHz = 100.0, kSnrHiHz = 5000.0;
constexpr double kPowerFloor = 1e-18;   // -180 dB, keeps log10 finite
}  // namespace

CoachAnalyzer::CoachAnalyzer(double fs) : fs_(fs > 0.0 ? fs : 48000.0), env_(fs_) {}

void CoachAnalyzer::prepare() {
    bands_ = makeBands(40.0, 12000.0);
    const int nb = bands_.size();

    win_.resize(kFftSize);
    double sum = 0.0;
    for (int i = 0; i < kFftSize; ++i) {
        win_[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (kFftSize - 1));  // Hann
        sum += win_[i];
    }
    // Amplitude-correct normaliser (sum/2); power divides by its square.
    const double amp = sum > 0.0 ? sum * 0.5 : 1.0;
    winPowNorm_ = amp * amp;

    const double binHz = fs_ / kFftSize;
    firstBin_.assign(nb, 0);
    endBin_.assign(nb, 0);
    bandWeights_.assign(nb, {});
    for (int b = 0; b < nb; ++b) {
        // Bin k owns the interval [(k-0.5)*binHz, (k+0.5)*binHz).  The band
        // takes each overlapping bin's power weighted by the fraction of that
        // interval inside [loHz, hiHz).  A hard "centre inside the band" rule
        // would make a ~1-bin-wide band swing by whole bins (up to +-3 dB on
        // pink noise near 100-150 Hz) and leave bands under 40 Hz-ish with
        // no bin at all; fractional edges give the same answer for wide
        // bands and a smooth one for narrow bands.
        const double lo = bands_.loHz[b] / binHz, hi = bands_.hiHz[b] / binHz;
        const int first = std::clamp(static_cast<int>(std::floor(lo + 0.5)), 0, kBins - 1);
        const int last = std::clamp(static_cast<int>(std::floor(hi + 0.5)), first, kBins - 1);
        firstBin_[b] = first;
        endBin_[b] = last + 1;
        std::vector<double> &w = bandWeights_[b];
        for (int k = first; k <= last; ++k) {
            const double ov = std::min(hi, k + 0.5) - std::max(lo, k - 0.5);
            w.push_back(std::max(ov, 0.0));
        }
    }

    buf_.assign(kFftSize, 0.0);
    re_.assign(kFftSize, 0.0);
    im_.assign(kFftSize, 0.0);
    binPow_.assign(kBins, 0.0);
    livePow_.assign(nb, 0.0);
    basePow_.assign(nb, 0.0);
    recPow_.assign(nb, 0.0);
    baseNoise_.assign(nb, 0.0);
    recNoise_.assign(nb, 0.0);
    noiseAvg_.assign(nb, 0.0);
    pendingPow_.assign(nb, 0.0);
    stageLive_.assign(nb, 0.0);
    stageBase_.assign(nb, 0.0);
    stageRec_.assign(nb, 0.0);
    stageLap_.assign(nb, 0.0);
    stagePow_.assign(nb, 0.0);
    stageSnr_.assign(nb, 0.0);
    stageNoise_.assign(nb, 0.0);
    snrScratch_.assign(nb, 0.0);
    pubLive_.assign(nb, 0.0);
    pubBase_.assign(nb, 0.0);
    pubRec_.assign(nb, 0.0);
    pubSnr_.assign(nb, 0.0);
    pubLap_.assign(nb, 0.0);
    pub_ = CoachSnapshot{};
    pub_.bands = bands_;

    const double hopSec = static_cast<double>(kHop) / fs_;
    alpha_ = 1.0 - std::exp(-hopSec / kLiveTauSec);
    noiseAlpha_ = 1.0 - std::exp(-hopSec / kNoiseTauSec);
    env_.prepare();
    baseStats_.prepare(env_.blockSize() / fs_);
    recStats_.prepare(env_.blockSize() / fs_);
    lastResetSeq_ = 0;
    doReset();
    frozenA_ = false;
    prepared_ = true;
    publish();
}

// ---- GUI-thread requests ---------------------------------------------------

// Each request carries the next sequence number so feed() can apply them in
// issue order relative to reset().
std::uint64_t CoachAnalyzer::post(std::atomic<std::uint64_t> &slot, int cmd) {
    const std::uint64_t seq = seq_.fetch_add(1) + 1;
    slot.store((seq << 2) | static_cast<std::uint64_t>(cmd));
    return seq;
}

void CoachAnalyzer::reset()         { post(resetReq_, kStart); }   // cmd bits unused
void CoachAnalyzer::startBaseline() { post(baseReq_, kStart); }
void CoachAnalyzer::stopBaseline()  { post(baseReq_, kStop); }
std::uint64_t CoachAnalyzer::startRecheck() { return post(recReq_, kStart); }
void CoachAnalyzer::stopRecheck()   { post(recReq_, kStop); }
void CoachAnalyzer::freeze(bool on) { frozenReq_.store(on); }

bool CoachAnalyzer::snapshot(CoachSnapshot &out) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (!dirty_) return false;
    out.bands = pub_.bands;
    out.liveDb.assign(pubLive_.begin(), pubLive_.begin() + (pubHasLive_ ? pubLive_.size() : 0));
    out.baselineDb.assign(pubBase_.begin(), pubBase_.begin() + (pubHasBase_ ? pubBase_.size() : 0));
    out.recheckDb.assign(pubRec_.begin(), pubRec_.begin() + (pubHasRec_ ? pubRec_.size() : 0));
    out.baseline = pub_.baseline;
    out.recheck = pub_.recheck;
    out.speechSec = pub_.speechSec;
    out.recheckSpeechSec = pub_.recheckSpeechSec;
    out.medianSnrDb = pub_.medianSnrDb;
    out.bandSnrDb.assign(pubSnr_.begin(), pubSnr_.begin() + (pubHasSnr_ ? pubSnr_.size() : 0));
    out.comp = pub_.comp;
    out.recheckComp = pub_.recheckComp;
    out.frozen = pub_.frozen;
    out.lapId = pub_.lapId;
    out.lapDb.assign(pubLap_.begin(), pubLap_.begin() + (pubHasLap_ ? pubLap_.size() : 0));
    out.lapSpeechSec = pub_.lapSpeechSec;
    out.lapComp = pub_.lapComp;
    dirty_ = false;
    return true;
}

// ---- audio thread ----------------------------------------------------------

void CoachAnalyzer::doReset() {
    std::fill(basePow_.begin(), basePow_.end(), 0.0);
    std::fill(recPow_.begin(), recPow_.end(), 0.0);
    std::fill(baseNoise_.begin(), baseNoise_.end(), 0.0);
    std::fill(recNoise_.begin(), recNoise_.end(), 0.0);
    std::fill(noiseAvg_.begin(), noiseAvg_.end(), 0.0);
    baseFrames_ = recFrames_ = baseNoiseFrames_ = recNoiseFrames_ = 0;
    noiseSeeded_ = false;
    baseState_ = recState_ = AvgState::Idle;
    baseStats_.reset();
    recStats_.reset();
    env_.reset();
    fwdBlocks_ = 0;
    pending_ = false;
    liveSeeded_ = false;
    fill_ = 0;
    recStartSeq_ = 0;
    lapId_ = 0;
    lapHas_ = false;
    lapSpeechSec_ = 0.0;
    lapComp_ = CompressionMetrics();
}

// The running re-check ends: keep its results as the lap (see LAP).  Called
// before a start clears it or a stop freezes it.  No allocation: stageLap_ is
// sized in prepare() and the metrics are a plain struct.
void CoachAnalyzer::captureLap() {
    lapHas_ = recFrames_ > 0;
    if (lapHas_) {
        speechPow(recPow_, recFrames_, recNoise_, recNoiseFrames_);
        curveDb(stagePow_, 1.0, stageLap_);
    }
    lapSpeechSec_ = recFrames_ * (static_cast<double>(kHop) / fs_);
    lapComp_ = recStats_.metrics();
    lapId_ = recStartSeq_;
}

void CoachAnalyzer::applyRequests() {
    // Read the channels BEFORE the reset slot.  A start/stop seen here was
    // stored before any reset we are about to see, unless its sequence
    // number says otherwise, so comparing numbers recovers issue order.  A
    // stale command that was overtaken by a reset applied in an earlier
    // feed() is caught by lastResetSeq_.
    const std::uint64_t br = baseReq_.exchange(0);
    const std::uint64_t rr = recReq_.exchange(0);
    const std::uint64_t rs = resetReq_.exchange(0);
    bool changed = false;
    if (rs) {
        lastResetSeq_ = std::max(lastResetSeq_, rs >> 2);
        doReset();
        changed = true;
    }
    const auto apply = [&](std::uint64_t req, AvgState &state, std::vector<double> &pow,
                           long &frames, std::vector<double> &noise, long &noiseFrames,
                           EnvelopeStats &stats) {
        if (!req || (req >> 2) < lastResetSeq_) return;   // issued before a reset
        const int cmd = static_cast<int>(req & 3u);
        if (cmd == kStart) {
            std::fill(pow.begin(), pow.end(), 0.0);
            std::fill(noise.begin(), noise.end(), 0.0);
            frames = noiseFrames = 0;
            stats.reset();
            state = AvgState::Running;
            changed = true;
        } else if (cmd == kStop && state == AvgState::Running) {
            state = AvgState::Stopped;
            changed = true;
        }
    };
    apply(br, baseState_, basePow_, baseFrames_, baseNoise_, baseNoiseFrames_, baseStats_);
    // Any live start/stop ends a running re-check: keep it as the lap first.
    // (A stop+start posted back to back arrives here as the start alone.)
    const bool recLive = rr && (rr >> 2) >= lastResetSeq_;
    if (recLive && recState_ == AvgState::Running) captureLap();
    apply(rr, recState_, recPow_, recFrames_, recNoise_, recNoiseFrames_, recStats_);
    if (recLive && static_cast<int>(rr & 3u) == kStart) recStartSeq_ = rr >> 2;
    const bool fz = frozenReq_.load();
    if (fz != frozenA_) { frozenA_ = fz; changed = true; }
    if (changed) publish();
}

void CoachAnalyzer::feed(const double *mono, int n, double agcGainDb) {
    if (!prepared_) return;
    applyRequests();
    int pos = 0;
    while (pos < n) {
        const int chunk = std::min(n - pos, kFftSize);
        int done = 0;
        while (done < chunk) {
            const int take = std::min(chunk - done, kFftSize - fill_);
            std::memcpy(buf_.data() + fill_, mono + pos + done, sizeof(double) * take);
            env_.push(mono + pos + done, take, agcGainDb);
            forwardBlocks();
            if (pending_) classifyPending(false);
            fill_ += take;
            done += take;
            if (fill_ >= kFftSize) {
                processFrame();
                // Keep the newest half for the next (50 % overlapped) frame.
                std::memmove(buf_.data(), buf_.data() + kHop, sizeof(double) * (kFftSize - kHop));
                fill_ = kFftSize - kHop;
            }
        }
        pos += chunk;
    }
}

void CoachAnalyzer::processFrame() {
    for (int i = 0; i < kFftSize; ++i) {
        re_[i] = buf_[i] * win_[i];
        im_[i] = 0.0;
    }
    fft(re_.data(), im_.data());
    for (int k = 0; k < kBins; ++k)
        binPow_[k] = (re_[k] * re_[k] + im_[k] * im_[k]) / winPowNorm_;

    const int nb = bands_.size();
    for (int b = 0; b < nb; ++b) {
        double p = 0.0;
        const double *w = bandWeights_[b].data();
        for (int k = firstBin_[b]; k < endBin_[b]; ++k) p += w[k - firstBin_[b]] * binPow_[k];
        // Live trace: one-pole average of band POWER (not dB), ungated.
        livePow_[b] = liveSeeded_ ? livePow_[b] + alpha_ * (p - livePow_[b]) : p;
        pendingPow_[b] = p;
    }
    liveSeeded_ = true;
    // The frame's last block may still be open; classify once it closes.
    if (pending_) classifyPending(true);   // never expected: hop >> block
    pending_ = true;
    pendingEnd_ = env_.samplesPushed();
    classifyPending(false);
    publish();
}

// Hand the envelope's newly finished blocks to the running recordings'
// compression statistics.
void CoachAnalyzer::forwardBlocks() {
    const long long done = env_.blocksDone();
    for (; fwdBlocks_ < done; ++fwdBlocks_) {
        const CoachEnvelope::Block &blk = env_.block(fwdBlocks_);
        if (blk.noInfo) continue;
        if (baseState_ == AvgState::Running) baseStats_.add(blk.levelDb, blk.active, blk.speech);
        if (recState_ == AvgState::Running) recStats_.add(blk.levelDb, blk.active, blk.speech);
    }
}

// Speech / noise decision for the pending frame from the envelope blocks it
// spans: speech at >= 70 % speech samples, noise only if every block is a
// noise block (at the floor, floor valid), otherwise dropped; a frame touching
// any no-information block is always dropped.  Waits until the block holding
// its last sample has closed unless `force` (then the open tail is simply not
// counted).
void CoachAnalyzer::classifyPending(bool force) {
    const long long B = env_.blockSize();
    const long long end = pendingEnd_, start = end - kFftSize;
    const long long done = env_.blocksDone();
    if (!force && done * B < end) return;
    pending_ = false;
    long long speech = 0, noise = 0, decided = 0;
    bool noInfo = false;
    const long long first = std::max<long long>(start / B, done - CoachEnvelope::kHistory);
    for (long long b = std::max<long long>(first, 0); b < done; ++b) {
        const long long s0 = std::max(b * B, start), s1 = std::min((b + 1) * B, end);
        if (s1 <= s0) continue;
        decided += s1 - s0;
        if (env_.block(b).speech) speech += s1 - s0;
        if (env_.block(b).noise) noise += s1 - s0;
        if (env_.block(b).noInfo) noInfo = true;
    }
    // A frame touching a no-information block (digital silence, unknown AGC
    // gain, our own transmit) is dropped: its spectrum may hold that audio.
    if (decided <= 0 || noInfo) return;
    const int nb = bands_.size();
    if (static_cast<double>(speech) >= kSpeechFrameFraction * static_cast<double>(decided)) {
        if (baseState_ == AvgState::Running) {
            for (int b = 0; b < nb; ++b) basePow_[b] += pendingPow_[b];
            ++baseFrames_;
        }
        if (recState_ == AvgState::Running) {
            for (int b = 0; b < nb; ++b) recPow_[b] += pendingPow_[b];
            ++recFrames_;
        }
    } else if (noise == decided) {
        for (int b = 0; b < nb; ++b) {
            const double p = pendingPow_[b];
            noiseAvg_[b] = noiseSeeded_ ? noiseAvg_[b] + noiseAlpha_ * (p - noiseAvg_[b]) : p;
            if (baseState_ == AvgState::Running) baseNoise_[b] += p;
            if (recState_ == AvgState::Running) recNoise_[b] += p;
        }
        noiseSeeded_ = true;
        if (baseState_ == AvgState::Running) ++baseNoiseFrames_;
        if (recState_ == AvgState::Running) ++recNoiseFrames_;
    } else {
        return;   // word edge: neither speech nor clean gap
    }
    publish();
}

const double *CoachAnalyzer::noisePowFor(const std::vector<double> &noiseSum, long noiseFrames) {
    const int nb = bands_.size();
    if (noiseFrames > 0) {
        for (int b = 0; b < nb; ++b) stageNoise_[b] = noiseSum[b] / static_cast<double>(noiseFrames);
        return stageNoise_.data();
    }
    return noiseSeeded_ ? noiseAvg_.data() : nullptr;
}

void CoachAnalyzer::speechPow(const std::vector<double> &sum, long frames,
                              const std::vector<double> &noiseSum, long noiseFrames) {
    const int nb = bands_.size();
    const double *noise = noisePowFor(noiseSum, noiseFrames);
    const double rel = std::pow(10.0, kNoiseSubFloorDb / 10.0);
    for (int b = 0; b < nb; ++b) {
        const double sp = sum[b] / static_cast<double>(frames);
        stagePow_[b] = noise ? std::max(sp - noise[b], sp * rel) : sp;
    }
}

void CoachAnalyzer::curveDb(const std::vector<double> &pow, double scale,
                            std::vector<double> &dbOut) {
    const int nb = bands_.size();
    for (int b = 0; b < nb; ++b)
        dbOut[b] = 10.0 * std::log10(pow[b] * scale + kPowerFloor);
    normalise(dbOut, bands_);
}

// Compute the normalised curves outside the lock into the stage buffers, then
// copy all of them together under it so a snapshot is never torn.
void CoachAnalyzer::publish() {
    const bool haveLive = liveSeeded_;
    const bool haveBase = baseFrames_ > 0;
    const bool haveRec = recFrames_ > 0;
    const bool updateLive = haveLive && !frozenA_;   // frozen holds the last trace
    if (updateLive) curveDb(livePow_, 1.0, stageLive_);
    if (haveRec) {
        speechPow(recPow_, recFrames_, recNoise_, recNoiseFrames_);
        curveDb(stagePow_, 1.0, stageRec_);
    }
    bool haveSnr = false;
    double medSnr = NAN;
    if (haveBase) {
        speechPow(basePow_, baseFrames_, baseNoise_, baseNoiseFrames_);
        const int nb = bands_.size();
        const double *noise = noisePowFor(baseNoise_, baseNoiseFrames_);
        if (noise) {
            int m = 0;
            for (int b = 0; b < nb; ++b) {
                stageSnr_[b] = 10.0 * std::log10((stagePow_[b] + kPowerFloor) / (noise[b] + kPowerFloor));
                if (bands_.centreHz[b] >= kSnrLoHz && bands_.centreHz[b] <= kSnrHiHz)
                    snrScratch_[m++] = stageSnr_[b];
            }
            if (m > 0) {
                std::nth_element(snrScratch_.begin(), snrScratch_.begin() + m / 2,
                                 snrScratch_.begin() + m);
                medSnr = snrScratch_[m / 2];
                if (m % 2 == 0) {
                    const double lo = *std::max_element(snrScratch_.begin(),
                                                        snrScratch_.begin() + m / 2);
                    medSnr = 0.5 * (medSnr + lo);
                }
                haveSnr = true;
            }
        }
        curveDb(stagePow_, 1.0, stageBase_);
    }
    const CompressionMetrics comp = baseStats_.metrics();
    const CompressionMetrics recComp = recStats_.metrics();

    const double hopSec = static_cast<double>(kHop) / fs_;
    std::lock_guard<std::mutex> lk(mtx_);
    if (updateLive) pubLive_ = stageLive_;           // same size: no allocation
    if (!haveLive) pubHasLive_ = false;
    else if (updateLive) pubHasLive_ = true;
    if (haveBase) pubBase_ = stageBase_;
    pubHasBase_ = haveBase;
    if (haveRec) pubRec_ = stageRec_;
    pubHasRec_ = haveRec;
    if (haveSnr) pubSnr_ = stageSnr_;
    pubHasSnr_ = haveSnr;
    pub_.medianSnrDb = medSnr;
    pub_.comp = comp;
    pub_.recheckComp = recComp;
    pub_.baseline = baseState_;
    pub_.recheck = recState_;
    pub_.speechSec = baseFrames_ * hopSec;
    pub_.recheckSpeechSec = recFrames_ * hopSec;
    pub_.frozen = frozenA_;
    if (lapHas_) pubLap_ = stageLap_;                // same size: no allocation
    pubHasLap_ = lapHas_;
    pub_.lapId = lapId_;
    pub_.lapSpeechSec = lapSpeechSec_;
    pub_.lapComp = lapComp_;
    dirty_ = true;
}

// In-place iterative radix-2 Cooley-Tukey FFT (decimation-in-time), the same
// approach as EqAnalyzer::fft but in double and with no allocation.
void CoachAnalyzer::fft(double *re, double *im) {
    const int n = kFftSize;
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const double ang = -2.0 * kPi / len;
        const double wr = std::cos(ang);
        const double wi = std::sin(ang);
        for (int i = 0; i < n; i += len) {
            double cr = 1.0, ci = 0.0;
            for (int k = 0; k < len / 2; ++k) {
                const int a = i + k, b = i + k + len / 2;
                const double tr = re[b] * cr - im[b] * ci;
                const double ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr;        im[a] += ti;
                const double ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

}  // namespace lyra::dsp::coach
