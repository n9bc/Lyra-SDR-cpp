import SwiftUI

/// A gradient stop shared by SwiftUI gradients and the Metal spectrum shader.
struct GradientStop: Equatable {
    let position: Float
    let rgba: SIMD4<Float>
}

/// Neon design-system tokens for Observatory.
enum LyraDS {
    enum Palette {
        static let electricBlue = Color(hex: "#2E6BFF")
        static let cyan = Color(hex: "#00E5FF")
        static let purple = Color(hex: "#8B5CF6")
        static let magenta = Color(hex: "#FF2BD6")
        static let pink = Color(hex: "#FF5C8A")
        static let yellow = Color(hex: "#FFD23F")
        static let green = Color(hex: "#2BFF88")

        static let void = Color(hex: "#05060B")
        static let surface = Color(hex: "#0B0D17")
        static let surfaceElevated = Color(hex: "#131628")

        static let textPrimary = Color(hex: "#EAF2FF")
        static let textMuted = Color(hex: "#8A93B2")
        static let textDim = Color(hex: "#4F5675")

        static let border = Color.white.opacity(0.08)

        // Console tokens (native console mockup).
        static let vfoTop = Color(hex: "#0F1427")
        static let vfoBottom = Color(hex: "#080A14")
        static let vfoBorder = Color(hex: "#78A0FF").opacity(0.16)
        static let chipFill = surfaceElevated
        static let segmentOff = Color(hex: "#1A1E33")
        static let freqGlow = Color(hex: "#E4FCFF")
        static let freqSub = Color(hex: "#A3ACC8")
        static let txFill = Color(hex: "#E8335F")
        static let txText = Color.white

        static let panelBorder = Color.white.opacity(0.07)
        static let chipBorder = Color.white.opacity(0.09)
        static let chipText = Color(hex: "#B7C0DE")
        static let chipSubText = Color(hex: "#C4B0FF")
        static let chipDimText = Color(hex: "#5E6688")
        static let chipDimFill = Color(hex: "#0F1220")
        static let vchipFill = Color(hex: "#0B0E1B")
        static let vchipBorder = Color.white.opacity(0.13)

        private static func stop(_ position: Float, _ hex: UInt32) -> GradientStop {
            GradientStop(
                position: position,
                rgba: SIMD4<Float>(
                    Float((hex >> 16) & 0xFF) / 255,
                    Float((hex >> 8) & 0xFF) / 255,
                    Float(hex & 0xFF) / 255,
                    1))
        }

        /// Single source of truth for the spectrum colour ramp (SwiftUI and Metal).
        static let spectrumStops: [GradientStop] = [
            stop(0.0, 0x2E6BFF),
            stop(0.3, 0x00E5FF),
            stop(0.55, 0x8B5CF6),
            stop(0.8, 0xFF2BD6),
            stop(1.0, 0xFFD23F),
        ]

        /// Linear interpolation across `stops` (assumed sorted by position); `t` is clamped to 0...1.
        static func sample(_ stops: [GradientStop], at t: Float) -> SIMD4<Float> {
            guard let first = stops.first, let last = stops.last else { return .zero }
            let t = min(max(t, 0), 1)
            if t <= first.position { return first.rgba }
            if t >= last.position { return last.rgba }
            for i in 1..<stops.count where t <= stops[i].position {
                let a = stops[i - 1]
                let b = stops[i]
                let span = b.position - a.position
                if span <= 0 { return b.rgba }
                let f = (t - a.position) / span
                return a.rgba + (b.rgba - a.rgba) * f
            }
            return last.rgba
        }

        static var spectrumGradient: Gradient {
            Gradient(stops: spectrumStops.map {
                Gradient.Stop(
                    color: Color(.sRGB,
                                 red: Double($0.rgba.x), green: Double($0.rgba.y),
                                 blue: Double($0.rgba.z), opacity: Double($0.rgba.w)),
                    location: CGFloat($0.position))
            })
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
    }

    enum Motion {
        static let standard: Animation = .spring(response: 0.3, dampingFraction: 0.8)
    }

    enum Font {
        static func frequency(size: CGFloat) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .monospaced).monospacedDigit()
        }

        static func label(size: CGFloat) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .default)
        }
    }
}

extension View {
    /// Two stacked neon shadows (radius/2 at 0.9, radius at 0.5); no-op when `active` is false.
    @ViewBuilder
    func neonGlow(_ color: Color, radius: CGFloat = 8, active: Bool = true) -> some View {
        if active {
            self
                .shadow(color: color.opacity(0.9), radius: radius / 2)
                .shadow(color: color.opacity(0.5), radius: radius)
        } else {
            self
        }
    }
}
