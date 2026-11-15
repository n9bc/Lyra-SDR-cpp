// Lyra — audio visualizer canvas: the AudioVisItem plus its effects.
//
// The picture part of the Audio Visualizer, without any controls, so the
// dock (AudioVisPanel.qml) and the Settings → Visualizer thumbnails share
// one implementation.  Bottom to top:
//
//   background  Rectangle, rgba(0,0,0, Background opacity).  At 0 the host's
//               own panel colour shows through; at 100 it is solid black.
//   glow        a halo UNDER the shapes (audiovis_glow.frag), blurred from a
//               hidden AudioVisGlowItem mask that draws only what glows, in
//               its glow colour (t = level; the FFT line but not its fill or
//               peak trace), like the mockup's canvas shadow.  The shapes
//               draw over it with premultiplied "over", so their own pixels
//               keep their exact colours.  Glow 0 → mask and halo unhooked:
//               no offscreen texture, no cost.
//   echo        shapes + halo captured into a texture and composited OVER
//               the previous output faded by Echo/100 (audiovis_echo.frag),
//               whose result a recursive ShaderEffectSource feeds back next
//               frame.  Premultiplied, so trails fade to transparent rather
//               than to black.  Echo 0 → the chain is unhooked (no source
//               item, nothing visible) and the shapes draw directly: no cost.
//               The trail texture is half-float where the backend renders to
//               one, so the fade stays geometric all the way down.
//
// Everything is clipped to the canvas: a radial peak dot or a stroke's
// half-width never spills over the dock's control bar.
//
// Echo is applied once per FEEDBACK STEP, not per rendered frame: a Timer
// at the item's own 16 ms tick asks both textures for one fresh capture
// (scheduleUpdate, live: false).  Per rendered frame would make the trail
// length depend on how often the window happens to render — twice as fast
// on a 120 Hz display, and up to N times as fast in a QQuickWidget holding N
// thumbnails whose timers each trigger a render.  ~60 steps/s matches the
// mockup's "keep Echo % of the last frame" at ~60 fps (each step's decay is
// scaled by its real length, so the trail lasts the same time regardless).
//
// What to draw: viewOverride / peakHoldOverride / paletteOverride left
// `undefined` (the default) make the item follow Prefs.visView /
// visPeakHold / visPalette; a value pins it (a Settings thumbnail pins its
// view).  The item's RESET handles `undefined`, see audiovisitem.h.  The
// effective values are readable as item.view / item.peakHold / item.palette.
//
// `active` must be driven by whoever hosts the canvas in a QQuickWidget:
// hiding a QDockWidget does not hide the QML items inside it, and the item
// only stops its timer (and lets go of the audio hub) when it is not visible.

import QtQuick
import LyraUI

Item {
    id: root

    // ---- what to draw (undefined = follow Prefs) ----
    property var  viewOverride: undefined
    property var  peakHoldOverride: undefined
    property var  paletteOverride: undefined
    // Built-in demo signal instead of the real audio tap.
    property bool demo: false
    // With demo false: animate the demo signal while no audio is flowing
    // (see audiovisitem.h).  The dock leaves this off.
    property bool demoWhenIdle: false

    // ---- effects (default to the operator's settings) ----
    // The context properties are looked up defensively so a host that
    // doesn't expose them (e.g. a widget-side QQuickWidget) gets the spec
    // defaults instead of a ReferenceError per binding.
    readonly property QtObject _prefs:
        (typeof Prefs !== "undefined") ? Prefs : null
    readonly property QtObject _engine:
        (typeof WdspEngine !== "undefined") ? WdspEngine : null
    property real echo:      _prefs ? _prefs.visEcho : 40          // 0..95
    property real glow:      _prefs ? _prefs.visGlow : 50          // 0..100
    property real bgOpacity: _prefs ? _prefs.visBgOpacity : 0      // 0..100

    // False = stop rendering and analysing (see the header).
    property bool active: true

    readonly property alias item: vis
    readonly property alias statusText: vis.statusText

    // Background (under the effects, so glow and trails never tint it).
    // Also the canvas's window sentinel: it must stay the FIRST child (see
    // fx.echoOn).
    Rectangle {
        id: backdrop
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, Math.max(0, Math.min(100, root.bgOpacity)) / 100)
    }

    Item {
        id: fx
        anchors.fill: parent
        visible: root.active
        clip: true

        // The software backend (graphics safe mode) can draw neither the
        // item nor ShaderEffect; the hosts show a notice there and never
        // activate the canvas.
        // The feedback loop is a window-reference cycle: echoPass holds
        // prevTex as an input and prevTex holds echoPass as its source, so
        // neither count can reach zero on its own.  Docking or floating the
        // panel makes QQuickWidget move the scene to a NEW offscreen window;
        // the cycle would keep the old, deleted window ("Cannot use same item
        // on different windows", then a crash).  So echo drops out the moment
        // the scene leaves its window: backdrop is released first, being the
        // first child, which unhooks prevTex before Qt reaches echoPass.
        readonly property bool inWindow: backdrop.Window.window !== null
        readonly property bool echoOn: root.echo > 0 && root.active && inWindow
        readonly property bool glowOn: root.glow > 0 && root.active
        // Half-float trail texture wherever the backend can render to one
        // (Metal, Vulkan, D3D, desktop OpenGL 3+); OpenGL ES / old GL keep
        // RGBA8 and the shader's 8-bit stall step.
        readonly property bool floatTrail:
            GraphicsInfo.api === GraphicsInfo.Metal
            || GraphicsInfo.api === GraphicsInfo.Vulkan
            || GraphicsInfo.api === GraphicsInfo.Direct3D11
            || GraphicsInfo.api === GraphicsInfo.Direct3D12
            || (GraphicsInfo.api === GraphicsInfo.OpenGL
                && GraphicsInfo.renderableType === GraphicsInfo.SurfaceFormatOpenGL
                && GraphicsInfo.majorVersion >= 3)

        // What one frame looks like: the halo under the shapes.  Echo
        // captures this whole item, so halos fade in the trail too (the
        // mockup fades its shadows with everything else).
        Item {
            id: shapes
            anchors.fill: parent

            // ---- glow ----
            // Radius follows the mockup's canvas shadowBlur (Glow/100 ×
            // width/40 px, ~2 sigma), taken out to 3 sigma.  The halo gain
            // starts at 0 with Glow, so Glow 1 looks like Glow 0 and there
            // is no step when the glow switches on; 2.8 at full scale gives
            // a clear halo at Glow 50.
            ShaderEffect {
                id: glowPass
                anchors.fill: parent
                visible: fx.glowOn
                property variant source: maskTex
                readonly property real radiusPx:
                    1.5 * Math.max(0, Math.min(100, root.glow)) / 100 * width / 40
                property real glowStrength: Math.max(0, Math.min(100, root.glow)) / 100 * 2.8
                property vector2d glowRadius:
                    Qt.vector2d(radiusPx / Math.max(1, width),
                                radiusPx / Math.max(1, height))
                // Mip level whose texel matches the spacing between taps
                // (radius × sqrt(pi / 28 taps) ≈ 0.335 radius, in device px).
                property real glowLod:
                    Math.log2(Math.max(1, radiusPx * Screen.devicePixelRatio * 0.335))
                fragmentShader: "qrc:/shaders/audiovis_glow.frag.qsb"
            }

            AudioVisItem {
                id: vis
                anchors.fill: parent
                visible: root.active && root.visible
                demo: root.demo
                demoWhenIdle: root.demoWhenIdle
                prefsSource: root._prefs
                engineSource: root._engine
                view: root.viewOverride
                peakHold: root.peakHoldOverride
                palette: root.paletteOverride
            }
        }

        // The glow mask: drawn only into maskTex (hidden), mipmapped so the
        // blur's sparse taps can read pre-filtered levels.
        AudioVisGlowItem {
            id: glowMask
            anchors.fill: parent
            visible: fx.glowOn
            source: fx.glowOn ? vis : null
        }
        ShaderEffectSource {
            id: maskTex
            width: 0; height: 0     // a texture provider only
            sourceItem: fx.glowOn ? glowMask : null
            hideSource: true
            mipmap: true
        }

        // ---- echo / trails ----
        // This frame (shapes + halo) as a texture (zero size: a texture
        // provider only, it draws nothing itself).  hideSource: while echo
        // is on, the frame is seen only through the feedback composite.
        ShaderEffectSource {
            id: curTex
            width: 0; height: 0
            sourceItem: fx.echoOn ? shapes : null
            hideSource: fx.echoOn
            live: false             // captured by the feedback step below
        }
        // New frame over the faded previous output.  Drawn only into
        // prevTex (which hides it and shows its own texture on screen).
        ShaderEffect {
            id: echoPass
            anchors.fill: parent
            visible: fx.echoOn
            property variant current: curTex
            property variant previous: prevTex
            // Echo/100 is the fraction kept per 1/60 s; each step raises it
            // to the step's real length (see the Timer).
            readonly property real keepPer60th: Math.max(0, Math.min(95, root.echo)) / 100
            property real decay: keepPer60th
            // One 8-bit step, taken only where an 8-bit trail would stall
            // (see the shader).  Always on, not tied to floatTrail: that is
            // a prediction, and a backend that silently falls back to RGBA8
            // must still fade out; on a half-float trail it only touches the
            // sub-visible tail.
            property real fadeFloor: 1.0 / 255.0
            fragmentShader: "qrc:/shaders/audiovis_echo.frag.qsb"
        }
        // The feedback loop: captures echoPass every step and is itself
        // echoPass's `previous`.  recursive: Qt ping-pongs two textures so
        // the pass can read its own last output.
        ShaderEffectSource {
            id: prevTex
            anchors.fill: parent
            sourceItem: fx.echoOn ? echoPass : null
            hideSource: true
            recursive: true
            live: false             // advanced by the feedback step below
            visible: fx.echoOn
            format: fx.floatTrail ? ShaderEffectSource.RGBA16F
                                  : ShaderEffectSource.RGBA8
        }
        // One feedback step per item tick (see the header).  Runs only
        // while echo is on and the canvas is active.  The decay is scaled
        // by the step's real length, so a late or stalled timer (a busy GUI
        // thread) gives the same trail length in seconds, not a longer one.
        // Date.now() is the wall clock: a step backwards (manual change, NTP
        // step after resume) clamps to 0 -- a negative dt would raise the
        // decay above 1 and flash the whole trail to full brightness.
        Timer {
            id: echoStep
            property real lastMs: 0
            interval: 16
            repeat: true
            running: fx.echoOn && vis.visible
            onRunningChanged: lastMs = 0
            onTriggered: {
                const now = Date.now()
                const dt = lastMs > 0 ? Math.max(0, Math.min(0.1, (now - lastMs) / 1000))
                                      : 1 / 60
                lastMs = now
                echoPass.decay = Math.pow(echoPass.keepPer60th, dt * 60)
                curTex.scheduleUpdate()
                prevTex.scheduleUpdate()
            }
        }
    }
}
