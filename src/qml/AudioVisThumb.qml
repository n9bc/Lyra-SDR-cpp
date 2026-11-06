// Lyra — one Settings → Visualizer "Look" thumbnail.
//
// A thin wrapper over AudioVisCanvas with the view pinned, a label, and a
// selection outline.  It follows the operator's palette / echo / glow /
// background live (those are left at their Prefs-following defaults), so the
// thumbnail previews exactly what the dock will draw.  A click selects the
// view (Prefs.visView).
//
// Signal: the real audio while samples flow, otherwise (radio stopped or absent,
// detected by the hub's own liveness) the built-in demo signal; a remote
// desk has no local audio tap and always shows the demo.  `active` is passed straight to the canvas: the
// Settings host drives it from real widget visibility, see AudioVisThumbs.qml.

import QtQuick

Item {
    id: root

    property int  view: 0
    property string label: ""
    property bool active: false

    // Defensive lookups: see AudioVisCanvas.qml.
    readonly property bool onDesk:
        (typeof DeskLink !== "undefined" && DeskLink) ? DeskLink.deskSide : false
    readonly property bool selected:
        (typeof Prefs !== "undefined" && Prefs) ? Prefs.visView === view : false

    Rectangle {
        anchors.fill: parent
        color: "#101820"
    }

    AudioVisCanvas {
        id: canvas
        anchors.fill: parent
        anchors.margins: 2
        viewOverride: root.view
        demo: root.onDesk
        demoWhenIdle: true
        active: root.active
    }

    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 6
        text: root.label
        color: root.selected ? "#00e5ff" : "#cdd9e5"
        font.pixelSize: 12
        font.bold: root.selected
        style: Text.Outline
        styleColor: "#101820"
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: root.selected ? 2 : 1
        border.color: root.selected ? "#00e5ff"
                      : (hover.hovered ? "#5a7a8a" : "#2a4a5a")
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler {
        onTapped: if (typeof Prefs !== "undefined" && Prefs) Prefs.visView = root.view
    }
}
