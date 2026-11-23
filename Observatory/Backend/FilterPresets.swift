import Foundation

/// One row of the filter preset list: a width, its label and whether it is the leading
/// "custom" entry for a width that is not a preset.
struct FilterPresetEntry: Equatable, Sendable {
    let hz: Int
    let label: String
    let isCustom: Bool

    /// Short title for a narrow chip: the label, starred when it is a custom width.
    nonisolated var chipTitle: String {
        isCustom ? FilterPresets.label(hz) + "*" : label
    }

    /// The chip's tooltip and accessibility label.
    nonisolated var chipHelp: String {
        guard isCustom else { return "Filter \(label)" }
        let width = FilterPresets.label(hz)
        return "Custom width \(hz >= 1000 ? width + "Hz" : width)"
    }
}

/// The engine's per-mode filter bandwidth presets (`src/qml/FilterPresets.js`), so the console
/// offers the same widths as the QML UI.
enum FilterPresets {
    private nonisolated static let ssb = [1500, 1800, 2100, 2400, 2700, 3000, 3600, 4000, 6000, 8000, 10000]
    private nonisolated static let cw = [50, 100, 150, 250, 400, 500, 750, 1000]
    private nonisolated static let dsb = [3000, 4000, 5000, 6000, 8000, 10000]
    private nonisolated static let am = [3000, 4000, 6000, 8000, 10000, 12000, 16000, 20000]
    /// FM channel widths the IF must pass, not SSB widths.
    private nonisolated static let fm = [8000, 10000, 12000, 16000]
    private nonisolated static let dig = [1500, 2400, 3000, 3600, 4000, 6000]

    nonisolated static func presets(for mode: RadioMode) -> [Int] {
        switch mode {
        case .lsb, .usb: ssb
        case .cwl, .cwu: cw
        case .dsb: dsb
        case .am, .sam: am
        case .fm: fm
        case .digl, .digu: dig
        }
    }

    /// "2.7 k", "3 k", "500 Hz". Mirrors the JS `toFixed(1)`: one decimal, halves round up.
    nonisolated static func label(_ hz: Int) -> String {
        guard hz >= 1000 else { return "\(hz) Hz" }
        if hz % 1000 == 0 { return "\(hz / 1000) k" }
        let tenths = (hz + 50) / 100
        return "\(tenths / 10).\(tenths % 10) k"
    }

    /// The presets for `mode`, led by a custom entry when `currentHz` is not one of them.
    nonisolated static func entries(mode: RadioMode, currentHz: Int) -> [FilterPresetEntry] {
        let list = presets(for: mode).map { FilterPresetEntry(hz: $0, label: label($0), isCustom: false) }
        guard !list.contains(where: { $0.hz == currentHz }) else { return list }
        return [FilterPresetEntry(hz: currentHz, label: label(currentHz) + " (custom)", isCustom: true)] + list
    }
}
