import SwiftUI

/// Display toolbar (mockup centre panel, top row): zoom, wheel step, peak hold and display toggles.
/// Actions are empty in Milestone 1; every selection renders from the snapshot (the engine owns
/// them), so nothing here can disagree with the rest of the console. Falls back to a compact
/// variant, then to horizontal scrolling, when the panel is narrow.
struct DisplayToolbarView: View {
    let display: DisplaySnapshot

    static let height: CGFloat = 36
    nonisolated static let zoomSteps = [1, 2, 4, 8, 16]
    nonisolated static let wheelOptions = ["50 Hz", "100 Hz", "500 Hz", "1 kHz"]
    nonisolated static let peakOptions = ["Off", "0.5 s", "2 s", "5 s"]

    init(display: DisplaySnapshot) {
        self.display = display
    }

    /// "500 Hz", "1 kHz", "2.5 kHz": the wheel step as the menu lists it.
    nonisolated static func wheelLabel(hz: Int) -> String {
        guard hz >= 1000 else { return "\(hz) Hz" }
        return String(format: "%g kHz", Double(hz) / 1000)
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
                Slider(value: .constant(display.zoom), in: 1...16)
                    .controlSize(.small).tint(LyraDS.Palette.cyan).frame(width: 90)
                    .accessibilityLabel("Fine zoom").accessibilityValue(String(format: "%.1f times", display.zoom))
                    .help("Fine zoom")
            }
            Text(String(format: "%.1f\u{00D7}", display.zoom))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(LyraDS.Palette.textPrimary)
                .frame(width: 34, alignment: .trailing)
            if !compact { label("Wheel") }
            ConsoleMenuChip(label: Self.wheelLabel(hz: display.wheelStepHz), help: "Wheel step",
                            options: Self.wheelOptions, selection: .constant(Self.wheelLabel(hz: display.wheelStepHz)))
            ConsoleChip(title: "Exact", help: "Exact tuning")
            if !compact { label("Peak") }
            ConsoleMenuChip(label: display.peakHold, help: "Peak hold", options: Self.peakOptions,
                            selection: .constant(display.peakHold))
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
