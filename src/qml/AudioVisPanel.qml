// Lyra — Audio Visualizer dock panel.
//
// A thin bar over the visualizer canvas.  Per the spec the bar carries only
// the view picker, the Peak hold toggle and a read-only span/source label
// ("0–4 kHz · RX", "· TX" while transmitting voice); palette, effects,
// speed and reactivity live in Settings → Visualizer.  The picker and the
// toggle write Prefs directly — Prefs is the single source of truth, so the
// Settings thumbnails and this dock always agree.
//
// The canvas (AudioVisCanvas.qml) follows Prefs for view / peak hold /
// palette / echo / glow / background opacity on its own.  Its `active`
// input is `dockOpen` (set by the dock host from the dock's real visibility;
// a hidden QDockWidget does not hide QML items, see there) and not a remote
// desk: on the desk side the audio comes from the host, so there is nothing
// to analyse and a notice replaces the canvas.  Under Qt Quick's software
// backend (graphics safe mode / safe boot) the canvas would draw nothing, so
// there too a notice replaces it and nothing is analysed.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    implicitWidth: 480
    implicitHeight: 320
    color: "#101820"
    border.color: "#2a4a5a"

    readonly property color cText:  "#cdd9e5"
    readonly property color cMuted: "#8a9aac"

    // Driven by the dock host: false until the dock is really showing, so a
    // dock hidden at startup never acquires the analysis hub.
    property bool dockOpen: false
    readonly property bool onDesk: DeskLink.deskSide
    readonly property bool software: GraphicsInfo.api === GraphicsInfo.Software
    readonly property bool noCanvas: onDesk || software

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // ── Bar: view picker, Peak hold, span/source ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: !root.noCanvas

            LyraComboBox {
                id: viewPicker
                Layout.preferredWidth: 104
                // Order = Prefs.visView / AudioVisItem.view (0..3).
                model: [qsTr("25-bar"), qsTr("FFT line"), qsTr("Scope"), qsTr("Radial")]
                currentIndex: Prefs.visView
                onActivated: (i) => Prefs.visView = i
                helpTitle: qsTr("View")
                helpText: qsTr("25-bar analyser, FFT line, oscilloscope or the radial ring.")
            }

            // Not `checkable`: a click on a checkable button would break the
            // `checked` binding, and a later change from Settings (or a
            // restored profile) would no longer show here.  Writing Prefs and
            // letting the binding follow keeps the two in step.
            LyraButton {
                text: qsTr("Peak hold")
                checked: Prefs.visPeakHold
                onClicked: Prefs.visPeakHold = !Prefs.visPeakHold
            }

            Item { Layout.fillWidth: true }

            Label {
                text: canvas.statusText
                color: root.cMuted
                font.pixelSize: 12
                elide: Text.ElideLeft
                Layout.maximumWidth: 160
            }
        }

        AudioVisCanvas {
            id: canvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 60
            visible: !root.noCanvas
            active: root.dockOpen && !root.noCanvas
        }

        Label {
            visible: root.onDesk
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Not available on a remote desk")
            color: root.cMuted
            font.pixelSize: 14
        }

        Label {
            visible: root.software && !root.onDesk
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            text: qsTr("Not available with software rendering (graphics safe mode)")
            color: root.cMuted
            font.pixelSize: 14
        }
    }
}
