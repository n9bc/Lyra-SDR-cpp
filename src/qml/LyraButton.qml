// Lyra — shared themed push button.
//
// A drop-in replacement for a stock Controls `Button` that draws its OWN
// background + label, so it renders identically regardless of the global
// Qt Quick Controls style.  The macOS native style draws an unstyled Button
// with dark text on Lyra's dark panels, which is nearly invisible.  All the
// usual Button properties (text / checkable / checked / onClicked /
// onToggled / font / enabled / ToolTip) pass straight through — callers
// only change `Button {` → `LyraButton {`.
//
// Look: Observatory tokens — elevated surface fill, hairline panel border,
// chip-text label; checked = cyan tint + cyan border + cyan label.
import QtQuick
import QtQuick.Controls

Button {
    id: control
    implicitWidth: Math.max(40, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: 24
    leftPadding: 6; rightPadding: 6
    topPadding: 2; bottomPadding: 2
    hoverEnabled: true

    background: Rectangle {
        radius: 4
        color: control.down ? LyraDS.palette.surface
             : control.checked ? Qt.alpha(LyraDS.palette.cyan, 0.10)
             : control.hovered ? LyraDS.palette.surface
             : LyraDS.palette.surfaceElevated
        border.width: 1
        border.color: control.checked ? LyraDS.palette.cyan
                    : control.hovered ? LyraDS.palette.cyan
                    : LyraDS.palette.panelBorder
        opacity: control.enabled ? 1.0 : 0.45
    }

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.checked ? LyraDS.palette.cyan : LyraDS.palette.chipText
        opacity: control.enabled ? 1.0 : 0.45
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
