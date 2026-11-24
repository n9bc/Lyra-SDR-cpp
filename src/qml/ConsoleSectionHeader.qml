// Lyra — console section header (Observatory ConsoleSectionHeader).
//
// Uppercase tracked title on the left, optional cyan detail on the right.
import QtQuick

Item {
    id: root

    property string title: ""
    property string detail: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: titleText.implicitWidth + detailText.implicitWidth + 4
    implicitHeight: Math.max(titleText.implicitHeight, detailText.implicitHeight) + 8

    Text {
        id: titleText
        anchors.left: parent.left
        anchors.top: parent.top
        text: root.title.toUpperCase()
        color: LyraDS.palette.textMuted
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.99
    }

    Text {
        id: detailText
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.left: titleText.right
        anchors.leftMargin: 4
        text: root.detail
        visible: root.detail !== ""
        color: LyraDS.palette.cyan
        font.pixelSize: 11
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
    }
}
