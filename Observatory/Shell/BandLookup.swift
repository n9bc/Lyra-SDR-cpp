import Foundation

/// Amateur-band table shared by the band strip and frequency-derived UI.
enum BandLookup {
    /// Band name, inclusive range in Hz, default tune frequency in Hz.
    struct Band: Sendable {
        let name: String
        let range: ClosedRange<UInt32>
        let defaultHz: UInt32
    }

    static let bands: [Band] = [
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
    static let general = "GEN"

    static func bandName(for hz: UInt32) -> String {
        bands.first { $0.range.contains(hz) }?.name ?? general
    }

    /// Index into `bands` for a frequency, or nil when off-band (GEN).
    static func bandIndex(for hz: UInt32) -> Int? {
        bands.firstIndex { $0.range.contains(hz) }
    }
}
