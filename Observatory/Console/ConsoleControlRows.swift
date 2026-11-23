import SwiftUI

/// Compact console slider row from the mockup: 54 pt label, flexible track, 58 pt monospaced value.
/// Wraps a SwiftUI `Slider` tinted from tokens; `dimmed` mutes the tint and value (stays interactive).
struct ConsoleSliderRow: View {
    let label: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    var tint: Color = LyraDS.Palette.cyan
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LyraDS.Palette.textMuted)
                .lineLimit(1)
                .frame(width: 54, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(dimmed ? LyraDS.Palette.textDim : tint)
                .accessibilityLabel(help)
                .accessibilityValue(readout)
                .help(help)
            Text(readout)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(dimmed ? LyraDS.Palette.chipDimText : LyraDS.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

/// Chip-styled pop-up menu (mockup `.sel`): current value plus a chevron.
struct ConsoleMenuChip: View {
    let label: String
    let help: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { selection = option }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ConsoleChipButtonStyle(.plain))
        .fixedSize()
        .accessibilityLabel(help)
        .accessibilityValue(selection)
        .help(help)
    }
}

/// Chip with an accessibility label and help; the action is empty in Milestone 1 unless supplied.
struct ConsoleChip: View {
    let title: String
    let help: String
    var kind: ConsoleChipStyle = .plain
    var height: CGFloat = 26
    var fullWidth = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title).minimumScaleFactor(0.7)
        }
        .buttonStyle(ConsoleChipButtonStyle(kind, height: height, fullWidth: fullWidth))
        .accessibilityLabel(help)
        .help(help)
    }
}

/// 7 pt status lamp with glow.
struct ConsoleLamp: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color, radius: 3)
            .accessibilityHidden(true)
    }
}

/// Uniform flexible-column chip grid with 5 pt gaps.
func consoleColumns(_ count: Int) -> [GridItem] {
    Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5), count: count)
}
