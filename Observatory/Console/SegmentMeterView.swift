import SwiftUI

/// Segmented S-meter bar for the VFO panels: cyan segments, magenta in the over-S9 zone.
/// Segments share the available width (up to 262 pt) so the meter shrinks with its column.
/// A nil reading (not reported by the radio) lights nothing.
struct SegmentMeterView: View {
    let dbm: Double?
    let enabled: Bool
    let count: Int

    init(dbm: Double?, enabled: Bool, count: Int = 44) {
        self.dbm = dbm
        self.enabled = enabled
        self.count = max(count, 1)
    }

    private var lit: Int {
        guard enabled, let dbm else { return 0 }
        return SegmentMeterModel(count: count).litCount(fraction: ConsoleFormat.meterFraction(dbm: dbm))
    }

    private func color(at index: Int) -> Color {
        guard index < lit else { return LyraDS.Palette.segmentOff }
        return SegmentMeterModel(count: count).zone(at: index) == .over
            ? LyraDS.Palette.magenta : LyraDS.Palette.cyan
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                let on = i < lit
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(at: i))
                    .frame(minWidth: 2, maxWidth: .infinity)
                    .frame(height: 12)
                    .shadow(color: on ? color(at: i).opacity(0.6) : .clear, radius: 2.5)
            }
        }
        .frame(maxWidth: 262)
        .accessibilityElement()
        .accessibilityLabel("Signal strength")
        .accessibilityValue(!enabled ? "Receiver off" : dbm.map { ConsoleFormat.sUnits(dbm: $0) } ?? "Not reported")
    }
}

#Preview("Segment meter") {
    VStack(alignment: .leading, spacing: 12) {
        SegmentMeterView(dbm: -63.2, enabled: true)
        SegmentMeterView(dbm: -40, enabled: true)
        SegmentMeterView(dbm: -63.2, enabled: false)
    }
    .padding(20)
    .frame(width: 320)
    .background(LyraDS.Palette.void)
}
