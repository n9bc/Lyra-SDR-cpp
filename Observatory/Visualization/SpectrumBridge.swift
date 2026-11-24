import Foundation
import Observation

/// One receiver's spectrum view state, shared by its renderer and its dB grid: which receiver
/// to draw, the pump that supplies frames, and the display settings from the snapshot.
@Observable @MainActor
final class SpectrumBridge {
    static let maxBins = 4096

    /// Shared by both stacks; the pump de-duplicates their pulls.
    @ObservationIgnored let pump: SpectrumPump
    @ObservationIgnored let receiver: ReceiverID
    /// Whether the Sub stack is on screen, so the pump pulls the Sub streams.
    @ObservationIgnored var pullsSub = false

    /// dB range being drawn. Follows `dbRange` unless it is auto, in which case the renderer
    /// publishes the auto-fit range here so the grid labels match the trace.
    var dbFloor: Double = -130
    var dbCeiling: Double = -20
    /// The snapshot's settings, applied by `apply(_:)`; defaults match the Qt panadapter.
    @ObservationIgnored private(set) var dbRange = DbRange(floor: -130, ceiling: -20, auto: false)
    @ObservationIgnored private(set) var peakHold: PeakHoldSetting = .off
    @ObservationIgnored private(set) var peakDecayDbps = 10.0
    @ObservationIgnored private(set) var smoothing = 0

    init(pump: SpectrumPump, receiver: ReceiverID = .main) {
        self.pump = pump
        self.receiver = receiver
    }

    convenience init(source: any SpectrumSource, receiver: ReceiverID = .main) {
        self.init(pump: SpectrumPump(source: source), receiver: receiver)
    }

    /// Takes the engine-owned display settings from the snapshot.
    func apply(_ display: DisplaySnapshot) {
        dbRange = display.dbRange
        peakHold = display.peakHold
        peakDecayDbps = display.peakDecayDbps
        smoothing = display.smoothing
        if !display.dbRange.auto {
            let r = Self.constrained(floor: display.dbRange.floor, ceiling: display.dbRange.ceiling)
            if dbFloor != r.floor { dbFloor = r.floor }
            if dbCeiling != r.ceiling { dbCeiling = r.ceiling }
        }
    }

    /// Publishes the auto-fit range for the grid, only when it moved enough to matter.
    func publishAutoRange(floor: Double, ceiling: Double) {
        guard abs(floor - dbFloor) >= 0.25 || abs(ceiling - dbCeiling) >= 0.25 else { return }
        dbFloor = floor
        dbCeiling = ceiling
    }

    /// Keeps the ceiling as given and pushes the floor down to preserve `minGap` dB.
    nonisolated static func constrained(floor: Double, ceiling: Double,
                                        minGap: Double = 10) -> (floor: Double, ceiling: Double) {
        ceiling - floor < minGap ? (ceiling - minGap, ceiling) : (floor, ceiling)
    }

    static func mock(receiver: ReceiverID = .main) -> SpectrumBridge {
        SpectrumBridge(source: SyntheticSpectrumSource(), receiver: receiver)
    }
}
