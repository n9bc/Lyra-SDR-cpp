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

    static func mock() -> SpectrumBridge { SpectrumBridge(source: SyntheticSpectrumSource()) }
}
