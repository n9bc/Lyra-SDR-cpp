import SwiftUI

/// Circular knob with a 270° glow ring, center value text and specular highlight.
/// Vertical drag changes the value; the value is always clamped to `range`.
struct GlowRingKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let accentColor: Color
    let format: (Double) -> String

    @State private var dragStartValue: Double?

    private let sweep = 0.75  // 270° of the circle
    private let size: CGFloat

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        label: String,
        accentColor: Color,
        size: CGFloat = 72,
        format: @escaping (Double) -> String
    ) {
        self._value = value
        self.range = range
        self.label = label
        self.accentColor = accentColor
        self.size = size
        self.format = format
    }

    /// Clamps `value` into `range`.
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Normalized 0...1 position of `value` within `range`.
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (clamp(value, to: range) - range.lowerBound) / span
    }

    private var fraction: Double { Self.fraction(value, in: range) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Track
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(LyraTheme.border, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Glow ring showing current position
                Circle()
                    .trim(from: 0, to: sweep * fraction)
                    .stroke(
                        AngularGradient(
                            colors: [accentColor.opacity(0.25), accentColor],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(270 * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .shadow(color: accentColor.opacity(0.6), radius: 6)
                // Knob body
                Circle()
                    .fill(LyraTheme.surface)
                    .overlay(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(LyraTheme.border, lineWidth: 0.5))
                    .padding(9)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                // Specular highlight
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .clear],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: size * 0.4, height: size * 0.16)
                    .offset(y: -size * 0.26)
                // Indicator dot
                Circle()
                    .fill(accentColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: accentColor, radius: 3)
                    .offset(y: -(size / 2 - 14))
                    .rotationEffect(.degrees(-135 + 270 * fraction))
                Text(format(Self.clamp(value, to: range)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LyraTheme.textPrimary)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStartValue ?? Self.clamp(value, to: range)
                        dragStartValue = start
                        let span = range.upperBound - range.lowerBound
                        // 150pt of vertical travel sweeps the whole range.
                        let delta = -Double(drag.translation.height) / 150 * span
                        value = Self.clamp(start + delta, to: range)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(LyraTheme.textMuted)
        }
    }
}
