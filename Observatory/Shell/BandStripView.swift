import SwiftUI

/// Horizontal band chips; the active band is derived from the RX1 frequency.
struct BandStripView: View {
    @Environment(RadioBridge.self) private var radio

    private static var bands: [BandLookup.Band] { BandLookup.bands }
    private static let general = BandLookup.general

    /// Tunes to the adjacent band's default frequency; off-band starts from the nearest edge.
    private func stepBand(_ delta: Int) {
        let hz = radio.rx1FreqHz
        let bands = BandLookup.bands
        let target: Int
        if let i = BandLookup.bandIndex(for: hz) {
            target = i + delta
        } else if delta > 0 {
            target = bands.firstIndex { $0.range.lowerBound > hz } ?? bands.count
        } else {
            target = bands.lastIndex { $0.range.upperBound < hz } ?? -1
        }
        guard bands.indices.contains(target) else { return }
        radio.setFrequency(bands[target].defaultHz)
    }

    var body: some View {
        let active = BandLookup.bandName(for: radio.rx1FreqHz)
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
            .background { shortcuts }
        }
        .padding(.vertical, 6)
        // Number keys 1-9 pick bands only while the strip has keyboard focus.
        .focusable()
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...Self.bands.count).contains(n) else { return .ignored }
            radio.setFrequency(Self.bands[n - 1].defaultHz)
            return .handled
        }
    }

    /// Invisible buttons that carry the band up/down shortcuts.
    private var shortcuts: some View {
        Group {
            Button("Band Down") { stepBand(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Band Up") { stepBand(1) }.keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
