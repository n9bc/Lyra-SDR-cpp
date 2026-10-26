// Lyra — the panadapter's slim Zoom strip (above the spectrum).
//
// The same Zoom row the Display panel carries — a preset combo for fast
// jumps, a fine slider, a live "N.Nx" readout — one glance from the trace
// it changes.  Both drive Prefs.zoom, so they stay in sync.

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

    Rectangle {   // bottom rule, against the spectrum
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: "#2a4a5a"
    }

    RowLayout {
        anchors { fill: parent; leftMargin: 8; rightMargin: 8; bottomMargin: 1 }
        spacing: 6

        Label {
            text: qsTr("Zoom"); color: "#cccccc"; font.bold: true
            font.pixelSize: 12
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
            Layout.preferredWidth: 180
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
        Item { Layout.fillWidth: true }
    }
}
