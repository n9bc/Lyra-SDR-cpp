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

/// Screen-only display choices (layout, audio terrain), persisted in `UserDefaults`.
@Observable @MainActor
final class DisplayStore {
    private enum Key {
        static let layout = "console.display.layout"
        static let terrainExpanded = "console.display.terrainExpanded"
        static let terrainView = "console.display.terrainView"
        static let terrainMix = "console.display.terrainMix"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var layout: DisplayLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    var terrainExpanded: Bool { didSet { defaults.set(terrainExpanded, forKey: Key.terrainExpanded) } }
    var terrainView: TerrainView { didSet { defaults.set(terrainView.rawValue, forKey: Key.terrainView) } }
    var terrainMix: Double {
        didSet {
            let clamped = Self.clampMix(terrainMix)
            if clamped != terrainMix { terrainMix = clamped; return }
            defaults.set(terrainMix, forKey: Key.terrainMix)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigned directly in init, so `didSet` does not write the loaded values back.
        layout = defaults.string(forKey: Key.layout).flatMap(DisplayLayout.init(rawValue:)) ?? .spectrumAndWaterfall
        terrainExpanded = defaults.object(forKey: Key.terrainExpanded) as? Bool ?? true
        terrainView = defaults.string(forKey: Key.terrainView).flatMap(TerrainView.init(rawValue:)) ?? .threeD
        terrainMix = Self.clampMix(defaults.object(forKey: Key.terrainMix) as? Double ?? 0.6)
    }

    nonisolated private static func clampMix(_ v: Double) -> Double { min(max(v, 0), 1) }
}
