import SwiftUI

struct FiltersPanel: LyraPanel {
    let id = "filters"
    let title = "Filters"
    let systemImage = "line.3.horizontal.decrease"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { FiltersPanelContent() }
}

private struct FiltersPanelContent: View {
    nonisolated init() {}

    @Environment(DspBridge.self) private var dsp

    private static let maxEdgeHz = 4000.0

    /// Preset bandwidths in Hz for the current mode.
    private var presets: [(label: String, hz: Int)] {
        switch dsp.mode {
        case "CW", "CWL", "CWU":
            return [("50", 50), ("100", 100), ("200", 200), ("500", 500), ("1k", 1000)]
        case "AM", "SAM":
            return [("6k", 6000), ("8k", 8000), ("10k", 10000)]
        default:
            return [("1.8k", 1800), ("2.4k", 2400), ("2.7k", 2700), ("3.0k", 3000), ("3.3k", 3300)]
        }
    }

    var body: some View {
        @Bindable var dsp = dsp
        VStack(alignment: .leading, spacing: 10) {
            passband
            HStack(spacing: 6) {
                ForEach(presets, id: \.hz) { preset in
                    BandChip(label: preset.label, isActive: dsp.bandwidth == preset.hz) {
                        apply(bandwidth: preset.hz)
                    }
                }
            }
            edgeSlider("Low", value: $dsp.passbandLowHz)
            edgeSlider("High", value: $dsp.passbandHighHz)
        }
        .onChange(of: dsp.passbandLowHz) { updateBandwidth() }
        .onChange(of: dsp.passbandHighHz) { updateBandwidth() }
    }

    private func apply(bandwidth hz: Int) {
        dsp.setBandwidth(hz)
        dsp.passbandHighHz = min(dsp.passbandLowHz + Double(hz), Self.maxEdgeHz)
    }

    private func updateBandwidth() {
        let width = Int((dsp.passbandHighHz - dsp.passbandLowHz).rounded())
        if width > 0, width != dsp.bandwidth { dsp.setBandwidth(width) }
    }

    private var passband: some View {
        GeometryReader { geo in
            let lo = max(0, min(dsp.passbandLowHz, Self.maxEdgeHz)) / Self.maxEdgeHz
            let hi = max(0, min(dsp.passbandHighHz, Self.maxEdgeHz)) / Self.maxEdgeHz
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(LyraTheme.surface)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LyraTheme.cyan.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LyraTheme.cyan, lineWidth: 1))
                    .frame(width: max(0, (hi - lo) * geo.size.width))
                    .offset(x: lo * geo.size.width)
            }
        }
        .frame(height: 24)
        .accessibilityLabel("Passband \(Int(dsp.passbandLowHz)) to \(Int(dsp.passbandHighHz)) hertz")
    }

    private func edgeSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 9, weight: .medium)).tracking(1)
                .foregroundStyle(LyraTheme.textMuted).frame(width: 32, alignment: .leading)
            Slider(value: value, in: 0...Self.maxEdgeHz)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LyraTheme.textPrimary).frame(width: 36, alignment: .trailing)
        }
    }
}
