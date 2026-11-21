import SwiftUI

/// Developer gallery showing one of every neon control bound to local state.
struct ControlGalleryPanel: LyraPanel {
    let id = "controls"
    let title = "Controls"
    let systemImage = "dial.medium"
    let category = PanelCategory.tools
    let defaultVisible = false

    var content: some View { ControlGalleryContent() }
}

private struct ControlGalleryContent: View {
    nonisolated init() {}

    @State private var dial = 50.0
    @State private var slider = 30.0
    @State private var toggleOn = true
    @State private var mode = "USB"
    @State private var hz: UInt32 = 14_074_000
    @State private var dbm = -73.0

    private static let modes = ["USB", "LSB", "CW", "AM"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LyraFrequencyDisplay(hz: hz, onChange: { hz = $0 }, size: 26)
                LyraSMeter(dbm: dbm)
                LyraSlider("S-Meter dBm", value: $dbm, in: -127 ... -13, unit: "dBm")
                LyraRotaryDial("Volume", value: $dial, in: 0 ... 100, unit: "%", defaultValue: 50)
                LyraSlider("Slider", value: $slider, in: 0 ... 100, unit: "%", defaultValue: 30)
                HStack(spacing: 8) {
                    LyraButton("Inactive", systemImage: "power") {}
                    LyraButton("Active", systemImage: "bolt.fill", isActive: true) {}
                }
                LyraToggle("Toggle", isOn: $toggleOn)
                LyraSegmentedControl("Mode", selection: $mode, options: Self.modes, title: { $0 })
            }
            .padding(12)
        }
    }
}
