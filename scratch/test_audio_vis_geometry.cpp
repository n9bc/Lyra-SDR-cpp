// Offline test for lyra::dsp::vis::geom (src/dsp/AudioVisGeometry.h) — the
// audio visualizer's Qt-free view layout (25-bar rects, Radial spokes, FFT
// line / Scope points) and the anti-aliased triangle mesh the scene-graph
// item uploads.
//   build: cmake --build build --target test_audio_vis_geometry
//   run:   build/test_audio_vis_geometry
#include "dsp/AudioVisGeometry.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

using namespace lyra::dsp::vis::geom;

namespace {

int g_failures = 0;

void check(const char *name, bool ok, double got)
{
    std::printf("  %-58s got=%9.4f  %s\n", name, got, ok ? "PASS" : "FAIL");
    if (!ok) ++g_failures;
}

bool near(double a, double b, double tol = 1e-3) { return std::fabs(a - b) <= tol; }

double dist(Pt a, Pt b) { return std::hypot(double(a.x) - b.x, double(a.y) - b.y); }

bool indicesInRange(const Mesh &m)
{
    for (uint16_t i : m.i)
        if (i >= m.v.size()) return false;
    return m.i.size() % 3 == 0;
}

}  // namespace

int main()
{
    std::printf("test_audio_vis_geometry\n");

    // 1. 25-bar: 25 bands, each bar 76 % of its slot, centred, rising from the
    //    bottom edge to level * 0.9 * h.
    {
        const float w = 500.f, h = 200.f;
        check("25-bar band count", kBarBands == 25, kBarBands);
        bool widthOk = true, centredOk = true, bottomOk = true;
        for (int k = 0; k < kBarBands; ++k) {
            const Rect r = barRect(k, kBarBands, 0.5f, w, h);
            const float slot = w / kBarBands;
            widthOk   &= near(r.w, 0.76f * slot);
            centredOk &= near(r.x + r.w / 2, (k + 0.5f) * slot);
            bottomOk  &= near(r.y + r.h, h);
        }
        check("25-bar every rect is 76% of the slot", widthOk, barRect(0, 25, 0.5f, w, h).w);
        check("25-bar every rect centred in its slot", centredOk, barRect(0, 25, 0.5f, w, h).x);
        check("25-bar rects stand on the bottom edge", bottomOk, 0);
        check("25-bar full level = 0.9 h", near(barRect(3, 25, 1.f, w, h).h, 0.9f * h),
              barRect(3, 25, 1.f, w, h).h);
        check("25-bar zero level = zero height", near(barRect(3, 25, 0.f, w, h).h, 0), 0);
        check("25-bar level clamped to 1", near(barRect(3, 25, 2.f, w, h).h, 0.9f * h), 0);

        const Rect cap = peakCapRect(7, 25, 0.6f, w, h);
        const float peakTop = h - 0.6f * 0.9f * h;
        check("peak cap sits just above the held peak", cap.y + cap.h <= peakTop + 1e-3f
                  && cap.y + cap.h > peakTop - 4.f, cap.y + cap.h);
        check("peak cap same width as the bar", near(cap.w, barRect(7, 25, 0.f, w, h).w), cap.w);
        check("peak cap is thin (< 2% of h)", cap.h > 0.f && cap.h < 0.02f * h, cap.h);

        check("bar gradient t=0.15 at the base", near(barGradientT(0.f), 0.15f), barGradientT(0.f));
        check("bar gradient t=0.6 at 60% height", near(barGradientT(0.6f), 0.6f), barGradientT(0.6f));
        check("bar gradient t=1 at full height", near(barGradientT(1.f), 1.f), barGradientT(1.f));
    }

    // 2. Radial: 48 spokes = 24 bands mirrored, inner radius 0.20 min(w,h),
    //    max length 0.28 min(w,h), spoke 0 at 12 o'clock, clockwise.
    {
        const float w = 400.f, h = 300.f, m = 300.f;
        const Pt c{w / 2, h / 2};
        check("radial spoke count 48", kSpokes == 48, kSpokes);
        check("radial band count 24", kRadialBands == 24, kRadialBands);
        std::vector<int> uses(kRadialBands, 0);
        bool mirrorOk = true;
        for (int k = 0; k < kSpokes; ++k) {
            const int b = spokeBand(k);
            if (b >= 0 && b < kRadialBands) ++uses[b];
            mirrorOk &= spokeBand(k) == spokeBand(kSpokes - 1 - k);
        }
        check("radial every band drives exactly 2 spokes",
              std::all_of(uses.begin(), uses.end(), [](int u) { return u == 2; }), uses[0]);
        check("radial spokes mirrored (k and 47-k share a band)", mirrorOk, 0);

        bool innerOk = true, maxOk = true, zeroOk = true;
        for (int k = 0; k < kSpokes; ++k) {
            Pt in{}, out{};
            spokeEnds(k, 1.f, w, h, 0.3f, in, out);
            innerOk &= near(dist(in, c), 0.20 * m);
            maxOk   &= near(dist(in, out), 0.28 * m);
            spokeEnds(k, 0.f, w, h, 0.3f, in, out);
            zeroOk  &= near(dist(in, out), 0.0);
        }
        check("radial inner radius = 0.20 min(w,h)", innerOk, 0.20 * m);
        check("radial max spoke length = 0.28 min(w,h)", maxOk, 0.28 * m);
        check("radial zero level = zero length", zeroOk, 0);

        Pt in{}, out{};
        spokeEnds(0, 0.5f, w, h, 0.f, in, out);
        check("radial spoke 0 starts at 12 o'clock (x = cx)", near(in.x, c.x), in.x);
        check("radial spoke 0 starts at 12 o'clock (above centre)", in.y < c.y && out.y < in.y, in.y);
        spokeEnds(12, 0.5f, w, h, 0.f, in, out);
        check("radial spoke 12 at 3 o'clock (clockwise)", in.x > c.x && near(in.y, c.y), in.x);
        check("radial rotation offsets the angle", near(spokeAngle(0, 0.25f), -3.14159265358979 / 2 + 0.25), spokeAngle(0, 0.25f));

        const Pt dot = peakDotCentre(5, 0.5f, w, h, 0.f);
        spokeEnds(5, 0.5f, w, h, 0.f, in, out);
        check("radial peak dot sits just beyond the held peak",
              dist(dot, c) > dist(out, c) && dist(dot, c) < dist(out, c) + 0.05 * m, dist(dot, c));
        check("radial faint circle at 0.92 x inner radius",
              near(innerCircleRadius(w, h), 0.92 * 0.20 * m), innerCircleRadius(w, h));
    }

    // 3. FFT line / Scope point mapping.
    {
        const float w = 300.f, h = 100.f;
        check("fft line first point at x=0", near(linePoint(0, 256, 0.f, w, h).x, 0), 0);
        check("fft line last point at x=w", near(linePoint(255, 256, 0.f, w, h).x, w), 0);
        check("fft line full level at 0.88 h above base",
              near(linePoint(10, 256, 1.f, w, h).y, h - 0.88f * h), linePoint(10, 256, 1.f, w, h).y);
        check("fft line zero level on the bottom edge", near(linePoint(10, 256, 0.f, w, h).y, h), 0);
        check("scope zero sample on the centre line", near(scopePoint(3, 512, 0.f, w, h).y, h / 2), 0);
        check("scope +1 sample 0.4 h above centre", near(scopePoint(3, 512, 1.f, w, h).y, h / 2 - 0.4f * h), 0);
        check("scope sample clamped to +-1", near(scopePoint(3, 512, -5.f, w, h).y, h / 2 + 0.4f * h), 0);
    }

    // 3b. Frequency -> x for the dock's axis labels.
    {
        const float w = 500.f;
        check("bar axis: low edge at x=0", near(barFreqX(50.f, 50.f, 4000.f, w), 0), barFreqX(50.f, 50.f, 4000.f, w));
        check("bar axis: span at x=w", near(barFreqX(4000.f, 50.f, 4000.f, w), w), barFreqX(4000.f, 50.f, 4000.f, w));
        // Band k's lower edge = 50·80^(k/25) lands on slot k's left edge.
        const float edge7 = 50.f * std::pow(80.f, 7.f / 25.f);
        check("bar axis: band 7's lower edge on slot 7's left edge",
              near(barFreqX(edge7, 50.f, 4000.f, w), 7.f * w / 25.f, 0.01), barFreqX(edge7, 50.f, 4000.f, w));
        // A frequency inside band k is under bar k's slot.
        const float x1k = barFreqX(1000.f, 50.f, 4000.f, w);
        const int k1k = int(25.f * std::log(1000.f / 50.f) / std::log(80.f));
        check("bar axis: 1 kHz inside its band's slot",
              x1k >= k1k * w / 25.f && x1k < (k1k + 1) * w / 25.f, x1k);
        check("bar axis: below the low edge -> -1", near(barFreqX(20.f, 50.f, 4000.f, w), -1), 0);
        check("bar axis: above the span -> -1", near(barFreqX(5000.f, 50.f, 4000.f, w), -1), 0);
        check("bar axis: wider span moves 1 kHz left",
              barFreqX(1000.f, 50.f, 10000.f, w) < x1k, barFreqX(1000.f, 50.f, 10000.f, w));
        check("line axis: 0 Hz at x=0", near(lineFreqX(0.f, 4000.f, 256, w), 0), lineFreqX(0.f, 4000.f, 256, w));
        check("line axis: span at x=w", near(lineFreqX(4000.f, 4000.f, 256, w), w), lineFreqX(4000.f, 4000.f, 256, w));
        // Point 64 covers [1000, 1015.6) Hz at span 4 kHz; its centre is drawn at 64/255 w.
        check("line axis: point 64's centre frequency at linePoint(64).x",
              near(lineFreqX(64.5f * 4000.f / 256.f, 4000.f, 256, w), linePoint(64, 256, 0.f, w, 100.f).x, 0.01),
              lineFreqX(64.5f * 4000.f / 256.f, 4000.f, 256, w));
        check("line axis: 2 kHz near mid-width at span 4 kHz",
              near(lineFreqX(2000.f, 4000.f, 256, w), w / 2, 1.5), lineFreqX(2000.f, 4000.f, 256, w));
        check("line axis: outside the span -> -1", near(lineFreqX(4500.f, 4000.f, 256, w), -1), 0);
    }

    // 4. Mesh: anti-aliased stroke = core + transparent fringe, premultiplied.
    {
        Mesh m;
        const Pt line[2] = {{0.f, 10.f}, {100.f, 10.f}};
        m.stroke(line, 2, 4.f, 1.f, Rgba{255.f, 0.f, 0.f, 0.5f});
        check("stroke 2 points -> 8 vertices", m.v.size() == 8, double(m.v.size()));
        check("stroke 2 points -> 18 indices (3 bands)", m.i.size() == 18, double(m.i.size()));
        check("stroke indices in range", indicesInRange(m), 0);
        float minY = 1e9f, maxY = -1e9f, coreMin = 1e9f, coreMax = -1e9f;
        bool fringeClear = true, corePremul = true;
        for (const Vtx &v : m.v) {
            minY = std::min(minY, v.y); maxY = std::max(maxY, v.y);
            if (v.a == 0) { fringeClear &= v.r == 0 && v.g == 0 && v.b == 0; }
            else {
                coreMin = std::min(coreMin, v.y); coreMax = std::max(coreMax, v.y);
                corePremul &= v.a == 128 && v.r == 128 && v.g == 0;   // 255 * 0.5
            }
        }
        check("stroke outer extent = width + feather", near(maxY - minY, 5.f), maxY - minY);
        check("stroke core extent = width - feather", near(coreMax - coreMin, 3.f), coreMax - coreMin);
        check("stroke fringe vertices fully transparent", fringeClear, 0);
        check("stroke core colour premultiplied (255*0.5)", corePremul, 0);

        m.clear();
        const Pt poly[4] = {{0, 0}, {10, 5}, {20, 0}, {30, 5}};
        m.stroke(poly, 4, 2.f, 1.f, Rgba{0, 255, 0, 1});
        check("stroke 4 points -> 16 vertices, 54 indices", m.v.size() == 16 && m.i.size() == 54,
              double(m.i.size()));
        m.clear();
        m.stroke(poly, 4, 2.f, 1.f, Rgba{0, 255, 0, 1}, /*closed*/ true);
        check("closed stroke adds the wrap segment (72 indices)", m.i.size() == 72, double(m.i.size()));
        check("closed stroke indices in range", indicesInRange(m), 0);

        m.clear();
        const Pt same[3] = {{5, 5}, {5, 5}, {5, 5}};
        m.stroke(same, 3, 2.f, 1.f, Rgba{0, 255, 0, 1});
        check("degenerate (coincident) polyline emits nothing", m.v.empty() && m.i.empty(), double(m.v.size()));

        m.clear();
        m.segment(Pt{50, 50}, Pt{50, 50}, Pt{0, -1}, 4.f, 1.f, Rgba{255, 255, 255, 1}, 2.f);
        float sMinY = 1e9f, sMaxY = -1e9f;
        for (const Vtx &v : m.v) { sMinY = std::min(sMinY, v.y); sMaxY = std::max(sMaxY, v.y); }
        check("zero-length segment still draws a cap-sized quad", m.v.size() == 8 && sMaxY - sMinY > 3.f,
              sMaxY - sMinY);

        m.clear();
        m.disc(Pt{20, 20}, 3.f, 1.f, Rgba{255, 255, 255, 1}, 12);
        check("disc -> 1 + 2*12 vertices", m.v.size() == 25, double(m.v.size()));
        check("disc -> 3*12 triangles", m.i.size() == 108, double(m.i.size()));
        check("disc indices in range", indicesInRange(m), 0);

        m.clear();
        m.rectV(Rect{0, 0, 10, 20}, Rgba{255, 255, 255, 1}, Rgba{0, 0, 255, 1});
        check("rect -> 4 vertices, 6 indices", m.v.size() == 4 && m.i.size() == 6, double(m.v.size()));

        m.clear();
        const Pt fpts[3] = {{0, 50}, {50, 0}, {100, 50}};
        m.fillUnder(fpts, 3, 100.f, Rgba{255, 0, 0, 0.35f}, Rgba{255, 0, 0, 0.f}, 100.f);
        bool baseClear = true; int topA = -1;
        for (const Vtx &v : m.v) {
            if (near(v.y, 100.f)) baseClear &= v.a == 0;
            if (near(v.y, 0.f)) topA = v.a;
        }
        check("fill -> 2 vertices per point, 6 indices per segment", m.v.size() == 6 && m.i.size() == 12,
              double(m.i.size()));
        check("fill fades to transparent at the base", baseClear, 0);
        check("fill top colour = 35% alpha at y=0", topA == 89, topA);   // 255 * 0.35

        // Vertex budget: a uint16 index buffer can't address more than 65535.
        m.clear();
        std::vector<Pt> many(30000, Pt{0, 0});
        for (size_t k = 0; k < many.size(); ++k) many[k] = Pt{float(k), float(k % 2)};
        m.stroke(many.data(), int(many.size()), 2.f, 1.f, Rgba{255, 255, 255, 1});
        check("mesh never exceeds the uint16 vertex budget", m.v.size() <= 65535 && indicesInRange(m),
              double(m.v.size()));
    }

    std::printf("%s (%d failure%s)\n", g_failures ? "FAILED" : "ALL PASS", g_failures,
                g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
