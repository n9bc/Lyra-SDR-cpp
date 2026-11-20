import SwiftUI

/// Sidebar row with SF Symbol; active state shows a left cyan border and glow.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    init(title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? LyraTheme.cyan : LyraTheme.textMuted)
            .shadow(color: isActive ? LyraTheme.cyan.opacity(0.6) : .clear, radius: 4)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(isActive ? LyraTheme.cyan.opacity(0.08) : .clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(LyraTheme.cyan)
                        .frame(width: 2)
                        .shadow(color: LyraTheme.cyan, radius: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
