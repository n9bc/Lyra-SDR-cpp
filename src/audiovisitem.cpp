// Lyra — audio visualizer scene-graph item.  See audiovisitem.h.

#include "audiovisitem.h"

#include "prefs.h"
#include "wdsp_engine.h"

#include <QQuickWindow>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGVertexColorMaterial>
#include <QTimer>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>

namespace lyra::ui {

namespace vis  = lyra::dsp::vis;
namespace geom = lyra::dsp::vis::geom;

namespace {

// Mesh vertices are copied into the QSGGeometry wholesale, so the Qt-free
// Vtx must be byte-for-byte ColoredPoint2D.
static_assert(sizeof(geom::Vtx) == sizeof(QSGGeometry::ColoredPoint2D),
              "geom::Vtx must match QSGGeometry::ColoredPoint2D");
static_assert(offsetof(geom::Vtx, r) == offsetof(QSGGeometry::ColoredPoint2D, r),
              "geom::Vtx colour offset must match ColoredPoint2D");

constexpr int    kFrameMs      = 16;       // ~60 fps pump
constexpr double kDefaultSpan  = 4000.0;   // no engine: the span floor
constexpr double kSampleRate   = vis::AudioVisHub::kSampleRate;
constexpr float  kPi           = 3.14159265358979323846f;
constexpr float  kMaxDt        = 0.1f;     // a stall must not slam the levels
// Bars are coloured by sampling the palette at this many rows of the full
// scale, so multi-stop palettes keep their middle stops (a 2-colour quad
// would interpolate straight past them).
constexpr int    kBarRows      = 10;
constexpr int    kDotSegments  = 10;
constexpr int    kRingSegments = 72;
constexpr qreal  kMinDrawPx    = 8.0;      // smaller than this: draw nothing

int clampView(int v)    { return std::clamp(v, 0, 3); }
int clampPalette(int p) { return std::clamp(p, 0, vis::kPaletteCount - 1); }

// "0–4 kHz", "0–5.6 kHz".  Rounded to 0.1 kHz.
QString spanLabel(double hz)
{
    const double k = std::round(hz / 100.0) / 10.0;
    const bool whole = std::fabs(k - std::round(k)) < 1e-9;
    const QString num = whole ? QString::number(static_cast<int>(std::round(k)))
                              : QString::number(k, 'f', 1);
    return QStringLiteral("0–%1 kHz").arg(num);
}

void silence(vis::Frame &f)
{
    std::fill(std::begin(f.lineDb), std::end(f.lineDb), -200.f);
    std::fill(std::begin(f.bandsDb25), std::end(f.bandsDb25), -200.f);
    std::fill(std::begin(f.bandsDbRadial), std::end(f.bandsDbRadial), -200.f);
    std::fill(std::begin(f.scope), std::end(f.scope), 0.f);
    f.live = false;
}

// `mesh` -> a QSGGeometryNode of vertex-coloured triangles, reusing oldNode.
// An empty mesh emits NO node: a geometry node that enters the scene graph
// with an empty geometry is never batched by the renderer afterwards, even
// once later frames fill it, so the item stayed blank for the whole session
// on most launches (the first paint can come before the first tick).  The
// next update() with content creates the node.
QSGNode *meshNode(QSGNode *oldNode, const geom::Mesh &mesh)
{
    if (mesh.v.empty() || mesh.i.empty()) {
        delete oldNode;
        return nullptr;
    }
    auto *node = static_cast<QSGGeometryNode *>(oldNode);
    if (!node) {
        node = new QSGGeometryNode;
        auto *geo = new QSGGeometry(QSGGeometry::defaultAttributes_ColoredPoint2D(),
                                    0, 0, QSGGeometry::UnsignedShortType);
        geo->setDrawingMode(QSGGeometry::DrawTriangles);
        node->setGeometry(geo);
        node->setFlag(QSGNode::OwnsGeometry);
        node->setMaterial(new QSGVertexColorMaterial);   // premultiplied blend
        node->setFlag(QSGNode::OwnsMaterial);
    }
    QSGGeometry *geo = node->geometry();
    const int nv = static_cast<int>(mesh.v.size());
    const int ni = static_cast<int>(mesh.i.size());
    geo->allocate(nv, ni);
    std::memcpy(geo->vertexData(), mesh.v.data(), mesh.v.size() * sizeof(geom::Vtx));
    std::memcpy(geo->indexData(), mesh.i.data(), mesh.i.size() * sizeof(uint16_t));
    node->markDirty(QSGNode::DirtyGeometry);
    return node;
}

// One device pixel of fringe keeps edges smooth without blurring them on a
// Retina (dpr 2) or a standard display alike.
float featherFor(const QQuickItem *item)
{
    const qreal dpr = item->window() ? item->window()->effectiveDevicePixelRatio() : 1.0;
    return static_cast<float>(1.0 / std::max<qreal>(dpr, 1.0));
}

} // namespace

AudioVisItem::AudioVisItem(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);

    // Fixed-cadence pump, as Panadapter: afterAnimating/frameSwapped don't
    // fire continuously inside a QQuickWidget.  Runs only while the item is
    // visible in a window (syncRunning), so a hidden dock costs nothing.
    timer_ = new QTimer(this);
    timer_->setTimerType(Qt::PreciseTimer);
    timer_->setInterval(kFrameMs);
    connect(timer_, &QTimer::timeout, this, &AudioVisItem::onTick);

    demoBuf_.assign(vis::AudioVisHub::kFftSize, 0.f);
    scope_.assign(std::size(frame_.scope), 0.f);
    silence(frame_);
    frame_.spanHz = kDefaultSpan;
    frame_.tx = false;
    setStatus(kDefaultSpan, false);
}

AudioVisItem::~AudioVisItem() {
    // Balance the hub ref-count even when destroyed while shown (dock
    // closed with the app, a thumbnail page torn down).
    if (acquired_) {
        vis::AudioVisHub::instance().release();
        acquired_ = false;
    }
}

// ---- properties -------------------------------------------------------------

int AudioVisItem::view() const {
    if (!viewSet_ && prefs_) return clampView(prefs_->visView());
    return view_;
}

void AudioVisItem::setView(int v) {
    view_ = clampView(v);
    viewSet_ = true;
    syncEffective();
}

void AudioVisItem::resetView() {
    view_ = 3;
    viewSet_ = false;
    syncEffective();
}

bool AudioVisItem::peakHold() const {
    if (!peakHoldSet_ && prefs_) return prefs_->visPeakHold();
    return peakHold_;
}

void AudioVisItem::setPeakHold(bool on) {
    peakHold_ = on;
    peakHoldSet_ = true;
    syncEffective();
}

void AudioVisItem::resetPeakHold() {
    peakHold_ = true;
    peakHoldSet_ = false;
    syncEffective();
}

int AudioVisItem::palette() const {
    if (!paletteSet_ && prefs_) return clampPalette(prefs_->visPalette());
    return palette_;
}

void AudioVisItem::setPalette(int p) {
    palette_ = clampPalette(p);
    paletteSet_ = true;
    syncEffective();
}

void AudioVisItem::resetPalette() {
    palette_ = 0;
    paletteSet_ = false;
    syncEffective();
}

void AudioVisItem::setDemoWhenIdle(bool on) {
    if (on == demoWhenIdle_) return;
    demoWhenIdle_ = on;
    emit demoWhenIdleChanged();
}

void AudioVisItem::setDemo(bool on) {
    if (on == demo_) return;
    demo_ = on;
    syncRunning(window());   // a demo item lets go of the hub (and v.v.)
    emit demoChanged();
    repaint();
}

QObject *AudioVisItem::prefsSource() const { return prefs_.data(); }

void AudioVisItem::setPrefsSource(QObject *o) {
    auto *p = qobject_cast<Prefs *>(o);
    if (p == prefs_.data()) return;
    if (prefs_) disconnect(prefs_.data(), nullptr, this, nullptr);
    prefs_ = p;
    if (prefs_) {
        connect(prefs_.data(), &Prefs::visViewChanged, this, &AudioVisItem::syncEffective);
        connect(prefs_.data(), &Prefs::visPeakHoldChanged, this, &AudioVisItem::syncEffective);
        connect(prefs_.data(), &Prefs::visPaletteChanged, this, &AudioVisItem::syncEffective);
        // Prefs going away mid-life (shutdown order) falls back to own values.
        connect(prefs_.data(), &QObject::destroyed, this, [this]() {
            prefs_ = nullptr;
            syncEffective();
        });
    }
    emit prefsSourceChanged();
    syncEffective();
}

QObject *AudioVisItem::engineSource() const {
    return engine_.data();
}

void AudioVisItem::setEngineSource(QObject *o) {
    auto *e = qobject_cast<lyra::dsp::WdspEngine *>(o);
    if (e == engine_.data()) return;
    engine_ = e;
    emit engineSourceChanged();
}

void AudioVisItem::syncEffective() {
    const int  v = view();
    const bool ph = peakHold();
    const int  p = palette();
    if (v != effView_) {
        effView_ = v;
        // Re-seed now, not on the next tick: the paint that follows this
        // update() would otherwise find the shaper sized for the old view,
        // draw nothing (a one-frame blink, caught by Echo into the trail)
        // and then regrow the levels from the floor.
        reseedShaper();
        emit viewChanged();
    }
    if (ph != effPeakHold_) { effPeakHold_ = ph; emit peakHoldChanged(); }
    if (p != effPalette_) { effPalette_ = p; emit paletteChanged(); }
    repaint();
}

void AudioVisItem::repaint() {
    update();
    emit contentUpdated();
}

int AudioVisItem::bandTargets(int v, const vis::Settings &s) {
    const float *db = frame_.bandsDbRadial;
    int n = geom::kRadialBands;
    if (v == 0)      { db = frame_.bandsDb25; n = geom::kBarBands; }
    else if (v == 1) { db = frame_.lineDb;    n = static_cast<int>(std::size(frame_.lineDb)); }
    targets_.resize(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i)
        targets_[static_cast<std::size_t>(i)] = vis::dbToUnit(db[i], s.floorDb, s.sensitivity);
    return n;
}

void AudioVisItem::scopeFromFrame(const vis::Settings &s) {
    const float gain = s.sensitivity / 100.f;
    for (std::size_t i = 0; i < scope_.size(); ++i)
        scope_[i] = std::clamp(frame_.scope[i] * gain, -1.f, 1.f);
}

void AudioVisItem::reseedShaper() {
    const vis::Settings s = settings();
    const int v = view();
    if (v == 2) {                 // Scope has no shaper; refresh its samples
        scopeFromFrame(s);
        return;
    }
    const int n = bandTargets(v, s);
    shaper_.seed(targets_.data(), n);
    shaperView_ = v;
}

vis::Settings AudioVisItem::settings() const {
    vis::Settings s;   // the spec's defaults
    if (prefs_) {
        s.attack      = prefs_->visAttack();
        s.decay       = prefs_->visDecay();
        s.smoothing   = prefs_->visSmoothing();
        s.peakHoldMs  = prefs_->visPeakHoldMs();
        s.sensitivity = prefs_->visSensitivity();
        s.floorDb     = static_cast<float>(prefs_->visFloorDb());
    }
    return s;
}

void AudioVisItem::setStatus(double spanHz, bool tx) {
    if (spanHz == statusSpan_ && tx == statusTx_ && !statusText_.isEmpty())
        return;
    statusSpan_ = spanHz;
    statusTx_ = tx;
    const QString s = spanLabel(spanHz) +
        (tx ? QStringLiteral(" · TX") : QStringLiteral(" · RX"));
    if (s != statusText_) {
        statusText_ = s;
        emit statusTextChanged();
    }
}

// ---- running state ----------------------------------------------------------

void AudioVisItem::itemChange(ItemChange change, const ItemChangeData &value) {
    if (change == ItemSceneChange)
        syncRunning(value.window);
    else if (change == ItemVisibleHasChanged)
        syncRunning(window());
    QQuickItem::itemChange(change, value);
}

void AudioVisItem::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) {
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    syncRunning(window());        // crossing the draw threshold starts/stops it
}

void AudioVisItem::syncRunning(QQuickWindow *win) {
    // Too small to draw (a dock squeezed to its title, a layout not yet
    // done) counts as not shown: no timer, no FFT, no hub reference.
    const bool run = win != nullptr && isVisible()
                     && width() >= kMinDrawPx && height() >= kMinDrawPx;
    if (run && !timer_->isActive()) {
        clock_.restart();
        lastTickNs_ = -1;          // first tick after a show uses a nominal dt
        timer_->start();
    } else if (!run && timer_->isActive()) {
        timer_->stop();
    }
    // The hub reference follows the timer exactly, so show/hide cycles stay
    // balanced however often they happen; a demo item never needs the rings.
    const bool wantHub = run && !demo_;
    if (wantHub != acquired_) {
        if (wantHub) vis::AudioVisHub::instance().acquire();
        else         vis::AudioVisHub::instance().release();
        acquired_ = wantHub;
    }
}

// ---- per-frame data -----------------------------------------------------------

void AudioVisItem::onTick() {
    if (!isVisible() || !window()) return;

    const qint64 nowNs = clock_.nsecsElapsed();
    float dt = 1.f / 60.f;
    if (lastTickNs_ >= 0) {
        dt = static_cast<float>(nowNs - lastTickNs_) * 1e-9f;
        // PreciseTimer dumps queued ticks after a GUI stall; one real frame
        // per interval is plenty (same guard as Panadapter::onFrame).
        if (dt < 0.5f * kFrameMs * 1e-3f) return;
    }
    lastTickNs_ = nowNs;
    dt = std::min(dt, kMaxDt);

    const double span = engine_ ? engine_->visSpanHz() : kDefaultSpan;
    auto &hub = vis::AudioVisHub::instance();
    bool got = false;
    bool tx = false;
    bool useDemo = demo_;
    if (!useDemo && acquired_) {
        tx = engine_ && engine_->visUsesTx();
        hub.setSource(tx);
        got = hub.frame(span, frame_);   // !live -> already silence
        if (got) tx = frame_.tx;
        // No samples for 250 ms (radio stopped or absent): preview with the
        // demo signal instead of the idle floor.  A running radio with a
        // closed squelch still pushes zeros, so it stays live.
        if (got && !frame_.live && demoWhenIdle_) useDemo = true;
    }
    if (useDemo) {
        // Slide the demo window on by this frame's worth of samples.
        const int n = std::clamp(static_cast<int>(std::lround(dt * kSampleRate)),
                                 1, static_cast<int>(demoBuf_.size()));
        std::memmove(demoBuf_.data(), demoBuf_.data() + n,
                     (demoBuf_.size() - static_cast<std::size_t>(n)) * sizeof(float));
        demoSignal_.fill(demoBuf_.data() + demoBuf_.size() - n, n, kSampleRate);
        got = hub.analyse(demoBuf_.data(), static_cast<int>(demoBuf_.size()),
                          span, frame_);
        tx = false;
    }
    if (!got) silence(frame_);
    setStatus(span, tx);

    const vis::Settings s = settings();
    const int v = view();
    if (v == 2) {
        // Scope: time domain only — no band work, no shaping.
        scopeFromFrame(s);
    } else {
        const int n = bandTargets(v, s);
        if (shaperView_ != v) {
            shaper_.seed(targets_.data(), n);   // normally done by syncEffective
            shaperView_ = v;
        }
        shaper_.step(targets_.data(), dt, s);
    }
    rotation_ = std::fmod(rotation_ + dt * geom::kRotationRadPerSec, 2.f * kPi);
    repaint();
}

// ---- rendering ------------------------------------------------------------------

QSGNode *AudioVisItem::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
    mesh_.clear();
    const float W = static_cast<float>(width());
    const float H = static_cast<float>(height());
    if (W >= kMinDrawPx && H >= kMinDrawPx)   // smaller: too small to read
        buildMesh(W, H, featherFor(this), /*glowMask*/ false, mesh_, pts_);
    return meshNode(oldNode, mesh_);
}

void AudioVisItem::buildMesh(float W, float H, float feather, bool glowMask,
                             geom::Mesh &mesh, std::vector<geom::Pt> &pts) const {
    mesh.clear();
    const int pal = palette();
    const bool peaks = peakHold();
    auto col = [pal](float t, float a = 1.f) {
        uint8_t rgb[3] = {0, 0, 0};
        vis::paletteColor(pal, t, rgb);
        return geom::Rgba{float(rgb[0]), float(rgb[1]), float(rgb[2]), a};
    };
    const int v = view();
    const auto &lv = shaper_.level;
    const auto &pk = shaper_.peak;

    if (v == 0) {                                          // ---- 25-bar
        if (shaperView_ != 0 || lv.size() != std::size_t(geom::kBarBands)) return;
        for (int k = 0; k < geom::kBarBands; ++k) {
            const geom::Rect bar = geom::barRect(k, geom::kBarBands, lv[k], W, H);
            const float top = std::clamp(lv[k], 0.f, 1.f);
            if (glowMask) {
                // The whole bar (and its cap) glows in col(level).
                const geom::Rgba g = col(lv[k]);
                mesh.rectV(bar, g, g);
                if (peaks)
                    mesh.rectV(geom::peakCapRect(k, geom::kBarBands, pk[k], W, H), g, g);
                continue;
            }
            // Gradient is fixed to the full scale (t=0.15 at the base,
            // t=1 at full height): a short bar only shows the low colours.
            for (int r = 0; r < kBarRows; ++r) {
                const float f0 = float(r) / kBarRows;
                if (f0 >= top) break;
                const float f1 = std::min(float(r + 1) / kBarRows, top);
                const float y0 = H - f0 * H * geom::kBarHeight;
                const float y1 = H - f1 * H * geom::kBarHeight;
                mesh.rectV(geom::Rect{bar.x, y1, bar.w, y0 - y1},
                           col(geom::barGradientT(f1)), col(geom::barGradientT(f0)));
            }
            if (peaks) {
                const geom::Rect cap = geom::peakCapRect(k, geom::kBarBands, pk[k], W, H);
                mesh.rectV(cap, col(1.f), col(1.f));
            }
        }
    } else if (v == 1) {                                   // ---- FFT line
        const int n = static_cast<int>(std::size(frame_.lineDb));
        if (shaperView_ != 1 || lv.size() != std::size_t(n)) return;
        pts.resize(static_cast<std::size_t>(n));
        for (int i = 0; i < n; ++i) pts[i] = geom::linePoint(i, n, lv[i], W, H);
        // Only the line glows: no fill, no peak trace.
        if (glowMask) {
            mesh.stroke(pts.data(), n, geom::strokeWidth(W, geom::kFftLineDiv),
                        feather, col(0.85f));
            return;
        }
        // Fill first so the line sits crisply on top of it.
        mesh.fillUnder(pts.data(), n, H, col(0.7f, 0.35f), col(0.1f, 0.f), H);
        mesh.stroke(pts.data(), n, geom::strokeWidth(W, geom::kFftLineDiv),
                    feather, col(0.85f));
        if (peaks) {
            for (int i = 0; i < n; ++i) pts[i] = geom::linePoint(i, n, pk[i], W, H);
            mesh.stroke(pts.data(), n, geom::strokeWidth(W, geom::kPeakTraceDiv),
                        feather, col(1.f, 0.6f));
        }
    } else if (v == 2) {                                   // ---- Scope
        const int n = static_cast<int>(scope_.size());
        pts.resize(static_cast<std::size_t>(n));
        for (int i = 0; i < n; ++i) pts[i] = geom::scopePoint(i, n, scope_[i], W, H);
        mesh.stroke(pts.data(), n, geom::strokeWidth(W, geom::kScopeLineDiv),
                    feather, col(0.8f));                   // glows as drawn
    } else {                                               // ---- Radial
        if (shaperView_ != 3 || lv.size() != std::size_t(geom::kRadialBands)) return;
        const float spokeW = geom::strokeWidth(W, geom::kSpokeDiv);
        for (int k = 0; k < geom::kSpokes; ++k) {
            const int b = geom::spokeBand(k);
            geom::Pt in{}, out{};
            geom::spokeEnds(k, lv[b], W, H, rotation_, in, out);
            const float a = geom::spokeAngle(k, rotation_);
            // Half-width cap on both ends stands in for the mockup's round
            // line cap: an idle ring still shows a dot per spoke.
            mesh.segment(in, out, geom::Pt{std::cos(a), std::sin(a)}, spokeW,
                         feather, col(lv[b]), spokeW * 0.5f);
            if (peaks) {
                // The dot glows in its spoke's colour (t = level).
                mesh.disc(geom::peakDotCentre(k, pk[b], W, H, rotation_),
                          std::max(0.75f, W / geom::kPeakDotDiv), feather,
                          glowMask ? col(lv[b]) : col(1.f), kDotSegments);
            }
        }
        if (glowMask) return;                              // the ring doesn't glow
        const float rr = geom::innerCircleRadius(W, H);
        pts.resize(kRingSegments);
        for (int s = 0; s < kRingSegments; ++s) {
            const float a = float(s) / kRingSegments * 2.f * kPi;
            pts[s] = geom::Pt{W * 0.5f + std::cos(a) * rr, H * 0.5f + std::sin(a) * rr};
        }
        mesh.stroke(pts.data(), kRingSegments, geom::strokeWidth(W, geom::kRingLineDiv),
                    feather, col(0.4f, 0.5f), /*closed*/ true);
    }
}

// ---- AudioVisGlowItem -----------------------------------------------------------

AudioVisGlowItem::AudioVisGlowItem(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
}

QQuickItem *AudioVisGlowItem::source() const { return source_.data(); }

void AudioVisGlowItem::setSource(QQuickItem *item) {
    auto *src = qobject_cast<AudioVisItem *>(item);
    if (src == source_.data()) return;
    if (source_) disconnect(source_.data(), nullptr, this, nullptr);
    source_ = src;
    if (source_)
        connect(source_.data(), &AudioVisItem::contentUpdated,
                this, [this]() { update(); });
    emit sourceChanged();
    update();
}

// Runs in the same scene-graph sync as the source's own updatePaintNode
// (one window, GUI thread blocked), so the state it reads is consistent.
QSGNode *AudioVisGlowItem::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
    mesh_.clear();
    const float W = static_cast<float>(width());
    const float H = static_cast<float>(height());
    if (source_ && W >= kMinDrawPx && H >= kMinDrawPx)
        source_->buildMesh(W, H, featherFor(this), /*glowMask*/ true, mesh_, pts_);
    return meshNode(oldNode, mesh_);
}

} // namespace lyra::ui
