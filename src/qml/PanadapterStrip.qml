// Lyra — the panadapter's slim control strip (above the spectrum).
//
// The Display panel's everyday spectrum controls, one glance from the trace
// they change: Zoom (preset combo + fine slider + "N.Nx") and the Panafall
// wheel step + Exact/100 Hz.  Every control binds the same Prefs the Display
// panel and Settings → Visuals use, so they all stay in sync.  Peak Hold and
// the set-and-forget rates (Spec fps, WF rows/s) stay there.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: strip
    implicitHeight: 26
    color: "#101820"

    readonly property var zoomLevels: [1, 2, 4, 8, 16]
    function zoomIndex(z) {
        var best = 0
        for (var i = 1; i < zoomLevels.length; ++i)
            if (Math.abs(zoomLevels[i] - z) < Math.abs(zoomLevels[best] - z))
                best = i
        return best
    }
    component Caption: Label {
        color: "#cccccc"; font.bold: true; font.pixelSize: 12
    }
    component Divider: Rectangle {
        Layout.preferredWidth: 1; Layout.preferredHeight: 16
        Layout.leftMargin: 6; Layout.rightMargin: 6
        color: "#2a4a5a"
    }

    Rectangle {   // bottom rule, against the spectrum
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: "#2a4a5a"
    }

    RowLayout {
        anchors { fill: parent; leftMargin: 8; rightMargin: 8; bottomMargin: 1 }
        spacing: 6

        // ── Zoom ──
        Caption {
            text: qsTr("Zoom")
            HoverHandler { id: zoomLblHov }
            LyraHoverHelp {
                title: qsTr("Zoom")
                text: qsTr("Panadapter span. Combo jumps 1× / 2× / 4× / 8× / 16×; the slider is fine zoom. Same control as the Display panel.")
                hovered: zoomLblHov.hovered
            }
        }
        LyraComboBox {
            helpTitle: qsTr("Zoom")
            helpText: qsTr("Jump panadapter zoom to 1× / 2× / 4× / 8× / 16×. The slider next to it is fine zoom.")
            Layout.preferredWidth: 52
            Layout.preferredHeight: 20
            font.pixelSize: 12
            textLeftPad: 4
            textRightPad: 14
            model: ["1x", "2x", "4x", "8x", "16x"]
            currentIndex: strip.zoomIndex(Prefs.zoom)
            onActivated: Prefs.zoom = strip.zoomLevels[currentIndex]
        }
        LyraSlider {
            helpTitle: qsTr("Zoom")
            helpText: qsTr("Fine panadapter zoom, 1.0× to 16.0×. Wheel ±0.1.")
            Layout.preferredWidth: 160
            Layout.minimumWidth: 60
            from: 10; to: 160; stepSize: 1     // slider int = zoom × 10
            value: Prefs.zoom * 10
            onMoved: Prefs.zoom = Math.round(value) / 10
            WheelHandler {
                onWheel: (ev) => {
                    Prefs.zoom = Math.max(1.0, Math.min(16.0,
                        Math.round(Prefs.zoom * 10
                            + (ev.angleDelta.y > 0 ? 1 : -1)) / 10))
                }
            }
        }
        Label {
            text: Prefs.zoom.toFixed(1) + qsTr("x")
            color: "#cdd9e5"; font.family: "Consolas"; font.bold: true
            font.pixelSize: 12
            Layout.preferredWidth: 36
        }

        Divider {}

        // ── Panafall wheel step + click/drag quantization ──
        Caption {
            text: qsTr("Panafall")
            HoverHandler { id: panaLblHov }
            LyraHoverHelp {
                title: qsTr("Panafall")
                text: qsTr("How far each mouse-wheel tick tunes over the panadapter/waterfall (coarse skim — not the VFO Step). Exact / 100 Hz quantizes click and drag.")
                hovered: panaLblHov.hovered
            }
        }
        LyraComboBox {
            id: stepCombo
            helpTitle: qsTr("Panafall")
            helpText: qsTr("Wheel-tune step over the panadapter and waterfall. Distinct from the VFO Step.")
            Layout.preferredWidth: 76
            Layout.preferredHeight: 20
            font.pixelSize: 12
            textLeftPad: 4
            textRightPad: 14
            readonly property var steps: [
                1, 10, 50, 500, 1000, 5000, 6250, 8333, 10000, 12500, 25000, 100000]
            model: ["1 Hz", "10 Hz", "50 Hz", "500 Hz", "1 kHz", "5 kHz",
                    "6.25 kHz", "8.33 kHz", "10 kHz", "12.5 kHz", "25 kHz", "100 kHz"]
            currentIndex: Math.max(0, steps.indexOf(Prefs.panScrollStepHz))
            onActivated: Prefs.panScrollStepHz = steps[currentIndex]
        }
        LyraButton {
            Layout.preferredWidth: 58
            Layout.preferredHeight: 20
            font.pixelSize: 11
            checkable: true
            checked: Prefs.panRound100
            text: Prefs.panRound100 ? qsTr("100 Hz") : qsTr("Exact")
            onToggled: Prefs.panRound100 = checked
            HoverHandler { id: exactHov }
            LyraHoverHelp {
                title: Prefs.panRound100 ? qsTr("100 Hz") : qsTr("Exact")
                text: qsTr("Click/drag quantization. Exact = hertz you clicked. 100 Hz snaps to the 100 Hz grid (and overrides the Panafall wheel grid).")
                hovered: exactHov.hovered
            }
        }

        Item { Layout.fillWidth: true }
    }
}
