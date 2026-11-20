import SwiftUI

/// Observatory design-system colors.
enum LyraTheme {
    static let background = Color(hex: "#0c0e14")
    static let surface = Color(hex: "#0f1219")
    static let border = Color(hex: "#1a1f2e")
    static let cyan = Color(hex: "#00e5ff")
    static let amber = Color(hex: "#ff9f43")
    static let violet = Color(hex: "#a78bfa")
    static let textPrimary = Color(hex: "#c8d6e5")
    static let textMuted = Color(hex: "#3a4a5a")
    static let textDim = Color(hex: "#2a3a4a")
}

extension Color {
    /// Parses "#RRGGBB" (the leading "#" is optional). Invalid input yields black.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&value) else {
            self = .black
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
