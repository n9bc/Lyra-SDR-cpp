import SwiftUI

/// 180° VU meter: tick marks, danger-zone arc, animated needle and peak pip.
/// `level`, `peak` and `dangerZone` are 0...1.
struct VUNeedleArc: View {
    let level: Double
    let peak: Double
    let dangerZone: Double
    let label: String
    let valueText: String
    let accentColor: Color
    var width: CGFloat = 120
    var height: CGFloat = 66

    /// Needle/pip position that SwiftUI can interpolate between frames.
    private struct Positions: Equatable {
        var level: Double
        var peak: Double
    }

    var body: some View {
        VStack(spacing: 4) {
            VUCanvas(
                level: level, peak: peak, dangerZone: dangerZone, accentColor: accentColor
            )
            .frame(width: width, height: height)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: Positions(level: level, peak: peak))

            Text(valueText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LyraTheme.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(LyraTheme.textMuted)
        }
    }
}

private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

/// Angle in radians: 0 maps to the left end (π), 1 to the right end (0), through the top.
private func angle(_ v: Double) -> Double { Double.pi * (1 - clamp01(v)) }

/// Animatable canvas so the needle and peak pip spring between values.
private struct VUCanvas: View, Animatable {
    var level: Double
    var peak: Double
    let dangerZone: Double
    let accentColor: Color

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, peak) }
        set { level = newValue.first; peak = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let radius = min(size.width / 2, size.height) - 6
            let center = CGPoint(x: size.width / 2, y: size.height - 2)

            func point(_ v: Double, _ r: Double) -> CGPoint {
                let a = angle(v)
                return CGPoint(x: center.x + CGFloat(cos(a) * r), y: center.y - CGFloat(sin(a) * r))
            }
            func arc(from: Double, to: Double) -> Path {
                var p = Path()
                // SwiftUI angles run clockwise with y down; negating flips to the upper half.
                p.addArc(
                    center: center, radius: radius,
                    startAngle: .radians(-angle(from)), endAngle: .radians(-angle(to)),
                    clockwise: false)
                return p
            }

            let danger = clamp01(dangerZone)
            let lvl = clamp01(level)
            let stroke = StrokeStyle(lineWidth: 4, lineCap: .butt)
            ctx.stroke(arc(from: 0, to: danger), with: .color(LyraTheme.border), style: stroke)
            if lvl > 0 {
                ctx.stroke(
                    arc(from: 0, to: min(lvl, danger)), with: .color(accentColor.opacity(0.6)),
                    style: stroke)
            }
            ctx.stroke(arc(from: danger, to: 1), with: .color(LyraTheme.amber.opacity(0.5)), style: stroke)
            if lvl > danger {
                ctx.stroke(arc(from: danger, to: lvl), with: .color(.red.opacity(0.9)), style: stroke)
            }

            // Ticks
            for i in 0...10 {
                let v = Double(i) / 10
                var t = Path()
                t.move(to: point(v, radius - 7))
                t.addLine(to: point(v, radius - (i % 5 == 0 ? 14 : 11)))
                ctx.stroke(
                    t, with: .color(v >= danger ? Color.red.opacity(0.8) : LyraTheme.textMuted),
                    lineWidth: 1)
            }

            // Peak pip
            let pip = point(peak, radius + 1)
            ctx.fill(
                Path(ellipseIn: CGRect(x: pip.x - 2.5, y: pip.y - 2.5, width: 5, height: 5)),
                with: .color(clamp01(peak) >= danger ? .red : accentColor))

            // Needle
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: point(level, radius - 4))
            ctx.stroke(needle, with: .color(LyraTheme.textPrimary), lineWidth: 1.5)
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                with: .color(LyraTheme.textPrimary))
        }
    }
}
