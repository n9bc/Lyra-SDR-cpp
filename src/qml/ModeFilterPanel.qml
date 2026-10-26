// Lyra — Filters dock panel.
//
// RX + TX filter bandwidth (per-mode presets, remembered per mode via the
// shared Prefs object) + IQ sample Rate + the 🔗 RX↔TX BW lock.  The
// bandwidth combos drive WdspEngine.bandwidth / Prefs.txBandwidth using
// the sideband-correct passband convention.
//
// NOTE: the Mode picker MOVED to the Tuning dock (under the VFO) in the
// VFO-cluster layout — so this panel is filters-only.  The
// Prefs.mode → WdspEngine.mode binding moved there with it.  Dock title
// is "Filters" (set in mainwindow.cpp addQuickDock); the file keeps its
// ModeFilterPanel.qml name to avoid churning the qml_module + qrc paths.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FilterPresets.js" as FilterPresets

Rectangle {
    id: root
    implicitHeight: 64
    implicitWidth: 460
    color: "#101820"
    border.color: "#2a4a5a"

    // Honest floor, measured from the content — see AudioPanel for the rationale.
    readonly property int lyraMinWidth:  body.implicitWidth + 24
    readonly property int lyraMinHeight: body.implicitHeight + 12

    // Mode list.  The per-mode bandwidth presets live in FilterPresets.js
    // (shared with the VFO's Filter picker).
    readonly property var modes: ["LSB", "USB", "CWL", "CWU",
                                  "DSB", "AM", "SAM", "FM", "DIGU", "DIGL"]
    // FM derives its occupied TX width from deviation (audio is brick-walled
    // to 3 kHz ahead of the modulator), so the TX-BW selector + RX↔TX lock
    // are meaningless in FM and are disabled there.
    readonly property bool isFm: Prefs.mode === "FM"

    function presetsFor(mode) { return FilterPresets.presetsFor(mode) }
    function fmtBw(hz) { return FilterPresets.fmtBw(hz) }
    // Nearest preset index for the current bandwidth (handles a stored
    // value that isn't an exact preset).
    function bwIndex(mode, bw) {
        var p = presetsFor(mode), best = 0
        for (var i = 1; i < p.length; ++i)
            if (Math.abs(p[i] - bw) < Math.abs(p[best] - bw)) best = i
        return best
    }
    // The RX BW combo shows the ACTUAL bandwidth — including non-preset
    // values from dragging the panadapter passband edge (old-Lyra parity):
    // a value that isn't a preset is shown as a "(custom)" entry at the
    // top of the list and selected.  Picking a real preset drops it.
    function bwIsPreset(mode, bw) { return FilterPresets.isPreset(mode, bw) }
    function bwModel(mode, bw) {
        return FilterPresets.model(mode, bw, qsTr(" (custom)"))
    }
    function bwCurrentIndex(mode, bw) { return FilterPresets.currentIndex(mode, bw) }
    function bwValueAt(mode, bw, idx) { return FilterPresets.valueAt(mode, bw, idx) }

    // IQ sample rates (96/192/384 k — 48 k excluded, EP2 cadence).
    readonly property var rateVals: [96000, 192000, 384000]
    function rateIndex(r) {
        var i = rateVals.indexOf(r)
        return i < 0 ? 1 : i
    }
    // A rate switch touches three places: Prefs (persist), the HL2 wire
    // speed bits (Stream), and the WDSP channel + analyzer (Engine).
    function applyRate(r) {
        Prefs.sampleRate = r
        Stream.setSampleRate(r)
        WdspEngine.setSampleRate(r)
    }
    // Push the persisted rate to the wire + DSP at startup (before the
    // channel opens on Start, so it comes up at the right rate).
    Component.onCompleted: applyRate(Prefs.sampleRate)

    // RX bandwidth is the single source of truth via Prefs; the engine
    // follows.  (Engine pushes RXASetPassband on change.)  The
    // Prefs.mode → WdspEngine.mode binding lives on the Tuning dock now
    // (it owns the Mode picker).
    Binding { target: WdspEngine; property: "bandwidth"; value: Prefs.rxBandwidth }
    Binding { target: WdspEngine; property: "bandwidthRx2"; value: Prefs.rx2Bandwidth }

    readonly property bool rx2Focus: Stream.subEnabled && Stream.focusedRx === 2
    readonly property string rxMode: rx2Focus ? Prefs.modeRx2 : Prefs.mode
    readonly property int rxBw: rx2Focus ? Prefs.rx2Bandwidth : Prefs.rxBandwidth
    // TX Component 8c — TX BW push lives in C++ main.cpp (a
    // QObject::connect on Prefs::txBandwidthChanged → Stream.setTxBwHz)
    // so it fires regardless of whether this QML panel is loaded.
    // No QML binding needed here.

    // Two packed rows.  Bandwidths stay on the top line; the low-edge
    // spins sit in the same columns underneath, so the dock stays about
    // as wide as it was before those spins existed.
    GridLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        columns: 9
        columnSpacing: 8
        rowSpacing: 4

        Label {
            Layout.row: 0; Layout.column: 0
            text: qsTr("Rate"); color: "#cccccc"; font.bold: true
            HoverHandler { id: rateLblHov }
            LyraHoverHelp {
                title: qsTr("Rate")
                text: rateCombo.helpText
                hovered: rateLblHov.hovered
            }
        }
        LyraComboBox {
            id: rateCombo
            helpTitle: qsTr("Rate")
            helpText: qsTr("IQ sample rate for the panadapter and DSP. All DDCs share this wire rate on Protocol 1.")
            Layout.row: 0; Layout.column: 1
            Layout.preferredWidth: 64
            font.pixelSize: 12
            textLeftPad: 4
            textRightPad: 14
            model: ["96 k", "192 k", "384 k"]
            currentIndex: root.rateIndex(Prefs.sampleRate)
            onActivated: root.applyRate(root.rateVals[currentIndex])
        }

        Rectangle {   // divider
            Layout.row: 0; Layout.column: 2; Layout.rowSpan: 2
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            Layout.topMargin: 4; Layout.bottomMargin: 4
            color: "#2a4a5a"
        }

        Label {
            Layout.row: 0; Layout.column: 3
            text: root.rx2Focus ? qsTr("RX2 BW") : qsTr("RX BW")
            color: "#cccccc"; font.bold: true
            HoverHandler { id: rxBwLblHov }
            LyraHoverHelp {
                title: root.rx2Focus ? qsTr("RX2 BW") : qsTr("RX BW")
                text: bwCombo.helpText
                hovered: rxBwLblHov.hovered
            }
        }
        LyraComboBox {
            id: bwCombo
            helpTitle: root.rx2Focus ? qsTr("RX2 BW") : qsTr("RX BW")
            helpText: root.isFm
                ? qsTr("N/A in FM — TX bandwidth is set from deviation. 🔗 lock is off.")
                : qsTr("🔗 lock (between the combos) ties TX BW and low edges to RX, both directions.")
            Layout.row: 0; Layout.column: 4
            Layout.preferredWidth: 92
            font.pixelSize: 12
            textLeftPad: 4
            textRightPad: 14
            model: root.bwModel(root.rxMode, root.rxBw)
            currentIndex: root.bwCurrentIndex(root.rxMode, root.rxBw)
            onActivated: {
                var v = root.bwValueAt(root.rxMode, root.rxBw, currentIndex)
                if (root.rx2Focus)
                    Prefs.rx2Bandwidth = v
                else
                    Prefs.rxBandwidth = v
            }
        }

        // 🔗 RX↔TX lock.  Sits BETWEEN the RX and TX combos (the glyph
        // alone carries the meaning; no label).  Checkable toggle wired
        // to Prefs.bwLocked: when ON, every BW change on either side
        // mirrors to the other (handled in Prefs::setRxBandwidth /
        // setTxBandwidth), and the low edges track the same way.
        // Toggling ON pulls RX into TX.
        LyraButton {
            id: bwLockBtn
            Layout.row: 0; Layout.column: 5; Layout.rowSpan: 2
            Layout.preferredWidth: 32
            Layout.alignment: Qt.AlignVCenter
            checkable: true
            checked: Prefs.bwLocked
            enabled: !root.isFm           // no TX-BW to lock to in FM
            text: "🔗"
            onToggled: Prefs.bwLocked = checked
            HoverHandler { id: bwLockHov }
            LyraHoverHelp {
                title: qsTr("BW lock")
                text: qsTr("Ties TX BW and low edges to RX, both directions. Off in FM.")
                hovered: bwLockHov.hovered
            }
        }

        Label {
            Layout.row: 0; Layout.column: 6
            text: qsTr("TX BW"); font.bold: true
            color: root.isFm ? "#666666" : "#cccccc"
            HoverHandler { id: txBwLblHov }
            LyraHoverHelp {
                title: qsTr("TX BW")
                text: txBwCombo.helpText
                hovered: txBwLblHov.hovered
            }
        }
        LyraComboBox {
            id: txBwCombo
            helpTitle: qsTr("TX BW")
            helpText: root.isFm
                ? qsTr("FM occupies ±(deviation + 3 kHz audio); set it with Dev on Tuning.")
                : qsTr("Transmit IF width. 🔗 lock ties this to RX BW.")
            Layout.row: 0; Layout.column: 7
            Layout.preferredWidth: 92
            font.pixelSize: 12
            textLeftPad: 4
            textRightPad: 14
            enabled: !root.isFm           // FM TX width is auto (deviation-derived)
            // In FM, show the auto-derived occupied channel (Carson:
            // 2·(deviation + 3 kHz audio)) instead of an editable preset —
            // it's a readout, not a control.
            model: root.isFm
                ? [root.fmtBw(2 * (Stream.fmDeviationHz + 3000)) + qsTr(" (auto)")]
                : root.bwModel(Prefs.mode, Prefs.txBandwidth)
            currentIndex: root.isFm ? 0
                : root.bwCurrentIndex(Prefs.mode, Prefs.txBandwidth)
            onActivated: if (!root.isFm) Prefs.txBandwidth =
                root.bwValueAt(Prefs.mode, Prefs.txBandwidth, currentIndex)
        }

        Item { Layout.row: 0; Layout.column: 8; Layout.rowSpan: 2; Layout.fillWidth: true }

        Label {
            Layout.row: 1; Layout.column: 3
            text: qsTr("RX lo"); color: "#cccccc"; font.bold: true
            HoverHandler { id: rxLoLblHov }
            LyraHoverHelp {
                title: qsTr("RX lo")
                text: qsTr("Receive low cutoff, 0–500 Hz. SSB and digital only.")
                hovered: rxLoLblHov.hovered
            }
        }
        LyraSpinBox {
            id: rxLoSpin
            helpTitle: qsTr("RX lo")
            helpText: qsTr("Receive low cutoff, 0–500 Hz. SSB and digital only.")
            Layout.row: 1; Layout.column: 4
            Layout.preferredWidth: 92
            from: 0; to: 500; stepSize: 10
            value: Prefs.filterLow
            textFromValue: function(v, loc) { return v + " Hz" }
            valueFromText: function(t, loc) { return Math.round(parseFloat(t)) }
            onValueModified: Prefs.filterLow = value
            Connections {
                target: Prefs
                function onFilterLowChanged() {
                    if (rxLoSpin.value !== Prefs.filterLow)
                        rxLoSpin.value = Prefs.filterLow
                }
            }
        }
        Label {
            Layout.row: 1; Layout.column: 6
            text: qsTr("TX lo"); font.bold: true
            color: root.isFm ? "#666666" : "#cccccc"
            HoverHandler { id: txLoLblHov }
            LyraHoverHelp {
                title: qsTr("TX lo")
                text: qsTr("Transmit low cutoff, 0–500 Hz. With the lock on, this follows the receive low.")
                hovered: txLoLblHov.hovered
            }
        }
        LyraSpinBox {
            id: txLoSpin
            helpTitle: qsTr("TX lo")
            helpText: qsTr("Transmit low cutoff, 0–500 Hz. With the lock on, this follows the receive low.")
            Layout.row: 1; Layout.column: 7
            Layout.preferredWidth: 92
            enabled: !root.isFm
            from: 0; to: 500; stepSize: 10
            value: Prefs.txFilterLow
            textFromValue: function(v, loc) { return v + " Hz" }
            valueFromText: function(t, loc) { return Math.round(parseFloat(t)) }
            onValueModified: Prefs.txFilterLow = value
            Connections {
                target: Prefs
                function onTxFilterLowChanged() {
                    if (txLoSpin.value !== Prefs.txFilterLow)
                        txLoSpin.value = Prefs.txFilterLow
                }
            }
        }
    }
}
