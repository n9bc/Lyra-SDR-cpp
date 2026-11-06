// Lyra — audio visualizer item (scene-graph renderer for the four views).
//
// A QQuickItem drawn on the GPU through the Qt Quick scene graph (RHI: Metal
// on macOS, Vulkan/GL on Linux, D3D/Vulkan on Windows) — the same route as
// the panadapter, no custom shaders.  One QSGGeometryNode holds the whole
// view as an indexed list of vertex-coloured triangles (QSGVertexColorMaterial,
// PREMULTIPLIED alpha, so the echo pass and background opacity can composite
// it later).  Lines are triangle ribbons with a soft one-pixel fringe
// (dsp/AudioVisGeometry.h) because line-primitive width is not honoured on
// Metal.
//
// Views (spec "Look details", mockup draw()):
//   0 = 25-bar   25 log bands, bars 76 % of the slot, vertical palette
//                gradient t=0.15 base -> t=1 full scale, peak caps.
//   1 = FFT line line at t=0.85 over a translucent gradient fill (t=0.7 at
//                35 % alpha -> 0), thinner peak trace at 60 % alpha.
//   2 = Scope    the raw waveform (trigger-aligned by the hub), t=0.8.
//   3 = Radial   48 spokes (24 bands mirrored) from a ring of radius
//                0.20·min(w,h), up to 0.28·min(w,h) long, rotating slowly;
//                peak dots past each spoke; faint circle at 0.92 × the ring.
// Colour is by amplitude: palette position t = the band's level.  Echo,
// glow and background opacity are NOT drawn here — the dock QML layers them
// on top (ShaderEffect / ShaderEffectSource).  The glow is fed by a separate
// AudioVisGlowItem (below), which draws the shapes that glow in their glow
// colour (spec / mockup: t = level; the FFT line only, not its fill or peak
// trace) as a mask for audiovis_glow.frag.
//
// Data: a QTimer (~60 fps, only while the item is visible in a window — a
// QQuickWidget doesn't pump afterAnimating continuously, see panadapter.cpp)
// pulls a lyra::dsp::vis::Frame from AudioVisHub, maps dB with dbToUnit and
// shapes it with vis::Shaper, then calls update().  A non-demo item holds an
// AudioVisHub::acquire() reference exactly while that timer runs (visible +
// in a window + at least 8 px each way, the size it draws at), so a hidden
// dock costs the audio taps one atomic load.  A view change re-seeds the
// levels from the current frame, so the new view appears at once instead of
// blinking blank and regrowing from the floor.
//
// Sources (QML binds them; both optional):
//   engineSource  the WdspEngine context object -> span (visSpanHz) and
//                 RX/TX source (visUsesTx).  Null: span 4000 Hz, RX.
//   prefsSource   the Prefs context object -> Attack/Decay/Smoothing/Peak
//                 hold time/Sensitivity/Floor, and the defaults for view,
//                 peakHold and palette.  Null: the spec's defaults.
// view / peakHold / palette resolve as: a value assigned on the item wins
// (a Settings thumbnail pins its own view); otherwise, with prefsSource set
// they follow Prefs.visView / visPeakHold / visPalette live; with no
// prefsSource they are the item's own values (defaults Radial / on / Neon).
// Assigning `undefined` (RESET) drops the item's own value and goes back to
// following Prefs.
//
// demo: true = always animate the built-in DemoSignal (Settings thumbnails
// with no audio, a remote desk) and never touch the rings or acquire the
// hub.  false = the real tap; when the radio isn't streaming the hub hands
// back silence and the view settles to its idle floor (no fake signal).
// demoWhenIdle: with demo false, acquire the hub as usual but, while it has
// had no samples for 250 ms (radio stopped or not attached), animate the
// DemoSignal instead of the idle floor; real audio takes over as soon as
// samples flow.  A running radio with a closed squelch pushes zeros and so
// stays on the real (idle) frame.  Default false (the dock).

#pragma once

#include "dsp/AudioVisCore.h"
#include "dsp/AudioVisGeometry.h"
#include "dsp/AudioVisHub.h"

#include <QElapsedTimer>
#include <QPointer>
#include <QQuickItem>
#include <QString>

#include <vector>

class QTimer;

namespace lyra::dsp { class WdspEngine; }

namespace lyra::ui {

class Prefs;

class AudioVisItem : public QQuickItem {
    Q_OBJECT
    // 0 = 25-bar, 1 = FFT line, 2 = Scope, 3 = Radial.
    Q_PROPERTY(int view READ view WRITE setView RESET resetView
               NOTIFY viewChanged)
    Q_PROPERTY(bool peakHold READ peakHold WRITE setPeakHold
               RESET resetPeakHold NOTIFY peakHoldChanged)
    // 0..8 (vis::paletteName order; 0 = Neon).  OVERRIDE: QQuickItem has a
    // VIRTUAL `palette` (the Controls colour palette) that this replaces;
    // without the marker QML logs "Member palette ... overrides a member of
    // the base object" when the type is first used.
    Q_PROPERTY(int palette READ palette WRITE setPalette RESET resetPalette
               NOTIFY paletteChanged OVERRIDE)
    Q_PROPERTY(bool demo READ demo WRITE setDemo NOTIFY demoChanged)
    Q_PROPERTY(bool demoWhenIdle READ demoWhenIdle WRITE setDemoWhenIdle
               NOTIFY demoWhenIdleChanged)
    Q_PROPERTY(QObject *prefsSource READ prefsSource WRITE setPrefsSource
               NOTIFY prefsSourceChanged)
    Q_PROPERTY(QObject *engineSource READ engineSource WRITE setEngineSource
               NOTIFY engineSourceChanged)
    // "0–4 kHz · RX" / "0–6 kHz · TX" — the span and source on screen.
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)

public:
    explicit AudioVisItem(QQuickItem *parent = nullptr);
    ~AudioVisItem() override;

    int  view() const;
    void setView(int v);
    void resetView();

    bool peakHold() const;
    void setPeakHold(bool on);
    void resetPeakHold();

    int  palette() const;
    void setPalette(int p);
    void resetPalette();

    bool demo() const { return demo_; }
    void setDemo(bool on);
    bool demoWhenIdle() const { return demoWhenIdle_; }
    void setDemoWhenIdle(bool on);

    QObject *prefsSource() const;
    void     setPrefsSource(QObject *o);
    QObject *engineSource() const;
    void     setEngineSource(QObject *o);

    QString statusText() const { return statusText_; }

signals:
    void viewChanged();
    void peakHoldChanged();
    void paletteChanged();
    void demoChanged();
    void demoWhenIdleChanged();
    void prefsSourceChanged();
    void engineSourceChanged();
    void statusTextChanged();
    // The drawn content changed (a tick, a view / palette / peak-hold
    // change): an AudioVisGlowItem following this item repaints too.
    void contentUpdated();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode,
                             UpdatePaintNodeData *data) override;
    void itemChange(ItemChange change,
                    const ItemChangeData &value) override;
    void geometryChange(const QRectF &newGeometry,
                        const QRectF &oldGeometry) override;

private:
    friend class AudioVisGlowItem;   // builds its mask from this item's state

    void onTick();
    void repaint();   // update() + contentUpdated()
    // Start/stop the frame timer and take/drop the hub reference to match
    // "visible in a window" (and !demo for the hub).  Idempotent.
    void syncRunning(QQuickWindow *win);
    // Re-resolve view/peakHold/palette (own value vs Prefs) and emit the
    // NOTIFY signals for whichever effective value changed.
    void syncEffective();
    lyra::dsp::vis::Settings settings() const;
    void setStatus(double spanHz, bool tx);
    // targets_ <- frame_ for view v (bars / line / radial); returns the band
    // count.  scopeFromFrame: scope_ <- frame_.scope scaled by Sensitivity.
    int  bandTargets(int v, const lyra::dsp::vis::Settings &s);
    void scopeFromFrame(const lyra::dsp::vis::Settings &s);
    // Size shaper_ for the current view, seeded from the latest frame.
    void reseedShaper();
    // glowMask false: the view as drawn.  true: only what glows, in its
    // glow colour (see AudioVisGlowItem).  Reads the per-frame state.
    void buildMesh(float w, float h, float feather, bool glowMask,
                   lyra::dsp::vis::geom::Mesh &mesh,
                   std::vector<lyra::dsp::vis::geom::Pt> &pts) const;

    // ---- sources ----
    QPointer<lyra::dsp::WdspEngine> engine_;
    QPointer<Prefs>                 prefs_;

    // ---- own property values (+ "assigned on the item" flags) ----
    int  view_ = 3;          bool viewSet_ = false;
    bool peakHold_ = true;   bool peakHoldSet_ = false;
    int  palette_ = 0;       bool paletteSet_ = false;
    bool demo_ = false;
    bool demoWhenIdle_ = false;
    // Last emitted effective values (syncEffective change detection).
    int  effView_ = 3;
    bool effPeakHold_ = true;
    int  effPalette_ = 0;

    // ---- pacing / hub ----
    QTimer       *timer_ = nullptr;
    QElapsedTimer clock_;
    qint64        lastTickNs_ = -1;
    bool          acquired_ = false;    // holding one AudioVisHub::acquire()

    // ---- per-frame data (GUI thread; read in updatePaintNode while the
    //      GUI thread is blocked for sync) ----
    lyra::dsp::vis::Frame      frame_{};
    lyra::dsp::vis::DemoSignal demoSignal_;
    std::vector<float>         demoBuf_;   // latest kFftSize demo samples
    lyra::dsp::vis::Shaper     shaper_;
    int                        shaperView_ = -1;   // view shaper_ is sized for
    std::vector<float>         targets_;  // dbToUnit'd frame values
    std::vector<float>         scope_;    // scaled, clamped scope samples
    float                      rotation_ = 0.f;    // Radial ring angle (rad)
    QString                    statusText_;
    double                     statusSpan_ = -1.0;
    bool                       statusTx_ = false;

    // ---- render scratch (reused; no per-frame allocation once warm) ----
    lyra::dsp::vis::geom::Mesh             mesh_;
    std::vector<lyra::dsp::vis::geom::Pt>  pts_;
};

// The glow mask for one AudioVisItem: the shapes that glow, each filled
// solid in its glow colour, drawn from `source`'s state (no ticking, no hub
// of its own; it repaints on source.contentUpdated).  Mockup draw(): bars,
// their caps, spokes and peak dots glow in col(level) of their band (the
// canvas shadowColor), the FFT line in col(0.85) and the scope in col(0.8);
// the FFT fill, the FFT peak trace and the radial ring do not glow.  QML
// captures it (hidden) into a texture that audiovis_glow.frag blurs into the
// halo under the shapes.  `source` null: draws nothing.
class AudioVisGlowItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QQuickItem *source READ source WRITE setSource NOTIFY sourceChanged)

public:
    explicit AudioVisGlowItem(QQuickItem *parent = nullptr);

    QQuickItem *source() const;
    void        setSource(QQuickItem *item);

signals:
    void sourceChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode,
                             UpdatePaintNodeData *data) override;

private:
    QPointer<AudioVisItem>                 source_;
    lyra::dsp::vis::geom::Mesh             mesh_;
    std::vector<lyra::dsp::vis::geom::Pt>  pts_;
};

} // namespace lyra::ui
