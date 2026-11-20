import SwiftUI

struct MetersPanel: LyraPanel {
    let id = "meters"
    let title = "Meters"
    let systemImage = "gauge"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { MetersPanelContent() }
}

private struct MetersPanelContent: View {
    nonisolated init() {}

    @Environment(MeterBridge.self) private var meter
    @State private var source = "S-Meter"

    private static let sources = ["S-Meter", "PWR", "SWR", "PA Current", "Temp"]

    /// Level 0...1 and display text. MeterBridge has no PA current / temperature yet (P0 mock),
    /// so those sources read zero until the facade supplies them.
    private var reading: (level: Double, text: String) {
        switch source {
        case "PWR": return (min(meter.txPowerW / 100, 1), String(format: "%.1f W", meter.txPowerW))
        case "SWR": return (min(max(meter.swr - 1, 0) / 2, 1), String(format: "%.1f:1", meter.swr))
        case "PA Current": return (0, "— A")
        case "Temp": return (0, "— °C")
        default: return (meter.sMeterLevel, meter.sMeterText)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            VUNeedleArc(level: reading.level, peak: reading.level, dangerZone: 0.8,
                        label: source, valueText: reading.text, accentColor: LyraTheme.cyan,
                        width: 180, height: 99)

            Picker("Source", selection: $source) {
                ForEach(Self.sources, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            HStack(spacing: 16) {
                readout("S", meter.sMeterText)
                readout("SNR", String(format: "%.0f dB", meter.rxSnrDb))
                readout("NF", String(format: "%.0f dBm", meter.noiseFloorDbm))
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(LyraTheme.textPrimary)
            Text(label).font(.system(size: 9, weight: .medium)).tracking(1)
                .foregroundStyle(LyraTheme.textMuted)
        }
    }
}
