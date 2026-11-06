// Lyra — audio visualizer view layout + triangle mesh.  See AudioVisGeometry.h.

#include "dsp/AudioVisGeometry.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace lyra::dsp::vis::geom {

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr std::size_t kMaxVertices = 65535;   // uint16 index range
// Sharp corners (a spiky spectrum, a scope trace of high-frequency audio)
// would otherwise throw miter joins far past the line; past this factor the
// join is simply narrower.
constexpr float kMiterLimit = 2.5f;

float clamp01(float v) noexcept { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

Pt sub(Pt a, Pt b) noexcept { return {a.x - b.x, a.y - b.y}; }

Pt unit(Pt d) noexcept
{
    const float len = std::sqrt(d.x * d.x + d.y * d.y);
    return len > 1e-9f ? Pt{d.x / len, d.y / len} : Pt{0.f, 0.f};
}

float radialScale(float w, float h) noexcept { return std::min(w, h); }

}  // namespace

// ---- layout ---------------------------------------------------------------

Rect barRect(int k, int n, float level, float w, float h) noexcept
{
    const float slot = n > 0 ? w / float(n) : w;
    const float bw = slot * kBarWidth;
    const float bh = clamp01(level) * h * kBarHeight;
    return Rect{k * slot + (slot - bw) * 0.5f, h - bh, bw, bh};
}

Rect peakCapRect(int k, int n, float peak, float w, float h) noexcept
{
    const Rect bar = barRect(k, n, peak, w, h);
    const float unitPx = w / 600.f;
    const float capH = std::max(1.f, 3.f * unitPx);
    const float bottom = bar.y - unitPx;
    return Rect{bar.x, bottom - capH, bar.w, capH};
}

float barGradientT(float f) noexcept
{
    f = clamp01(f);
    return f <= 0.6f ? 0.15f + f * (0.45f / 0.6f) : f;
}

Pt linePoint(int i, int n, float level, float w, float h) noexcept
{
    const float x = n > 1 ? float(i) / float(n - 1) * w : 0.f;
    return Pt{x, h - clamp01(level) * h * kLineHeight};
}

Pt scopePoint(int i, int n, float sample, float w, float h) noexcept
{
    const float x = n > 1 ? float(i) / float(n - 1) * w : 0.f;
    const float s = sample < -1.f ? -1.f : (sample > 1.f ? 1.f : sample);
    return Pt{x, h * 0.5f - s * h * kScopeAmp};
}

int spokeBand(int k) noexcept
{
    k = ((k % kSpokes) + kSpokes) % kSpokes;
    return k < kRadialBands ? k : kSpokes - 1 - k;
}

float spokeAngle(int k, float rotation) noexcept
{
    return float(k) / float(kSpokes) * 2.f * kPi - kPi / 2.f + rotation;
}

void spokeEnds(int k, float level, float w, float h, float rotation,
               Pt &inner, Pt &outer) noexcept
{
    const float R = radialScale(w, h);
    const float r0 = R * kInnerRadius;
    const float r1 = r0 + clamp01(level) * R * kSpokeLength;
    const float a = spokeAngle(k, rotation);
    const float cx = w * 0.5f, cy = h * 0.5f;
    const float ca = std::cos(a), sa = std::sin(a);
    inner = Pt{cx + ca * r0, cy + sa * r0};
    outer = Pt{cx + ca * r1, cy + sa * r1};
}

Pt peakDotCentre(int k, float peak, float w, float h, float rotation) noexcept
{
    const float R = radialScale(w, h);
    const float rp = R * kInnerRadius + clamp01(peak) * R * kSpokeLength + w / 120.f;
    const float a = spokeAngle(k, rotation);
    return Pt{w * 0.5f + std::cos(a) * rp, h * 0.5f + std::sin(a) * rp};
}

float innerCircleRadius(float w, float h) noexcept
{
    return radialScale(w, h) * kInnerRadius * kRingRadius;
}

float strokeWidth(float w, float divisor) noexcept
{
    return divisor > 0.f ? std::max(1.f, w / divisor) : 1.f;
}

// ---- mesh -----------------------------------------------------------------

bool Mesh::room(std::size_t addV) const
{
    return v.size() + addV <= kMaxVertices;
}

void Mesh::pushP(float x, float y, float r, float g, float b, float a)
{
    auto q = [](float c) {
        return static_cast<uint8_t>(std::lround(std::clamp(c, 0.f, 255.f)));
    };
    v.push_back(Vtx{x, y, q(r), q(g), q(b), q(a)});
}

void Mesh::tri(std::size_t a, std::size_t b, std::size_t c)
{
    i.push_back(static_cast<uint16_t>(a));
    i.push_back(static_cast<uint16_t>(b));
    i.push_back(static_cast<uint16_t>(c));
}

void Mesh::rectV(Rect r, Rgba top, Rgba bottom)
{
    if (!room(4)) return;
    const std::size_t base = v.size();
    const float ta = clamp01(top.a), ba = clamp01(bottom.a);
    pushP(r.x,       r.y,       top.r * ta, top.g * ta, top.b * ta, 255.f * ta);
    pushP(r.x + r.w, r.y,       top.r * ta, top.g * ta, top.b * ta, 255.f * ta);
    pushP(r.x,       r.y + r.h, bottom.r * ba, bottom.g * ba, bottom.b * ba, 255.f * ba);
    pushP(r.x + r.w, r.y + r.h, bottom.r * ba, bottom.g * ba, bottom.b * ba, 255.f * ba);
    tri(base, base + 1, base + 2);
    tri(base + 1, base + 3, base + 2);
}

void Mesh::stroke(const Pt *p, int n, float width, float feather, Rgba c,
                  bool closed)
{
    if (!p || n < 2) return;
    pts_.clear();
    for (int k = 0; k < n; ++k) {
        if (!pts_.empty()) {
            const Pt d = sub(p[k], pts_.back());
            if (d.x * d.x + d.y * d.y < 1e-8f) continue;
        }
        pts_.push_back(p[k]);
    }
    if (closed && pts_.size() > 1) {
        const Pt d = sub(pts_.front(), pts_.back());
        if (d.x * d.x + d.y * d.y < 1e-8f) pts_.pop_back();
    }
    const std::size_t m = pts_.size();
    if (m < 2) return;
    if (closed && m < 3) closed = false;
    const std::size_t segs = closed ? m : m - 1;
    if (!room(4 * m)) return;

    dir_.resize(segs);
    for (std::size_t s = 0; s < segs; ++s)
        dir_[s] = unit(sub(pts_[(s + 1) % m], pts_[s]));

    const float core  = std::max(0.f, (width - feather) * 0.5f);
    const float outer = (width + feather) * 0.5f;
    const float ca = clamp01(c.a);
    const float pr = c.r * ca, pg = c.g * ca, pb = c.b * ca, pa = 255.f * ca;
    const std::size_t base = v.size();

    for (std::size_t j = 0; j < m; ++j) {
        Pt t;
        float miter = 1.f;
        const bool end = !closed && (j == 0 || j == m - 1);
        if (end) {
            t = dir_[j == 0 ? 0 : segs - 1];
        } else {
            const Pt d0 = dir_[(j + segs - 1) % segs];
            const Pt d1 = dir_[j % segs];
            t = unit(Pt{d0.x + d1.x, d0.y + d1.y});
            if (t.x == 0.f && t.y == 0.f) t = d1;   // full reversal
            const float cosHalf = t.x * d1.x + t.y * d1.y;
            miter = 1.f / std::max(cosHalf, 1.f / kMiterLimit);
        }
        const Pt nrm{-t.y * miter, t.x * miter};
        const Pt q = pts_[j];
        pushP(q.x - nrm.x * outer, q.y - nrm.y * outer, 0, 0, 0, 0);
        pushP(q.x - nrm.x * core,  q.y - nrm.y * core,  pr, pg, pb, pa);
        pushP(q.x + nrm.x * core,  q.y + nrm.y * core,  pr, pg, pb, pa);
        pushP(q.x + nrm.x * outer, q.y + nrm.y * outer, 0, 0, 0, 0);
    }
    for (std::size_t s = 0; s < segs; ++s) {
        const std::size_t a = base + 4 * s;
        const std::size_t b = base + 4 * ((s + 1) % m);
        for (std::size_t band = 0; band < 3; ++band) {
            tri(a + band, a + band + 1, b + band);
            tri(a + band + 1, b + band + 1, b + band);
        }
    }
}

void Mesh::segment(Pt a, Pt b, Pt dir, float width, float feather, Rgba c,
                   float capExtend)
{
    if (!room(8)) return;
    const Pt d = unit(dir);
    if (d.x == 0.f && d.y == 0.f) return;
    const Pt a2{a.x - d.x * capExtend, a.y - d.y * capExtend};
    const Pt b2{b.x + d.x * capExtend, b.y + d.y * capExtend};
    const Pt nrm{-d.y, d.x};
    const float core  = std::max(0.f, (width - feather) * 0.5f);
    const float outer = (width + feather) * 0.5f;
    const float ca = clamp01(c.a);
    const float pr = c.r * ca, pg = c.g * ca, pb = c.b * ca, pa = 255.f * ca;
    const std::size_t base = v.size();
    for (const Pt q : {a2, b2}) {
        pushP(q.x - nrm.x * outer, q.y - nrm.y * outer, 0, 0, 0, 0);
        pushP(q.x - nrm.x * core,  q.y - nrm.y * core,  pr, pg, pb, pa);
        pushP(q.x + nrm.x * core,  q.y + nrm.y * core,  pr, pg, pb, pa);
        pushP(q.x + nrm.x * outer, q.y + nrm.y * outer, 0, 0, 0, 0);
    }
    for (std::size_t band = 0; band < 3; ++band) {
        tri(base + band, base + band + 1, base + 4 + band);
        tri(base + band + 1, base + 4 + band + 1, base + 4 + band);
    }
}

void Mesh::disc(Pt c, float radius, float feather, Rgba col, int segments)
{
    if (segments < 3) segments = 3;
    const std::size_t m = static_cast<std::size_t>(segments);
    if (!room(1 + 2 * m)) return;
    const float core  = std::max(0.f, radius - feather * 0.5f);
    const float outer = radius + feather * 0.5f;
    const float ca = clamp01(col.a);
    const float pr = col.r * ca, pg = col.g * ca, pb = col.b * ca, pa = 255.f * ca;
    const std::size_t base = v.size();
    pushP(c.x, c.y, pr, pg, pb, pa);
    for (std::size_t k = 0; k < m; ++k) {
        const float a = float(k) / float(m) * 2.f * kPi;
        const float cs = std::cos(a), sn = std::sin(a);
        pushP(c.x + cs * core,  c.y + sn * core,  pr, pg, pb, pa);
        pushP(c.x + cs * outer, c.y + sn * outer, 0, 0, 0, 0);
    }
    for (std::size_t k = 0; k < m; ++k) {
        const std::size_t in0 = base + 1 + 2 * k, out0 = in0 + 1;
        const std::size_t in1 = base + 1 + 2 * ((k + 1) % m), out1 = in1 + 1;
        tri(base, in0, in1);
        tri(in0, out0, in1);
        tri(in1, out0, out1);
    }
}

void Mesh::fillUnder(const Pt *p, int n, float baseY, Rgba atTop, Rgba atBottom,
                     float h)
{
    if (!p || n < 2 || !(h > 0.f)) return;
    const std::size_t m = static_cast<std::size_t>(n);
    if (!room(2 * m)) return;
    const float ta = clamp01(atTop.a), ba = clamp01(atBottom.a);
    const float t[4] = {atTop.r * ta, atTop.g * ta, atTop.b * ta, 255.f * ta};
    const float b[4] = {atBottom.r * ba, atBottom.g * ba, atBottom.b * ba, 255.f * ba};
    auto put = [&](float x, float y) {
        const float s = clamp01(y / h);
        pushP(x, y, t[0] + (b[0] - t[0]) * s, t[1] + (b[1] - t[1]) * s,
              t[2] + (b[2] - t[2]) * s, t[3] + (b[3] - t[3]) * s);
    };
    const std::size_t base = v.size();
    for (std::size_t k = 0; k < m; ++k) {
        put(p[k].x, p[k].y);
        put(p[k].x, baseY);
    }
    for (std::size_t k = 0; k + 1 < m; ++k) {
        const std::size_t a = base + 2 * k;
        tri(a, a + 1, a + 2);
        tri(a + 1, a + 3, a + 2);
    }
}

}  // namespace lyra::dsp::vis::geom
