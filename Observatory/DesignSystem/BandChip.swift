import SwiftUI

/// Pill-shaped band selector chip; cyan glow when active.
struct BandChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    init(label: String, isActive: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassButton(isActive: isActive, accentColor: LyraTheme.cyan)
                .background(
                    Capsule().fill(isActive ? LyraTheme.cyan.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
