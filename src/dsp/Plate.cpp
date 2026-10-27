// Lyra — Plate reverb implementation.  See Plate.h +
// docs/architecture/plate_design.md.

#include "dsp/Plate.h"

#include <algorithm>
#include <cmath>

namespace lyra::dsp {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kSizeMin = 0.5, kSizeSpan = 1.3;   // SIZE 1..100 -> 0.5..1.8 scale
constexpr double kSizeMax = kSizeMin + kSizeSpan;   // 1.8 (buffer alloc headroom)

inline double clampd(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}
}  // namespace

void Plate::designLowShelf(Shelf &s, double fs, double f0, double gainDb) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * f0 / fs, cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / 2.0 * std::sqrt(2.0);          // Q ~ 0.707
    const double tsa = 2.0 * std::sqrt(A) * alpha;
    const double a0 =        (A + 1) + (A - 1) * cw + tsa;
    s.b0 =      A * ((A + 1) - (A - 1) * cw + tsa) / a0;
    s.b1 =  2 * A * ((A - 1) - (A + 1) * cw)       / a0;
    s.b2 =      A * ((A + 1) - (A - 1) * cw - tsa) / a0;
    s.a1 =     -2 * ((A - 1) + (A + 1) * cw)       / a0;
    s.a2 =          ((A + 1) + (A - 1) * cw - tsa) / a0;
}

void Plate::designHighShelf(Shelf &s, double fs, double f0, double gainDb) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * f0 / fs, cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / 2.0 * std::sqrt(2.0);
    const double tsa = 2.0 * std::sqrt(A) * alpha;
    const double a0 =        (A + 1) - (A - 1) * cw + tsa;
    s.b0 =      A * ((A + 1) + (A - 1) * cw + tsa) / a0;
    s.b1 = -2 * A * ((A - 1) + (A + 1) * cw)       / a0;
    s.b2 =      A * ((A + 1) + (A - 1) * cw - tsa) / a0;
    s.a1 =      2 * ((A - 1) - (A + 1) * cw)       / a0;
    s.a2 =          ((A + 1) - (A - 1) * cw - tsa) / a0;
}

Plate::Plate() {
    setSampleRate(48000.0);   // allocates buffers + seeds the N8SDR preset state
}

void Plate::setSampleRate(double fs) {
    if (fs <= 0.0) return;
    fs_ = fs;
    const double rscale = fs_ / 48000.0;   // base delays are quoted @ 48 kHz
    for (int i = 0; i < kNumCombs; ++i) {
        const int cap = static_cast<int>(std::ceil(baseComb_[i] * rscale * kSizeMax)) + 2;
        combBuf_[i].assign(cap, 0.0);
        combWrite_[i] = 0; combLp_[i] = 0.0;
    }
    for (int a = 0; a < kNumAllpass; ++a) {
        const int cap = static_cast<int>(std::ceil(baseAp_[a] * rscale * kSizeMax * 1.3)) + 2;
        apBuf_[a].assign(cap, 0.0);
        apWrite_[a] = 0;
    }
    preBuf_.assign(static_cast<int>(std::ceil(0.100 * fs_)) + 2, 0.0);
    preWrite_ = 0;
    bassCached_ = trebCached_ = 1e9;   // force shelf recompute
}

void Plate::setBypass(bool on)       { bypass_.store(on, std::memory_order_relaxed); }
void Plate::setPreDelayS(double s)   { preDelayS_.store(clampd(s, 0.0, 0.100), std::memory_order_relaxed); }
void Plate::setDecayS(double s)      { decayS_.store(clampd(s, 0.1, 5.0), std::memory_order_relaxed); }
void Plate::setDamp(double v)        { damp_.store(clampd(v, 1.0, 100.0), std::memory_order_relaxed); }
void Plate::setSize(double v)        { size_.store(clampd(v, 1.0, 100.0), std::memory_order_relaxed); }
void Plate::setDensity(double v)     { density_.store(clampd(v, 1.0, 100.0), std::memory_order_relaxed); }
void Plate::setDiff(double v)        { diff_.store(clampd(v, 1.0, 100.0), std::memory_order_relaxed); }
void Plate::setBassDb(double db)     { bassDb_.store(clampd(db, -18.0, 18.0), std::memory_order_relaxed); }
void Plate::setTrebDb(double db)     { trebDb_.store(clampd(db, -18.0, 18.0), std::memory_order_relaxed); }
void Plate::setMix(double frac)      { mix_.store(clampd(frac, 0.0, 1.0), std::memory_order_relaxed); }

void Plate::processInterleaved(double *iq, int nPairs) {
    // A pending flush runs here, on the audio thread, before any sample of
    // this block (cheap load first: no RMW on the common no-request path).
    if (resetReq_.load(std::memory_order_relaxed)
        && resetReq_.exchange(false, std::memory_order_acq_rel))
        reset();
    if (bypass_.load(std::memory_order_relaxed) || nPairs <= 0) return;

    // ── derive per-block coefficients from the atomic params ────────────
    const double rscale  = fs_ / 48000.0;
    const double sizeSc  = kSizeMin + (size_.load(std::memory_order_relaxed) / 100.0) * kSizeSpan;
    const double decay   = decayS_.load(std::memory_order_relaxed);
    const double dampC   = (damp_.load(std::memory_order_relaxed) / 100.0) * 0.7;  // 0..0.7
    const double apCoef  = 0.3 + (density_.load(std::memory_order_relaxed) / 100.0) * 0.4;  // 0.3..0.7
    const double diffSc  = 0.7 + (diff_.load(std::memory_order_relaxed) / 100.0) * 0.6;     // 0.7..1.3
    const double mix     = mix_.load(std::memory_order_relaxed);
    const double bassDb  = bassDb_.load(std::memory_order_relaxed);
    const double trebDb  = trebDb_.load(std::memory_order_relaxed);

    int    combDelay[kNumCombs];
    double combG[kNumCombs];
    for (int i = 0; i < kNumCombs; ++i) {
        int d = static_cast<int>(std::lround(baseComb_[i] * rscale * sizeSc));
        d = std::clamp(d, 1, static_cast<int>(combBuf_[i].size()) - 1);
        combDelay[i] = d;
        // RT60: per-comb feedback gain g = 10^(-3 * (d/fs) / decay).
        double g = std::pow(10.0, -3.0 * (d / fs_) / decay);
        combG[i] = clampd(g, 0.0, 0.98);
    }
    int apDelay[kNumAllpass];
    for (int a = 0; a < kNumAllpass; ++a) {
        int d = static_cast<int>(std::lround(baseAp_[a] * rscale * sizeSc * diffSc));
        d = std::clamp(d, 1, static_cast<int>(apBuf_[a].size()) - 1);
        apDelay[a] = d;
    }
    int preDelay = static_cast<int>(std::lround(preDelayS_.load(std::memory_order_relaxed) * fs_));
    preDelay = std::clamp(preDelay, 0, static_cast<int>(preBuf_.size()) - 1);

    if (bassDb != bassCached_) { designLowShelf(bass_, fs_, 250.0, bassDb); bassCached_ = bassDb; }
    if (trebDb != trebCached_) { designHighShelf(treb_, fs_, 4000.0, trebDb); trebCached_ = trebDb; }

    const int preLen = static_cast<int>(preBuf_.size());
    const double invCombs = 1.0 / kNumCombs;

    for (int n = 0; n < nPairs; ++n) {
        const double x = iq[2 * n];
        const double dry = x;

        // ── pre-delay ────────────────────────────────────────────────
        preBuf_[preWrite_] = x;
        int pr = preWrite_ - preDelay; if (pr < 0) pr += preLen;
        const double pd = preBuf_[pr];
        if (++preWrite_ >= preLen) preWrite_ = 0;

        // ── 6 parallel Moorer combs ──────────────────────────────────
        double combSum = 0.0;
        for (int i = 0; i < kNumCombs; ++i) {
            const int cap = static_cast<int>(combBuf_[i].size());
            int rd = combWrite_[i] - combDelay[i]; if (rd < 0) rd += cap;
            const double y = combBuf_[i][rd];
            combSum += y;
            combLp_[i] = y * (1.0 - dampC) + combLp_[i] * dampC;   // HF damping
            combBuf_[i][combWrite_[i]] = pd + combLp_[i] * combG[i];
            if (++combWrite_[i] >= cap) combWrite_[i] = 0;
        }
        double w = combSum * invCombs;

        // ── 4 series allpass diffusers ───────────────────────────────
        for (int a = 0; a < kNumAllpass; ++a) {
            const int cap = static_cast<int>(apBuf_[a].size());
            int rd = apWrite_[a] - apDelay[a]; if (rd < 0) rd += cap;
            const double d = apBuf_[a][rd];
            const double win = w + apCoef * d;       // proper Schroeder allpass
            const double y = d - apCoef * win;
            apBuf_[a][apWrite_[a]] = win;
            if (++apWrite_[a] >= cap) apWrite_[a] = 0;
            w = y;
        }

        // ── wet tone (low-shelf + high-shelf) ────────────────────────
        w = runShelf(treb_, runShelf(bass_, w));

        iq[2 * n] = (1.0 - mix) * dry + mix * w;
    }
}

void Plate::reset() {
    for (int i = 0; i < kNumCombs; ++i) {
        std::fill(combBuf_[i].begin(), combBuf_[i].end(), 0.0);
        combWrite_[i] = 0; combLp_[i] = 0.0;
    }
    for (int a = 0; a < kNumAllpass; ++a) {
        std::fill(apBuf_[a].begin(), apBuf_[a].end(), 0.0);
        apWrite_[a] = 0;
    }
    std::fill(preBuf_.begin(), preBuf_.end(), 0.0);
    preWrite_ = 0;
    bass_.z1 = bass_.z2 = treb_.z1 = treb_.z2 = 0.0;
}

}  // namespace lyra::dsp
