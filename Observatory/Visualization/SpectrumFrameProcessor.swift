import Foundation

/// Reduces a dB spectrum frame to smoothed 0...1 column heights. Pure CPU, no Metal.
struct SpectrumFrameProcessor {
    nonisolated static let attack: Float = 0.6
    nonisolated static let release: Float = 0.15

    /// Smoothed column heights, 0...1.
    private(set) var heights: [Float] = []

    nonisolated init() {}

    nonisolated static func columnCount(forDrawableWidth px: Int) -> Int {
        min(2048, max(64, px / 2))
    }

    nonisolated static func normalize(_ db: Float, floor: Float, ceiling: Float) -> Float {
        guard db.isFinite else { return 0 }
        let top = ceiling <= floor ? floor + 1 : ceiling
        return min(1, max(0, (db - floor) / (top - floor)))
    }

    /// Reallocates only when the column count changes.
    nonisolated mutating func resize(columns: Int) {
        guard columns != heights.count else { return }
        heights = [Float](repeating: 0, count: columns)
    }

    /// Peak-per-column reduction, normalise, then attack/release smoothing.
    /// Does not allocate; call `resize` first.
    nonisolated mutating func ingest(_ bins: UnsafeBufferPointer<Float>, floor: Float, ceiling: Float) {
        let cols = heights.count
        let n = bins.count
        for c in 0..<cols {
            var target: Float = 0
            if n > 0, let base = bins.baseAddress {
                let start = c * n / cols
                let end = max(start + 1, (c + 1) * n / cols)
                var peak = -Float.infinity
                var i = start
                while i < min(end, n) {
                    let v = base[i]
                    if v.isFinite && v > peak { peak = v }
                    i += 1
                }
                target = Self.normalize(peak, floor: floor, ceiling: ceiling)
            }
            let h = heights[c]
            heights[c] = h + (target - h) * (target > h ? Self.attack : Self.release)
        }
    }
}
