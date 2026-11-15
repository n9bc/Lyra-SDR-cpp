// Lyra — audio visualizer core (pure functions).
//
// The Qt-free foundation of the dock visualizer: which audio span to show,
// which source (RX tap vs TX mic) feeds it, the dB -> 0..1 mapping and the
// automatic noise floor under it, the attack/decay/smoothing/peak-hold
// shaping of the band levels, and the nine amplitude-mapped colour palettes.  Dependency-free so it unit-tests
// standalone (scratch/test_audio_vis_core.cpp); the hub, engine taps and the
// scene-graph item consume these exact signatures.
//
// Mode strings are the engine's: USB LSB CWU CWL DSB AM SAM FM DIGU DIGL DRM.

#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

namespace lyra::dsp::vis {

// Audio span (Hz) shown for one receiver: AM/SAM/DSB = full filter width
// (high - low); every other mode = max(|low|, |high|).  Clamped 4000..10000.
double spanHz(std::string_view mode, double lowHz, double highHz) noexcept;

// Span for the whole mix: the wider of the audible receivers (RX2 only when
// open and audible); a muted receiver is excluded.  None audible -> 4000.
double combinedSpanHz(double rx1Span, bool rx1Audible,
                      double rx2Span, bool rx2Open, bool rx2Audible) noexcept;

// One mixed mono sample from the RX tap's L/R.  Not SUB: l (mono-dup, the
// receiver mute is not applied).  SUB: mean of the audible channels
// (a muted receiver is left out); none audible -> 0.
float mixSample(float l, float r, bool sub, bool muteRx1, bool muteRx2) noexcept;

// True when the visualizer should show TX mic audio instead of the RX tap:
// MOX up, a voice/digital mode (USB LSB AM SAM DSB FM DIGU DIGL DRM), and not
// TUNE / two-tone.  CW and everything else stay on the RX tap.
bool useTxSource(bool mox, std::string_view mode, bool tuneOrTwoTone) noexcept;

struct Settings {
    int   attack      = 70;     // 5..100   per-frame approach fraction (%)
    int   decay       = 12;     // 1..60    per-frame approach fraction (%)
    int   smoothing   = 30;     // 0..90    input averaging weight (%)
    int   peakHoldMs  = 800;    // 0..3000
    int   sensitivity = 100;    // 20..300  linear gain (%)
    float floorDb     = -90.f;  // -120..-40
};

// Per-band level + peak shaping.  `targets` are 0..1 normalised (n values as
// given to reset()).  Fractions are per-frame at 60 fps and made
// frame-rate independent via 1 - (1 - f)^(dt * 60).
struct Shaper {
    void reset(int n);
    // reset(n), then start every band settled AT targets (level, smoothed
    // input and peak all = the clamped target) instead of at the floor --
    // a view switch shows the current picture at once.
    void seed(const float *targets, int n);
    void step(const float *targets, float dtSec, const Settings &s);

    std::vector<float> level, peak;

private:
    std::vector<float> smooth_;   // smoothed input
    std::vector<float> hold_;     // per-band peak hold time left (s)
};

// Automatic noise floor (Settings → Visualizer → Auto floor, on by default).
// Tracks the received noise from the FFT line points -- their 25th
// percentile, so a signal covering up to three quarters of the span does not
// move it -- fast down (0.25 s time constant), slow up (2 s), and puts the
// display floor kMarginDb above it, so band noise sits at the bottom of the
// picture and signals stand out.  Points at the digital-silence floor
// (radio stopped, squelch closed) are left out; with fewer than a quarter of
// the points above it the estimate holds.  The first estimate is taken as
// is (no ramp from an arbitrary start).  Fixed scratch, no allocation.
class AutoFloor {
public:
    static constexpr int   kMaxPoints  = 256;      // Frame::lineDb
    static constexpr float kPercentile = 0.25f;
    static constexpr float kMarginDb   = 8.f;      // floor = noise + margin
    static constexpr float kDownSec    = 0.25f;    // time constant, noise falling
    static constexpr float kUpSec      = 2.0f;     // time constant, noise rising
    static constexpr float kMinDb      = -120.f;   // the manual Floor's range
    static constexpr float kMaxDb      = -40.f;
    static constexpr float kSilentDb   = -190.f;   // at/below: digital silence

    void reset() noexcept { have_ = false; }
    // One frame of line points (dB; the first kMaxPoints are used), dtSec
    // since the previous frame.
    void step(const float *lineDb, int n, float dtSec) noexcept;
    // The floor to draw with: noise + margin, clamped to kMinDb..kMaxDb;
    // `fallback` until the first estimate.
    float floorDb(float fallback) const noexcept;
    bool  valid() const noexcept { return have_; }
    float noiseDb() const noexcept { return noise_; }

private:
    float scratch_[kMaxPoints] = {};
    float noise_ = 0.f;
    bool  have_ = false;
};

// (db - floor) / (0 - floor), scaled by sensitivity/100, clamped 0..1.
// NaN and -inf map to 0.
float dbToUnit(float db, float floorDb, int sensitivityPct) noexcept;

constexpr int kPaletteCount = 9;
const char *paletteName(int i);                        // "" if out of range
// Linear interpolation across the palette's evenly spaced stops; t clamped to
// 0..1 (an out-of-range palette index is clamped too).
void paletteColor(int palette, float t, uint8_t rgb[3]);

}  // namespace lyra::dsp::vis
