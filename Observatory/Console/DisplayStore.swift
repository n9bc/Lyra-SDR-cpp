import Foundation
import Observation

/// Which of the display's two traces are shown. Screen-only state; the engine has no such concept.
enum DisplayLayout: String, CaseIterable, Sendable {
    case spectrumAndWaterfall, spectrumOnly, waterfallOnly

    var title: String {
        switch self {
        case .spectrumAndWaterfall: "Spectrum and Waterfall"
        case .spectrumOnly: "Spectrum Only"
        case .waterfallOnly: "Waterfall Only"
        }
    }
}

/// Screen-only display choices (layout, audio terrain shown and smoothed), persisted in `UserDefaults`.
/// The retired terrain view and mix keys are no longer read or written; any values a user already
/// stored under them are left alone.
@Observable @MainActor
final class DisplayStore {
    private enum Key {
        static let layout = "console.display.layout"
        static let terrainExpanded = "console.display.terrainExpanded"
        static let terrainSmoothing = "console.display.terrainSmoothing"
    }

    /// The Smooth control's default: the standard terrain shaping.
    nonisolated static let defaultTerrainSmoothing = 0.5

    @ObservationIgnored private let defaults: UserDefaults

    var layout: DisplayLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    var terrainExpanded: Bool { didSet { defaults.set(terrainExpanded, forKey: Key.terrainExpanded) } }
    /// The audio terrain's Smooth control, 0 (sharp) ... 1 (smooth); see `TerrainShaping.forSmoothing`.
    var terrainSmoothing: Double { didSet { defaults.set(terrainSmoothing, forKey: Key.terrainSmoothing) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigned directly in init, so `didSet` does not write the loaded values back.
        layout = defaults.string(forKey: Key.layout).flatMap(DisplayLayout.init(rawValue:)) ?? .spectrumAndWaterfall
        terrainExpanded = defaults.object(forKey: Key.terrainExpanded) as? Bool ?? true
        // A stored value that is missing, not a number, or outside 0...1 falls back to the default.
        let stored = (defaults.object(forKey: Key.terrainSmoothing) as? NSNumber)?.doubleValue
        terrainSmoothing = stored.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            ?? Self.defaultTerrainSmoothing
    }
}
