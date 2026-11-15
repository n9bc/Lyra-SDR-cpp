// Lyra — audio visualizer view layout + triangle mesh (pure functions).
//
// Where each of the four views puts its shapes, and the small mesh builder
// that turns them into vertex-coloured triangles for the scene graph.  The
// numbers are the approved mockup's (docs/superpowers/specs/
// 2026-11-05-audio-visualizer-mockup.html, draw()): 25-bar bars at 76 % of
// their slot and 0.9 h full scale, FFT line at 0.88 h, Scope at ±0.4 h,
// Radial inner radius 0.20·min(w,h) with spokes up to 0.28·min(w,h).
//
// Lines are built as triangles here rather than QSGGeometry line primitives:
// line width is not reliably honoured on Metal/Vulkan/D3D, so every stroke is
// a solid core plus a one-pixel transparent fringe on each side — the
// fringe gives cheap anti-aliasing without MSAA.  All vertex colours are
// stored PREMULTIPLIED (QSGVertexColorMaterial blends premultiplied), so a
// translucent fill or trace stays correct when the echo pass and background
// opacity composite the item later.
//
// Qt-free so it unit-tests standalone (scratch/test_audio_vis_geometry.cpp);
// AudioVisItem copies Mesh::v straight into a QSGGeometry (Vtx has the
// ColoredPoint2D layout).

#pragma once

#include <cstdint>
#include <vector>

namespace lyra::dsp::vis::geom {

struct Pt   { float x, y; };
struct Rect { float x, y, w, h; };

// Straight (not premultiplied) colour: r/g/b 0..255, a 0..1.
struct Rgba { float r, g, b, a; };

// One vertex, premultiplied RGBA — same layout as QSGGeometry::ColoredPoint2D.
struct Vtx { float x, y; uint8_t r, g, b, a; };

// ---- 25-bar ---------------------------------------------------------------
constexpr int   kBarBands  = 25;
constexpr float kBarWidth  = 0.76f;   // bar width / slot width
constexpr float kBarHeight = 0.90f;   // full-scale bar height / item height

// Bar k of n at `level` (0..1, clamped), standing on the bottom edge.
Rect  barRect(int k, int n, float level, float w, float h) noexcept;
// Thin cap just above the held peak (mockup: 3 units tall, 1 unit gap, where
// a unit is w/600 — at least 1 px tall).
Rect  peakCapRect(int k, int n, float peak, float w, float h) noexcept;
// Palette position at height fraction f (0 = base, 1 = full scale) of the
// bars' vertical gradient: stops 0 -> 0.15, 0.6 -> 0.6, 1 -> 1 (mockup).
float barGradientT(float f) noexcept;

// x (0..w) of frequency hz on the 25-bar axis: the bands are log-spaced from
// lowHz to spanHz and share the width equally, so band k's range maps onto
// its slot [k, k+1)·w/n and hz lands inside the bar that shows it.  -1 when
// hz is outside lowHz..spanHz (or the range is empty).
float barFreqX(float hz, float lowHz, float spanHz, float w) noexcept;

// ---- FFT line / Scope -----------------------------------------------------
constexpr float kLineHeight = 0.88f;  // FFT line full scale / item height
constexpr float kScopeAmp   = 0.40f;  // Scope ±1 / item height

// Point i of n across the full width; level 0..1 (clamped) up from the bottom.
Pt linePoint(int i, int n, float level, float w, float h) noexcept;
// x (0..w) of frequency hz on the FFT line: point i of n covers
// [i, i+1)·spanHz/n and is drawn at linePoint's x, so hz sits at its point's
// centre, clamped to the width.  -1 when hz is outside 0..spanHz.
float lineFreqX(float hz, float spanHz, int n, float w) noexcept;
// Point i of n across the full width; sample -1..1 (clamped) about the centre.
Pt scopePoint(int i, int n, float sample, float w, float h) noexcept;

// ---- Radial ---------------------------------------------------------------
constexpr int   kRadialBands = 24;
constexpr int   kSpokes      = 48;     // 24 bands, mirrored
constexpr float kInnerRadius = 0.20f;  // × min(w,h)
constexpr float kSpokeLength = 0.28f;  // max spoke length × min(w,h)
constexpr float kRingRadius  = 0.92f;  // faint inner circle × inner radius
constexpr float kRotationRadPerSec = 0.05f;   // slow ring rotation

// Band that drives spoke k: 0..23 clockwise from 12 o'clock down the right
// side, then 23..0 back up the left — the ring is mirrored left/right, so it
// has no seam where the highest band would meet the lowest.
int   spokeBand(int k) noexcept;
// Screen angle (y down) of spoke k: k = 0 at 12 o'clock, clockwise, plus the
// ring's `rotation` (radians).
float spokeAngle(int k, float rotation) noexcept;
// Inner/outer ends of spoke k at `level` (0..1, clamped).
void  spokeEnds(int k, float level, float w, float h, float rotation,
                Pt &inner, Pt &outer) noexcept;
// Centre of the peak dot just beyond spoke k's held `peak` (a gap of w/120).
Pt    peakDotCentre(int k, float peak, float w, float h, float rotation) noexcept;
float innerCircleRadius(float w, float h) noexcept;

// ---- line widths ----------------------------------------------------------
// The mockup scales every stroke with the item width (lineWidth = W/divisor);
// never thinner than 1 px so a small thumbnail keeps a solid line.
constexpr float kFftLineDiv   = 300.f;
constexpr float kPeakTraceDiv = 700.f;
constexpr float kScopeLineDiv = 350.f;
constexpr float kSpokeDiv     = 170.f;
constexpr float kPeakDotDiv   = 300.f;   // dot radius
constexpr float kRingLineDiv  = 600.f;
float strokeWidth(float w, float divisor) noexcept;

// ---- mesh -----------------------------------------------------------------
// Indexed triangle list.  Indices are uint16 (the scene graph's default
// index type), so a mesh never grows past 65535 vertices: a shape that would
// overflow is dropped whole, never half-written.
class Mesh {
public:
    std::vector<Vtx>      v;
    std::vector<uint16_t> i;

    void clear() { v.clear(); i.clear(); }

    // Axis-aligned rectangle, colour `top` along its top edge and `bottom`
    // along its bottom edge (vertical gradient).
    void rectV(Rect r, Rgba top, Rgba bottom);

    // Polyline of n points as a ribbon `width` wide (miter joins, limited)
    // with a `feather`-wide transparent fringe each side.  `closed` joins the
    // last point back to the first.  Coincident points are skipped; a
    // polyline with no extent emits nothing.
    void stroke(const Pt *p, int n, float width, float feather, Rgba c,
                bool closed = false);

    // Straight segment a -> b along unit direction `dir` (given, so a
    // zero-length segment still has an orientation), each end pushed out by
    // `capExtend` (square cap).
    void segment(Pt a, Pt b, Pt dir, float width, float feather, Rgba c,
                 float capExtend);

    // Filled circle with a `feather`-wide transparent rim.
    void disc(Pt c, float radius, float feather, Rgba col, int segments);

    // Area between the polyline and y = baseY.  Colour is a vertical
    // gradient in item space: `atTop` at y = 0 to `atBottom` at y = h
    // (premultiplied, so it is exact along every vertical edge).
    void fillUnder(const Pt *p, int n, float baseY, Rgba atTop, Rgba atBottom,
                   float h);

private:
    bool room(std::size_t addV) const;
    // Premultiplied components, 0..255 each (rounded + clamped here).
    void pushP(float x, float y, float r, float g, float b, float a);
    void tri(std::size_t a, std::size_t b, std::size_t c);

    std::vector<Pt>    pts_;    // stroke scratch: de-duplicated points
    std::vector<Pt>    dir_;    //   unit segment directions
};

}  // namespace lyra::dsp::vis::geom
