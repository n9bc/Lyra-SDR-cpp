import AppKit
import SwiftUI

/// Nine-digit neon frequency readout (`DDD.DDD.DDD` Hz). Leading zeros are dimmed; with an
/// `onChange` handler, scrolling over a digit tunes by that digit's place value.
struct LyraFrequencyDisplay: View {
    let hz: UInt32
    let onChange: ((UInt32) -> Void)?
    let size: CGFloat

    @State private var hovered: Int?
    @State private var scrollRemainder = 0.0

    nonisolated static let maxHz: UInt32 = 500_000_000
    private static let scrollPointsPerStep = 8.0

    init(hz: UInt32, onChange: ((UInt32) -> Void)? = nil, size: CGFloat = 44) {
        self.hz = hz
        self.onChange = onChange
        self.size = size
    }

    /// Exactly nine decimal digits, most significant first; values above 999,999,999 clamp to all 9s.
    nonisolated static func digits(_ hz: UInt32) -> [Int] {
        var v = min(UInt64(hz), 999_999_999)
        var out = [Int](repeating: 0, count: 9)
        for i in stride(from: 8, through: 0, by: -1) {
            out[i] = Int(v % 10)
            v /= 10
        }
        return out
    }

    /// Adds `delta` units of 10^place Hz (place 0 = 1 Hz ... 8 = 100 MHz), clamped to `0...maxHz`.
    nonisolated static func adjusted(_ hz: UInt32, place: Int, delta: Int) -> UInt32 {
        var unit: Int64 = 1
        for _ in 0..<max(0, place) { unit *= 10 }
        let result = Int64(hz) + Int64(delta) * unit
        return UInt32(min(max(result, 0), Int64(maxHz)))
    }

    private var readout: String {
        String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }

    var body: some View {
        let digits = Self.digits(hz)
        let firstSignificant = digits.firstIndex(where: { $0 != 0 }) ?? digits.count
        HStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { i in
                digitView(digits[i], index: i, significant: i >= firstSignificant)
                if i == 2 || i == 5 {
                    Text(".")
                        .font(LyraDS.Font.frequency(size: size))
                        .foregroundStyle(LyraDS.Palette.textDim)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequency")
        .accessibilityValue(readout)
        .modifier(AdjustableIfEditable(onChange: onChange, hz: hz))
        .help(onChange == nil ? "Frequency: \(readout)" : "Frequency: \(readout). Scroll over a digit to tune.")
    }

    private func digitView(_ digit: Int, index: Int, significant: Bool) -> some View {
        let place = 8 - index
        return Text(String(digit))
            .font(LyraDS.Font.frequency(size: size))
            .foregroundStyle(significant ? LyraDS.Palette.textPrimary : LyraDS.Palette.textDim)
            .neonGlow(LyraDS.Palette.cyan, radius: 8, active: significant)
            .contentTransition(.numericText())
            .animation(LyraDS.Motion.standard, value: digit)
            .padding(.horizontal, 1)
            .background(
                RoundedRectangle(cornerRadius: LyraDS.Radius.sm)
                    .fill(LyraDS.Palette.cyan.opacity(hovered == index && onChange != nil ? 0.18 : 0))
            )
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
            .overlay(Group {
                if let onChange {
                    ScrollWheelCapture { dy in
                        scrollRemainder += dy
                        let steps = Int((scrollRemainder / Self.scrollPointsPerStep).rounded(.towardZero))
                        guard steps != 0 else { return }
                        scrollRemainder -= Double(steps) * Self.scrollPointsPerStep
                        onChange(Self.adjusted(hz, place: place, delta: steps))
                    }
                }
            })
    }
}

private struct AdjustableIfEditable: ViewModifier {
    let onChange: ((UInt32) -> Void)?
    let hz: UInt32

    func body(content: Content) -> some View {
        if let onChange {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(LyraFrequencyDisplay.adjusted(hz, place: 3, delta: 1))
                case .decrement: onChange(LyraFrequencyDisplay.adjusted(hz, place: 3, delta: -1))
                @unknown default: break
                }
            }
        } else {
            content
        }
    }
}

#Preview {
    VStack(spacing: LyraDS.Space.lg) {
        LyraFrequencyDisplay(hz: 14_074_000)
        LyraFrequencyDisplay(hz: 7_200_000, onChange: { _ in }, size: 28)
    }
    .padding(LyraDS.Space.xl)
    .background(LyraDS.Palette.void)
}
