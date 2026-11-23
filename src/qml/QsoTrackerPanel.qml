// Lyra — QSO tracker dock panel.
//
// A thin view over the QsoTracker model ("Qso" context property): it shows
// where the current QSO stands (the stage pills) and the live contact row
// (their call / RST / name / QTH / DXCC), filled from the decoded CW copy.
//
// The model is a pure CONSUMER of the WdspEngine decoded-text signals — the
// same ones CwDecoderPanel shows — so this panel never touches the decode
// pipeline.  We forward those signals to Qso.feedText(); the model buffers and
// segments them into messages and runs the state machine.
//
// Styled to match CwDecoderPanel — hand-drawn chips + section dividers.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    implicitWidth: 470
    implicitHeight: collapsed ? 40 : (body.implicitHeight + 12)
    color: Prefs.panelBgColor
    border.color: "#2a4a5a"

    readonly property color cAccent: "#00e5ff"
    readonly property color cText:   "#cdd9e5"
    readonly property color cMuted:  "#8a9aac"
    readonly property color cGreen:  "#5dff9a"
    readonly property color cAmber:  "#ffbe5a"

    property bool collapsed: false

    // Stage-pill labels — index matches QsoTracker::Stage.  "Complete" is shown
    // by lighting every pill as done rather than a 7th pill.
    readonly property var stageLabels:
        ["Idle", "CQ detected", "Replied", "Exchanging", "Conversation", "Closing"]

    // Keep the model's notion of "my call" in step with Prefs.
    Component.onCompleted: Qso.myCall = Prefs.callsign
    Connections {
        target: Prefs
        function onCallsignChanged() { Qso.myCall = Prefs.callsign }
    }

    // Forward decoded text from whichever engine is live.  All three stream
    // into the same model; it buffers + segments them.
    Connections {
        target: WdspEngine
        function onCwDecodedChar(ch, conf) { Qso.feedText(ch) }
        function onCwNeuralText(newText)   { Qso.feedText(newText) }
        function onCwAutoText(text, fb)    { Qso.feedText(text) }
    }

    // ── Reusable hand-styled chip (lit = active) ──
    component ChipButton: Rectangle {
        id: chip
        property string label: ""
        property bool   lit: false
        property bool   chipEnabled: true
        signal clicked()
        implicitHeight: 26
        implicitWidth: chipTxt.implicitWidth + 22
        radius: 4
        opacity: chipEnabled ? 1.0 : 0.4
        color: chip.lit ? "#2e7d9a" : "#1c252b"
        border.color: chip.lit ? root.cAccent : "#3a4750"
        Text {
            id: chipTxt
            anchors.centerIn: parent
            text: chip.label
            color: chip.lit ? "#ffffff" : root.cMuted
            font.pixelSize: 12; font.bold: chip.lit
        }
        MouseArea {
            anchors.fill: parent
            enabled: chip.chipEnabled
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    // ── Reusable labelled divider ──
    component Divider: RowLayout {
        id: div
        property string label: ""
        Layout.fillWidth: true
        spacing: 8
        Rectangle { Layout.fillWidth: true; height: 1; color: "#243845" }
        Label { text: div.label; color: root.cMuted; font.pixelSize: 11 }
        Rectangle { Layout.fillWidth: true; height: 1; color: "#243845" }
    }

    // ── One contact field: muted label + value (optional accent colour) ──
    component Field: RowLayout {
        property string label: ""
        property string value: ""
        property color  valueColor: root.cText
        property bool   mono: false
        spacing: 6
        Label {
            text: label; color: root.cMuted; font.pixelSize: 12
            Layout.minimumWidth: 44
        }
        Label {
            text: value.length > 0 ? value : "—"
            color: value.length > 0 ? valueColor : root.cMuted
            font.pixelSize: 13
            font.family: mono ? "Consolas" : Qt.application.font.family
            font.bold: mono
        }
    }

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        // ── Header ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Label { text: qsTr("QSO Tracker"); color: root.cAccent
                    font.bold: true; font.pixelSize: 14 }
            Item { Layout.fillWidth: true }
            Label {
                text: Qso.theirCall.length > 0 ? Qso.theirCall : ""
                color: root.cText; font.family: "Consolas"; font.bold: true
                font.pixelSize: 12
            }
            ChipButton {
                label: root.collapsed ? "▲" : "▼"
                onClicked: root.collapsed = !root.collapsed
            }
        }

        // ── Stage pills ──
        Flow {
            visible: !root.collapsed
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                model: root.stageLabels
                delegate: Rectangle {
                    required property int index
                    required property string modelData
                    readonly property bool isActive: index === Qso.stage
                    // Complete (6) lights every pill as done.
                    readonly property bool isDone: index < Qso.stage
                    radius: 4
                    implicitHeight: 22
                    implicitWidth: pillTxt.implicitWidth + 20
                    color: isActive ? "#0c2a32" : "transparent"
                    border.color: isActive ? root.cAccent
                                 : isDone  ? "#2a4a5a" : "#243845"
                    Text {
                        id: pillTxt
                        anchors.centerIn: parent
                        text: parent.modelData
                        font.pixelSize: 11
                        color: parent.isActive ? root.cAccent
                             : parent.isDone  ? root.cGreen : "#4a5a6a"
                    }
                }
            }
        }

        // ── Contact ──
        Divider { label: qsTr("Contact"); visible: !root.collapsed }

        Rectangle {
            visible: !root.collapsed
            Layout.fillWidth: true
            implicitHeight: contactCol.implicitHeight + 20
            radius: 6
            color: "#070d12"
            border.color: "#1c2a36"
            ColumnLayout {
                id: contactCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    Field {
                        label: qsTr("His call"); value: Qso.theirCall
                        valueColor: root.cAccent; mono: true
                    }
                    Item { Layout.fillWidth: true }
                    Field {
                        label: qsTr("RST"); value: Qso.theirRst
                        valueColor: root.cAmber; mono: true
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Field { label: qsTr("Name"); value: Qso.theirName }
                    Item { Layout.fillWidth: true }
                    Field { label: qsTr("QTH"); value: Qso.theirQth }
                }
                Field {
                    label: qsTr("DXCC"); value: Qso.theirDxcc
                    valueColor: root.cGreen; mono: true
                }
            }
        }

        // ── Actions ──
        RowLayout {
            visible: !root.collapsed
            Layout.fillWidth: true
            spacing: 8
            ChipButton {
                label: qsTr("→ His Call")
                chipEnabled: Qso.theirCall.length > 0
                onClicked: CwMacros.hisCall = Qso.theirCall
            }
            ChipButton {
                label: qsTr("→ Name")
                chipEnabled: Qso.theirName.length > 0
                onClicked: CwMacros.opName = Qso.theirName
            }
            Item { Layout.fillWidth: true }
            ChipButton {
                label: qsTr("New QSO")
                onClicked: Qso.reset()
            }
        }

        Label {
            visible: !root.collapsed
            Layout.fillWidth: true
            text: qsTr("Fills from the decoded copy; the stage advances as the "
                       + "QSO progresses.  Double-click a call in the decoder to "
                       + "seed the contact.")
            color: root.cMuted; font.pixelSize: 10; wrapMode: Text.WordWrap
        }
    }
}
