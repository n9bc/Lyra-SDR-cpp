import Foundation

/// Pure value math shared by the neon controls (dial, slider, ...). No UI dependencies.
nonisolated enum ControlMath {
    /// Points of drag that sweep the full range; `fine` (Option held) is 10x slower.
    static let dragPointsPerRange: Double = 200
    static let fineDragPointsPerRange: Double = 2000

    static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }

    /// Position of `v` within `r` as 0...1; 0 when the range is degenerate.
    static func fraction(_ v: Double, in r: ClosedRange<Double>) -> Double {
        let span = r.upperBound - r.lowerBound
        guard span > 0 else { return 0 }
        return clamp((v - r.lowerBound) / span, to: 0...1)
    }

    /// Value at fraction `f` (clamped to 0...1), snapped to `step` measured from the lower bound.
    static func value(atFraction f: Double, in r: ClosedRange<Double>, step: Double?) -> Double {
        let span = r.upperBound - r.lowerBound
        let raw = r.lowerBound + min(max(f, 0), 1) * span
        return snap(raw, in: r, step: step)
    }

    /// Fine = one `step` (or 1% of the span); coarse = 10% of the span, never less than `step`.
    static func keyboardStep(in r: ClosedRange<Double>, step: Double?, coarse: Bool) -> Double {
        let span = r.upperBound - r.lowerBound
        return coarse ? max(step ?? 0, span * 0.10) : (step ?? span * 0.01)
    }

    /// Applies a drag of `deltaPoints` (up/right positive) to `v`.
    static func dragAdjusted(_ v: Double, deltaPoints: Double, in r: ClosedRange<Double>,
                             step: Double?, fine: Bool) -> Double {
        let span = r.upperBound - r.lowerBound
        let perRange = fine ? fineDragPointsPerRange : dragPointsPerRange
        return snap(v + deltaPoints / perRange * span, in: r, step: step)
    }

    private static func snap(_ raw: Double, in r: ClosedRange<Double>, step: Double?) -> Double {
        guard let step, step > 0 else { return clamp(raw, to: r) }
        let snapped = r.lowerBound + ((raw - r.lowerBound) / step).rounded() * step
        return clamp(snapped, to: r)
    }
}
