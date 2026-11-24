import Foundation

/// dB to colour, as in the Qt waterfall: `t` clamps to 0...1 over the range and indexes a
/// 256-entry RGB table.
enum WaterfallColorMap {
    nonisolated static func index(db: Float, floor: Float, ceiling: Float) -> Int {
        let span = ceiling > floor ? Double(ceiling - floor) : 1.0
        let t = min(max((Double(db) - Double(floor)) / span, 0), 1)
        return t.isNaN ? 0 : Int(t * 255 + 0.5)
    }

    /// The custom ramp: black to `baseRGB` (0xRRGGBB) over t 0...0.65, then base toward white
    /// (x0.7) over 0.65...1. 768 bytes of RGB, truncated to integers like the C++ (`Waterfall::rebuildLut`).
    nonisolated static func customRamp(baseRGB: UInt32) -> [UInt8] {
        let base = [Double((baseRGB >> 16) & 0xFF), Double((baseRGB >> 8) & 0xFF), Double(baseRGB & 0xFF)]
        var out = [UInt8](repeating: 0, count: 768)
        for i in 0..<256 {
            let t = Double(i) / 255
            for c in 0..<3 {
                let v: Double
                if t <= 0.65 {
                    v = base[c] * (t / 0.65)
                } else {
                    v = base[c] + (255 - base[c]) * ((t - 0.65) / 0.35) * 0.7
                }
                out[i * 3 + c] = UInt8(min(max(Int(v), 0), 255))
            }
        }
        return out
    }

    /// The 768-byte table for a snapshot's colour setting.
    nonisolated static func table(for colors: WaterfallColors) -> [UInt8] {
        switch colors {
        case .lut(let bytes): bytes.count == 768 ? bytes : customRamp(baseRGB: 0x30B0FF)
        case .custom(let base): customRamp(baseRGB: base)
        }
    }
}
