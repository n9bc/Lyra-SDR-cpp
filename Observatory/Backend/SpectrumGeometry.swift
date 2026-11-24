import Foundation

/// Which edge of the span a Sub carrier lies beyond.
enum OffSpanCue: Equatable, Sendable { case left, right }

/// Pure frequency-axis maths for the spectrum overlays (engine reference: map §3 and §6.4).
/// Hz are `Int64`; callers convert the engine's `UInt32`/`Int` fields at the mapper boundary.
enum SpectrumGeometry {
    /// The DDC centre the Main span is drawn around: the CTUN centre when CTUN is on, else the
    /// dial, moved by RIT while it is on.
    nonisolated static func mainCentreHz(rx1Hz: Int64, ritEnabled: Bool, ritHz: Int64,
                                         ctuneEnabled: Bool, ctuneCentreHz: Int64) -> Int64 {
        ctuneEnabled ? ctuneCentreHz : rx1Hz + (ritEnabled ? ritHz : 0)
    }

    /// How far the dial sits from the DDC centre under CTUN (0 otherwise).
    nonisolated static func ctunDialOffsetHz(rx1Hz: Int64, ctuneEnabled: Bool,
                                             ctuneCentreHz: Int64) -> Int64 {
        ctuneEnabled ? rx1Hz - ctuneCentreHz : 0
    }

    /// The Main VFO line: the centre plus the engine's marker offset (the CW pitch) and the CTUN
    /// dial offset.
    nonisolated static func mainCarrierHz(centre: Int64, markerOffsetHz: Int64,
                                          ctunDialOffsetHz: Int64) -> Int64 {
        centre + markerOffsetHz + ctunDialOffsetHz
    }

    /// The passband in Hz. The engine's edges are signed offsets from the DDC centre, not from
    /// the dial; the CTUN dial offset moves them with the dial.
    nonisolated static func passband(centre: Int64, ctunDialOffsetHz: Int64, lowOffsetHz: Int64,
                                     highOffsetHz: Int64) -> ClosedRange<Int64> {
        let lo = centre + ctunDialOffsetHz + lowOffsetHz
        let hi = centre + ctunDialOffsetHz + highOffsetHz
        return min(lo, hi)...max(lo, hi)
    }

    /// The Sub carrier (RX2 has no CTUN or RIT of its own here).
    nonisolated static func subCarrierHz(rx2Hz: Int64, markerOffsetHzRx2: Int64) -> Int64 {
        rx2Hz + markerOffsetHzRx2
    }

    /// Which side of `lowHz...highHz` the frequency lies beyond, or nil when it is inside.
    nonisolated static func offSpanCue(hz: Int64, lowHz: Int64, highHz: Int64) -> OffSpanCue? {
        if hz < lowHz { return .left }
        if hz > highHz { return .right }
        return nil
    }
}
