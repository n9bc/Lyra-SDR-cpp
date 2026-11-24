import Foundation

/// Auto-fit dB range for the panadapter: a port of `src/autoscale.h` (`lyra::ui::AutoScaler`).
///
/// The floor sits 15 dB below the noise floor (the 20th percentile of the dB values), the
/// ceiling 15 dB above a slowly decaying peak hold, and the span never falls under 50 dB. The
/// applied range is EWMA-smoothed. Feed it at about 5 Hz (the caller gates on 200 ms).
struct AutoRange {
    nonisolated static let noiseHeadroomDb = 15.0
    nonisolated static let peakHeadroomDb = 15.0
    nonisolated static let minSpanDb = 50.0
    /// Peak fall per feed (about 1.25 dB/s at 5 Hz).
    nonisolated static let peakDecayDb = 0.25
    /// EWMA weight per feed.
    nonisolated static let alpha = 0.10
    /// Minimum interval between feeds, owned by the caller.
    nonisolated static let feedInterval: TimeInterval = 0.2

    private(set) var floor: Double = -130
    private(set) var ceiling: Double = -20
    private var peakHold: Double = -200
    private var seeded = false
    /// Reused between feeds; only reallocates when the bin count grows.
    private var scratch: [Float] = []

    nonisolated init() {}

    nonisolated mutating func reset() {
        seeded = false
        peakHold = -200
    }

    nonisolated mutating func feed(_ spec: UnsafeBufferPointer<Float>) {
        let n = spec.count
        guard let base = spec.baseAddress, n >= 4 else { return }
        if scratch.count != n { scratch = [Float](repeating: 0, count: n) }

        var pk = -Double.infinity
        scratch.withUnsafeMutableBufferPointer { s in
            for i in 0..<n {
                let v = base[i].isFinite ? base[i] : -200
                s[i] = v
                pk = max(pk, Double(v))
            }
        }
        // 20th percentile via quickselect (the C++ uses nth_element).
        let k = min(max(Int(Double(n) * 0.20), 1), n - 1)
        let nf = Double(scratch.withUnsafeMutableBufferPointer { Self.select($0, k: k) })

        if pk >= peakHold {
            peakHold = pk
        } else {
            peakHold = max(pk, peakHold - Self.peakDecayDb)
        }

        let tFloor = nf - Self.noiseHeadroomDb
        var tCeil = peakHold + Self.peakHeadroomDb
        if tCeil - tFloor < Self.minSpanDb { tCeil = tFloor + Self.minSpanDb }

        if !seeded {
            floor = tFloor
            ceiling = tCeil
            seeded = true
        } else {
            floor += Self.alpha * (tFloor - floor)
            ceiling += Self.alpha * (tCeil - ceiling)
        }
    }

    /// The k-th smallest value (0-based), partially reordering `a`. Allocation-free.
    private nonisolated static func select(_ a: UnsafeMutableBufferPointer<Float>, k: Int) -> Float {
        var lo = 0, hi = a.count - 1
        while lo < hi {
            // Median of three keeps sorted and flat inputs from degrading to O(n^2).
            let mid = lo + (hi - lo) / 2
            if a[mid] < a[lo] { a.swapAt(mid, lo) }
            if a[hi] < a[lo] { a.swapAt(hi, lo) }
            if a[hi] < a[mid] { a.swapAt(hi, mid) }
            let pivot = a[mid]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return a[k]
    }
}
