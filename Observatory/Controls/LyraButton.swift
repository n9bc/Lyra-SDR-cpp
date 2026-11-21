import SwiftUI

/// Neon push button. Pressed state comes from `configuration.isPressed`.
struct LyraButtonStyle: ButtonStyle {
    let accent: Color
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LyraDS.Font.label(size: 11))
            .foregroundStyle(isActive ? accent : LyraDS.Palette.textPrimary)
            .padding(.horizontal, LyraDS.Space.md)
            .padding(.vertical, LyraDS.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: LyraDS.Radius.md)
                    .fill(isActive ? accent.opacity(0.18) : LyraDS.Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LyraDS.Radius.md)
                    .strokeBorder(isActive ? accent : LyraDS.Palette.border, lineWidth: 1)
            )
            .neonGlow(accent, radius: 8, active: isActive)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(LyraDS.Motion.standard, value: configuration.isPressed)
            .animation(LyraDS.Motion.standard, value: isActive)
    }
}

/// Neon button with optional SF Symbol and an "active" (latched) look.
struct LyraButton: View {
    let title: String
    let systemImage: String?
    let accent: Color
    let isActive: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, accent: Color = LyraDS.Palette.cyan,
         isActive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: LyraDS.Space.xs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .buttonStyle(LyraButtonStyle(accent: accent, isActive: isActive))
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On" : "Off")
        .help(title)
    }
}

#Preview("Button") {
    struct Demo: View {
        @State private var on = true
        var body: some View {
            HStack(spacing: LyraDS.Space.md) {
                LyraButton("Peak Hold", systemImage: "waveform", isActive: on) { on.toggle() }
                LyraButton("Reset", accent: LyraDS.Palette.magenta) {}
            }
            .padding(LyraDS.Space.xl)
            .background(LyraDS.Palette.void)
        }
    }
    return Demo()
}
