import SwiftUI

struct BandSelectorPanel: LyraPanel {
    let id = "band-selector"
    let title = "Bands"
    let systemImage = "square.grid.3x3"
    let category = PanelCategory.bands
    let defaultVisible = true

    var content: some View { BandSelectorPanelContent() }
}

private struct BandSelectorPanelContent: View {
    nonisolated init() {}

    @Environment(RadioBridge.self) private var radio

    private var activeName: String {
        BandLookup.bandName(for: radio.rx1FreqHz)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
            ForEach(BandLookup.bands, id: \.name) { band in
                VStack(spacing: 2) {
                    BandChip(label: band.name, isActive: activeName == band.name) {
                        radio.setFrequency(band.defaultHz)
                    }
                    Text(FrequencyDisplay.format(band.defaultHz))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LyraTheme.textMuted)
                }
            }
            // GEN has no fixed band; it is active whenever the VFO is outside the amateur bands.
            BandChip(label: "GEN", isActive: activeName == "GEN") {}
        }
    }
}
