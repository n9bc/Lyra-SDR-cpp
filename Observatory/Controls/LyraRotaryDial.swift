import AppKit
import SwiftUI

/// Neon rotary dial: vertical drag, scroll wheel, arrow keys, double-click to reset.
struct LyraRotaryDial: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let unit: String
    let accent: Color
    let defaultValue: Double?
    let format: (Double) -> String

    @State private var dragStart: Double?

    private static let diameter: CGFloat = 64
    nonisolated private static let sweep: Double = 270
    private static let tickCount = 11

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double? = nil, unit: String = "", accent: Color = LyraDS.Palette.cyan,
         defaultValue: Double? = nil,
         format: @escaping (Double) -> String = { String(format: "%.0f", $0) }) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.accent = accent
        self.defaultValue = defaultValue
        self.format = format
    }

    /// Indicator angle in degrees from 12 o'clock: -135 at min, +135 at max.
    nonisolated static func angle(for v: Double, in r: ClosedRange<Double>) -> Double {
        (ControlMath.fraction(v, in: r) - 0.5) * sweep
    }

    private var fraction: Double { ControlMath.fraction(value, in: range) }
    private var readout: String { ControlMath.readout(value, unit: unit, format: format) }

    var body: some View {
        VStack(spacing: LyraDS.Space.xs) {
            ZStack {
                Circle().fill(LyraDS.Palette.surfaceElevated)
                Circle().strokeBorder(LyraDS.Palette.border, lineWidth: 1)
                ticks
                // Arcs start at the 3 o'clock origin; rotate so 0 lands at -135 degrees.
                Circle()
                    .trim(from: 0, to: Self.sweep / 360)
                    .stroke(LyraDS.Palette.textDim.opacity(0.5),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(10)
                Circle()
                    .trim(from: 0, to: Self.sweep / 360 * fraction)
                    .stroke(AngularGradient(
                                gradient: Gradient(colors: [accent.opacity(0.35), accent]),
                                center: .center, startAngle: .degrees(0),
                                endAngle: .degrees(Self.sweep)),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(10)
                    .neonGlow(accent, radius: 6, active: fraction > 0)
                indicator
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())

            Text(readout)
                .font(LyraDS.Font.frequency(size: 11))
                .foregroundStyle(LyraDS.Palette.textPrimary)
            Text(label)
                .font(LyraDS.Font.label(size: 10))
                .foregroundStyle(LyraDS.Palette.textMuted)
        }
        .gesture(dragGesture)
        .modifier(LyraValueControl(label: label, value: $value, range: range, step: step,
                                   defaultValue: defaultValue, readout: readout))
    }

    private var ticks: some View {
        ForEach(0..<Self.tickCount, id: \.self) { i in
            let t = Double(i) / Double(Self.tickCount - 1)
            let lit = t <= fraction + 1e-9
            Capsule()
                .fill(lit ? accent : LyraDS.Palette.textDim)
                .frame(width: 2, height: 4)
                .offset(y: -(Self.diameter / 2 - 4))
                .rotationEffect(.degrees((t - 0.5) * Self.sweep))
        }
    }

    private var indicator: some View {
        let a = Self.angle(for: value, in: range) * .pi / 180
        let r = Double(Self.diameter) / 2 - 10
        return Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
            .neonGlow(accent, radius: 6)
            .offset(x: r * sin(a), y: -r * cos(a))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let start = dragStart ?? value
                dragStart = start
                let fine = NSEvent.modifierFlags.contains(.option)
                value = ControlMath.dragAdjusted(start, deltaPoints: -g.translation.height,
                                                 in: range, step: step, fine: fine)
            }
            .onEnded { _ in dragStart = nil }
    }
}

#Preview("Rotary dial") {
    struct Demo: View {
        @State private var a = 40.0
        @State private var b = -20.0
        var body: some View {
            HStack(spacing: LyraDS.Space.xl) {
                LyraRotaryDial("AF Gain", value: $a, in: 0...100, unit: "%", defaultValue: 50)
                LyraRotaryDial("Squelch", value: $b, in: -60...0, step: 1, unit: "dB",
                               accent: LyraDS.Palette.magenta)
            }
            .padding(LyraDS.Space.xl)
            .background(LyraDS.Palette.void)
        }
    }
    return Demo()
}
