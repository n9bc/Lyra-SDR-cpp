// eSSB Coach splatter meter.  See SplatterMeter.h for the contract.

#include "dsp/coach/SplatterMeter.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace lyra::dsp::coach {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kPowerFloor = 1e-18;   // -180 dB, keeps log10 finite
}  // namespace

void SplatterMeter::setRateDerived(int rate) {
    rate_ = rate;
    binHz_ = static_cast<double>(rate_) / kFftSize;
    bandBins_ = std::max(1, static_cast<int>(std::lround(kBandHz / binHz_)));
    const double hopSec = static_cast<double>(kHop) / rate_;
    alpha_ = 1.0 - std::exp(-hopSec / kTauSec);
}

void SplatterMeter::prepare(int iqRate) {
    setRateDerived(iqRate > 0 ? iqRate : 192000);
    reqRate_.store(rate_);

    win_.resize(kFftSize);
    double sum = 0.0;
    for (int i = 0; i < kFftSize; ++i) {
        win_[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (kFftSize - 1));   // Hann
        sum += win_[i];
    }
    // Per-bin power divisor: (sum of window)^2, so a unit complex tone reads 1.
    winNorm_ = sum > 0.0 ? sum * sum : 1.0;

    cs_.resize(kFftSize / 2);
    sn_.resize(kFftSize / 2);
    for (int i = 0; i < kFftSize / 2; ++i) {
        cs_[i] = std::cos(2.0 * kPi * i / kFftSize);
        sn_[i] = -std::sin(2.0 * kPi * i / kFftSize);
    }
    rev_.resize(kFftSize);
    int bits = 0;
    while ((1 << bits) < kFftSize) ++bits;
    for (int i = 0; i < kFftSize; ++i) {
        int r = 0;
        for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
        rev_[i] = r;
    }

    ring_.assign(2 * static_cast<size_t>(kFftSize), 0.0);
    re_.assign(kFftSize, 0.0);
    im_.assign(kFftSize, 0.0);
    avg_.assign(kFftSize, 0.0);
    pre_.assign(kFftSize + 1, 0.0);
    floorScratch_.assign(kFftSize, 0.0);   // bandBins_ >= 1: room for any later rate
    fill_ = 0;
    seeded_ = false;
    framesSeen_ = 0;
    restartSeen_ = restartReq_.load();
    chSeen_ = chSeq_.load();
    applyChannel();
    {
        std::lock_guard<std::mutex> lk(mtx_);
        pub_ = SplatterResult{};
        dirty_ = true;
    }
    prepared_ = true;
}

// ---- GUI thread ------------------------------------------------------------

void SplatterMeter::setChannel(double shiftHz, bool upperSideband, double channelEdgeHz) {
    const unsigned s = chSeq_.load();
    chSeq_.store(s | 1u);                       // odd: write in progress
    reqShift_.store(shiftHz);
    reqEdge_.store(channelEdgeHz);
    reqUsb_.store(upperSideband);
    chSeq_.store((s | 1u) + 1u);                // even: published
}

void SplatterMeter::restart() { restartReq_.fetch_add(1); }

void SplatterMeter::setRate(int iqRate) {
    if (iqRate > 0) reqRate_.store(iqRate);
}

bool SplatterMeter::snapshot(SplatterResult &out) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (!dirty_) return false;
    out = pub_;
    dirty_ = false;
    return true;
}

// ---- worker thread ---------------------------------------------------------

bool SplatterMeter::applyChannel() {
    const unsigned s1 = chSeq_.load();
    if (s1 & 1u) return false;                  // being written: next feed()
    const Channel c{reqShift_.load(), reqEdge_.load(), reqUsb_.load()};
    if (chSeq_.load() != s1) return false;      // torn: next feed()
    const bool changed = c.shiftHz != ch_.shiftHz || c.edgeHz != ch_.edgeHz || c.usb != ch_.usb;
    ch_ = c;
    chSeen_ = s1;
    return changed;
}

bool SplatterMeter::applyRate() {
    const int r = reqRate_.load();
    if (r <= 0 || r == rate_) return false;
    setRateDerived(r);
    return true;
}

// Drop the averaged spectrum and any partly filled frame, and restart the
// 3 s validity timer.
void SplatterMeter::rearm() {
    fill_ = 0;
    seeded_ = false;
    framesSeen_ = 0;
}

void SplatterMeter::fft(double *re, double *im, const std::vector<int> &rev,
                        const std::vector<double> &cs, const std::vector<double> &sn) {
    const int n = kFftSize;
    for (int i = 0; i < n; ++i) {
        const int j = rev[i];
        if (j > i) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const int half = len >> 1, step = n / len;
        for (int i = 0; i < n; i += len) {
            for (int k = 0; k < half; ++k) {
                const double wr = cs[k * step], wi = sn[k * step];
                const int a = i + k, b = a + half;
                const double tr = re[b] * wr - im[b] * wi;
                const double ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr;        im[a] += ti;
            }
        }
    }
}

void SplatterMeter::feed(const double *iq, int frames) {
    if (!prepared_) return;
    bool rearmed = applyChannel();
    if (applyRate()) rearmed = true;
    const unsigned rs = restartReq_.load();
    if (rs != restartSeen_) { restartSeen_ = rs; rearmed = true; }
    if (rearmed) rearm();
    int pos = 0;
    bool framed = rearmed;
    while (pos < frames) {
        const int take = std::min(frames - pos, kFftSize - fill_);
        std::memcpy(&ring_[2 * static_cast<size_t>(fill_)], iq + 2 * static_cast<size_t>(pos),
                    2 * sizeof(double) * static_cast<size_t>(take));
        fill_ += take;
        pos += take;
        framesSeen_ += take;
        if (fill_ == kFftSize) {
            processFrame();
            // Keep the newest kFftSize - kHop frames for the next frame.
            std::memmove(ring_.data(), &ring_[2 * static_cast<size_t>(kHop)],
                         2 * sizeof(double) * static_cast<size_t>(kFftSize - kHop));
            fill_ = kFftSize - kHop;
            framed = true;
        }
    }
    // Publish once per feed() (a channel change or the 3 s mark may land
    // between frames); the maths runs before the lock is taken.
    if (framed || frames == 0 || chSeen_ != lastPubSeq_) {
        const SplatterResult r = measure();
        lastPubSeq_ = chSeen_;
        std::lock_guard<std::mutex> lk(mtx_);
        pub_ = r;
        dirty_ = true;
    }
}

void SplatterMeter::processFrame() {
    for (int i = 0; i < kFftSize; ++i) {
        re_[i] = ring_[2 * static_cast<size_t>(i)] * win_[i];
        im_[i] = ring_[2 * static_cast<size_t>(i) + 1] * win_[i];
    }
    fft(re_.data(), im_.data(), rev_, cs_, sn_);
    for (int k = 0; k < kFftSize; ++k) {
        const double p = (re_[k] * re_[k] + im_[k] * im_[k]) / winNorm_;
        avg_[k] = seeded_ ? avg_[k] + alpha_ * (p - avg_[k]) : p;
    }
    seeded_ = true;
}

SplatterResult SplatterMeter::measure() const {
    SplatterResult r;
    const double edge = ch_.edgeHz, shift = ch_.shiftHz;
    const double half = rate_ / 2.0;
    const double farHz = edge + kOutFarHz;
    const double extremeLo = ch_.usb ? shift : shift - farHz;
    const double extremeHi = ch_.usb ? shift + farHz : shift;
    if (!seeded_ || framesSeen_ < static_cast<long long>(kMinDataSec * rate_)
        || !(edge > 0.0) || extremeLo < -half || extremeHi > half)
        return r;

    // Centred order: j = 0 is -rate/2, j = kFftSize/2 is DC.  pre_[j] = sum
    // of the first j entries.
    double acc = 0.0;
    pre_[0] = 0.0;
    for (int j = 0; j < kFftSize; ++j) {
        acc += avg_[(j + kFftSize / 2) % kFftSize];
        pre_[j + 1] = acc;
    }
    const auto maxBand = [&](double loHz, double hiHz) {
        const int jlo = std::clamp(static_cast<int>(std::lround(loHz / binHz_)) + kFftSize / 2,
                                   0, kFftSize - 1);
        const int jhi = std::clamp(static_cast<int>(std::lround(hiHz / binHz_)) + kFftSize / 2,
                                   jlo, kFftSize - 1);
        const int nb = std::min(bandBins_, jhi - jlo + 1);
        double best = 0.0;
        for (int s = jlo; s + nb - 1 <= jhi; ++s)
            best = std::max(best, pre_[s + nb] - pre_[s]);
        return best;
    };
    double peak, out;
    if (ch_.usb) {
        peak = maxBand(shift, shift + edge);
        out = maxBand(shift + edge + kOutNearHz, shift + farHz);
    } else {
        peak = maxBand(shift - edge, shift);
        out = maxBand(shift - farHz, shift - edge - kOutNearHz);
    }
    // Noise floor: median of the non-overlapping 100 Hz band powers across
    // the whole IQ span.
    const int nBands = kFftSize / bandBins_;
    for (int b = 0; b < nBands; ++b)
        floorScratch_[b] = pre_[(b + 1) * bandBins_] - pre_[b * bandBins_];
    std::nth_element(floorScratch_.begin(), floorScratch_.begin() + nBands / 2,
                     floorScratch_.begin() + nBands);
    r.noiseDb = 10.0 * std::log10(std::max(floorScratch_[nBands / 2], kPowerFloor));
    r.peakDb = 10.0 * std::log10(std::max(peak, kPowerFloor));
    r.outDb = 10.0 * std::log10(std::max(out, kPowerFloor));
    r.marginDb = r.peakDb - r.outDb;
    r.valid = r.peakDb >= r.noiseDb + kPresentAboveNoiseDb;
    r.alert = r.valid && r.marginDb < kAlertMarginDb
              && r.outDb >= r.noiseDb + kOutAboveNoiseDb;
    return r;
}

}  // namespace lyra::dsp::coach
