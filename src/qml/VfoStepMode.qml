// Lyra — a VFO's Step, Mode and Filter pickers, shared by every VFO style.
//
// Holds ALL the Step/Mode logic — per-mode step memory, and RX2's own step
// and mode on VFO B — so a style only decides where this row sits (its
// stepModeRect) and its colours (its theme).  VFO B shows Mode only in SUB;
// in SPLIT it transmits on VFO A's mode; Filter follows Mode's visibility.
// theme.compact hides the "Step" / "Mode" / "Filter" captions and narrows
// the pickers for small styles.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FilterPresets.js" as FilterPresets

RowLayout {
    id: sm
    required property var panel      // TuningPanel root (step / mode lists)
    required property bool isB
    property bool showMode: true
    property var theme
    readonly property bool compact: theme.compact === true
    readonly property int stepHz: panel.vfoStepHzList[stepBox.currentIndex]
    spacing: 6

    Item { Layout.fillWidth: true }
    Label {
        visible: !sm.compact
        text: qsTr("Step")
        color: sm.theme.label
        font.bold: true
    }
    LyraComboBox {
        id: stepBox
        Layout.preferredWidth: sm.compact ? 84 : 92
        model: sm.panel.vfoStepLabels
        helpTitle: sm.isB ? qsTr("Step B") : qsTr("Step")
        helpText: sm.isB ? qsTr("Click/wheel VFO B step for this mode.")
                         : qsTr("Click/wheel VFO step for this mode. Remembered per mode.")
        currentIndex: sm.panel.vfoStepIndex(sm.isB
            ? Prefs.vfoStepHzRx2(Prefs.modeRx2)
            : Prefs.vfoStepHz(Prefs.mode))
        onActivated: {
            var hz = sm.panel.vfoStepHzList[currentIndex]
            if (sm.isB) Prefs.setVfoStepHzRx2(Prefs.modeRx2, hz)
            else        Prefs.setVfoStepHz(Prefs.mode, hz)
        }
        fieldColor: sm.theme.field
        fieldBorderColor: sm.theme.fieldBorder
        textColor: sm.theme.text
        accentColor: sm.theme.accent
    }
    Label {
        visible: sm.showMode && !sm.compact
        text: qsTr("Mode")
        color: sm.theme.label
        font.bold: true
    }
    LyraComboBox {
        visible: sm.showMode
        Layout.preferredWidth: sm.compact ? 70 : 78
        model: sm.panel.modeList
        helpTitle: sm.isB ? qsTr("Mode B") : qsTr("Mode")
        helpText: sm.isB
            ? qsTr("Demod mode for VFO B. Filter bandwidths are remembered per mode.")
            : qsTr("Demod mode for VFO A. Filter bandwidths are remembered per mode.")
        currentIndex: Math.max(0, sm.panel.modeList.indexOf(sm.isB ? Prefs.modeRx2 : Prefs.mode))
        onActivated: {
            if (sm.isB) Prefs.modeRx2 = sm.panel.modeList[currentIndex]
            else        Prefs.mode    = sm.panel.modeList[currentIndex]
        }
        fieldColor: sm.theme.field
        fieldBorderColor: sm.theme.fieldBorder
        textColor: sm.theme.text
        accentColor: sm.theme.accent
    }
    // RX filter bandwidth, from this VFO's mode presets.
    Label {
        visible: sm.showMode && !sm.compact
        text: qsTr("Filter")
        color: sm.theme.label
        font.bold: true
    }
    LyraComboBox {
        id: bwBox
        readonly property string bwMode: sm.isB ? Prefs.modeRx2 : Prefs.mode
        readonly property int bw: sm.isB ? Prefs.rx2Bandwidth : Prefs.rxBandwidth
        visible: sm.showMode
        Layout.preferredWidth: sm.compact ? 64 : 72
        font.pixelSize: 12
        textLeftPad: 4
        textRightPad: 14
        model: FilterPresets.model(bwMode, bw, "")
        currentIndex: FilterPresets.currentIndex(bwMode, bw)
        helpTitle: sm.isB ? qsTr("Filter B") : qsTr("Filter")
        helpText: sm.isB
            ? qsTr("RX2 filter bandwidth — presets for VFO B's mode.")
            : qsTr("RX filter bandwidth — presets for this mode. Remembered per mode.")
        onActivated: {
            var hz = FilterPresets.valueAt(bwMode, bw, currentIndex)
            if (sm.isB) Prefs.rx2Bandwidth = hz
            else        Prefs.rxBandwidth  = hz
        }
        fieldColor: sm.theme.field
        fieldBorderColor: sm.theme.fieldBorder
        textColor: sm.theme.text
        accentColor: sm.theme.accent
    }
    Item { Layout.fillWidth: true }
}
