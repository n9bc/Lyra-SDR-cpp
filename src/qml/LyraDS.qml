pragma Singleton
import QtQuick

// Observatory neon design-system tokens.
// Source of truth: Observatory/Theme/LyraDesignSystem.swift — keep values
// byte-identical to the Swift `LyraDS` enum.
QtObject {
    readonly property QtObject palette: QtObject {
        readonly property color electricBlue: "#2E6BFF"
        readonly property color cyan: "#00E5FF"
        readonly property color purple: "#8B5CF6"
        readonly property color magenta: "#FF2BD6"
        readonly property color pink: "#FF5C8A"
        readonly property color yellow: "#FFD23F"
        readonly property color green: "#2BFF88"

        readonly property color void_: "#05060B"   // Swift `void` (reserved word in JS)
        readonly property color surface: "#0B0D17"
        readonly property color surfaceElevated: "#131628"

        readonly property color textPrimary: "#EAF2FF"
        readonly property color textMuted: "#8A93B2"
        readonly property color textDim: "#4F5675"

        readonly property color border: Qt.rgba(1, 1, 1, 0.08)

        // Console tokens (native console mockup).
        readonly property color vfoTop: "#0F1427"
        readonly property color vfoBottom: "#080A14"
        readonly property color vfoBorder: Qt.alpha("#78A0FF", 0.16)
        readonly property color vfoBorderHighlight: Qt.alpha("#00E5FF", 0.32)
        readonly property color vfoGlowHighlight: Qt.alpha("#00E5FF", 0.06)
        readonly property color vfoInnerHighlight: Qt.rgba(1, 1, 1, 0.05)
        readonly property color chipFill: surfaceElevated
        readonly property color segmentOff: "#1A1E33"
        readonly property color freqGlow: "#E4FCFF"
        readonly property color freqSub: "#A3ACC8"
        readonly property color txFill: "#E8335F"
        readonly property color txText: "#FFFFFF"
        readonly property color moxHint: "#FF9DB8"
        readonly property color moxIdleFill: Qt.alpha(pink, 0.06)
        readonly property color meterTrack: "#171A2E"

        readonly property color panelBorder: Qt.rgba(1, 1, 1, 0.07)
        readonly property color chipBorder: Qt.rgba(1, 1, 1, 0.09)
        readonly property color chipText: "#B7C0DE"
        readonly property color chipSubText: "#C4B0FF"
        readonly property color chipDimText: "#5E6688"
        readonly property color chipDimFill: "#0F1220"
        readonly property color vchipFill: "#0B0E1B"
        readonly property color vchipBorder: Qt.rgba(1, 1, 1, 0.13)
        readonly property color zeroBeatTrack: "#171A2E"
        readonly property color sBoxBorder: Qt.rgba(1, 1, 1, 0.2)
        readonly property color sBoxBorderOff: Qt.rgba(1, 1, 1, 0.12)
        readonly property color barFill: "#080A12"
        readonly property color barBorder: Qt.rgba(1, 1, 1, 0.06)
        // Sample waterfall ground (mockup #071036).
        readonly property color waterfallGround: "#071036"

        // Spectrum colour ramp: position 0..1, channels 0..1 (hex / 255).
        readonly property var spectrumStops: [
            { position: 0.0,  r: 0x2E / 255, g: 0x6B / 255, b: 0xFF / 255 },
            { position: 0.3,  r: 0x00 / 255, g: 0xE5 / 255, b: 0xFF / 255 },
            { position: 0.55, r: 0x8B / 255, g: 0x5C / 255, b: 0xF6 / 255 },
            { position: 0.8,  r: 0xFF / 255, g: 0x2B / 255, b: 0xD6 / 255 },
            { position: 1.0,  r: 0xFF / 255, g: 0xD2 / 255, b: 0x3F / 255 }
        ]
    }

    readonly property QtObject space: QtObject {
        readonly property real xs: 4
        readonly property real sm: 8
        readonly property real md: 12
        readonly property real lg: 16
        readonly property real xl: 24
    }

    readonly property QtObject radius: QtObject {
        readonly property real sm: 6
        readonly property real md: 10
        readonly property real lg: 16
    }
}
