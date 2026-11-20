import SwiftUI

/// Panadapter slot. TODO(P1): replace the placeholder with the Metal `MTKView` representable.
struct SpectrumPanel: LyraPanel {
    let id = "spectrum"
    let title = "Spectrum"
    let systemImage = "waveform"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { SpectrumPanelContent() }
}

private struct SpectrumPanelContent: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [LyraTheme.background, LyraTheme.surface],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Text("Metal Panadapter — P1 Integration")
                    .font(.system(size: 11))
                    .foregroundStyle(LyraTheme.textMuted)
            }
            .frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
