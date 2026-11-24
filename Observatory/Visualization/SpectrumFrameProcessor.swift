import Foundation

/// Reduces a dB trace to 0...1 column heights, one peak per column. Pure CPU, no Metal.
/// Smoothing and peak hold happen upstream in `SpectrumTraceProcessor`; this only maps to pixels.
struct SpectrumFrameProcessor {
    /// Trace column heights, 0...1.
    private(set) var heights: [Float] = []
    /// Peak-hold line column heights, 0...1.
    private(set) var peakHeights: [Float] = []

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
        peakHeights = [Float](repeating: 0, count: columns)
    }

    /// Peak-per-column reduction of the trace, normalised to the dB range. No allocation.
    nonisolated mutating func ingest(_ bins: UnsafeBufferPointer<Float>, floor: Float, ceiling: Float) {
        Self.reduce(bins, into: &heights, floor: floor, ceiling: ceiling)
    }

    /// Same reduction for the peak-hold trace.
    nonisolated mutating func ingestPeaks(_ bins: UnsafeBufferPointer<Float>, floor: Float, ceiling: Float) {
        Self.reduce(bins, into: &peakHeights, floor: floor, ceiling: ceiling)
    }

    nonisolated mutating func clearPeaks() {
        for i in peakHeights.indices { peakHeights[i] = 0 }
    }

    private nonisolated static func reduce(_ bins: UnsafeBufferPointer<Float>, into out: inout [Float],
                                           floor: Float, ceiling: Float) {
        let cols = out.count
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
                target = normalize(peak, floor: floor, ceiling: ceiling)
            }
            out[c] = target
        }
    }
}
