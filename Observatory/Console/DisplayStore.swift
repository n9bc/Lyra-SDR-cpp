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

/// Screen-only display choices (layout, audio terrain shown), persisted in `UserDefaults`.
/// The retired terrain view and mix keys are no longer read or written; any values a user already
/// stored under them are left alone.
@Observable @MainActor
final class DisplayStore {
    private enum Key {
        static let layout = "console.display.layout"
        static let terrainExpanded = "console.display.terrainExpanded"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var layout: DisplayLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    var terrainExpanded: Bool { didSet { defaults.set(terrainExpanded, forKey: Key.terrainExpanded) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigned directly in init, so `didSet` does not write the loaded values back.
        layout = defaults.string(forKey: Key.layout).flatMap(DisplayLayout.init(rawValue:)) ?? .spectrumAndWaterfall
        terrainExpanded = defaults.object(forKey: Key.terrainExpanded) as? Bool ?? true
    }
}
