// Lyra — Audio Visualizer dock panel.
//
// A thin bar over the visualizer canvas.  Per the spec the bar carries only
// the view picker, the Peak hold toggle and a read-only span/source label
// ("0–4 kHz · RX", "· TX" while transmitting voice); palette, effects,
// speed and reactivity live in Settings → Visualizer.  The picker and the
// toggle write Prefs directly — Prefs is the single source of truth, so the
// Settings thumbnails and this dock always agree.  Under the canvas a small
// kHz axis labels the 25-bar and FFT line views (not Scope or Radial, and
// not the Settings thumbnails, which use AudioVisCanvas without this panel).
//
// The canvas (AudioVisCanvas.qml) follows Prefs for view / peak hold /
// palette / echo / glow / background opacity on its own.  Its `active`
// input is `dockOpen` (set by the dock host from the dock's real visibility;
// a hidden QDockWidget does not hide QML items, see there) and not a remote
// desk: on the desk side the audio comes from the host, so there is nothing
// to analyse and a notice replaces the canvas.  Under Qt Quick's software
// backend (graphics safe mode / safe boot) the canvas would draw nothing, so
// there too a notice replaces it and nothing is analysed.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    implicitWidth: 480
    implicitHeight: 320
    color: "#101820"
    border.color: "#2a4a5a"

    readonly property color cText:  "#cdd9e5"
    readonly property color cMuted: "#8a9aac"

    // Driven by the dock host: false until the dock is really showing, so a
    // dock hidden at startup never acquires the analysis hub.
    property bool dockOpen: false
    readonly property bool onDesk: DeskLink.deskSide
    readonly property bool software: GraphicsInfo.api === GraphicsInfo.Software
    readonly property bool noCanvas: onDesk || software

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // ── Bar: view picker, Peak hold, span/source ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: !root.noCanvas

            LyraComboBox {
                id: viewPicker
                Layout.preferredWidth: 104
                // Order = Prefs.visView / AudioVisItem.view (0..3).
                model: [qsTr("25-bar"), qsTr("FFT line"), qsTr("Scope"), qsTr("Radial")]
                currentIndex: Prefs.visView
                onActivated: (i) => Prefs.visView = i
                // In-scene list, not LyraComboBox's own Popup.Window: once
                // that window has opened, moving this panel to another
                // top-level (docking or floating the dock) leaves the popup
                // "open" with its window never shown again, so the picker
                // stops working for the session.
                // Four rows fit inside the panel (minimum height 320), so
                // the in-scene list is never clipped.
                popup.popupType: Popup.Item
                helpTitle: qsTr("View")
                helpText: qsTr("25-bar analyser, FFT line, oscilloscope or the radial ring.")
            }

            // Not `checkable`: a click on a checkable button would break the
            // `checked` binding, and a later change from Settings (or a
            // restored profile) would no longer show here.  Writing Prefs and
            // letting the binding follow keeps the two in step.
            LyraButton {
                text: qsTr("Peak hold")
                checked: Prefs.visPeakHold
                onClicked: Prefs.visPeakHold = !Prefs.visPeakHold
            }

            // Takes what the picker and Peak hold leave, so it gives way
            // first in a narrow panel: the span elides, keeping "· RX", and
            // below a readable width the label drops out altogether.  (A
            // layout item without fillWidth can't shrink below its text.)
            Label {
                text: canvas.statusText
                color: root.cMuted
                font.pixelSize: 12
                elide: Text.ElideLeft
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                opacity: width >= 40 ? 1 : 0
            }
        }

        AudioVisCanvas {
            id: canvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 60
            visible: !root.noCanvas
            active: root.dockOpen && !root.noCanvas
        }

        // ── Frequency axis (25-bar and FFT line; empty for Scope / Radial) ──
        // Outside the canvas, so its echo trails and glow never smear the
        // labels, and always the same height, so a view switch never
        // resizes the canvas.  Positions come from the item (freqToX: the
        // maths that draws the bars / line), so a label sits exactly under
        // its frequency.  Bars are log-spaced, so they get 0.1 / 0.2 / 0.5 /
        // 1 / 2 / 5 … kHz; the line is linear and gets the smallest 0.5 /
        // 1 / 2 / 5 kHz step whose labels fit.  A label that would touch an
        // earlier one is dropped, so they never overlap at any width.
        Item {
            id: axis
            Layout.fillWidth: true
            Layout.preferredHeight: 12
            Layout.topMargin: -3
            visible: !root.noCanvas

            readonly property int  gap: 6
            readonly property var  ticks: axis.layoutTicks(canvas.item.view,
                                                            canvas.item.spanHz,
                                                            canvas.item.width)

            // FontMetrics.advanceWidth() is a plain call: measuring through
            // a TextMetrics' text/advanceWidth properties would make `ticks`
            // depend on what it writes (a binding loop).
            FontMetrics { id: tickMetrics; font.pixelSize: 10 }

            function label(khz) {
                return Number.isInteger(khz) ? String(khz) : khz.toFixed(1)
            }
            function textWidth(t) {
                return tickMetrics.advanceWidth(t)
            }
            function layoutTicks(view, span, w) {
                if ((view !== 0 && view !== 1) || !(span > 0) || !(w > 0))
                    return []
                const top = span / 1000
                let cands = []                  // in priority order, kHz
                if (view === 0) {
                    cands = [1, 0.1, 2, 5, 0.2, 0.5, 3, 4, 6, 8, 10, 7, 9]
                } else {
                    const steps = [0.5, 1, 2, 5]
                    let step = 5
                    for (const s of steps) {
                        let widest = 0
                        for (let f = 0; f <= top + 1e-9; f += s)
                            widest = Math.max(widest, textWidth(label(f)))
                        if (s / top * w >= widest + axis.gap) { step = s; break }
                    }
                    // Whole kHz first, so a crowded end drops a half.
                    for (let f = 0; f <= top + 1e-9; f += step)
                        if (Number.isInteger(f)) cands.push(f)
                    for (let f = 0; f <= top + 1e-9; f += step)
                        if (!Number.isInteger(f)) cands.push(f)
                }
                let kept = []
                for (const f of cands) {
                    const x = canvas.item.freqToX(f * 1000)
                    if (x < 0) continue
                    const text = label(f)
                    const tw = textWidth(text)
                    const left = Math.max(0, Math.min(w - tw, x - tw / 2))
                    if (kept.some(k => left < k.left + k.width + axis.gap
                                       && k.left < left + tw + axis.gap))
                        continue
                    kept.push({ left: left, width: tw, text: text })
                }
                return kept
            }

            Repeater {
                model: axis.ticks
                Text {
                    required property var modelData
                    x: modelData.left
                    text: modelData.text
                    color: root.cMuted
                    font.pixelSize: 10
                }
            }
        }

        Label {
            visible: root.onDesk
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Not available on a remote desk")
            color: root.cMuted
            font.pixelSize: 14
        }

        Label {
            visible: root.software && !root.onDesk
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            text: qsTr("Not available with software rendering (graphics safe mode)")
            color: root.cMuted
            font.pixelSize: 14
        }
    }
}
