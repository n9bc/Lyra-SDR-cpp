// Lyra VFO style — Observatory.  The default.
//
// Ports the Observatory VFO panel (Observatory/Console/VFOPanelView.swift) to
// Qt: a vfoTop -> vfoBottom gradient card with a hairline border that lights
// up (vfoBorderHighlight + soft outer glow) while this VFO is the live one,
// Share Tech Mono digits in freqGlow with a cyan halo, a ConsoleChip header
// (VFO letter, RX/TX role, step, mode) and an embedded SegmentMeter.
// Style contract: see VfoBox.qml.
import QtQuick
import QtQuick.Effects

Item {
    id: st
    // Qt Quick's software renderer cannot run MultiEffect; show the source directly (no glow) there.
    readonly property bool softwareRender: GraphicsInfo.api === GraphicsInfo.Software
    property int freqHz: 0
    property int selectedDigit: -1
    property string vfoState: "rx"
    property string roleText: "RX"
    property string vfoLetter: "A"
    property string modeText: ""
    property int stepHz: 0
    property bool showMode: true
    // 0-1 signal level for the embedded meter.  The style contract carries no
    // level (styles must not touch Stream), so this stays 0 until VfoBox
    // binds it.
    property real meterValue: 0
    property real meterPeak: 0

    readonly property real naturalWidth: 460
    readonly property real naturalHeight: 144
    readonly property rect tuneRect: Qt.rect(10, 34, 440, 56)
    readonly property rect stepModeRect: Qt.rect(10, 110, 400, 26)
    readonly property rect txPipRect: Qt.rect(422, 115, 28, 16)
    readonly property var digitRects: digits.rects.map(function (r) {
        return Qt.rect(tuneRect.x + digits.x + r.x, tuneRect.y + digits.y + r.y,
                       r.width, r.height)
    })
    readonly property var theme: ({
        label: LyraDS.palette.textMuted, field: LyraDS.palette.vfoBottom,
        fieldBorder: LyraDS.palette.vfoBorder, text: LyraDS.palette.freqGlow,
        accent: LyraDS.palette.cyan, pipIdle: LyraDS.palette.moxIdleFill,
        pipIdleBorder: LyraDS.palette.pink, pipIdleText: LyraDS.palette.moxHint,
        compact: false
    })

    readonly property string digitString: ("0000000000" + freqHz).slice(-10)
    readonly property bool isTx: vfoState === "tx"
    // "armed" = the other receiver has focus; rx / tx = this VFO is live.
    readonly property bool live: vfoState !== "armed"
    readonly property string stepLabel: stepHz >= 1000
        ? (stepHz / 1000) + " kHz" : stepHz + " Hz"

    width: naturalWidth
    height: naturalHeight

    Rectangle {   // outer glow while live
        anchors.fill: card
        anchors.margins: -3
        radius: card.radius + 3
        visible: st.live
        color: "transparent"
        border.width: 3
        border.color: st.isTx ? Qt.alpha(LyraDS.palette.txFill, 0.14)
                              : LyraDS.palette.vfoGlowHighlight
    }
    Rectangle {
        id: card
        anchors.fill: parent
        radius: 14
        gradient: Gradient {
            GradientStop { position: 0.0; color: LyraDS.palette.vfoTop }
            GradientStop { position: 1.0; color: LyraDS.palette.vfoBottom }
        }
        border.width: 1
        border.color: st.isTx ? LyraDS.palette.txFill
                    : st.live ? LyraDS.palette.vfoBorderHighlight
                              : LyraDS.palette.vfoBorder
    }
    Rectangle {   // inner top highlight
        x: 1; y: 1
        width: parent.width - 2
        height: 1
        color: LyraDS.palette.vfoInnerHighlight
    }

    Row {   // header chips (read-only: the Step/Mode controls live in VfoBox)
        x: 10; y: 6
        spacing: 6
        ConsoleChip {
            height: 22
            title: qsTr("VFO %1").arg(st.vfoLetter)
            kind: st.live ? "on" : "plain"
            enabled: false
            opacity: 1
        }
        Rectangle {   // role tag: filled while transmitting, chip otherwise
            visible: st.isTx
            height: 22
            width: txLabel.implicitWidth + 18
            radius: 7
            color: LyraDS.palette.txFill
            Text {
                id: txLabel
                anchors.centerIn: parent
                text: st.roleText
                color: LyraDS.palette.txText
                font.pixelSize: 12
                font.weight: Font.Medium
            }
        }
        ConsoleChip {
            visible: !st.isTx
            height: 22
            title: st.roleText
            kind: "plain"
            enabled: false
            opacity: 1
        }
        ConsoleChip {
            height: 22
            title: st.stepLabel
            kind: "dim"
            enabled: false
            opacity: 1
        }
        ConsoleChip {
            visible: st.showMode && st.modeText !== ""
            height: 22
            title: st.modeText
            kind: "sub"
            enabled: false
            opacity: 1
        }
    }

    Item {
        id: area
        x: st.tuneRect.x
        y: st.tuneRect.y
        width: st.tuneRect.width
        height: st.tuneRect.height

        VfoDigitRow {
            id: digits
            visible: st.softwareRender   // else drawn through the halo effect below
            digitString: st.digitString
            digitFont: Qt.font({ family: "Share Tech Mono", pixelSize: 48 })
            digitColor: LyraDS.palette.freqGlow
            dimColor: Qt.alpha(LyraDS.palette.freqGlow, 0.18)
            sepColor: LyraDS.palette.cyan
            selectedDigit: st.selectedDigit
            selectColor: LyraDS.palette.cyan
            selectThickness: 2
            x: (area.width - implicitWidth) / 2
            y: (area.height - cellH) / 2
        }
        MultiEffect {
            visible: !st.softwareRender
            source: digits
            anchors.fill: digits
            shadowEnabled: true
            shadowColor: LyraDS.palette.cyan
            shadowOpacity: 0.55
            shadowBlur: 0.6
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
            blurMax: 16
        }
    }

    SegmentMeter {
        x: 10; y: 96
        width: 440
        height: 6
        segments: 40
        value: st.meterValue
        peak: st.meterPeak
    }
}
