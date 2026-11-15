// Offline test for lyra::dsp::vis (src/dsp/AudioVisCore.h) — the audio
// visualizer's Qt-free core: span rule, source choice, level/peak shaping,
// dB mapping and palettes.
//   build: cmake --build build --target test_audio_vis_core
//   run:   build/test_audio_vis_core
#include "dsp/AudioVisCore.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

using namespace lyra::dsp::vis;

namespace {

int g_failures = 0;

void check(const char *name, bool ok, double got)
{
    std::printf("  %-58s got=%9.4f  %s\n", name, got, ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

bool rgbIs(int palette, float t, unsigned hex)
{
    uint8_t c[3] = {0, 0, 0};
    paletteColor(palette, t, c);
    return c[0] == ((hex >> 16) & 0xFF) && c[1] == ((hex >> 8) & 0xFF) && c[2] == (hex & 0xFF);
}

unsigned rgbHex(int palette, float t)
{
    uint8_t c[3] = {0, 0, 0};
    paletteColor(palette, t, c);
    return (unsigned(c[0]) << 16) | (unsigned(c[1]) << 8) | c[2];
}

// Step a Shaper with a constant target for `frames` frames of `dt`.
float run(Shaper &sh, float target, int frames, float dt, const Settings &s)
{
    const float t[1] = {target};
    for (int i = 0; i < frames; ++i) sh.step(t, dt, s);
    return sh.level[0];
}

// One FFT-line frame of noise: each point's power is exponential (a Hann bin
// of white noise) around `meanDb`.
void noiseFrame(float *out, int n, float meanDb, std::mt19937 &rng)
{
    std::exponential_distribution<float> pw(1.f);
    for (int i = 0; i < n; ++i)
        out[i] = meanDb + 10.f * std::log10(std::max(pw(rng), 1e-12f));
}

// Fraction of points that map above `unit` with floor `floorDb`.
float fractionAbove(const float *db, int n, float floorDb, float unit)
{
    int c = 0;
    for (int i = 0; i < n; ++i) c += dbToUnit(db[i], floorDb, 100) > unit;
    return float(c) / float(n);
}

}  // namespace

int main()
{
    std::printf("test_audio_vis_core\n");

    // 1. Span rule (clamped 4-10 kHz; AM/SAM/DSB full width, others max |edge|).
    check("span USB 100..2900 -> 4000 (floor)", near(spanHz("USB", 100, 2900), 4000), spanHz("USB", 100, 2900));
    check("span USB 100..6000 -> 6000", near(spanHz("USB", 100, 6000), 6000), spanHz("USB", 100, 6000));
    check("span AM -5000..5000 -> 10000 (full width)", near(spanHz("AM", -5000, 5000), 10000), spanHz("AM", -5000, 5000));
    check("span AM -8000..8000 -> 10000 (cap)", near(spanHz("AM", -8000, 8000), 10000), spanHz("AM", -8000, 8000));
    check("span CWU 300..900 -> 4000", near(spanHz("CWU", 300, 900), 4000), spanHz("CWU", 300, 900));
    check("span LSB -2900..-100 -> 4000", near(spanHz("LSB", -2900, -100), 4000), spanHz("LSB", -2900, -100));
    check("span LSB -7000..-100 -> 7000 (|low|)", near(spanHz("LSB", -7000, -100), 7000), spanHz("LSB", -7000, -100));
    check("span SAM -3000..3000 -> 6000 (full width)", near(spanHz("SAM", -3000, 3000), 6000), spanHz("SAM", -3000, 3000));
    check("span DSB -2500..2500 -> 5000 (full width)", near(spanHz("DSB", -2500, 2500), 5000), spanHz("DSB", -2500, 2500));
    check("span FM -6000..6000 -> 6000 (max edge, not width)", near(spanHz("FM", -6000, 6000), 6000), spanHz("FM", -6000, 6000));

    // 2. Combined span.
    check("combined: muted RX2 ignored -> 4000", near(combinedSpanHz(4000, true, 10000, true, false), 4000),
          combinedSpanHz(4000, true, 10000, true, false));
    check("combined: both audible -> wider", near(combinedSpanHz(4000, true, 7000, true, true), 7000),
          combinedSpanHz(4000, true, 7000, true, true));
    check("combined: closed RX2 ignored -> 4000", near(combinedSpanHz(4000, true, 10000, false, true), 4000),
          combinedSpanHz(4000, true, 10000, false, true));
    check("combined: muted RX1 -> RX2 only", near(combinedSpanHz(9000, false, 6000, true, true), 6000),
          combinedSpanHz(9000, false, 6000, true, true));
    check("combined: nothing audible -> 4000", near(combinedSpanHz(9000, false, 9000, true, false), 4000),
          combinedSpanHz(9000, false, 9000, true, false));

    // 3. Mix.
    check("mix mono-dup -> l", near(mixSample(0.5f, 0.1f, false, false, false), 0.5), mixSample(0.5f, 0.1f, false, false, false));
    check("mix SUB, RX1 muted -> r", near(mixSample(0.5f, 0.1f, true, true, false), 0.1), mixSample(0.5f, 0.1f, true, true, false));
    check("mix SUB, RX2 muted -> l", near(mixSample(0.5f, 0.1f, true, false, true), 0.5), mixSample(0.5f, 0.1f, true, false, true));
    check("mix SUB, both audible -> mean", near(mixSample(0.5f, 0.1f, true, false, false), 0.3), mixSample(0.5f, 0.1f, true, false, false));
    check("mix SUB, none audible -> 0", mixSample(0.5f, 0.1f, true, true, true) == 0.0f, mixSample(0.5f, 0.1f, true, true, true));

    // 4. Source choice.
    check("tx source: MOX + USB", useTxSource(true, "USB", false), 1);
    check("tx source: MOX + DIGL", useTxSource(true, "DIGL", false), 1);
    check("tx source: MOX + DRM", useTxSource(true, "DRM", false), 1);
    check("tx source: MOX + AM", useTxSource(true, "AM", false), 1);
    check("tx source: MOX + FM", useTxSource(true, "FM", false), 1);
    check("tx source: not CW", !useTxSource(true, "CWU", false), 0);
    check("tx source: not CWL", !useTxSource(true, "CWL", false), 0);
    check("tx source: not TUNE / two-tone", !useTxSource(true, "USB", true), 0);
    check("tx source: not without MOX", !useTxSource(false, "USB", false), 0);
    check("tx source: unknown mode -> RX", !useTxSource(true, "XYZ", false), 0);

    // 5. dB mapping.
    check("dbToUnit floor -> 0", dbToUnit(-90.f, -90.f, 100) == 0.0f, dbToUnit(-90.f, -90.f, 100));
    check("dbToUnit 0 dB -> 1", dbToUnit(0.f, -90.f, 100) == 1.0f, dbToUnit(0.f, -90.f, 100));
    check("dbToUnit -inf -> 0", dbToUnit(-INFINITY, -90.f, 100) == 0.0f, dbToUnit(-INFINITY, -90.f, 100));
    check("dbToUnit NaN -> 0", dbToUnit(NAN, -90.f, 100) == 0.0f, dbToUnit(NAN, -90.f, 100));
    check("dbToUnit -45 dB -> 0.5", near(dbToUnit(-45.f, -90.f, 100), 0.5), dbToUnit(-45.f, -90.f, 100));
    check("dbToUnit sensitivity 200% doubles", near(dbToUnit(-67.5f, -90.f, 200), 0.5), dbToUnit(-67.5f, -90.f, 200));
    check("dbToUnit clamps high to 1", dbToUnit(-10.f, -90.f, 300) == 1.0f, dbToUnit(-10.f, -90.f, 300));
    check("dbToUnit below floor -> 0", dbToUnit(-120.f, -90.f, 100) == 0.0f, dbToUnit(-120.f, -90.f, 100));

    // 6. Shaper: attack / decay / frame-rate independence / peak hold.
    {
        const Settings s;   // defaults: attack 70, decay 12, smoothing 30, hold 800
        Shaper sh60; sh60.reset(1);
        const float l10 = run(sh60, 1.0f, 10, 1.f / 60.f, s);
        check("attack 70: > 0.9 within 10 frames", l10 > 0.9f, l10);

        // Same elapsed time (4 frames @60 == 2 frames @30) lands in the same place.
        Shaper a60, a30; a60.reset(1); a30.reset(1);
        const float v60 = run(a60, 1.0f, 4, 1.f / 60.f, s);
        const float v30 = run(a30, 1.0f, 2, 1.f / 30.f, s);
        check("frame-rate independent attack (4@60 vs 2@30, +-0.02)", std::fabs(v60 - v30) <= 0.02f, v60 - v30);
        Shaper b60, b30; b60.reset(1); b30.reset(1);
        const float w60 = run(b60, 1.0f, 12, 1.f / 60.f, s);
        const float w30 = run(b30, 1.0f, 6, 1.f / 30.f, s);
        check("frame-rate independent attack (12@60 vs 6@30, +-0.02)", std::fabs(w60 - w30) <= 0.02f, w60 - w30);

        // Decay 12: slow fall.
        Shaper d; d.reset(1);
        run(d, 1.0f, 300, 1.f / 60.f, s);
        const float settled = d.level[0];
        const float after5 = run(d, 0.0f, 5, 1.f / 60.f, s);
        check("level settles at 1.0 on constant 1.0", near(settled, 1.0, 1e-3), settled);
        check("decay 12: > 0.5 left after 5 frames", after5 > 0.5f, after5);
        const float after300 = run(d, 0.0f, 300, 1.f / 60.f, s);
        check("decay 12: eventually near 0", after300 < 0.01f, after300);

        // Decay is frame-rate independent too.
        Shaper e60, e30; e60.reset(1); e30.reset(1);
        run(e60, 1.0f, 300, 1.f / 60.f, s); run(e30, 1.0f, 150, 1.f / 30.f, s);
        const float f60 = run(e60, 0.0f, 20, 1.f / 60.f, s);
        const float f30 = run(e30, 0.0f, 10, 1.f / 30.f, s);
        check("frame-rate independent decay (20@60 vs 10@30, +-0.02)", std::fabs(f60 - f30) <= 0.02f, f60 - f30);

        // Peak: holds at ~1.0 for peakHoldMs, then falls at 0.5/s.
        Shaper p; p.reset(1);
        run(p, 1.0f, 300, 1.f / 60.f, s);
        const float pk0 = p.peak[0];
        check("peak follows level up to 1.0", near(pk0, 1.0, 1e-3), pk0);
        run(p, 0.0f, 40, 1.f / 60.f, s);   // 667 ms < 800 ms hold
        check("peak held at 1.0 inside hold window (40 frames)", near(p.peak[0], 1.0, 1e-3), p.peak[0]);
        run(p, 0.0f, 80, 1.f / 60.f, s);   // 2.0 s total: ~1.2 s past the hold
        check("peak falling after hold (< 0.6 at 2.0 s)", p.peak[0] < 0.6f, p.peak[0]);
        check("peak still above 0 (fall is 0.5/s, not instant)", p.peak[0] > 0.2f, p.peak[0]);
        run(p, 0.0f, 300, 1.f / 60.f, s);
        check("peak floors at ~0", p.peak[0] < 1e-6f, p.peak[0]);

        // Peak hold 0 ms: begins falling right away.
        Settings z; z.peakHoldMs = 0;
        Shaper q; q.reset(1);
        run(q, 1.0f, 300, 1.f / 60.f, z);
        run(q, 0.0f, 30, 1.f / 60.f, z);   // 0.5 s
        check("peakHoldMs 0: falling without a hold", q.peak[0] < 0.9f, q.peak[0]);

        // Multi-band independence + reset sizing.
        Shaper m; m.reset(3);
        const float tg[3] = {1.f, 0.5f, 0.f};
        for (int i = 0; i < 60; ++i) m.step(tg, 1.f / 60.f, s);
        check("reset(3) sizes level/peak", m.level.size() == 3 && m.peak.size() == 3, double(m.level.size()));
        check("bands independent (1.0 / 0.5 / 0.0)",
              near(m.level[0], 1.0, 0.01) && near(m.level[1], 0.5, 0.01) && near(m.level[2], 0.0, 0.01), m.level[1]);
        m.reset(3);
        check("reset zeroes level and peak", m.level[0] == 0.f && m.peak[0] == 0.f, m.level[0]);

        // seed(): sized and settled at the (clamped) targets, then steady.
        Shaper sd;
        const float st[3] = {0.8f, 1.7f, -0.2f};
        sd.seed(st, 3);
        check("seed(3) sizes level/peak", sd.level.size() == 3 && sd.peak.size() == 3, double(sd.level.size()));
        check("seed: level == clamped targets (0.8 / 1 / 0)",
              sd.level[0] == 0.8f && sd.level[1] == 1.f && sd.level[2] == 0.f, sd.level[0]);
        check("seed: peak == level", sd.peak[0] == 0.8f && sd.peak[1] == 1.f, sd.peak[0]);
        const float st2[3] = {0.8f, 1.f, 0.f};
        sd.step(st2, 1.f / 60.f, s);
        check("seed: steady target does not move the level",
              near(sd.level[0], 0.8, 1e-6) && near(sd.level[1], 1.0, 1e-6), sd.level[0]);
    }

    // 7. Palettes.
    check("kPaletteCount == 9", kPaletteCount == 9, kPaletteCount);
    check("paletteName(0) == Neon", std::string(paletteName(0)) == "Neon", 0);
    check("paletteName(8) == Prism", std::string(paletteName(8)) == "Prism", 8);
    check("Neon t=0 == 06021a", rgbIs(0, 0.f, 0x06021a), rgbHex(0, 0.f));
    check("Neon t=1 == ff2bd6", rgbIs(0, 1.f, 0xff2bd6), rgbHex(0, 1.f));
    check("Neon t=0.5 == 00e5ff (middle stop)", rgbIs(0, 0.5f, 0x00e5ff), rgbHex(0, 0.5f));
    check("Prism t=0 == ff004d", rgbIs(8, 0.f, 0xff004d), rgbHex(8, 0.f));
    check("Prism t=1 == b14dff", rgbIs(8, 1.f, 0xb14dff), rgbHex(8, 1.f));
    check("Ice t=1 == ffffff", rgbIs(4, 1.f, 0xffffff), rgbHex(4, 1.f));
    check("t clamps below 0", rgbIs(0, -3.f, 0x06021a), rgbHex(0, -3.f));
    check("t clamps above 1", rgbIs(0, 7.f, 0xff2bd6), rgbHex(0, 7.f));
    {
        uint8_t c[3]; paletteColor(0, 0.25f, c);   // halfway 06021a -> 00e5ff
        check("Neon t=0.25 is the midpoint of stops 0,1",
              std::abs(int(c[0]) - 3) <= 1 && std::abs(int(c[1]) - 0x73) <= 1 && std::abs(int(c[2]) - 0x8c) <= 1, c[1]);
    }

    // 8. Auto floor.
    {
        constexpr int N = AutoFloor::kMaxPoints;
        const float dt = 1.f / 60.f;
        std::mt19937 rng(7);
        float f[N];

        AutoFloor af;
        check("auto floor: fallback before any estimate", near(af.floorDb(-90.f), -90.0), af.floorDb(-90.f));
        for (int i = 0; i < N; ++i) f[i] = -200.f;
        af.step(f, N, dt);
        check("auto floor: digital silence gives no estimate", !af.valid(), af.floorDb(-90.f));

        // Steady noise around -60 dB for 10 s.
        for (int k = 0; k < 600; ++k) { noiseFrame(f, N, -60.f, rng); af.step(f, N, dt); }
        const float steady = af.floorDb(-90.f);
        // 25th percentile of exponential power = -5.6 dB rel. mean; + 8 dB margin.
        check("auto floor: steady noise -> floor near -57.6 dB", near(steady, -57.6, 1.5), steady);
        noiseFrame(f, N, -60.f, rng);
        const float above = fractionAbove(f, N, steady, 0.1f);
        check("auto floor: < 3 % of noise points above 10 % height", above < 0.03f, above);
        float sorted[N];
        std::copy(f, f + N, sorted);
        std::nth_element(sorted, sorted + N / 2, sorted + N);
        const float medU = dbToUnit(sorted[N / 2], steady, 100);
        check("auto floor: median noise point sits at the bottom (0)", medU == 0.f, medU);
        // Manual floor -90 for comparison: the same noise fills a third.
        const float medManual = dbToUnit(sorted[N / 2], -90.f, 100);
        check("manual floor -90: median noise point at ~1/3 height", medManual > 0.3f, medManual);

        // A tone 40 dB above the noise still reads high, and doesn't move the floor.
        for (int k = 0; k < 120; ++k) {
            noiseFrame(f, N, -60.f, rng);
            for (int i = 100; i < 104; ++i) f[i] = -20.f;
            af.step(f, N, dt);
        }
        const float withTone = af.floorDb(-90.f);
        check("auto floor: tone leaves the floor alone (< 1 dB)", std::fabs(withTone - steady) < 1.f, withTone);
        const float toneU = dbToUnit(-20.f, withTone, 100);
        check("auto floor: -20 dB tone reads > 0.6", toneU > 0.6f, toneU);

        // Speech-like: half the span 30 dB up.  The 25th percentile then
        // lands on the noise half's median (~4 dB over its 25th percentile),
        // so it lifts a little but stays in the noise.
        for (int k = 0; k < 180; ++k) {
            noiseFrame(f, N, -60.f, rng);
            for (int i = 0; i < N / 2; ++i) f[i] += 30.f;
            af.step(f, N, dt);
        }
        const float wide = af.floorDb(-90.f);
        check("auto floor: signal over half the span lifts it < 5 dB", wide - steady < 5.f, wide);
        for (int k = 0; k < 300; ++k) { noiseFrame(f, N, -60.f, rng); af.step(f, N, dt); }

        // Burst: 0.5 s of noise 30 dB up, then back.  Slow up -> only part
        // of the way during the burst; fast down -> back within 3 s.
        const float before = af.floorDb(-90.f);
        for (int k = 0; k < 30; ++k) { noiseFrame(f, N, -30.f, rng); af.step(f, N, dt); }
        const float during = af.floorDb(-90.f);
        check("auto floor: 0.5 s burst lifts it < 30 % of the 30 dB step",
              during - before < 9.f && during > before, during);
        for (int k = 0; k < 180; ++k) { noiseFrame(f, N, -60.f, rng); af.step(f, N, dt); }
        const float after = af.floorDb(-90.f);
        check("auto floor: back within 1 dB 3 s after the burst", std::fabs(after - before) < 1.f, after);

        // A lasting rise is followed within a few seconds.
        for (int k = 0; k < 600; ++k) { noiseFrame(f, N, -45.f, rng); af.step(f, N, dt); }
        const float risen = af.floorDb(-90.f);
        check("auto floor: follows a lasting 15 dB rise within 10 s", near(risen, -42.6, 1.5), risen);

        // Silence (radio stopped / squelch) holds the estimate.
        for (int i = 0; i < N; ++i) f[i] = -200.f;
        for (int k = 0; k < 300; ++k) af.step(f, N, dt);
        check("auto floor: silence holds the floor", near(af.floorDb(-90.f), risen, 1e-4), af.floorDb(-90.f));

        // Clamped to the manual Floor's range.
        AutoFloor loud; for (int i = 0; i < N; ++i) f[i] = -10.f;
        loud.step(f, N, dt);
        check("auto floor: loud noise clamps to -40", near(loud.floorDb(-90.f), -40.0), loud.floorDb(-90.f));
        AutoFloor quiet; for (int i = 0; i < N; ++i) f[i] = -170.f;
        quiet.step(f, N, dt);
        check("auto floor: very quiet clamps to -120", near(quiet.floorDb(-90.f), -120.0), quiet.floorDb(-90.f));
        // NaN points are ignored, not propagated.
        AutoFloor nanf; noiseFrame(f, N, -60.f, rng); f[3] = NAN; f[9] = INFINITY;
        nanf.step(f, N, dt);
        check("auto floor: NaN / Inf points ignored", std::isfinite(nanf.floorDb(-90.f)), nanf.floorDb(-90.f));
    }

    std::printf(g_failures ? "FAILED (%d)\n" : "ALL PASS (0 failures)\n", g_failures);
    return g_failures ? 1 : 0;
}
