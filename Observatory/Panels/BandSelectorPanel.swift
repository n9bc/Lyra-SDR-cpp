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

    /// Name, inclusive range in Hz, stored (default) tune frequency in Hz.
    private struct Band {
        let name: String
        let range: ClosedRange<UInt32>
        let hz: UInt32
    }

    private static let bands: [Band] = [
        Band(name: "160", range: 1_800_000...2_000_000, hz: 1_840_000),
        Band(name: "80", range: 3_500_000...4_000_000, hz: 3_573_000),
        Band(name: "60", range: 5_300_000...5_410_000, hz: 5_357_000),
        Band(name: "40", range: 7_000_000...7_300_000, hz: 7_074_000),
        Band(name: "20", range: 14_000_000...14_350_000, hz: 14_074_000),
        Band(name: "17", range: 18_068_000...18_168_000, hz: 18_100_000),
        Band(name: "15", range: 21_000_000...21_450_000, hz: 21_074_000),
        Band(name: "12", range: 24_890_000...24_990_000, hz: 24_915_000),
        Band(name: "10", range: 28_000_000...29_700_000, hz: 28_074_000),
        Band(name: "6", range: 50_000_000...54_000_000, hz: 50_313_000),
        Band(name: "2", range: 144_000_000...148_000_000, hz: 144_174_000),
    ]

    private var activeName: String {
        Self.bands.first { $0.range.contains(radio.rx1FreqHz) }?.name ?? "GEN"
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
            ForEach(Self.bands, id: \.name) { band in
                VStack(spacing: 2) {
                    BandChip(label: band.name, isActive: activeName == band.name) {
                        radio.setFrequency(band.hz)
                    }
                    Text(FrequencyDisplay.format(band.hz))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LyraTheme.textMuted)
                }
            }
            // GEN has no fixed band; it is active whenever the VFO is outside the amateur bands.
            BandChip(label: "GEN", isActive: activeName == "GEN") {}
        }
    }
}
