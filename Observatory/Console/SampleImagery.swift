import CoreGraphics
import AppKit
import Foundation
import SwiftUI

/// Deterministic sample imagery for the static console (no system random generator).
/// Ported from the approved mockup's generating script.
enum SampleImagery {
    /// The mockup's sin-hash: stable pseudo-random value in 0..<1.
    nonisolated static func rnd(_ a: Double) -> Double {
        let s = sin(a * 12.9898) * 43758.5453
        return s - s.rounded(.down)
    }

    /// Baseline y of terrain row `row` of `rows` (row 0 = back).
    nonisolated static func ridgeBase(row: Int, rows: Int, height: CGFloat) -> CGFloat {
        let t = rows > 1 ? Double(row) / Double(rows - 1) : 1
        return 30 + CGFloat(pow(t, 1.2) * 0.79) * height
    }

    /// Amplitude scale for a row (front rows are taller).
    nonisolated static func ridgeAmpScale(row: Int, rows: Int) -> CGFloat {
        let t = rows > 1 ? Double(row) / Double(rows - 1) : 1
        return CGFloat(0.40 + 0.60 * t)
    }

    /// Voice-like audio terrain: `rows` ridges of `points` points each, row 0 = back.
    /// Amplitude scales with `size`: the tallest peak is at most 0.5 * height * ampScale.
    /// Every x is clamped into 0...width and every y into 0...height.
    nonisolated static func terrainRidges(rows: Int, points: Int, size: CGSize) -> [[CGPoint]] {
        guard rows > 0, points > 1 else { return [] }
        var out: [[CGPoint]] = []
        out.reserveCapacity(rows)
        for i in 0..<rows {
            let t = rows > 1 ? Double(i) / Double(rows - 1) : 1
            let base = Double(ridgeBase(row: i, rows: rows, height: size.height))
            let ws = 0.70 + 0.30 * t
            let amp = Double(ridgeAmpScale(row: i, rows: rows))
            let f0 = 128 + 26 * sin(Double(i) * 0.41)
            var syl = pow(abs(sin(Double(i) * 0.52 + 0.4)), 0.6)
            if i % 11 == 7 { syl *= 0.15 }
            var ridge: [CGPoint] = []
            ridge.reserveCapacity(points)
            for q in 0..<points {
                let u = Double(q) / Double(points - 1)
                let hz = u * 3000
                var a = 0.03 + 0.05 * rnd(Double(i) * 577 + Double(q) * 3.7)
                let env = exp(-pow((hz - 520) / 320, 2))
                    + 0.65 * exp(-pow((hz - 1500) / 420, 2))
                    + 0.3 * exp(-pow((hz - 2450) / 300, 2))
                var harm = 0.0
                for h in 1...22 {
                    let dd = (hz - Double(h) * f0) / 32
                    if abs(dd) < 3 { harm += exp(-dd * dd / 2) }
                }
                let gate = hz < 120 || hz > 2850 ? 0.1 : 1.0
                a += syl * env * harm * gate * (0.75 + 0.25 * rnd(Double(i) * 13 + Double(q)))
                let peak = min(a, 1.1) / 1.1 * 0.5 * Double(size.height) * amp
                let x = Double(size.width) / 2 + (u - 0.5) * Double(size.width) * ws
                let y = base - peak
                ridge.append(CGPoint(
                    x: min(max(x, 0), Double(size.width)),
                    y: min(max(y, 0), Double(size.height))))
            }
            out.append(ridge)
        }
        return out
    }

    // MARK: Waterfall

    private struct RGB { var r: Float; var g: Float; var b: Float }

    nonisolated private static func rgb(_ color: Color) -> RGB {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGB(r: Float(c.redComponent), g: Float(c.greenComponent), b: Float(c.blueComponent))
    }

    nonisolated private static func stopColor(_ t: Float) -> RGB {
        let c = LyraDS.Palette.sample(LyraDS.Palette.spectrumStops, at: t)
        return RGB(r: c.x, g: c.y, b: c.z)
    }

    /// Sample waterfall: a dark blue grid ground with one signal trace per entry of `signals`.
    /// Deterministic; RGBA8, opaque.
    /// `traceWidthHz` is the width of each signal trace (5 kHz suits the RF display, about 70 Hz the 0-3 kHz audio axis).
    nonisolated static func waterfall(width: Int, height: Int, axis: FrequencyAxis, signals: [Int64],
                                      traceWidthHz: Int64 = 5_000) -> CGImage {
        let w = max(width, 1), h = max(height, 1)
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        let blue = stopColor(0.0), cyan = stopColor(0.3), purple = stopColor(0.55)
        let ground = rgb(LyraDS.Palette.waterfallGround)
        let core = rgb(LyraDS.Palette.freqGlow), shade = rgb(LyraDS.Palette.void)

        struct Trace { var x0: Int; var x1: Int; var kind: Int; var op: Float }
        let traces: [Trace] = signals.enumerated().compactMap { idx, hz in
            guard axis.contains(hz) else { return nil }
            let r = rnd(Double(hz) / 1000 + Double(idx))
            let kind = r < 0.15 ? 0 : (r < 0.5 ? 1 : 2)
            let amp = Float(0.3 + 0.6 * rnd(Double(hz) / 777))
            let px = max(3, Int((Double(traceWidthHz) / Double(max(axis.highHz - axis.lowHz, 1)) * Double(axis.width)).rounded()))
            let cx = Int(axis.x(for: hz).rounded())
            return Trace(x0: cx - px / 2, x1: cx + px / 2, kind: kind, op: 0.45 + amp * 0.55)
        }

        for y in 0..<h {
            for x in 0..<w {
                var c = ground
                // Vertical grid texture, then scanlines.
                let col = x % 9
                let gridA: Float = col == 0 ? 0.16 : (col >= 4 && col < 5 ? 0.07 : 0)
                if gridA > 0 { c = mix(c, blue, gridA) }
                for tr in traces where x >= tr.x0 && x < tr.x1 {
                    let (color, a) = traceSample(kind: tr.kind, x: x, x0: tr.x0, x1: tr.x1, y: y,
                                                 cyan: cyan, purple: purple, blue: blue, core: core)
                    if a > 0 { c = mix(c, color, a * tr.op) }
                }
                if y % 3 == 0 { c = mix(c, shade, 0.28) }
                let o = (y * w + x) * 4
                buf[o] = byte(c.r); buf[o + 1] = byte(c.g); buf[o + 2] = byte(c.b)
            }
        }

        let provider = CGDataProvider(data: Data(buf) as CFData)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    nonisolated private static func traceSample(
        kind: Int, x: Int, x0: Int, x1: Int, y: Int, cyan: RGB, purple: RGB, blue: RGB, core: RGB
    ) -> (RGB, Float) {
        switch kind {
        case 0: // narrow carrier: soft horizontal edges, bright core
            let u = Float(x - x0) / Float(max(x1 - x0 - 1, 1))
            let edge = min(u, 1 - u)
            let a: Float = edge < 0.4 ? edge / 0.4 : 1
            return (mix(cyan, core, 0.5), a)
        case 1: // keyed bursts: 9 on, 6 dim
            let p = y % 15
            return (cyan, p < 9 ? 1 : 0.15)
        default: // voice: banded syllables, period 34
            let p = y % 34
            switch p {
            case 0..<5: return (cyan, 0.95)
            case 5..<9: return (purple, 0.55)
            case 9..<17: return (cyan, 0.7)
            case 23..<29: return (blue, 0.6)
            default: return (cyan, 0)
            }
        }
    }

    nonisolated private static func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    nonisolated private static func byte(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 1) * 255 + 0.5)
    }
}
