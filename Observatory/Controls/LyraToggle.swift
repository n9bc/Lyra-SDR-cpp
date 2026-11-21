import SwiftUI

/// Neon pill toggle with sliding knob. Space/Return toggles when focused.
struct LyraToggle: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color

    private static let trackSize = CGSize(width: 36, height: 20)
    private static let knob: CGFloat = 14

    init(_ label: String, isOn: Binding<Bool>, accent: Color = LyraDS.Palette.green) {
        self.label = label
        self._isOn = isOn
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: LyraDS.Space.sm) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? accent.opacity(0.25) : LyraDS.Palette.surfaceElevated)
                Capsule().strokeBorder(isOn ? accent : LyraDS.Palette.border, lineWidth: 1)
                Circle()
                    .fill(isOn ? accent : LyraDS.Palette.textDim)
                    .frame(width: Self.knob, height: Self.knob)
                    .padding(3)
            }
            .frame(width: Self.trackSize.width, height: Self.trackSize.height)
            .neonGlow(accent, radius: 6, active: isOn)

            Text(label)
                .font(LyraDS.Font.label(size: 11))
                .foregroundStyle(isOn ? LyraDS.Palette.textPrimary : LyraDS.Palette.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .focusable()
        .onKeyPress(keys: [.space, .return]) { _ in
            toggle()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { toggle() }
        .help("\(label): \(isOn ? "On" : "Off")")
    }

    private func toggle() {
        withAnimation(LyraDS.Motion.standard) { isOn.toggle() }
    }
}

#Preview("Toggle") {
    struct Demo: View {
        @State private var a = true
        @State private var b = false
        var body: some View {
            VStack(alignment: .leading, spacing: LyraDS.Space.md) {
                LyraToggle("Noise Blanker", isOn: $a)
                LyraToggle("Notch", isOn: $b, accent: LyraDS.Palette.yellow)
            }
            .padding(LyraDS.Space.xl)
            .background(LyraDS.Palette.void)
        }
    }
    return Demo()
}
