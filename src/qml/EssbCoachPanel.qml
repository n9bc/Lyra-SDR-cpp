// Lyra — eSSB Coach dock panel.
//
// Listens to the received audio (RX1) and tells you how it sounds to the
// other end: tone against a target curve, bandwidth edges, compression and
// splatter.  Bound to the EssbCoach context property (lyra::ui::EssbCoachModel);
// the model attaches its measurement taps only while the panel is open:
// MainWindow calls EssbCoach.setActive(chip/toggle checked AND the dock's
// window showing) on the toggle action and on every show / hide / re-parent,
// and the model debounces the false edge (a dock tabbed behind stays open).
// Workflow: Baseline (Start .. Stop) -> change something -> Re-check -> compare
// -> Make baseline.  RX1 local only: in desk mode the panel says so.
//
// Practice section (beside the graph), bound to the Practice context property
// (lyra::tx::PracticeLoop): record a 15-30 s clip, loop it unkeyed through the
// TX rack, flip A (saved rack) / B (live edits), Save.  While practice runs the
// coach graphs the post-rack TX monitor (EssbCoach.practice): A in the
// baseline slot, B in the re-check slot, so Baseline / Re-check are disabled.
//
// Styled like the DSP rack panels (SpeechPanel): lit controls use cOn / cOnFill.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    implicitWidth: 780
    implicitHeight: collapsed ? 40 : (body.implicitHeight + 12)
    color: "#101820"
    border.color: "#2a4a5a"

    readonly property color cAccent: "#00e5ff"
    // Lit "on" look, shared across the rack: the Audio panel's Auto orange.
    readonly property color cOn:     "#ff9a3c"
    readonly property color cOnFill: "#3a2a14"
    readonly property color cText:   "#cdd9e5"
    readonly property color cMuted:  "#8a9aac"
    readonly property color cBad:    "#ff5a4a"
    readonly property color cWarn:   "#e0a030"

    property bool collapsed: false

    // The model re-publishes every list on each update (25 Hz while measuring).
    // A ComboBox model that is reassigned that often closes its popup and
    // resets its selection, so the target list is copied only when it changes.
    property var targetList: []
    readonly property int targetIndex: {
        for (var i = 0; i < targetList.length; i++)
            if (targetList[i].id === EssbCoach.targetId) return i
        return 0
    }
    readonly property var metrics: EssbCoach.metrics
    readonly property var edges: EssbCoach.edges
    readonly property var splatter: EssbCoach.splatter
    readonly property bool hasBaseline: EssbCoach.baselineDb.length > 0
    readonly property bool hasRecheck:  EssbCoach.recheckDb.length > 0
    // Practice loop: the context property may be missing in a stripped-down host.
    readonly property bool hasPractice: typeof Practice !== "undefined" && Practice !== null
    readonly property bool inPractice: EssbCoach.practice
    // Voice clips for the practice picker, newest first (the bank appends).
    readonly property var practiceClips: {
        var l = Clips.clips, out = []
        for (var i = l.length - 1; i >= 0; i--)
            if (l[i].kind === 0) out.push(l[i])
        return out
    }
    readonly property bool customTarget: {
        for (var i = 0; i < targetList.length; i++)
            if (targetList[i].id === EssbCoach.targetId) return !targetList[i].builtin
        return false
    }

    function refreshTargets() {
        var t = EssbCoach.targets
        if (JSON.stringify(t) !== JSON.stringify(root.targetList)) root.targetList = t
    }

    function num(v, digits) {
        return (typeof v === "number" && isFinite(v)) ? v.toFixed(digits) : "—"
    }
    function signedDb(v) {
        if (typeof v !== "number" || !isFinite(v)) return "—"
        var r = Math.round(v)
        return (r < 0 ? "−" : (r > 0 ? "+" : "")) + Math.abs(r) + " dB"
    }
    function fmtHz(f) {
        if (f >= 1000) return (f / 1000).toFixed(f < 10000 ? 1 : 0) + "k"
        return Math.round(f).toString()
    }

    // The one status line: transmitting, no audio, or why the gap / crest
    // readings are dashes.  Never repeated in the advice list.
    readonly property string statusNote: {
        if (EssbCoach.transmitting)
            return qsTr("Transmitting: not measuring until you unkey.")
        if (EssbCoach.noAudio)
            return qsTr("No RX audio arriving: nothing to measure.")
        if (EssbCoach.agcFallback)
            return qsTr("Compression readings withheld: AGC correction is not in effect. Set AGC to Off.")
        if (EssbCoach.compressionUnavailable)
            return EssbCoach.unalignedStage.length > 0
                ? qsTr("Compression unavailable while %1 is on").arg(EssbCoach.unalignedStage)
                : qsTr("Compression unavailable while a post-AGC stage with unknown delay is on")
        return ""
    }

    // Lit-state push button, same look as the Audio panel's Auto.
    component LitButton : Button {
        id: lb
        property bool lit: false
        implicitHeight: 24
        implicitWidth: Math.max(48, implicitContentWidth + 16)
        background: Rectangle {
            radius: 3
            color: lb.lit ? root.cOnFill : (lb.down ? "#0c2a32" : "#161e28")
            border.color: lb.lit ? root.cOn : (lb.hovered ? "#6a8aa8" : "#2a3a4a")
            border.width: 1
            opacity: lb.enabled ? 1.0 : 0.45
        }
        contentItem: Text {
            text: lb.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: lb.lit ? root.cOn : root.cText
            font.pixelSize: 12
            opacity: lb.enabled ? 1.0 : 0.45
        }
    }

    // One labelled readout: small muted caption over the value.
    component Readout : ColumnLayout {
        property string caption: ""
        property string value: ""
        property color valueColor: root.cText
        spacing: 0
        Label { text: parent.caption; color: root.cMuted; font.pixelSize: 11 }
        Label { text: parent.value; color: parent.valueColor; font.bold: true
                font.family: "Consolas"; font.pixelSize: 13 }
    }

    Component.onCompleted: refreshTargets()
    Connections {
        target: EssbCoach
        function onUpdated() {
            root.refreshTargets()
            graph.requestPaint()
        }
    }
    Connections {
        target: root.hasPractice ? Practice : null
        // A freshly recorded clip becomes the picked one.
        function onChanged() {
            if (Practice.clipId.length > 0 && Practice.clipId !== practiceBox.wantId) {
                practiceBox.wantId = Practice.clipId
                Qt.callLater(practiceBox.selectWanted)
            }
        }
    }

    // Not available on a desk-side Lyra: the coach measures the local radio.
    Label {
        anchors.centerIn: parent
        width: parent.width - 40
        visible: !EssbCoach.available
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        color: root.cMuted
        font.pixelSize: 14
        text: qsTr("eSSB Coach measures the local radio only — not available in desk mode.")
    }

    // Name prompt for "Capture as target".
    Popup {
        id: capturePopup
        popupType: Popup.Window
        x: Math.round((root.width - width) / 2); y: 60
        width: 280
        padding: 10
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onAboutToShow: { nameFld.text = ""; nameFld.forceActiveFocus() }
        background: Rectangle { color: "#0d141b"; border.color: root.cAccent; radius: 4 }
        contentItem: ColumnLayout {
            spacing: 8
            Label { text: qsTr("Name for the new target"); color: root.cText
                    font.bold: true; font.pixelSize: 13 }
            TextField {
                id: nameFld
                Layout.fillWidth: true
                implicitHeight: 26
                selectByMouse: true
                color: "#f2f8fc"
                font.pixelSize: 13
                onAccepted: okBtn.clicked()
                background: Rectangle {
                    radius: 4; color: "#161e28"
                    border.color: nameFld.activeFocus ? root.cAccent : "#2a3a4a"
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                LyraButton { text: qsTr("Cancel"); onClicked: capturePopup.close() }
                LyraButton {
                    id: okBtn
                    text: qsTr("Capture")
                    enabled: nameFld.text.trim().length > 0
                    onClicked: {
                        if (!enabled) return
                        EssbCoach.captureAsTarget(nameFld.text.trim())
                        capturePopup.close()
                    }
                }
            }
        }
    }

    // Confirm before removing a captured target.
    Popup {
        id: deletePopup
        popupType: Popup.Window
        x: Math.round((root.width - width) / 2); y: 60
        width: 280
        padding: 10
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: "#0d141b"; border.color: root.cAccent; radius: 4 }
        contentItem: ColumnLayout {
            spacing: 8
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: root.cText; font.bold: true; font.pixelSize: 13
                text: qsTr("Delete target \u201C%1\u201D?")
                          .arg(root.targetList.length > root.targetIndex
                               ? root.targetList[root.targetIndex].name : "")
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                LyraButton { text: qsTr("Cancel"); onClicked: deletePopup.close() }
                LyraButton {
                    text: qsTr("Delete")
                    onClicked: {
                        EssbCoach.deleteTarget(EssbCoach.targetId)
                        deletePopup.close()
                    }
                }
            }
        }
    }

    // Editable thresholds and zone edges (EssbCoach.settings), kept here rather
    // than in the main Settings dialog.
    Popup {
        id: settingsPopup
        popupType: Popup.Window
        x: Math.max(0, root.width - width - 6); y: 34
        width: 330
        padding: 10
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: "#0d141b"; border.color: root.cAccent; radius: 4 }
        readonly property var labels: ({
            minSpeechSec:  [qsTr("Min speech"),         " s"],
            minSnrDb:      [qsTr("Min SNR"),            " dB"],
            gapToSpeechDb: [qsTr("Gap to speech limit"), " dB"],
            gapRiseDb:     [qsTr("Gap rise limit"),     " dB"],
            crestDb:       [qsTr("Crest limit"),        " dB"],
            zone0Hz:       [qsTr("Bass from"),          " Hz"],
            zone1Hz:       [qsTr("Low-mid from"),       " Hz"],
            zone2Hz:       [qsTr("Body from"),          " Hz"],
            zone3Hz:       [qsTr("Upper from"),         " Hz"],
            zone4Hz:       [qsTr("Top from"),           " Hz"]
        })
        contentItem: ColumnLayout {
            spacing: 6
            Label { text: qsTr("Coach settings"); color: root.cAccent
                    font.bold: true; font.pixelSize: 14 }
            Repeater {
                model: EssbCoach.settingDefs
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        color: root.cText; font.pixelSize: 13
                        text: settingsPopup.labels[modelData.key]
                              ? settingsPopup.labels[modelData.key][0] : modelData.key
                    }
                    LyraSpinBox {
                        implicitWidth: 92
                        from: Math.round(modelData.min); to: Math.round(modelData.max)
                        stepSize: modelData.key.indexOf("zone") === 0 ? 10 : 1
                        value: Math.round(EssbCoach.settings[modelData.key])
                        onValueModified: EssbCoach.setSetting(modelData.key, value)
                    }
                    Label {
                        Layout.preferredWidth: 26
                        color: root.cMuted; font.pixelSize: 12
                        text: settingsPopup.labels[modelData.key]
                              ? settingsPopup.labels[modelData.key][1] : ""
                    }
                }
            }
            LyraButton {
                Layout.alignment: Qt.AlignRight
                text: qsTr("Defaults")
                onClicked: EssbCoach.resetSettings()
            }
        }
    }

    // Vertical scroll when the panel is shorter than its content (floated
    // small or racked) — same idiom as SpeechPanel / the CW decoder.
    ScrollView {
        id: bodyScroll
        anchors.fill: parent
        anchors.margins: 6
        clip: true
        visible: EssbCoach.available
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            id: body
            width: bodyScroll.availableWidth
            spacing: 6

            // ── Header: title, target, advice style, settings, collapse ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Label { text: qsTr("eSSB Coach"); color: root.cAccent
                        font.bold: true; font.pixelSize: 14 }
                Label { text: qsTr("RX1 audio"); color: root.cMuted; font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
                Label { text: qsTr("Target"); color: root.cMuted; font.pixelSize: 12
                        visible: !root.collapsed }
                LyraComboBox {
                    id: targetBox
                    visible: !root.collapsed
                    implicitWidth: 170
                    model: root.targetList
                    textRole: "name"
                    currentIndex: root.targetIndex
                    onActivated: (i) => EssbCoach.targetId = root.targetList[i].id
                }
                Label { text: qsTr("Advice for"); color: root.cMuted; font.pixelSize: 12
                        visible: !root.collapsed }
                LitButton {
                    visible: !root.collapsed
                    text: qsTr("Lyra"); lit: EssbCoach.lyraAdvice
                    onClicked: EssbCoach.lyraAdvice = true
                }
                LitButton {
                    visible: !root.collapsed
                    text: qsTr("Other"); lit: !EssbCoach.lyraAdvice
                    onClicked: EssbCoach.lyraAdvice = false
                }
                Button {
                    visible: !root.collapsed
                    implicitWidth: 28; implicitHeight: 22
                    text: "⚙"
                    onClicked: settingsPopup.open()
                    background: Rectangle { radius: 4; color: "#1f2a35"; border.color: "#3a5060" }
                    contentItem: Text { text: parent.text; color: root.cAccent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    implicitWidth: 28; implicitHeight: 22
                    text: root.collapsed ? "▲" : "▼"
                    onClicked: root.collapsed = !root.collapsed
                    background: Rectangle { radius: 4; color: "#1f2a35"; border.color: "#3a5060" }
                    contentItem: Text { text: parent.text; color: root.cAccent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter }
                }
            }

            // ── Controls ────────────────────────────────────────────────
            Flow {
                Layout.fillWidth: true
                visible: !root.collapsed
                spacing: 6
                LitButton {
                    text: EssbCoach.baselineState === 1 ? qsTr("Baseline: Stop")
                                                        : qsTr("Baseline: Start")
                    lit: EssbCoach.baselineState === 1
                    enabled: EssbCoach.recheckState !== 1 && !root.inPractice
                    onClicked: EssbCoach.baselineState === 1 ? EssbCoach.stopBaseline()
                                                             : EssbCoach.startBaseline()
                }
                LitButton {
                    text: EssbCoach.recheckState === 1 ? qsTr("Re-check: Stop")
                                                       : qsTr("Re-check: Start")
                    lit: EssbCoach.recheckState === 1
                    enabled: root.hasBaseline && EssbCoach.baselineState !== 1 && !root.inPractice
                    onClicked: EssbCoach.recheckState === 1 ? EssbCoach.stopRecheck()
                                                            : EssbCoach.startRecheck()
                }
                LitButton {
                    text: qsTr("Make baseline")
                    enabled: root.hasRecheck && EssbCoach.recheckState !== 1 && !root.inPractice
                    onClicked: EssbCoach.makeBaseline()
                }
                LitButton {
                    text: qsTr("Reset")
                    onClicked: {
                        if (root.hasPractice) Practice.stop()   // Reset ends practice
                        EssbCoach.reset()
                    }
                }
                LitButton {
                    text: qsTr("Freeze"); lit: EssbCoach.frozen
                    onClicked: EssbCoach.setFrozen(!EssbCoach.frozen)
                }
                LitButton {
                    text: qsTr("Capture as target")
                    enabled: root.hasBaseline
                    onClicked: capturePopup.open()
                }
                LitButton {
                    text: qsTr("Delete target")
                    visible: root.customTarget
                    onClicked: deletePopup.open()
                }
                LitButton {
                    text: EssbCoach.recording ? qsTr("Recording") : qsTr("Record")
                    lit: EssbCoach.recording
                    onClicked: EssbCoach.toggleRecord()
                }
            }
            Label {
                Layout.fillWidth: true
                visible: !root.collapsed
                wrapMode: Text.WordWrap
                color: root.cMuted; font.pixelSize: 11
                text: EssbCoach.holdNote
            }
            Label {
                Layout.fillWidth: true
                visible: !root.collapsed && EssbCoach.pausedWhileHidden
                wrapMode: Text.WordWrap
                color: root.cWarn; font.pixelSize: 12
                text: (EssbCoach.baselineState === 1
                          ? qsTr("Baseline paused while the panel was hidden.")
                          : qsTr("Re-check paused while the panel was hidden."))
                      + " " + qsTr("That time was not measured.")
            }

            // ── Graph + Practice ────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                visible: !root.collapsed
                spacing: 8
                Canvas {
                    id: graph
                    Layout.fillWidth: true
                    Layout.preferredHeight: 230
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

                    readonly property real padL: 36
                    readonly property real padR: 8
                    readonly property real padT: 8
                    readonly property real padB: 18
                    readonly property real dbMin: -20
                    readonly property real dbMax: 20
                    readonly property real fMin: 40

                    function xOf(f, fMax) {
                        var w = width - padL - padR
                        var t = Math.log(Math.max(f, fMin) / fMin) / Math.log(fMax / fMin)
                        return padL + Math.max(0, Math.min(1, t)) * w
                    }
                    function yOf(db) {
                        var h = height - padT - padB
                        var t = (dbMax - Math.max(dbMin, Math.min(dbMax, db))) / (dbMax - dbMin)
                        return padT + t * h
                    }

                    // A polyline through finite points; NaN breaks the line.
                    function strokeCurve(ctx, bands, vals, fMax) {
                        ctx.beginPath()
                        var pen = false
                        for (var i = 0; i < bands.length && i < vals.length; i++) {
                            if (!isFinite(vals[i])) { pen = false; continue }
                            if (bands[i] > fMax) break   // past the plot: no pile-up at the edge
                            var x = xOf(bands[i], fMax), y = yOf(vals[i])
                            if (pen) ctx.lineTo(x, y); else ctx.moveTo(x, y)
                            pen = true
                        }
                        ctx.stroke()
                    }

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var W = width, H = height
                        ctx.fillStyle = "#0b141b"
                        ctx.fillRect(0, 0, W, H)

                        var bands = EssbCoach.bandsHz
                        var rxLo = EssbCoach.rxLowHz, rxHi = EssbCoach.rxHighHz
                        // Axis runs 40 Hz .. just past the RX passband so the part
                        // beyond the filter is visible (and greyed).
                        var fMax = Math.max(1000, Math.min(12000, rxHi * 1.25))
                        var x0 = padL, x1 = W - padR
                        var yTop = padT, yBot = H - padB

                        // grey out what our own RX filter removes
                        ctx.fillStyle = "rgba(120,130,140,0.22)"
                        if (rxLo > fMin) ctx.fillRect(x0, yTop, xOf(rxLo, fMax) - x0, yBot - yTop)
                        if (rxHi < fMax) {
                            var xr = xOf(rxHi, fMax)
                            ctx.fillRect(xr, yTop, x1 - xr, yBot - yTop)
                        }

                        // grid + labels
                        ctx.font = "10px sans-serif"
                        ctx.lineWidth = 1
                        ctx.textBaseline = "middle"
                        ctx.textAlign = "right"
                        for (var d = dbMin; d <= dbMax; d += 10) {
                            var yy = Math.round(yOf(d)) + 0.5
                            ctx.strokeStyle = d === 0 ? "#3a5060" : "#1c2a36"
                            ctx.beginPath(); ctx.moveTo(x0, yy); ctx.lineTo(x1, yy); ctx.stroke()
                            ctx.fillStyle = root.cMuted
                            ctx.fillText((d > 0 ? "+" : "") + d, x0 - 4, yy)
                        }
                        ctx.textAlign = "center"
                        ctx.textBaseline = "top"
                        // Ticks run up to the filter edge, which gets its own label
                        // ("TX 4.00k" in practice, as the TX EQ shows it); a tick
                        // label that would collide with a neighbour is dropped.
                        var edgeX = rxHi < fMax ? xOf(rxHi, fMax) : -1
                        var edgeTxt = (EssbCoach.practice ? "TX " : "RX ") + (rxHi / 1000).toFixed(2) + "k"
                        var edgeHalf = ctx.measureText(edgeTxt).width / 2
                        var ticks = [100, 200, 500, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000]
                        var lastX = -1e9
                        for (var k = 0; k < ticks.length; k++) {
                            if (ticks[k] >= fMax) continue
                            var xx = Math.round(xOf(ticks[k], fMax)) + 0.5
                            ctx.strokeStyle = "#1c2a36"
                            ctx.beginPath(); ctx.moveTo(xx, yTop); ctx.lineTo(xx, yBot); ctx.stroke()
                            var lbl = ticks[k] >= 1000 ? (ticks[k] / 1000) + "k" : ticks[k].toString()
                            var labelHalf = ctx.measureText(lbl).width / 2
                            if (xx - labelHalf < lastX + 4
                                    || (edgeX >= 0 && Math.abs(xx - edgeX) < labelHalf + edgeHalf + 4)) continue
                            ctx.fillStyle = root.cMuted
                            ctx.fillText(lbl, xx, yBot + 3)
                            lastX = xx + labelHalf
                        }
                        if (edgeX >= 0) {
                            ctx.fillStyle = root.cAccent
                            ctx.fillText(edgeTxt, edgeX, yBot + 3)
                        }

                        // target +- tolerance band, then the target line
                        var tdb = EssbCoach.targetDb, tol = EssbCoach.tolDb
                        if (tdb.length > 1 && tol.length === tdb.length) {
                            ctx.fillStyle = "rgba(0,229,255,0.14)"
                            ctx.beginPath()
                            var started = false, i
                            for (i = 0; i < bands.length; i++) {
                                if (!isFinite(tdb[i]) || !isFinite(tol[i])) continue
                                if (bands[i] > fMax) break
                                var xa = xOf(bands[i], fMax), ya = yOf(tdb[i] + tol[i])
                                if (started) ctx.lineTo(xa, ya); else ctx.moveTo(xa, ya)
                                started = true
                            }
                            for (i = bands.length - 1; i >= 0; i--) {
                                if (!isFinite(tdb[i]) || !isFinite(tol[i]) || bands[i] > fMax) continue
                                ctx.lineTo(xOf(bands[i], fMax), yOf(tdb[i] - tol[i]))
                            }
                            ctx.closePath()
                            ctx.fill()
                            ctx.strokeStyle = root.cAccent
                            ctx.lineWidth = 1
                            strokeCurve(ctx, bands, tdb, fMax)
                        }

                        // live bars (1/6 octave), grey outside the RX passband
                        var live = EssbCoach.liveDb
                        var half = Math.pow(2, 1 / 12)
                        for (var b = 0; b < bands.length && b < live.length; b++) {
                            if (!isFinite(live[b]) || bands[b] / half >= fMax) continue
                            var bl = xOf(bands[b] / half, fMax), br = xOf(Math.min(bands[b] * half, fMax), fMax)
                            var inRx = bands[b] >= rxLo && bands[b] <= rxHi
                            ctx.fillStyle = inRx ? "rgba(0,229,255,0.35)" : "rgba(138,154,172,0.30)"
                            var by = yOf(live[b])
                            ctx.fillRect(bl + 0.5, by, Math.max(1, br - bl - 1), yBot - by)
                        }

                        // baseline (dimmed once a re-check exists) and current average
                        var base = EssbCoach.baselineDb, rc = EssbCoach.recheckDb
                        ctx.lineWidth = 2
                        if (rc.length > 0) {
                            ctx.strokeStyle = "rgba(138,154,172,0.75)"
                            strokeCurve(ctx, bands, base, fMax)
                            ctx.strokeStyle = root.cOn
                            strokeCurve(ctx, bands, rc, fMax)
                        } else if (base.length > 0) {
                            ctx.strokeStyle = root.cOn
                            strokeCurve(ctx, bands, base, fMax)
                        }

                        // bandwidth edges from the measured curve
                        var ed = root.edges
                        ctx.setLineDash([4, 3])
                        ctx.lineWidth = 1
                        ctx.strokeStyle = root.cWarn
                        ctx.fillStyle = root.cWarn
                        ctx.textBaseline = "top"
                        var eh = [ed.lowHz, ed.highHz]
                        for (var e = 0; e < 2; e++) {
                            if (typeof eh[e] !== "number" || !isFinite(eh[e])) continue
                            var ex = Math.round(xOf(eh[e], fMax)) + 0.5
                            ctx.beginPath(); ctx.moveTo(ex, yTop); ctx.lineTo(ex, yBot); ctx.stroke()
                            ctx.textAlign = e === 0 ? "left" : "right"
                            ctx.fillText(root.fmtHz(eh[e]), ex + (e === 0 ? 3 : -3), yTop + 2)
                        }
                        ctx.setLineDash([])
                    }
                }

                // ── Practice loop (PracticeLoop, "Practice") ───────────────
                ColumnLayout {
                    id: practiceCol
                    visible: root.hasPractice
                    Layout.preferredWidth: 230
                    Layout.maximumWidth: 230
                    Layout.alignment: Qt.AlignTop
                    spacing: 5

                    readonly property bool counting: root.hasPractice && Practice.countdownSec > 0
                    readonly property bool recording: root.hasPractice && Practice.recording
                    readonly property bool looping: root.hasPractice && Practice.looping
                    readonly property bool ab: root.hasPractice && Practice.abAvailable

                    Label { text: qsTr("Practice"); color: root.cAccent
                            font.bold: true; font.pixelSize: 13 }
                    // The shown clip is the one Loop plays.  The pick is kept
                    // by id (wantId), so a clip added or removed elsewhere does
                    // not move it; a new practice clip selects itself.
                    LyraComboBox {
                        id: practiceBox
                        Layout.fillWidth: true
                        property string wantId: ""
                        readonly property string selectedId:
                            (currentIndex >= 0 && currentIndex < root.practiceClips.length)
                            ? root.practiceClips[currentIndex].id : ""
                        function selectWanted() {
                            for (var i = 0; i < root.practiceClips.length; i++)
                                if (root.practiceClips[i].id === wantId) { currentIndex = i; return }
                            currentIndex = root.practiceClips.length > 0 ? 0 : -1
                        }
                        model: root.practiceClips
                        textRole: "label"
                        enabled: !practiceCol.looping && !practiceCol.recording && !practiceCol.counting
                        onModelChanged: Qt.callLater(selectWanted)
                        onActivated: (i) => wantId = root.practiceClips[i].id
                    }
                    RowLayout {
                        spacing: 6
                        LitButton {
                            text: practiceCol.counting
                                  ? qsTr("Get set %1").arg(Practice.countdownSec)
                                  : (practiceCol.recording ? qsTr("Stop record") : qsTr("Record"))
                            lit: practiceCol.recording || practiceCol.counting
                            enabled: !practiceCol.looping
                            onClicked: (practiceCol.recording || practiceCol.counting)
                                       ? Practice.stopRecord() : Practice.startRecord()
                        }
                        Label {
                            visible: practiceCol.recording
                            color: Practice.recordMs >= 15000 ? root.cText : root.cWarn
                            font.family: "Consolas"; font.pixelSize: 12
                            text: qsTr("%1 s / 30").arg(Math.floor(Practice.recordMs / 1000))
                        }
                    }
                    RowLayout {
                        spacing: 6
                        LitButton {
                            text: practiceCol.looping ? qsTr("Stop") : qsTr("Loop")
                            lit: practiceCol.looping
                            enabled: practiceCol.looping
                                     || (practiceBox.selectedId.length > 0
                                         && !practiceCol.recording && !practiceCol.counting)
                            onClicked: practiceCol.looping ? Practice.stop()
                                                           : Practice.play(practiceBox.selectedId)
                        }
                        // A | B: A = the profile's saved rack, B = the live edits.
                        LitButton {
                            text: qsTr("A")
                            implicitWidth: 32
                            lit: practiceCol.ab && Practice.side === 0
                            enabled: practiceCol.ab
                            onClicked: if (Practice.side !== 0) Practice.flip()
                        }
                        LitButton {
                            text: qsTr("B")
                            implicitWidth: 32
                            lit: practiceCol.ab && Practice.side === 1
                            enabled: practiceCol.ab
                            onClicked: if (Practice.side !== 1) Practice.flip()
                        }
                        LitButton {
                            text: qsTr("Save")
                            enabled: practiceCol.ab
                            onClicked: Practice.save()
                        }
                    }
                    Label {
                        visible: practiceCol.looping
                        color: root.cMuted; font.pixelSize: 11
                        text: qsTr("Pass %1 · %2%").arg(Practice.passes + 1)
                                                   .arg(Math.round(Practice.progress * 100))
                    }
                    Label {
                        Layout.fillWidth: true
                        color: root.inPractice ? root.cOn : root.cMuted
                        font.pixelSize: 11
                        text: root.inPractice ? qsTr("Practice: post-rack TX") : qsTr("RX1")
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: root.hasPractice && Practice.note.length > 0
                        wrapMode: Text.WordWrap
                        color: root.cWarn; font.pixelSize: 12
                        text: root.hasPractice ? Practice.note : ""
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        color: root.cMuted; font.pixelSize: 11
                        text: qsTr("Mic gain and PHROT are not in the loop.")
                    }
                }
            }

            // ── Readouts ────────────────────────────────────────────────
            Flow {
                Layout.fillWidth: true
                visible: !root.collapsed
                spacing: 22
                Readout {
                    caption: qsTr("Confidence")
                    value: qsTr("Speech %1 s · SNR %2 dB")
                               .arg(Math.round(EssbCoach.speechSec)).arg(root.num(EssbCoach.snrDb, 0))
                }
                Readout {
                    caption: qsTr("Edges")
                    value: EssbCoach.edgesText.length > 0 ? EssbCoach.edgesText : "—"
                }
                Readout { caption: qsTr("Gap to speech")
                          value: root.num(root.metrics.gapToSpeechDb, 0) + (isFinite(root.metrics.gapToSpeechDb) ? " dB" : "") }
                Readout { caption: qsTr("Gap rise")
                          value: root.num(root.metrics.gapRiseDb, 0) + (isFinite(root.metrics.gapRiseDb) ? " dB" : "") }
                Readout { caption: qsTr("Crest")
                          value: root.num(root.metrics.crestDb, 0) + (isFinite(root.metrics.crestDb) ? " dB" : "") }
                Readout {
                    caption: qsTr("Splatter")
                    value: root.splatter.status === "practice" ? qsTr("Not measured in practice")
                           : root.splatter.status === "am" ? qsTr("not measured in AM")
                           : !root.splatter.valid ? qsTr("not measured")
                           : (root.splatter.alert
                              ? qsTr("ALERT −%1 dB").arg(Math.round(root.splatter.marginDb))
                              : qsTr("OK −%1 dB").arg(Math.round(root.splatter.marginDb)))
                    valueColor: (root.splatter.valid && root.splatter.alert) ? root.cBad : root.cText
                }
            }
            Label {
                Layout.fillWidth: true
                visible: !root.collapsed && root.statusNote.length > 0
                wrapMode: Text.WordWrap
                color: root.cWarn; font.pixelSize: 12
                text: root.statusNote
            }

            // ── Advice ──────────────────────────────────────────────────
            Repeater {
                model: root.collapsed ? [] : EssbCoach.adviceLines
                delegate: Label {
                    required property string modelData
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: root.cText; font.pixelSize: 13
                    text: "• " + modelData
                }
            }

            // ── Compare: re-check minus baseline, per zone ──────────────
            Flow {
                Layout.fillWidth: true
                visible: !root.collapsed && root.hasRecheck && EssbCoach.zoneDeltas.length > 0
                spacing: 18
                Repeater {
                    model: EssbCoach.zoneDeltas
                    delegate: Label {
                        required property var modelData
                        color: root.cText; font.bold: true; font.pixelSize: 13
                        text: modelData.label + " " + root.signedDb(modelData.db)
                    }
                }
            }
        }
    }
}
