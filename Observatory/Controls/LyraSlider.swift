import AppKit
import SwiftUI

/// Neon slider (horizontal or vertical). Drag sets the value from the pointer position;
/// Option-drag is relative and ten times finer.
struct LyraSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let unit: String
    let accent: Color
    let axis: Axis
    let defaultValue: Double?
    let format: (Double) -> String

    @State private var dragStart: Double?

    private static let thickness: CGFloat = 22
    private static let trackWidth: CGFloat = 4
    private static let thumb: CGFloat = 14
    private static let length: CGFloat = 140

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double? = nil, unit: String = "", accent: Color = LyraDS.Palette.cyan,
         axis: Axis = .horizontal, defaultValue: Double? = nil,
         format: @escaping (Double) -> String = { String(format: "%.0f", $0) }) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.accent = accent
        self.axis = axis
        self.defaultValue = defaultValue
        self.format = format
    }

    private var fraction: Double { ControlMath.fraction(value, in: range) }
    private var readout: String { unit.isEmpty ? format(value) : "\(format(value)) \(unit)" }
    private var horizontal: Bool { axis == .horizontal }

    var body: some View {
        let content = Group {
            if horizontal {
                VStack(alignment: .leading, spacing: LyraDS.Space.xs) {
                    header
                    track
                        .frame(width: Self.length, height: Self.thickness)
                }
            } else {
                VStack(spacing: LyraDS.Space.xs) {
                    Text(readout)
                        .font(LyraDS.Font.frequency(size: 11))
                        .foregroundStyle(LyraDS.Palette.textPrimary)
                    track
                        .frame(width: Self.thickness, height: Self.length)
                    Text(label)
                        .font(LyraDS.Font.label(size: 10))
                        .foregroundStyle(LyraDS.Palette.textMuted)
                }
            }
        }
        content
            .focusable()
            .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                let up = press.key == .upArrow || press.key == .rightArrow
                let s = ControlMath.keyboardStep(in: range, step: step, coarse: press.modifiers.contains(.shift))
                value = ControlMath.clamp(value + (up ? s : -s), to: range)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(readout)
            .accessibilityAdjustableAction { direction in
                let s = ControlMath.keyboardStep(in: range, step: step, coarse: false)
                switch direction {
                case .increment: value = ControlMath.clamp(value + s, to: range)
                case .decrement: value = ControlMath.clamp(value - s, to: range)
                @unknown default: break
                }
            }
            .help("\(label): \(readout)")
    }

    private var header: some View {
        HStack {
            Text(label)
                .font(LyraDS.Font.label(size: 10))
                .foregroundStyle(LyraDS.Palette.textMuted)
            Spacer(minLength: LyraDS.Space.sm)
            Text(readout)
                .font(LyraDS.Font.frequency(size: 11))
                .foregroundStyle(LyraDS.Palette.textPrimary)
        }
        .frame(width: Self.length)
    }

    private var track: some View {
        GeometryReader { geo in
            let length = horizontal ? geo.size.width : geo.size.height
            let usable = max(length - Self.thumb, 1)
            let pos = Self.thumb / 2 + usable * fraction
            ZStack(alignment: horizontal ? .leading : .bottom) {
                Capsule()
                    .fill(LyraDS.Palette.surfaceElevated)
                    .overlay(Capsule().strokeBorder(LyraDS.Palette.border, lineWidth: 1))
                    .frame(width: horizontal ? nil : Self.trackWidth,
                           height: horizontal ? Self.trackWidth : nil)
                Capsule()
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.35), accent],
                        startPoint: horizontal ? .leading : .bottom,
                        endPoint: horizontal ? .trailing : .top))
                    .frame(width: horizontal ? pos : Self.trackWidth,
                           height: horizontal ? Self.trackWidth : pos)
                    .neonGlow(accent, radius: 6, active: fraction > 0)
                Circle()
                    .fill(accent)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .neonGlow(accent, radius: 8)
                    .offset(x: horizontal ? pos - Self.thumb / 2 : 0,
                            y: horizontal ? 0 : -(pos - Self.thumb / 2))
            }
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: horizontal ? .leading : .bottom)
            .contentShape(Rectangle())
            .gesture(drag(length: length, usable: usable))
            .onTapGesture(count: 2) {
                if let defaultValue {
                    withAnimation(LyraDS.Motion.standard) { value = ControlMath.clamp(defaultValue, to: range) }
                }
            }
            .overlay(ScrollWheelCapture { dy in
                value = ControlMath.dragAdjusted(value, deltaPoints: dy, in: range, step: step,
                                                 fine: NSEvent.modifierFlags.contains(.option))
            })
        }
    }

    private func drag(length: CGFloat, usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let start = dragStart ?? value
                dragStart = start
                if NSEvent.modifierFlags.contains(.option) {
                    let delta = horizontal ? g.translation.width : -g.translation.height
                    value = ControlMath.dragAdjusted(start, deltaPoints: Double(delta), in: range,
                                                     step: step, fine: true)
                } else {
                    let p = horizontal ? g.location.x : length - g.location.y
                    let f = Double((p - Self.thumb / 2) / usable)
                    value = ControlMath.value(atFraction: f, in: range, step: step)
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}

#Preview("Slider") {
    struct Demo: View {
        @State private var a = 30.0
        @State private var b = -10.0
        var body: some View {
            HStack(spacing: LyraDS.Space.xl) {
                LyraSlider("Volume", value: $a, in: 0...100, unit: "%", defaultValue: 50)
                LyraSlider("Ref level", value: $b, in: -40...0, step: 1, unit: "dB",
                           accent: LyraDS.Palette.purple, axis: .vertical)
            }
            .padding(LyraDS.Space.xl)
            .background(LyraDS.Palette.void)
        }
    }
    return Demo()
}
