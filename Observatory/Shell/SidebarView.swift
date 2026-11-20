import SwiftUI

/// Sidebar column: panels grouped by category, with the live frequency pinned at the bottom.
struct SidebarView: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(RadioBridge.self) private var radio
    @Environment(DspBridge.self) private var dsp

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(PanelCategory.allCases, id: \.self) { category in
                        section(for: category)
                    }
                }
                .padding(.vertical, 12)
            }
            VStack(spacing: 2) {
                FrequencyDisplay(frequencyHz: radio.rx1FreqHz, fontSize: 20)
                Text(dsp.mode)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(LyraTheme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(LyraTheme.border).frame(height: 1) }
        }
        .background(LyraTheme.surface)
    }

    @ViewBuilder
    private func section(for category: PanelCategory) -> some View {
        let panels = registry.panelsForCategory(category)
        if !panels.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(LyraTheme.textDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(panels, id: \.id) { panel in
                    SidebarItem(title: panel.title, systemImage: panel.systemImage,
                                isActive: registry.selectedPanelID == panel.id) {
                        registry.selectedPanelID = registry.selectedPanelID == panel.id ? nil : panel.id
                    }
                }
            }
        }
    }
}
