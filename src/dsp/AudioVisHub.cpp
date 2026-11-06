// Lyra — audio visualizer hub.  See AudioVisHub.h.

#include "dsp/AudioVisHub.h"

#include "dsp/AudioVisCore.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace lyra::dsp::vis {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr float  kSilenceDb = -200.0f;
constexpr double kMinMag = 1e-10;   // 20*log10 -> -200 dB

float magToDb(double mag)
{
    return mag > kMinMag ? float(20.0 * std::log10(mag)) : kSilenceDb;
}

}  // namespace

AudioVisHub &AudioVisHub::instance()
{
    static AudioVisHub hub;
    return hub;
}

AudioVisHub::AudioVisHub()
{
    const int n = kFftSize;
    window_.assign(size_t(n), 0.0);
    anaWindow_.assign(size_t(n), 0.0);
    hann_.resize(size_t(n));
    double sum = 0.0;
    for (int i = 0; i < n; ++i) {
        hann_[size_t(i)] = 0.5 * (1.0 - std::cos(2.0 * kPi * i / n));
        sum += hann_[size_t(i)];
    }
    hannSum_ = sum;
    re_.assign(size_t(n), 0.0);
    im_.assign(size_t(n), 0.0);
    cosT_.resize(size_t(n / 2));
    sinT_.resize(size_t(n / 2));
    for (int i = 0; i < n / 2; ++i) {
        cosT_[size_t(i)] = std::cos(2.0 * kPi * i / n);
        sinT_[size_t(i)] = -std::sin(2.0 * kPi * i / n);
    }
    rev_.resize(size_t(n));
    int bits = 0;
    while ((1 << bits) < n) ++bits;
    for (int i = 0; i < n; ++i) {
        int r = 0;
        for (int b = 0; b < bits; ++b)
            if (i & (1 << b)) r |= 1 << (bits - 1 - b);
        rev_[size_t(i)] = r;
    }
    magDb_.assign(size_t(n / 2 + 1), kSilenceDb);
}

void AudioVisHub::clearConsumerState()
{
    rx_.clear();
    tx_ring_.clear();
    std::fill(window_.begin(), window_.end(), 0.0);
    haveData_ = false;
}

void AudioVisHub::acquire()
{
    if (consumers_.load(std::memory_order_relaxed) == 0)
        clearConsumerState();            // stale samples from the last session
    consumers_.fetch_add(1, std::memory_order_relaxed);
}

void AudioVisHub::release()
{
    // Never below zero: an unbalanced release must not leave the taps off
    // for the next acquire().
    int c = consumers_.load(std::memory_order_relaxed);
    while (c > 0 && !consumers_.compare_exchange_weak(c, c - 1, std::memory_order_relaxed)) {}
}

void AudioVisHub::reset()
{
    consumers_.store(0, std::memory_order_relaxed);
    tx_.store(false, std::memory_order_relaxed);
    lastTx_ = false;
    clearConsumerState();
}

void AudioVisHub::pushRx(const double *interleavedLR, int nframes,
                         bool sub, bool muteRx1, bool muteRx2) noexcept
{
    if (consumers_.load(std::memory_order_relaxed) <= 0 || !interleavedLR || nframes <= 0)
        return;
    double tmp[512];                      // bounded stack chunk, no allocation
    int i = 0;
    while (i < nframes) {
        const int k = std::min(nframes - i, 512);
        for (int j = 0; j < k; ++j) {
            const double *p = interleavedLR + size_t(2) * size_t(i + j);
            const float m = mixSample(float(p[0]), float(p[1]), sub, muteRx1, muteRx2);
            tmp[j] = std::isfinite(m) ? double(m) : 0.0;   // NaN / Inf -> 0
        }
        rx_.push(tmp, size_t(k));
        i += k;
    }
}

void AudioVisHub::pushTx(const double *mono, int n) noexcept
{
    if (!wantsTx() || !mono || n <= 0)
        return;
    double tmp[512];                      // bounded stack chunk, no allocation
    int i = 0;
    while (i < n) {
        const int k = std::min(n - i, 512);
        for (int j = 0; j < k; ++j) {
            const double s = mono[i + j];
            tmp[j] = std::isfinite(s) ? s : 0.0;           // NaN / Inf -> 0
        }
        tx_ring_.push(tmp, size_t(k));
        i += k;
    }
}

// In-place iterative radix-2 decimation-in-time FFT over re_/im_ (kFftSize).
void AudioVisHub::fft()
{
    const int n = kFftSize;
    for (int i = 0; i < n; ++i) {
        const int j = rev_[size_t(i)];
        if (j > i) {
            std::swap(re_[size_t(i)], re_[size_t(j)]);
            std::swap(im_[size_t(i)], im_[size_t(j)]);
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const int half = len >> 1;
        const int step = n / len;
        for (int base = 0; base < n; base += len) {
            for (int k = 0; k < half; ++k) {
                const double wr = cosT_[size_t(k * step)];
                const double wi = sinT_[size_t(k * step)];
                const size_t a = size_t(base + k), b = a + size_t(half);
                const double tr = re_[b] * wr - im_[b] * wi;
                const double ti = re_[b] * wi + im_[b] * wr;
                re_[b] = re_[a] - tr;
                im_[b] = im_[a] - ti;
                re_[a] += tr;
                im_[a] += ti;
            }
        }
    }
}

namespace {

// Peak dB of the bins whose centres lie in [loHz, hiHz); when the range holds
// no bin centre, linear interpolation (in dB) at its midpoint.
float rangeDb(const std::vector<float> &magDb, double binHz, double loHz, double hiHz)
{
    const int last = int(magDb.size()) - 1;
    const int i0 = int(std::ceil(loHz / binHz));
    int i1 = int(std::ceil(hiHz / binHz)) - 1;    // bin centre strictly below hiHz
    if (i1 > last) i1 = last;
    if (i0 <= i1) {
        float m = kSilenceDb;
        for (int i = std::max(i0, 0); i <= i1; ++i) m = std::max(m, magDb[size_t(i)]);
        return m;
    }
    const double pos = 0.5 * (loHz + hiHz) / binHz;
    const int lo = std::clamp(int(std::floor(pos)), 0, last);
    const int hi = std::min(lo + 1, last);
    const double fr = std::clamp(pos - lo, 0.0, 1.0);
    return float(magDb[size_t(lo)] * (1.0 - fr) + magDb[size_t(hi)] * fr);
}

}  // namespace

bool AudioVisHub::frame(double spanHz, Frame &out)
{
    if (!active()) return false;

    const bool tx = tx_.load(std::memory_order_relaxed);
    // Source switch: don't mix two sources.  The liveness clock is kept: the
    // TX ring only fills once the source is TX (pushTx), so the first TX
    // frame finds it empty, and that is not "audio stopped".
    if (tx != lastTx_) {
        std::fill(window_.begin(), window_.end(), 0.0);
        lastTx_ = tx;
    }

    // Drain both rings; only the selected one feeds the window (the other
    // would otherwise sit stale until the source flips back).
    MonitorRing &used = tx ? tx_ring_ : rx_;
    MonitorRing &idle = tx ? rx_ : tx_ring_;
    idle.clear();

    // A full ring means the GUI stalled for longer than the ring holds: the
    // producer has been dropping the NEWEST samples, so everything queued is
    // at least that old.  Discard it (consumer-side clear, SPSC-safe) and
    // restart the window rather than present it as live.  The producer is
    // evidently running, so this still counts as data arriving.
    bool gotAny = false;
    if (used.available() >= kRingSize) {
        used.clear();
        std::fill(window_.begin(), window_.end(), 0.0);
        gotAny = true;
    }

    const size_t n = size_t(kFftSize);
    double chunk[1024];
    for (;;) {
        const size_t k = used.pop(chunk, 1024);
        if (k == 0) break;
        gotAny = true;
        if (k >= n) {
            std::memcpy(window_.data(), chunk + (k - n), n * sizeof(double));
        } else {
            std::memmove(window_.data(), window_.data() + k, (n - k) * sizeof(double));
            std::memcpy(window_.data() + (n - k), chunk, k * sizeof(double));
        }
    }
    const auto now = std::chrono::steady_clock::now();
    if (gotAny) {
        lastData_ = now;
        haveData_ = true;
    }
    const bool live = haveData_
        && std::chrono::duration_cast<std::chrono::milliseconds>(now - lastData_).count() < kLiveMs;
    // Data stopped (radio stopped / dock idle): analyse silence, never the
    // frozen last spectrum.  Resuming data refills the window from zeros.
    if (!live) std::fill(window_.begin(), window_.end(), 0.0);

    build(window_.data(), spanHz, tx, live, out);
    return true;
}

bool AudioVisHub::analyse(const float *samples, int n, double spanHz, Frame &out)
{
    if (!samples || n <= 0) return false;
    // Latest kFftSize samples, zero-padded in front when n is shorter; the
    // ring window_ is left alone.
    const size_t N = size_t(kFftSize);
    const size_t take = std::min(size_t(n), N);
    std::fill(anaWindow_.begin(), anaWindow_.end() - std::ptrdiff_t(take), 0.0);
    for (size_t i = 0; i < take; ++i)
        anaWindow_[N - take + i] = double(samples[size_t(n) - take + i]);
    build(anaWindow_.data(), spanHz, false, true, out);
    return true;
}

// Window `win` (kFftSize samples) -> Frame.  Shared by frame() and analyse().
void AudioVisHub::build(const double *win, double spanHz, bool tx, bool live, Frame &out)
{
    const size_t n = size_t(kFftSize);

    // Hann + FFT -> amplitude-correct magnitude (full-scale sine = 0 dB).
    for (size_t i = 0; i < n; ++i) {
        re_[i] = win[i] * hann_[i];
        im_[i] = 0.0;
    }
    fft();
    const size_t bins = n / 2 + 1;
    for (size_t i = 0; i < bins; ++i) {
        // Single-sided spectrum: every bin but DC and Nyquist folds in its
        // negative-frequency twin (x2); those two have no twin.
        const double side = (i == 0 || i == n / 2) ? 1.0 : 2.0;
        const double mag = side * std::hypot(re_[i], im_[i]) / hannSum_;
        magDb_[i] = magToDb(mag);
    }

    const double span = std::clamp(spanHz, 100.0, kSampleRate * 0.5);
    const double binHz = kSampleRate / double(kFftSize);

    for (int i = 0; i < 256; ++i)
        out.lineDb[i] = rangeDb(magDb_, binHz, span * i / 256.0, span * (i + 1) / 256.0);

    const double ratio = span > kLowHz ? span / kLowHz : 1.0;
    for (int i = 0; i < 25; ++i)
        out.bandsDb25[i] = rangeDb(magDb_, binHz,
                                   kLowHz * std::pow(ratio, double(i) / 25.0),
                                   kLowHz * std::pow(ratio, double(i + 1) / 25.0));
    for (int i = 0; i < 24; ++i)
        out.bandsDbRadial[i] = rangeDb(magDb_, binHz,
                                       kLowHz * std::pow(ratio, double(i) / 24.0),
                                       kLowHz * std::pow(ratio, double(i + 1) / 24.0));

    // Scope: 512 samples from the last rising zero-crossing that still leaves
    // 512 samples after it; none found -> the newest 512.
    size_t start = n - 512;
    for (size_t i = n - 512; i >= 1; --i) {
        if (win[i - 1] < 0.0 && win[i] >= 0.0) { start = i; break; }
    }
    for (size_t i = 0; i < 512; ++i) out.scope[i] = float(win[start + i]);

    out.spanHz = span;
    out.tx = tx;
    out.live = live;
}

// --------------------------------------------------------------------------
// DemoSignal

void DemoSignal::fill(float *dst, int n, double fs)
{
    // Vowel formants (F1, F2, F3 Hz): /a/ /e/ /i/ /o/ /u/.
    static const double kVowel[5][3] = {
        {700, 1220, 2600}, {530, 1840, 2480}, {270, 2290, 3010},
        {570,  840, 2410}, {300,  870, 2240},
    };
    static const double kBw[3] = {80.0, 100.0, 140.0};
    static const double kGain[3] = {1.0, 0.7, 0.45};

    for (int s = 0; s < n; ++s) {
        if (untilCoeff_ <= 0) {           // retune the resonators every 64 samples
            untilCoeff_ = 64;
            const double pos = t_ * 0.8;            // ~one vowel per 1.25 s
            const int v0 = int(std::floor(pos)) % 5;
            const int v1 = (v0 + 1) % 5;
            const double fr = pos - std::floor(pos);
            const double sm = fr * fr * (3.0 - 2.0 * fr);
            for (int k = 0; k < 3; ++k) {
                const double f = kVowel[v0][k] * (1.0 - sm) + kVowel[v1][k] * sm;
                const double r = std::exp(-kPi * kBw[k] / fs);
                a1_[k] = 2.0 * r * std::cos(2.0 * kPi * f / fs);
                a2_[k] = -r * r;
                b0_[k] = (1.0 - r) * kGain[k];
            }
        }
        --untilCoeff_;

        const double f0 = 118.0 * (1.0 + 0.03 * std::sin(2.0 * kPi * 5.0 * t_));  // vibrato
        phase_ += f0 / fs;
        phase_ -= std::floor(phase_);
        const double src = 2.0 * phase_ - 1.0;      // sawtooth glottal source

        double y = 0.0;
        for (int k = 0; k < 3; ++k) {
            const double o = b0_[k] * src + a1_[k] * y1_[k] + a2_[k] * y2_[k];
            y2_[k] = y1_[k];
            y1_[k] = o;
            y += o;
        }
        // ~2.5 syllables/s with a short gap between them.
        const double e = std::max(0.0, std::sin(2.0 * kPi * 2.5 * t_));
        dst[s] = float(std::tanh(3.0 * y * (0.25 + 0.75 * e * e)) * 0.6);
        t_ += 1.0 / fs;
    }
}

}  // namespace lyra::dsp::vis
