import SwiftUI

/// Horizontal band chips; the active band is derived from the RX1 frequency.
struct BandStripView: View {
    @Environment(RadioBridge.self) private var radio

    /// Band name, inclusive range in Hz, default tune frequency in Hz.
    private struct Band {
        let name: String
        let range: ClosedRange<UInt32>
        let defaultHz: UInt32
    }

    private static let bands: [Band] = [
        Band(name: "160", range: 1_800_000...2_000_000, defaultHz: 1_840_000),
        Band(name: "80", range: 3_500_000...4_000_000, defaultHz: 3_573_000),
        Band(name: "60", range: 5_300_000...5_410_000, defaultHz: 5_357_000),
        Band(name: "40", range: 7_000_000...7_300_000, defaultHz: 7_074_000),
        Band(name: "20", range: 14_000_000...14_350_000, defaultHz: 14_074_000),
        Band(name: "17", range: 18_068_000...18_168_000, defaultHz: 18_100_000),
        Band(name: "15", range: 21_000_000...21_450_000, defaultHz: 21_074_000),
        Band(name: "12", range: 24_890_000...24_990_000, defaultHz: 24_915_000),
        Band(name: "10", range: 28_000_000...29_700_000, defaultHz: 28_074_000),
        Band(name: "6", range: 50_000_000...54_000_000, defaultHz: 50_313_000),
        Band(name: "2", range: 144_000_000...148_000_000, defaultHz: 144_174_000),
    ]
    private static let general = "GEN"

    static func bandName(for hz: UInt32) -> String {
        bands.first { $0.range.contains(hz) }?.name ?? general
    }

    var body: some View {
        let active = Self.bandName(for: radio.rx1FreqHz)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.bands, id: \.name) { band in
                    BandChip(label: band.name, isActive: active == band.name) {
                        radio.setFrequency(band.defaultHz)
                    }
                }
                // GEN is a catch-all: it shows active off-band but has no tune target.
                BandChip(label: Self.general, isActive: active == Self.general) {}
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }
}
