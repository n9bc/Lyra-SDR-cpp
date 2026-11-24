// Lyra — shared themed horizontal slider.
//
// A drop-in replacement for a stock Controls `Slider` that draws its OWN
// groove + handle at a FIXED size, so it renders identically regardless of
// the global Qt Quick Controls style (native / Basic / …) and can never
// balloon or clip a panel.  All the usual Slider properties (from / to /
// value / stepSize / snapMode / onMoved / hovered / WheelHandler / ToolTip)
// pass straight through — callers only change `Slider {` → `LyraSlider {`.
//
// Look: thin dark groove with a cyan-filled track up to a compact round
// handle (Observatory cyan on the meter-track groove).
import QtQuick
import QtQuick.Controls

Slider {
    id: control
    // Extra height below the groove when integer tick labels are shown.
    implicitHeight: showTickNumbers ? 32 : 20

    // Parked Help card — never a Qt ToolTip on the thumb (GitHub #24).
    property string helpTitle: ""
    property string helpText: ""
    ToolTip.visible: false
    HoverHandler { id: helpHov }
    LyraHoverHelp {
        title: control.helpTitle
        text: control.helpText
        hovered: helpHov.hovered && control.helpText.length > 0
    }

    // Optional step tick marks below the groove (e.g. for a stepped slider).
    property bool showTicks: false
    readonly property int tickCount:
        (showTicks && stepSize > 0) ? Math.round((to - from) / stepSize) + 1 : 0

    // Optional numeric labels under the integer tick positions.
    property bool showTickNumbers: false
    readonly property int _labelFirst: Math.ceil(from)
    readonly property int labelCount:
        showTickNumbers ? Math.floor(to) - _labelFirst + 1 : 0

    // Dark meter-track groove with a cyan fill up to the handle.
    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: control.availableWidth
        height: 4
        radius: 2
        color: LyraDS.palette.meterTrack
        Rectangle {
            width: control.visualPosition * parent.width
            height: parent.height
            radius: parent.radius
            color: control.enabled ? LyraDS.palette.cyan : LyraDS.palette.textDim
        }
        // Step ticks — short vertical marks at each snap position.
        Repeater {
            model: control.tickCount
            delegate: Rectangle {
                width: 2; height: 7; radius: 1
                color: LyraDS.palette.textDim
                opacity: control.enabled ? 1.0 : 0.5
                x: (control.tickCount > 1
                    ? index / (control.tickCount - 1) : 0) * (parent.width - width)
                y: parent.height + 2
            }
        }
        // Numeric labels centred under the integer ticks (opt-in).
        Repeater {
            model: control.labelCount
            delegate: Text {
                readonly property int val: control._labelFirst + index
                readonly property real pos:
                    (val - control.from) / (control.to - control.from)
                text: val === 0 ? "0" : (val > 0 ? "+" + val : "" + val)
                color: LyraDS.palette.textDim
                opacity: control.enabled ? 1.0 : 0.5
                font.pixelSize: 8
                x: pos * (parent.width - 2) + 1 - width / 2
                y: parent.height + 10
            }
        }
    }

    // Compact round handle — fixed 14 px so the style can't resize it.
    // Cyan; brighter on hover, dimmer on press.
    handle: Rectangle {
        x: control.leftPadding
           + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        implicitWidth: 14
        implicitHeight: 14
        radius: 7
        color: !control.enabled ? LyraDS.palette.textDim
             : control.pressed  ? Qt.darker(LyraDS.palette.cyan, 1.25)
             : control.hovered  ? Qt.lighter(LyraDS.palette.cyan, 1.2)
             :                     LyraDS.palette.cyan
        border.color: LyraDS.palette.void_
        border.width: 1
    }
}
