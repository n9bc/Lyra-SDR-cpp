// Lyra — console chip button (Observatory ConsoleChipButtonStyle).
//
// Mirrors Observatory/Console/ConsoleStyles.swift: 26 pt high, radius 7,
// 12 pt medium label, 9 px horizontal padding. `kind` selects one of the
// seven visual states; a disabled chip dims to chipDim* at 0.45 opacity and a
// pressed chip drops to 0.7 opacity.
import QtQuick
import QtQuick.Controls
import QtQuick.Effects

Button {
    id: control

    // plain | on | sub | armed | warn | hot | dim
    property string kind: "plain"
    // Accessibility label and hover tooltip.
    property string help: ""
    property bool fullWidth: false

    // Wrap an opaque palette colour in an alpha (SwiftUI `Color.opacity`).
    function _alpha(c: color, a: real): color { return Qt.rgba(c.r, c.g, c.b, a) }

    readonly property color _text: {
        switch (kind) {
        case "on":    return LyraDS.palette.cyan
        case "sub":   return LyraDS.palette.chipSubText
        case "armed": return LyraDS.palette.green
        case "warn":  return LyraDS.palette.yellow
        case "hot":   return LyraDS.palette.pink
        case "dim":   return LyraDS.palette.chipDimText
        default:      return LyraDS.palette.chipText
        }
    }
    readonly property color _border: {
        switch (kind) {
        case "on":    return LyraDS.palette.cyan
        case "sub":   return LyraDS.palette.purple
        case "armed": return LyraDS.palette.green
        case "warn":  return LyraDS.palette.yellow
        case "hot":   return LyraDS.palette.pink
        default:      return LyraDS.palette.chipBorder   // plain, dim
        }
    }
    readonly property color _fill: {
        switch (kind) {
        case "on":    return _alpha(LyraDS.palette.cyan, 0.10)
        case "sub":   return _alpha(LyraDS.palette.purple, 0.12)
        case "armed": return _alpha(LyraDS.palette.green, 0.08)
        case "warn":  return _alpha(LyraDS.palette.yellow, 0.08)
        case "hot":   return _alpha(LyraDS.palette.pink, 0.10)
        case "dim":   return LyraDS.palette.chipDimFill
        default:      return LyraDS.palette.chipFill
        }
    }

    height: 26
    implicitHeight: height
    implicitWidth: Math.max(0, implicitContentWidth + leftPadding + rightPadding)
    width: fullWidth && parent ? parent.width : implicitWidth
    leftPadding: 9
    rightPadding: 9
    topPadding: 0
    bottomPadding: 0
    hoverEnabled: true

    opacity: !enabled ? 0.45 : (down ? 0.7 : 1.0)

    Accessible.role: Accessible.Button
    Accessible.name: help !== "" ? help : text

    ToolTip.visible: help !== "" && hovered
    ToolTip.text: help
    ToolTip.delay: 800

    background: Item {
        Rectangle {
            id: chipShape
            anchors.fill: parent
            radius: 7
            visible: false
            color: control.enabled ? control._fill : LyraDS.palette.chipDimFill
            border.width: 1
            border.color: control.enabled ? control._border : LyraDS.palette.chipBorder
        }
        // MultiEffect paints the (hidden) source plus the optional "on" glow.
        MultiEffect {
            anchors.fill: chipShape
            source: chipShape
            shadowEnabled: control.enabled && control.kind === "on"
            shadowColor: control._alpha(LyraDS.palette.cyan, 0.22)
            shadowBlur: 1.0
            paddingRect: Qt.rect(6, 6, 6, 6)
        }
    }

    contentItem: Text {
        text: control.text
        font.pixelSize: 12
        font.weight: Font.Medium
        color: control.enabled ? control._text : LyraDS.palette.chipDimText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        maximumLineCount: 1
    }
}
