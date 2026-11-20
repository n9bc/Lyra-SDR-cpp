import SwiftUI

/// Monospace frequency readout, e.g. 14074000 Hz → "14.074.000".
struct FrequencyDisplay: View {
    let frequencyHz: UInt32
    let fontSize: CGFloat

    /// Groups digits in threes with "." separators.
    static func format(_ hz: UInt32) -> String {
        let digits = String(hz)
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    var body: some View {
        Text(Self.format(frequencyHz))
            .font(.system(size: fontSize, weight: .light, design: .monospaced))
            .foregroundStyle(LyraTheme.cyan)
            .shadow(color: LyraTheme.cyan.opacity(0.3), radius: 8)
            .accessibilityLabel("\(frequencyHz) hertz")
    }
}
