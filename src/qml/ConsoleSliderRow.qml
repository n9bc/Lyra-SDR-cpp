// Lyra — console slider row (Observatory console slider row).
//
// Label (60 px) | themed slider | monospaced readout (50 px). `dimmed` draws
// the whole row at 0.45 opacity. `moved` is the Slider's own signal, exposed
// so callers can write `onMoved: ...`.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

RowLayout {
    id: root

    property string label: ""
    // Accessibility label and hover tooltip.
    property string help: ""
    property alias value: slider.value
    property alias from: slider.from
    property alias to: slider.to
    property alias stepSize: slider.stepSize
    property string readout: ""
    property color tint: LyraDS.palette.cyan
    property bool dimmed: false
    signal moved()

    spacing: 8
    opacity: dimmed ? 0.45 : 1.0

    Text {
        text: root.label
        Layout.preferredWidth: 60
        Layout.minimumWidth: 60
        Layout.maximumWidth: 60
        font.pixelSize: 11
        color: LyraDS.palette.textMuted
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    Slider {
        id: slider
        Layout.fillWidth: true
        Layout.preferredHeight: 18
        hoverEnabled: true
        onMoved: root.moved()

        Accessible.name: root.help !== "" ? root.help : root.label
        ToolTip.visible: root.help !== "" && hovered
        ToolTip.text: root.help
        ToolTip.delay: 800

        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth
            height: 4
            radius: 2
            color: LyraDS.palette.meterTrack

            Rectangle {
                width: slider.handle.x + slider.handle.width / 2 - slider.leftPadding
                height: parent.height
                radius: 2
                color: root.tint
            }
        }

        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 12
            height: 12
            radius: 6
            color: root.tint
            border.width: slider.pressed ? 2 : 0
            border.color: LyraDS.palette.textPrimary
        }
    }

    Text {
        text: root.readout
        Layout.preferredWidth: 50
        Layout.minimumWidth: 50
        Layout.maximumWidth: 50
        font.pixelSize: 11
        font.family: Qt.platform.os === "osx" ? "Menlo" : "Consolas"
        font.styleHint: Font.Monospace
        color: LyraDS.palette.textPrimary
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideLeft
    }
}
