// eSSB Coach envelope.  See CoachEnvelope.h for the definitions.

#include "dsp/coach/CoachEnvelope.h"

#include <algorithm>

namespace lyra::dsp::coach {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kMinDb = -200.0;   // level of digital silence
}  // namespace

// ---- LevelHistogram --------------------------------------------------------

void LevelHistogram::init(double loDb, double hiDb, double stepDb) {
    lo_ = loDb;
    step_ = stepDb;
    bins_.assign(static_cast<size_t>(std::ceil((hiDb - loDb) / stepDb)), 0u);
    total_ = 0;
}

void LevelHistogram::clear() {
    std::fill(bins_.begin(), bins_.end(), 0u);
    total_ = 0;
}

void LevelHistogram::add(double db) {
    if (bins_.empty() || std::isnan(db)) return;
    const double pos = std::floor((db - lo_) / step_);
    const long last = static_cast<long>(bins_.size()) - 1;
    const long i = pos < 0.0 ? 0 : (pos > static_cast<double>(last) ? last : static_cast<long>(pos));
    ++bins_[static_cast<size_t>(i)];
    ++total_;
}

double LevelHistogram::quantile(double q) const {
    if (total_ <= 0) return NAN;
    const long long want = std::max<long long>(1, static_cast<long long>(std::ceil(q * static_cast<double>(total_))));
    long long cum = 0;
    for (size_t i = 0; i < bins_.size(); ++i) {
        cum += bins_[i];
        if (cum >= want) return lo_ + (static_cast<double>(i) + 0.5) * step_;
    }
    return lo_ + (static_cast<double>(bins_.size()) - 0.5) * step_;
}

// ---- EnvelopeStats ---------------------------------------------------------

void EnvelopeStats::prepare(double blockSec) {
    speech_.init(kMinDb, 60.0, 0.1);
    gap_.init(kMinDb, 60.0, 0.1);
    rise_.init(-100.0, 100.0, 0.05);
    const auto blocks = [&](double sec) { return static_cast<int>(std::lround(sec / blockSec)); };
    earlyFrom_ = blocks(kRiseEarlyFromSec);
    earlyTo_ = blocks(kRiseEarlyToSec);
    lateFrom_ = blocks(kRiseLateFromSec);
    lateTo_ = blocks(kRiseLateToSec);
    // A pause is scored once it has lasted both the minimum pause and the
    // late window, i.e. at its 80th block for the defaults.
    recordAt_ = std::max(blocks(kMinPauseSec), lateTo_) - 1;
    onsetSpan_ = std::clamp(blocks(kOnsetSpanSec), 1, kRing - 1);
    reset();
}

void EnvelopeStats::reset() {
    speech_.clear();
    gap_.clear();
    rise_.clear();
    sinceActive_ = -1;
    earlySum_ = lateSum_ = 0.0;
    earlyN_ = lateN_ = pauses_ = 0;
    nRing_ = 0;
}

void EnvelopeStats::add(double levelDb, bool active, bool speech) {
    // Speech level = active blocks only: hangover blocks are word tails at
    // gap level and would drag the speech median down.  Gap = not speech.
    if (active) speech_.add(levelDb);
    else if (!speech) gap_.add(levelDb);
    const double before = nRing_ >= onsetSpan_ ? ring_[(nRing_ - onsetSpan_) % kRing] : NAN;
    ring_[nRing_ % kRing] = levelDb;
    ++nRing_;
    if (active) {
        // Gate re-opened inside an unscored pause.  A smooth climb (no word
        // onset step) after the early window is pumping that reached speech
        // level: score it rather than lose the pause.
        if (sinceActive_ >= earlyTo_ && sinceActive_ <= recordAt_ && earlyN_ > 0
            && !std::isnan(before) && levelDb - before < kOnsetStepDb) {
            double recent = 0.0;
            for (int k = 1; k <= onsetSpan_; ++k) recent += ring_[(nRing_ - 1 - k) % kRing];
            recent /= onsetSpan_;
            rise_.add(std::max(recent - earlySum_ / earlyN_, kSpeechAboveFloorDb));
            ++pauses_;
        }
        sinceActive_ = 0;   // the next block is 0-10 ms after speech end
        earlySum_ = lateSum_ = 0.0;
        earlyN_ = lateN_ = 0;
        return;
    }
    if (sinceActive_ < 0 || sinceActive_ > recordAt_) return;   // no speech yet / scored
    const long j = sinceActive_++;
    if (j >= earlyFrom_ && j < earlyTo_) { earlySum_ += levelDb; ++earlyN_; }
    if (j >= lateFrom_ && j < lateTo_) { lateSum_ += levelDb; ++lateN_; }
    if (j == recordAt_ && earlyN_ > 0 && lateN_ > 0) {
        rise_.add(lateSum_ / lateN_ - earlySum_ / earlyN_);
        ++pauses_;
    }
}

CompressionMetrics EnvelopeStats::metrics() const {
    CompressionMetrics m;
    const double sMed = speech_.quantile(0.5);
    m.gapToSpeechDb = sMed - gap_.quantile(0.5);   // NaN if either is empty
    m.crestDb = speech_.quantile(kCrestPercentile) - sMed;
    m.gapRiseDb = rise_.quantile(0.5);
    m.pauses = pauses_;
    return m;
}

// ---- CoachEnvelope ---------------------------------------------------------

CoachEnvelope::CoachEnvelope(double fs) : fs_(fs > 0.0 ? fs : 48000.0) {}

void CoachEnvelope::prepare() {
    blockN_ = std::max(1, static_cast<int>(std::lround(fs_ * kBlockSec)));
    const double blockSec = blockN_ / fs_;
    hangBlocks_ = static_cast<int>(std::lround(kHangoverSec / blockSec));
    win_.assign(static_cast<size_t>(std::max(1L, std::lround(kFloorWindowSec / blockSec))), 0.0);
    riseCap_ = kFloorRiseDbPerSec * blockSec;
    refAlpha_ = 1.0 - std::exp(-blockSec / kSpeechRefTauSec);
    refDecay_ = kSpeechRefDecayDbPerSec * blockSec;

    // RBJ cookbook 2nd-order Butterworth (Q = 1/sqrt 2), normalised by a0.
    const auto design = [&](Biquad &f, double hz, bool high) {
        const double w0 = 2.0 * kPi * std::min(hz, 0.45 * fs_) / fs_;
        const double c = std::cos(w0), al = std::sin(w0) / (2.0 * std::sqrt(0.5));
        const double a0 = 1.0 + al;
        const double k = high ? (1.0 + c) / 2.0 : (1.0 - c) / 2.0;
        f.b0 = k / a0;
        f.b1 = (high ? -2.0 * k : 2.0 * k) / a0;
        f.b2 = k / a0;
        f.a1 = -2.0 * c / a0;
        f.a2 = (1.0 - al) / a0;
    };
    design(hp_, kEnvLoHz, true);
    design(lp_, kEnvHiHz, false);
    stats_.prepare(blockSec);
    reset();
}

void CoachEnvelope::reset() {
    hp_.z1 = hp_.z2 = lp_.z1 = lp_.z2 = 0.0;
    acc_ = 0.0;
    accN_ = 0;
    gainUnknown_ = false;
    samples_ = blocks_ = 0;
    std::fill(win_.begin(), win_.end(), 0.0);
    winPos_ = winFill_ = 0;
    floor_ = ref_ = NAN;
    valid_ = false;
    hang_ = 0;
    lastSpeech_ = false;
    for (Block &b : hist_) b = Block{};
    stats_.reset();
}

bool CoachEnvelope::push(const double *mono, int n, double agcGainDb) {
    // Remove our AGC per sample (amplitude * 10^(-gain/20)), BEFORE the band
    // filter so its memory never mixes corrected and uncorrected samples.
    // A non-finite gain means "unknown": no correction, and every 10 ms block
    // holding such a sample is a noInfo block.
    const bool unknown = !std::isfinite(agcGainDb);
    const double undo = unknown ? 1.0 : std::pow(10.0, -agcGainDb / 20.0);
    for (int i = 0; i < n; ++i) {
        const double y = lp_.run(hp_.run(mono[i] * undo));
        acc_ += y * y;
        if (unknown) gainUnknown_ = true;
        if (++accN_ >= blockN_) endBlock();
    }
    samples_ += n > 0 ? n : 0;
    return lastSpeech_;
}

void CoachEnvelope::endBlock() {
    const double ms = acc_ / accN_;
    acc_ = 0.0;
    accN_ = 0;
    const double level = ms > 0.0 ? std::max(10.0 * std::log10(ms), kMinDb) : kMinDb;
    const bool gainUnknown = gainUnknown_;
    gainUnknown_ = false;
    // Digital silence, or a block whose AGC gain was unknown (uncorrected
    // level), carries no information.
    if (level <= kSilenceDb || gainUnknown) {
        hist_[blocks_ % kHistory] = Block{level, false, false, false, true};
        ++blocks_;
        lastSpeech_ = false;
        return;
    }

    // Minimum statistics over the floor window (current block included).
    win_[static_cast<size_t>(winPos_)] = level;
    winPos_ = (winPos_ + 1) % static_cast<int>(win_.size());
    winFill_ = std::min(winFill_ + 1, static_cast<int>(win_.size()));
    double mn = win_[0], mx = win_[0];
    for (int k = 1; k < winFill_; ++k) {
        mn = std::min(mn, win_[static_cast<size_t>(k)]);
        mx = std::max(mx, win_[static_cast<size_t>(k)]);
    }
    const double target = mn + kFloorBiasDb;
    if (!valid_ || std::isnan(floor_) || target <= floor_
        || (!std::isnan(ref_) && target < ref_ - kSpeechBelowRefDb))
        floor_ = target;                              // fall, or rise to a noise-like level
    else
        floor_ = std::min(target, floor_ + riseCap_); // slow rise toward speech level

    // Until speechRef exists, the loudest block in the window stands in for
    // it, so pumped noise right after a cold start cannot bootstrap it.
    const double ref = std::isnan(ref_) ? mx : ref_;
    const bool active = level >= floor_ + kSpeechAboveFloorDb
                        && level >= ref - kSpeechBelowRefDb;
    if (active) {
        valid_ = true;
        ref_ = std::isnan(ref_) ? level : ref_ + refAlpha_ * (level - ref_);
        hang_ = hangBlocks_;
    } else if (!std::isnan(ref_)) {
        ref_ = std::max(ref_ - refDecay_, floor_ + kSpeechAboveFloorDb);
    }
    const bool speech = active || hang_ > 0;
    if (!active && hang_ > 0) --hang_;

    Block &b = hist_[blocks_ % kHistory];
    b.levelDb = level;
    b.active = active;
    b.speech = speech;
    b.noise = valid_ && !speech && level <= floor_ + kNoiseNearFloorDb;
    b.noInfo = false;   // the slot may hold a noInfo block from kHistory blocks ago
    ++blocks_;
    lastSpeech_ = speech;
    stats_.add(level, active, speech);
}

double CoachEnvelope::noiseFloorDb() const { return floor_; }

CompressionMetrics CoachEnvelope::metrics() const { return stats_.metrics(); }

}  // namespace lyra::dsp::coach
