import SwiftUI

/// Display toolbar (mockup centre panel, top row): zoom, wheel step, peak hold and display toggles.
/// Actions are empty in Milestone 1; the chips reflect the snapshot. Falls back to a compact
/// variant, then to horizontal scrolling, when the panel is narrow.
struct DisplayToolbarView: View {
    let display: DisplaySnapshot
    @State private var fineZoom: Double
    @State private var wheel: String
    @State private var peak: String

    static let height: CGFloat = 36
    nonisolated static let zoomSteps = [1, 2, 4, 8, 16]
    nonisolated static let wheelOptions = ["50 Hz", "100 Hz", "500 Hz", "1 kHz"]
    nonisolated static let peakOptions = ["Off", "0.5 s", "2 s", "5 s"]

    init(display: DisplaySnapshot) {
        self.display = display
        _fineZoom = State(initialValue: display.zoom)
        _wheel = State(initialValue: display.wheelStepHz >= 1000
                       ? "\(display.wheelStepHz / 1000) kHz" : "\(display.wheelStepHz) Hz")
        _peak = State(initialValue: display.peakHold)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if !compact { label("Zoom") }
            ForEach(Self.zoomSteps, id: \.self) { z in
                ConsoleChip(title: "\(z)\u{00D7}", help: "Zoom \(z) times",
                            kind: abs(display.zoom - Double(z)) < 0.01 ? .on : .plain)
            }
            if !compact {
                Slider(value: $fineZoom, in: 1...16)
                    .controlSize(.small).tint(LyraDS.Palette.cyan).frame(width: 90)
                    .accessibilityLabel("Fine zoom").accessibilityValue(String(format: "%.1f times", fineZoom))
                    .help("Fine zoom")
            }
            Text(String(format: "%.1f\u{00D7}", display.zoom))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(LyraDS.Palette.textPrimary)
                .frame(width: 34, alignment: .trailing)
            if !compact { label("Wheel") }
            ConsoleMenuChip(label: wheel, help: "Wheel step", options: Self.wheelOptions, selection: $wheel)
            ConsoleChip(title: "Exact", help: "Exact tuning")
            if !compact { label("Peak") }
            ConsoleMenuChip(label: peak, help: "Peak hold", options: Self.peakOptions, selection: $peak)
            ConsoleChip(title: "Avg", help: "Spectrum averaging", kind: display.averaging ? .on : .plain)
            ConsoleChip(title: "Spots", help: "Show spots")
            ConsoleChip(title: "Band plan", help: "Show band plan", kind: display.bandPlanVisible ? .on : .plain)
            Spacer(minLength: 6)
            ConsoleChip(title: "WF-ID", help: "Waterfall ID warning", kind: .warn)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { controls(compact: true) }
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) { Rectangle().fill(LyraDS.Palette.border).frame(height: 1) }
    }
}
