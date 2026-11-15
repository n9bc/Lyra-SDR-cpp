// Lyra — audio visualizer core.  See AudioVisCore.h.

#include "dsp/AudioVisCore.h"

#include <algorithm>
#include <cmath>

namespace lyra::dsp::vis {

namespace {

constexpr double kSpanMinHz = 4000.0;
constexpr double kSpanMaxHz = 10000.0;
constexpr float  kPeakFallPerSec = 0.5f;

double clampSpan(double v) noexcept
{
    if (!(v > kSpanMinHz)) return kSpanMinHz;   // also catches NaN
    return v > kSpanMaxHz ? kSpanMaxHz : v;
}

float clamp01(float v) noexcept { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

// Per-frame fraction f (at 60 fps) -> fraction for a step of dtSec.
float perStep(float f, float dtSec) noexcept
{
    f = clamp01(f);
    return 1.f - std::pow(1.f - f, dtSec * 60.f);
}

struct Palette {
    const char *name;
    int         n;
    uint8_t     stops[5][3];
};

constexpr Palette kPalettes[kPaletteCount] = {
    {"Neon",      3, {{0x06, 0x02, 0x1a}, {0x00, 0xe5, 0xff}, {0xff, 0x2b, 0xd6}}},
    {"Synthwave", 4, {{0x14, 0x00, 0x28}, {0x8a, 0x2b, 0xe2}, {0xff, 0x3d, 0x9a}, {0xff, 0xa6, 0x4d}}},
    {"Aurora",    4, {{0x00, 0x1a, 0x14}, {0x00, 0xe0, 0x8a}, {0x00, 0xc8, 0xd6}, {0xa0, 0x66, 0xff}}},
    {"Ember",     4, {{0x1a, 0x00, 0x00}, {0xc4, 0x1a, 0x00}, {0xff, 0x7a, 0x00}, {0xff, 0xe1, 0x4d}}},
    {"Ice",       4, {{0x00, 0x0a, 0x24}, {0x14, 0x60, 0xff}, {0x5f, 0xe6, 0xff}, {0xff, 0xff, 0xff}}},
    {"Toxic",     4, {{0x00, 0x14, 0x00}, {0x14, 0xb4, 0x00}, {0x9c, 0xff, 0x00}, {0xf0, 0xff, 0x4d}}},
    {"Sunset",    4, {{0x12, 0x00, 0x3a}, {0xc1, 0x30, 0x7a}, {0xff, 0x6b, 0x4a}, {0xff, 0xd1, 0x66}}},
    {"Phosphor",  4, {{0x00, 0x0d, 0x00}, {0x0f, 0x7a, 0x2a}, {0x33, 0xff, 0x66}, {0xc8, 0xff, 0xd8}}},
    {"Prism",     5, {{0xff, 0x00, 0x4d}, {0xff, 0xb3, 0x00}, {0x3d, 0xff, 0x5a}, {0x00, 0xb3, 0xff}, {0xb1, 0x4d, 0xff}}},
};

}  // namespace

double spanHz(std::string_view mode, double lowHz, double highHz) noexcept
{
    const bool fullWidth = (mode == "AM" || mode == "SAM" || mode == "DSB");
    const double span = fullWidth ? (highHz - lowHz)
                                  : std::max(std::fabs(lowHz), std::fabs(highHz));
    return clampSpan(span);
}

double combinedSpanHz(double rx1Span, bool rx1Audible,
                      double rx2Span, bool rx2Open, bool rx2Audible) noexcept
{
    double span = kSpanMinHz;
    if (rx1Audible) span = std::max(span, rx1Span);
    if (rx2Open && rx2Audible) span = std::max(span, rx2Span);
    return clampSpan(span);
}

float mixSample(float l, float r, bool sub, bool muteRx1, bool muteRx2) noexcept
{
    if (!sub) return l;
    const bool a = !muteRx1, b = !muteRx2;
    if (a && b) return 0.5f * (l + r);
    if (a) return l;
    if (b) return r;
    return 0.f;
}

bool useTxSource(bool mox, std::string_view mode, bool tuneOrTwoTone) noexcept
{
    if (!mox || tuneOrTwoTone) return false;
    return mode == "USB" || mode == "LSB" || mode == "AM" || mode == "SAM" ||
           mode == "DSB" || mode == "FM"  || mode == "DIGU" || mode == "DIGL" ||
           mode == "DRM";
}

void Shaper::reset(int n)
{
    const size_t sz = n > 0 ? static_cast<size_t>(n) : 0;
    level.assign(sz, 0.f);
    peak.assign(sz, 0.f);
    smooth_.assign(sz, 0.f);
    hold_.assign(sz, 0.f);
}

void Shaper::seed(const float *targets, int n)
{
    reset(n);
    if (!targets) return;
    for (size_t i = 0; i < level.size(); ++i) {
        const float t = clamp01(targets[i]);
        level[i] = peak[i] = smooth_[i] = t;
    }
}

void Shaper::step(const float *targets, float dtSec, const Settings &s)
{
    if (!(dtSec > 0.f)) return;
    // Smoothing is the weight kept on the previous input (s/100 per frame);
    // the fresh input gets the remainder.
    const float smoothKeep = clamp01(s.smoothing / 100.f);
    const float fSmooth = perStep(1.f - smoothKeep, dtSec);
    const float fAttack = perStep(s.attack / 100.f, dtSec);
    const float fDecay  = perStep(s.decay / 100.f, dtSec);
    const float holdSec = s.peakHoldMs > 0 ? s.peakHoldMs / 1000.f : 0.f;

    for (size_t i = 0; i < level.size(); ++i) {
        smooth_[i] += (clamp01(targets[i]) - smooth_[i]) * fSmooth;
        const float gap = smooth_[i] - level[i];
        level[i] += gap * (gap > 0.f ? fAttack : fDecay);

        if (level[i] >= peak[i]) {
            peak[i] = level[i];
            hold_[i] = holdSec;
        } else {
            hold_[i] -= dtSec;
            if (hold_[i] < 0.f) peak[i] = std::max(0.f, peak[i] - dtSec * kPeakFallPerSec);
        }
    }
}

void AutoFloor::step(const float *lineDb, int n, float dtSec) noexcept
{
    if (!lineDb || n <= 0) return;
    n = std::min(n, kMaxPoints);
    int m = 0;
    for (int i = 0; i < n; ++i) {
        const float v = lineDb[i];
        if (std::isfinite(v) && v > kSilentDb) scratch_[m++] = v;
    }
    if (m < std::max(1, n / 4)) return;            // mostly silence: hold
    const int k = std::min(m - 1, static_cast<int>(kPercentile * static_cast<float>(m)));
    std::nth_element(scratch_, scratch_ + k, scratch_ + m);
    const float est = scratch_[k];
    if (!have_) {
        noise_ = est;
        have_ = true;
        return;
    }
    if (!(dtSec > 0.f)) return;
    const float tau = est < noise_ ? kDownSec : kUpSec;
    noise_ += (est - noise_) * (1.f - std::exp(-dtSec / tau));
}

float AutoFloor::floorDb(float fallback) const noexcept
{
    if (!have_) return fallback;
    return std::clamp(noise_ + kMarginDb, kMinDb, kMaxDb);
}

float dbToUnit(float db, float floorDb, int sensitivityPct) noexcept
{
    if (std::isnan(db) || (std::isinf(db) && db < 0.f)) return 0.f;
    if (!(floorDb < 0.f)) return 0.f;
    const float u = (db - floorDb) / (0.f - floorDb) * (sensitivityPct / 100.f);
    return clamp01(u);
}

const char *paletteName(int i)
{
    return (i >= 0 && i < kPaletteCount) ? kPalettes[i].name : "";
}

void paletteColor(int palette, float t, uint8_t rgb[3])
{
    const Palette &p = kPalettes[std::clamp(palette, 0, kPaletteCount - 1)];
    t = std::isnan(t) ? 0.f : clamp01(t);
    const float pos = t * static_cast<float>(p.n - 1);
    const int   k   = std::min(static_cast<int>(pos), p.n - 2);
    const float f   = pos - static_cast<float>(k);
    for (int c = 0; c < 3; ++c) {
        const float v = p.stops[k][c] + (p.stops[k + 1][c] - p.stops[k][c]) * f;
        rgb[c] = static_cast<uint8_t>(std::lround(v));
    }
}

}  // namespace lyra::dsp::vis
