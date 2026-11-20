import SwiftUI

/// Main radio surface: toolbar, bands, spectrum/waterfall placeholders, controls, meters.
/// The selected registry panel (if any) appears as an overlay on the spectrum area.
struct DetailView: View {
    @Environment(PanelRegistry.self) private var registry

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            BandStripView()
            Rectangle().fill(LyraTheme.background)
                .overlay { Text("Spectrum — Metal").font(.system(size: 11)).foregroundStyle(LyraTheme.textDim) }
                .overlay(alignment: .topTrailing) { panelOverlay }
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(LinearGradient(colors: [LyraTheme.background, LyraTheme.cyan.opacity(0.15), LyraTheme.surface],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 80)
            ControlStripView()
            VUMeterStripView()
        }
        .background(LyraTheme.background)
    }

    @ViewBuilder
    private var panelOverlay: some View {
        if let id = registry.selectedPanelID,
           let panel = registry.panels.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(panel.title.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(LyraTheme.textMuted)
                AnyView(panel.content)
            }
            .padding(14)
            .frame(width: 280)
            .glassCard()
            .padding(12)
        }
    }
}
