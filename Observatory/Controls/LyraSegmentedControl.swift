import SwiftUI

/// Neon segmented control with a sliding highlight. Left/Right arrows move the selection.
struct LyraSegmentedControl<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String
    let accent: Color

    @Namespace private var highlight

    init(_ label: String, selection: Binding<T>, options: [T],
         title: @escaping (T) -> String, accent: Color = LyraDS.Palette.magenta) {
        self.label = label
        self._selection = selection
        self.options = options
        self.title = title
        self.accent = accent
    }

    /// Next index after moving `delta` steps; clamped to `0...count-1`, never wraps.
    nonisolated static func index(from current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }

    private var currentIndex: Int { options.firstIndex(of: selection) ?? 0 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Text(title(option))
                    .font(LyraDS.Font.label(size: 11))
                    .foregroundStyle(selected ? accent : LyraDS.Palette.textMuted)
                    .padding(.horizontal, LyraDS.Space.md)
                    .padding(.vertical, LyraDS.Space.xs + 2)
                    .background {
                        if selected {
                            Capsule()
                                .fill(accent.opacity(0.18))
                                .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                                .neonGlow(accent, radius: 6)
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { select(option) }
            }
        }
        .padding(2)
        .background(Capsule().fill(LyraDS.Palette.surfaceElevated))
        .overlay(Capsule().strokeBorder(LyraDS.Palette.border, lineWidth: 1))
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            move(press.key == .rightArrow ? 1 : -1)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .help("\(label): \(title(selection))")
    }

    private func select(_ option: T) {
        withAnimation(LyraDS.Motion.standard) { selection = option }
    }

    private func move(_ delta: Int) {
        let i = Self.index(from: currentIndex, delta: delta, count: options.count)
        if options.indices.contains(i) { select(options[i]) }
    }
}

#Preview("Segmented control") {
    struct Demo: View {
        @State private var mode = "USB"
        var body: some View {
            LyraSegmentedControl("Mode", selection: $mode,
                                 options: ["LSB", "USB", "CW", "AM", "FM"], title: { $0 })
                .padding(LyraDS.Space.xl)
                .background(LyraDS.Palette.void)
        }
    }
    return Demo()
}
