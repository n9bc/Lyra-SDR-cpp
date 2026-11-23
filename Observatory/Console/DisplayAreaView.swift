import SwiftUI

/// Vertical budget for the display panel: the terrain never drops below 120 pt, the spectrum
/// and waterfall give way first when the panel is short.
struct DisplayAreaLayout: Equatable {
    var spectrum: CGFloat
    var waterfall: CGFloat
    var terrain: CGFloat

    nonisolated static let gutter: CGFloat = 28
    nonisolated static let scaleHeight: CGFloat = 18
    nonisolated static let minTerrain: CGFloat = 120
    nonisolated static let minSpectrum: CGFloat = 80
    nonisolated static let minWaterfall: CGFloat = 24
    nonisolated static let idealSpectrum: CGFloat = 218
    nonisolated static let idealWaterfall: CGFloat = 132
    /// Toolbar, frequency scale and terrain header (the fixed parts).
    nonisolated static let fixed: CGFloat = 36 + scaleHeight + 32

    nonisolated static func compute(height: CGFloat) -> DisplayAreaLayout {
        let avail = max(height - fixed, 0)
        let minSum = minTerrain + minSpectrum + minWaterfall
        if avail <= minSum {
            // Compress proportionally; the terrain keeps its floor while there is room for it.
            let terrain = min(minTerrain, avail * minTerrain / minSum)
            let rest = max(avail - terrain, 0)
            let sp = rest * minSpectrum / (minSpectrum + minWaterfall)
            return DisplayAreaLayout(spectrum: sp, waterfall: rest - sp, terrain: terrain)
        }
        var extra = avail - minSum
        let sp = min(extra, idealSpectrum - minSpectrum); extra -= sp
        let wf = min(extra, idealWaterfall - minWaterfall); extra -= wf
        return DisplayAreaLayout(spectrum: minSpectrum + sp, waterfall: minWaterfall + wf,
                                 terrain: minTerrain + extra)
    }
}

/// Centre display panel: toolbar, Metal spectrum with overlays, frequency scale,
/// sample waterfall and audio terrain. Reads `SpectrumBridge` from the environment (via
/// `NeonSpectrumView`). Sample imagery only in Milestone 1.
struct DisplayAreaView: View {
    let display: DisplaySnapshot
    let main: ReceiverSnapshot
    /// Shows the "Sample" marker on the spectrum (see `showsSampleMarker`).
    let sampleSpectrum: Bool

    init(display: DisplaySnapshot, main: ReceiverSnapshot, sampleSpectrum: Bool) {
        self.display = display
        self.main = main
        self.sampleSpectrum = sampleSpectrum
    }

    /// Width of the "Sample" marker; the band plan stops short of it so the two never overlap.
    static let sampleMarkerWidth: CGFloat = 56

    /// Truthfulness: the spectrum is marked as sample whenever the backend mocks it.
    nonisolated static func showsSampleMarker(_ capabilities: BackendCapabilities) -> Bool {
        capabilities.status(.spectrum) == .mocked
    }

    private var sampleMarker: some View {
        Text("Sample")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LyraDS.Palette.yellow)
            .lineLimit(1)
            .frame(width: Self.sampleMarkerWidth, height: SpectrumOverlays.bandPlanHeight)
            .background(Capsule().fill(LyraDS.Palette.void.opacity(0.85)))
            .background(Capsule().fill(LyraDS.Palette.yellow.opacity(0.08)))
            .overlay(Capsule().strokeBorder(LyraDS.Palette.yellow, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Sample spectrum")
    }

    private func gutterLabels(_ labels: [String], padding: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                Text(labels[i]).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LyraDS.Palette.chipDimText).lineLimit(1).minimumScaleFactor(0.6)
                if i < labels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .padding(padding)
        .frame(width: DisplayAreaLayout.gutter, alignment: .trailing)
        .accessibilityHidden(true)
    }

    var body: some View {
        GeometryReader { geo in
            let lay = DisplayAreaLayout.compute(height: geo.size.height)
            let w = max(geo.size.width - DisplayAreaLayout.gutter, 0)
            let axis = FrequencyAxis(lowHz: display.spanLowHz, highHz: display.spanHighHz, width: w)
            VStack(spacing: 0) {
                DisplayToolbarView(display: display)
                HStack(spacing: 0) {
                    // dB labels come from NeonSpectrumView itself; keep the gutter so rows stay aligned.
                    Color.clear.frame(width: DisplayAreaLayout.gutter)
                    ZStack(alignment: .topLeading) {
                        NeonSpectrumView()
                        SpectrumOverlays(display: display, main: main, axis: axis,
                                         bandPlanTrailingInset: sampleSpectrum ? Self.sampleMarkerWidth + 4 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if sampleSpectrum { sampleMarker.padding(.trailing, 2) }
                    }
                    .frame(width: w, height: lay.spectrum)
                    .clipped()
                }
                .frame(height: lay.spectrum)
                frequencyScale(axis)
                HStack(spacing: 0) {
                    gutterLabels([":25", ":15", ":05"], padding: EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 3))
                    ZStack(alignment: .topLeading) {
                        SampleWaterfallImage(axis: { FrequencyAxis(lowHz: display.spanLowHz, highHz: display.spanHighHz, width: $0) },
                                             signals: display.spots.map(\.frequencyHz) + [main.frequencyHz])
                        Rectangle().fill(LyraDS.Palette.yellow.opacity(0.7))
                            .frame(width: 1).offset(x: axis.x(for: main.frequencyHz))
                    }
                    .frame(width: w, height: lay.waterfall)
                    .clipped()
                }
                .frame(height: lay.waterfall)
                HStack(spacing: 0) {
                    Color.clear.frame(width: DisplayAreaLayout.gutter)
                    AudioTerrainView(display: display)
                }
                .frame(height: lay.terrain + 32)
            }
        }
        .background(LyraDS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LyraDS.Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display")
    }

    private func frequencyScale(_ axis: FrequencyAxis) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(axis.ticks(every: 20_000).filter { $0.x > 18 && $0.x < axis.width - 18 }, id: \.hz) { tick in
                Text(String(format: "%.3f", Double(tick.hz) / 1_000_000))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1).fixedSize()
                    .position(x: tick.x, y: DisplayAreaLayout.scaleHeight / 2)
            }
        }
        .frame(width: axis.width, height: DisplayAreaLayout.scaleHeight, alignment: .topLeading)
        .background(LyraDS.Palette.barFill)
        .overlay(alignment: .top) { Rectangle().fill(LyraDS.Palette.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(LyraDS.Palette.border).frame(height: 1) }
        .padding(.leading, DisplayAreaLayout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

#Preview("Display 940x620") {
    DisplayAreaView(display: RadioSnapshot.sample.display, main: RadioSnapshot.sample.main, sampleSpectrum: true)
        .environment(SpectrumBridge.mock())
        .frame(width: 940, height: 620)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Display 648x330") {
    DisplayAreaView(display: RadioSnapshot.sample.display, main: RadioSnapshot.sample.main, sampleSpectrum: true)
        .environment(SpectrumBridge.mock())
        .frame(width: 648, height: 330)
        .padding(8).background(LyraDS.Palette.void)
}
