// Lyra — segment meter for the S-meter bar.
//
// `value` and `peak` are 0-1 fractions. Lit segments are cyan, turning yellow
// above 75 % and pink above 90 % of the scale; unlit segments are segmentOff.
// The peak-hold segment is drawn in textPrimary. Scale labels belong to the
// parent.
pragma ComponentBehavior: Bound
import QtQuick

Row {
    id: root

    property real value: 0
    property real peak: 0
    property int segments: 20

    readonly property int _lit: Math.round(Math.max(0, Math.min(1, value)) * segments)
    readonly property int _peakIndex: peak > 0
        ? Math.min(segments - 1, Math.max(0, Math.ceil(Math.min(1, peak) * segments) - 1))
        : -1

    spacing: 1
    height: 12

    Repeater {
        model: root.segments

        Rectangle {
            required property int index
            readonly property real _pos: (index + 1) / root.segments

            width: 3
            height: root.height
            color: {
                if (index === root._peakIndex)
                    return LyraDS.palette.textPrimary
                if (index >= root._lit)
                    return LyraDS.palette.segmentOff
                if (_pos > 0.90)
                    return LyraDS.palette.pink
                if (_pos > 0.75)
                    return LyraDS.palette.yellow
                return LyraDS.palette.cyan
            }
        }
    }
}
