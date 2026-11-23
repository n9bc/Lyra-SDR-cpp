import SwiftUI

// MARK: - Chip buttons

enum ConsoleChipStyle: CaseIterable {
    case plain, on, sub, armed, warn, hot, dim
}

/// Standard console chip: 26 pt high, radius 7, 12 pt medium label.
struct ConsoleChipButtonStyle: ButtonStyle {
    let kind: ConsoleChipStyle
    let height: CGFloat
    let fullWidth: Bool

    init(_ kind: ConsoleChipStyle, height: CGFloat = 26, fullWidth: Bool = false) {
        self.kind = kind
        self.height = height
        self.fullWidth = fullWidth
    }

    private var text: Color {
        switch kind {
        case .plain: LyraDS.Palette.chipText
        case .on: LyraDS.Palette.cyan
        case .sub: LyraDS.Palette.chipSubText
        case .armed: LyraDS.Palette.green
        case .warn: LyraDS.Palette.yellow
        case .hot: LyraDS.Palette.pink
        case .dim: LyraDS.Palette.chipDimText
        }
    }

    private var border: Color {
        switch kind {
        case .plain, .dim: LyraDS.Palette.chipBorder
        case .on: LyraDS.Palette.cyan
        case .sub: LyraDS.Palette.purple
        case .armed: LyraDS.Palette.green
        case .warn: LyraDS.Palette.yellow
        case .hot: LyraDS.Palette.pink
        }
    }

    private var fill: Color {
        switch kind {
        case .plain: LyraDS.Palette.chipFill
        case .on: LyraDS.Palette.cyan.opacity(0.10)
        case .sub: LyraDS.Palette.purple.opacity(0.12)
        case .armed: LyraDS.Palette.green.opacity(0.08)
        case .warn: LyraDS.Palette.yellow.opacity(0.08)
        case .hot: LyraDS.Palette.pink.opacity(0.10)
        case .dim: LyraDS.Palette.chipDimFill
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: kind == .on ? LyraDS.Palette.cyan.opacity(0.22) : .clear, radius: 6)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

// MARK: - VFO chip buttons

enum VFOChipStyle: CaseIterable {
    case plain, active, cyan, tx
}

/// Compact monospaced chip used inside the VFO panels: 22 pt high, radius 5.
struct VFOChipButtonStyle: ButtonStyle {
    let kind: VFOChipStyle
    let fullWidth: Bool

    init(_ kind: VFOChipStyle, fullWidth: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
    }

    private var text: Color {
        switch kind {
        case .plain: LyraDS.Palette.chipText
        case .active: LyraDS.Palette.yellow
        case .cyan: LyraDS.Palette.cyan
        case .tx: LyraDS.Palette.txText
        }
    }

    private var border: Color {
        switch kind {
        case .plain: LyraDS.Palette.vchipBorder
        case .active: LyraDS.Palette.yellow
        case .cyan: LyraDS.Palette.cyan
        case .tx: LyraDS.Palette.pink
        }
    }

    private var fill: Color {
        switch kind {
        case .plain: LyraDS.Palette.vchipFill
        case .active: LyraDS.Palette.yellow.opacity(0.08)
        case .cyan: LyraDS.Palette.cyan.opacity(0.10)
        case .tx: LyraDS.Palette.txFill
        }
    }

    private var glow: (color: Color, radius: CGFloat)? {
        switch kind {
        case .cyan: (LyraDS.Palette.cyan.opacity(0.2), 5)
        case .tx: (LyraDS.Palette.pink.opacity(0.45), 6)
        default: nil
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(0.55)
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 22)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: glow?.color ?? .clear, radius: glow?.radius ?? 0)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

// MARK: - Panels

extension View {
    /// Standard console panel: surface fill, hairline border, radius 12.
    func consolePanel(padding: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .padding(padding)
            .background(shape.fill(LyraDS.Palette.surface))
            .overlay(shape.strokeBorder(LyraDS.Palette.panelBorder, lineWidth: 1))
    }

    /// VFO panel: vertical gradient, blue-tinted border (cyan when `highlighted`), top inner highlight.
    func vfoPanel(highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                shape.fill(LinearGradient(
                    colors: [LyraDS.Palette.vfoTop, LyraDS.Palette.vfoBottom],
                    startPoint: .top, endPoint: .bottom)))
            .overlay(
                shape.strokeBorder(
                    highlighted ? LyraDS.Palette.vfoBorderHighlight : LyraDS.Palette.vfoBorder,
                    lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LyraDS.Palette.vfoInnerHighlight)
                    .frame(height: 1)
                    .padding(.horizontal, 6)
            }
            .clipShape(shape)
            .shadow(color: highlighted ? LyraDS.Palette.vfoGlowHighlight : .clear, radius: 14)
    }
}

// MARK: - Section header

/// Uppercase tracked section title with an optional cyan detail on the right.
struct ConsoleSectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.99)
                .foregroundStyle(LyraDS.Palette.textMuted)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LyraDS.Palette.cyan)
            }
        }
        .padding(.bottom, 8)
    }
}

#Preview("Console chips") {
    VStack(alignment: .leading, spacing: 12) {
        ConsoleSectionHeader("Chips", detail: "all kinds")
        HStack {
            ForEach(ConsoleChipStyle.allCases, id: \.self) { kind in
                Button("\(String(describing: kind))") {}
                    .buttonStyle(ConsoleChipButtonStyle(kind))
            }
        }
        HStack {
            ForEach(VFOChipStyle.allCases, id: \.self) { kind in
                Button("\(String(describing: kind))".uppercased()) {}
                    .buttonStyle(VFOChipButtonStyle(kind))
            }
        }
        Text("Panel").consolePanel()
        Text("VFO").foregroundStyle(LyraDS.Palette.textPrimary).vfoPanel(highlighted: false)
        Text("VFO hi").foregroundStyle(LyraDS.Palette.textPrimary).vfoPanel(highlighted: true)
    }
    .padding(20)
    .frame(width: 560)
    .background(LyraDS.Palette.void)
}
