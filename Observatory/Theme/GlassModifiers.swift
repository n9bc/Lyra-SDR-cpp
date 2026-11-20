import SwiftUI

/// Frosted card surface: thin material, hairline border, inner top highlight.
struct GlassCardModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(LyraTheme.border, lineWidth: 0.5))
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .clear],
                            startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                    .padding(0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

/// Button surface with an accent glow when active.
struct GlassButtonModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color
    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isActive ? accentColor : LyraTheme.textMuted)
            .shadow(color: isActive ? accentColor.opacity(0.8) : .clear, radius: 4)
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    isActive ? accentColor.opacity(0.8) : LyraTheme.border,
                    lineWidth: isActive ? 1 : 0.5)
            )
            .shadow(color: isActive ? accentColor.opacity(0.35) : .clear, radius: 8)
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCardModifier()) }

    func glassButton(isActive: Bool = false, accentColor: Color = LyraTheme.cyan) -> some View {
        modifier(GlassButtonModifier(isActive: isActive, accentColor: accentColor))
    }
}
