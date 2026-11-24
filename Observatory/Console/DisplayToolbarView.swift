import SwiftUI

/// Display toolbar (mockup centre panel, top row): zoom, wheel step, peak hold and display toggles.
/// Every control is gated on `.displaySettings` (Spots on the spots feature) and sends a command;
/// every selection renders from the snapshot (the engine owns them), so nothing here can
/// disagree with the rest of the console. Falls back to a compact variant, then
/// to horizontal scrolling, when the panel is narrow.
struct DisplayToolbarView: View {
    let display: DisplaySnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void

    static let height: CGFloat = 36
    nonisolated static let zoomSteps = [1, 2, 4, 8, 16]
    nonisolated static let wheelOptions = ["50 Hz", "100 Hz", "500 Hz", "1 kHz"]
    nonisolated static let peakOptions = ["Off", "Hold", "Live", "0.5 s", "2 s", "5 s"]

    /// The chip's text for the engine's peak-hold setting.
    nonisolated static func peakLabel(_ p: PeakHoldSetting) -> String {
        switch p {
        case .off: "Off"
        case .hold: "Hold"
        case .live: "Live"
        case .seconds(let s): String(format: "%g s", s)
        }
    }

    init(display: DisplaySnapshot, capabilities: BackendCapabilities,
         send: @escaping (RadioCommand) -> Void = { _ in }) {
        self.display = display
        self.capabilities = capabilities
        self.send = send
    }

    enum Toggle { case exact, averaging, spots, bandPlan }

    /// What the toolbar's chips show, read from the snapshot alone.
    struct ChipState: Equatable {
        var wheel: String
        var peak: String
        var exact: Bool
        var averaging: Bool
        var spots: Bool
        var bandPlan: Bool
    }

    nonisolated static func chipState(for d: DisplaySnapshot) -> ChipState {
        ChipState(wheel: wheelLabel(hz: d.wheelStepHz), peak: peakLabel(d.peakHold), exact: d.exactTuning,
                  averaging: d.averaging, spots: d.spotsVisible, bandPlan: d.bandPlanVisible)
    }

    /// The command a toggle chip sends: the opposite of what the snapshot shows.
    nonisolated static func toggleCommand(_ toggle: Toggle, display d: DisplaySnapshot) -> RadioCommand {
        switch toggle {
        case .exact: .setExactTuning(!d.exactTuning)
        case .averaging: .setAveraging(!d.averaging)
        case .spots: .setSpotsVisible(!d.spotsVisible)
        case .bandPlan: .setBandPlanVisible(!d.bandPlanVisible)
        }
    }

    /// The peak-hold setting a menu option stands for.
    nonisolated static func peakSetting(option: String) -> PeakHoldSetting? {
        switch option {
        case "Off": .off
        case "Hold": .hold
        case "Live": .live
        case "0.5 s": .seconds(0.5)
        case "2 s": .seconds(2)
        case "5 s": .seconds(5)
        default: nil
        }
    }

    /// The wheel step in Hz a menu option stands for.
    nonisolated static func wheelHz(option: String) -> Int? {
        switch option {
        case "50 Hz": 50
        case "100 Hz": 100
        case "500 Hz": 500
        case "1 kHz": 1000
        default: nil
        }
    }

    /// "500 Hz", "1 kHz", "2.5 kHz": the wheel step as the menu lists it.
    nonisolated static func wheelLabel(hz: Int) -> String {
        guard hz >= 1000 else { return "\(hz) Hz" }
        return String(format: "%g kHz", Double(hz) / 1000)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
    }

    /// A menu's selection reads from the snapshot; choosing an option only sends a command.
    private func menuBinding(_ current: String, _ choose: @escaping (String) -> RadioCommand?) -> Binding<String> {
        Binding(get: { current }, set: { option in if let c = choose(option) { send(c) } })
    }

    private func toggleChip(_ title: String, _ help: String, _ toggle: Toggle, on: Bool,
                            status: CapabilityStatus) -> some View {
        ConsoleChip(title: title, help: help, kind: on ? .on : .plain, status: status) {
            send(Self.toggleCommand(toggle, display: display))
        }
    }

    private func controls(compact: Bool) -> some View {
        let status = capabilities.control(.displaySettings)
        let chips = Self.chipState(for: display)
        return HStack(spacing: 6) {
            if !compact { label("Zoom") }
            ForEach(Self.zoomSteps, id: \.self) { z in
                ConsoleChip(title: "\(z)\u{00D7}", help: "Zoom \(z) times",
                            kind: abs(display.zoom - Double(z)) < 0.01 ? .on : .plain, status: status) {
                    send(.setZoom(Double(z)))
                }
            }
            if !compact {
                Slider(value: Binding(get: { display.zoom }, set: { send(.setZoom($0)) }), in: 1...16)
                    .controlSize(.small).tint(LyraDS.Palette.cyan).frame(width: 90)
                    .accessibilityLabel("Fine zoom").accessibilityValue(String(format: "%.1f times", display.zoom))
                    .consoleAvailability(status, help: "Fine zoom")
            }
            Text(String(format: "%.1f\u{00D7}", display.zoom))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(LyraDS.Palette.textPrimary)
                .frame(width: 34, alignment: .trailing)
            if !compact { label("Wheel") }
            ConsoleMenuChip(label: chips.wheel, help: "Wheel step", options: Self.wheelOptions,
                            selection: menuBinding(chips.wheel) { Self.wheelHz(option: $0).map { .setWheelStep($0) } },
                            status: status)
            toggleChip("Exact", "Exact tuning", .exact, on: chips.exact, status: status)
            if !compact { label("Peak") }
            ConsoleMenuChip(label: chips.peak, help: "Peak hold", options: Self.peakOptions,
                            selection: menuBinding(chips.peak) { Self.peakSetting(option: $0).map { .setPeakHold($0) } },
                            status: status)
            toggleChip("Avg", "Spectrum averaging", .averaging, on: chips.averaging, status: status)
            // Spots follow the engine's setting; the feature gate says whether spots exist at all.
            toggleChip("Spots", "Show spots", .spots, on: chips.spots, status: capabilities.status(.spots))
            toggleChip("Band plan", "Show band plan", .bandPlan, on: chips.bandPlan, status: status)
            Spacer(minLength: 6)
            // No snapshot field reports a waterfall ID yet, so the chip stays neutral and off.
            ConsoleChip(title: "WF-ID", help: "Waterfall ID",
                        status: .unavailable("Waterfall ID arrives in a later milestone"))
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
