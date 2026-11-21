import Foundation
import Observation

/// Owns the spectrum source and the dB display range shared by the renderer and UI.
@Observable @MainActor
final class SpectrumBridge {
    static let maxBins = 4096

    @ObservationIgnored let source: any SpectrumSource
    /// Display range in dB (the Qt panadapter's defaults).
    var dbFloor: Double = -130
    var dbCeiling: Double = -20

    init(source: any SpectrumSource) { self.source = source }

    /// Keeps the ceiling as given and pushes the floor down to preserve `minGap` dB.
    nonisolated static func constrained(floor: Double, ceiling: Double,
                                        minGap: Double = 10) -> (floor: Double, ceiling: Double) {
        ceiling - floor < minGap ? (ceiling - minGap, ceiling) : (floor, ceiling)
    }

    static func mock() -> SpectrumBridge { SpectrumBridge(source: SyntheticSpectrumSource()) }
}
