// Lyra — Settings → Visualizer "Look" row: the four view thumbnails.
//
// Hosted by a QQuickWidget on the Settings dialog's Visualizer tab.  A
// QQuickWidget on a hidden QTabWidget page or in a closed dialog keeps its
// QML items "visible", which would keep the audio hub acquired, so `open` is
// driven from C++ (SettingsDialog) from the widget's real visibility: tab
// current, dialog shown and not minimised.  Under Qt Quick's software backend
// (graphics safe mode) the thumbnails would be blank, so a notice replaces them
// and nothing is analysed.

import QtQuick

Item {
    id: root

    property bool open: false

    readonly property int gap: 10
    readonly property bool software: GraphicsInfo.api === GraphicsInfo.Software

    Text {
        anchors.fill: parent
        visible: root.software
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.WordWrap
        text: qsTr("Not available with software rendering (graphics safe mode)")
        color: "#8a9aac"
        font.pixelSize: 14
    }

    Row {
        anchors.fill: parent
        visible: !root.software
        spacing: root.gap

        // Order = Prefs.visView / AudioVisItem.view (0..3).
        Repeater {
            model: [qsTr("25-bar"), qsTr("FFT line"), qsTr("Scope"), qsTr("Radial")]
            AudioVisThumb {
                required property int index
                required property string modelData
                width: (root.width - 3 * root.gap) / 4
                height: root.height
                view: index
                label: modelData
                active: root.open && !root.software
            }
        }
    }
}
