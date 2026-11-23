import SwiftUI

/// Vertical budget for the display panel. Panes: main spectrum, main waterfall, Sub spectrum,
/// Sub waterfall (each only when its layout and stack are visible) and the audio terrain (only
/// when expanded). The terrain never drops below 120 pt while it is shown; all panes shrink
/// proportionally to their minimums when the panel is short.
struct DisplayAreaLayout: Equatable {
    var spectrum: CGFloat
    var waterfall: CGFloat
    var subSpectrum: CGFloat
    var subWaterfall: CGFloat
    var terrain: CGFloat

    nonisolated static let gutter: CGFloat = 28
    nonisolated static let scaleHeight: CGFloat = 18
    nonisolated static let minTerrain: CGFloat = 120
    nonisolated static let minSpectrum: CGFloat = 80
    nonisolated static let minWaterfall: CGFloat = 24
    nonisolated static let idealSpectrum: CGFloat = 218
    nonisolated static let idealWaterfall: CGFloat = 132
    /// Ideal height of the one trace left when the layout hides the other.
    nonisolated static let idealSingle: CGFloat = 350
    nonisolated static let toolbarHeight: CGFloat = 36
    nonisolated static let terrainHeaderHeight: CGFloat = 32

    /// Toolbar, one frequency scale per visible stack and the terrain header (which stays when the terrain is hidden).
    nonisolated static func fixed(subVisible: Bool) -> CGFloat {
        toolbarHeight + scaleHeight * (subVisible ? 2 : 1) + terrainHeaderHeight
    }

    private struct Pane { var minimum: CGFloat; var ideal: CGFloat; var isTerrain: Bool }

    nonisolated static func compute(height: CGFloat, layout: DisplayLayout = .spectrumAndWaterfall,
                                    subVisible: Bool = false, terrainExpanded: Bool = true) -> DisplayAreaLayout {
        let showSpectrum = layout != .waterfallOnly
        let showWaterfall = layout != .spectrumOnly
        let spectrum = Pane(minimum: minSpectrum, ideal: layout == .spectrumOnly ? idealSingle : idealSpectrum, isTerrain: false)
        let waterfall = Pane(minimum: minWaterfall, ideal: layout == .waterfallOnly ? idealSingle : idealWaterfall, isTerrain: false)
        let terrain = Pane(minimum: minTerrain, ideal: minTerrain, isTerrain: true)

        // Slot order: spectrum, waterfall, subSpectrum, subWaterfall, terrain.
        let slots: [Pane?] = [showSpectrum ? spectrum : nil, showWaterfall ? waterfall : nil,
                              subVisible && showSpectrum ? spectrum : nil,
                              subVisible && showWaterfall ? waterfall : nil,
                              terrainExpanded ? terrain : nil]
        let panes = slots.compactMap { $0 }
        let avail = max(height - fixed(subVisible: subVisible), 0)
        let minSum = panes.reduce(0) { $0 + $1.minimum }
        var sizes = panes.map(\.minimum)

        if avail <= minSum {
            sizes = panes.map { avail * $0.minimum / minSum }
        } else {
            let growth = avail - minSum
            let room = panes.filter { !$0.isTerrain }.reduce(0) { $0 + ($1.ideal - $1.minimum) }
            let used = min(growth, room)
            for i in panes.indices where !panes[i].isTerrain {
                sizes[i] += used * (panes[i].ideal - panes[i].minimum) / room
            }
            let leftover = growth - used
            if leftover > 0 {
                if let t = panes.firstIndex(where: \.isTerrain) {
                    sizes[t] += leftover
                } else {
                    let idealSum = panes.reduce(0) { $0 + $1.ideal }
                    for i in panes.indices { sizes[i] += leftover * panes[i].ideal / idealSum }
                }
            }
        }

        var out = [CGFloat](repeating: 0, count: slots.count)
        var next = 0
        for (i, slot) in slots.enumerated() where slot != nil { out[i] = sizes[next]; next += 1 }
        return DisplayAreaLayout(spectrum: out[0], waterfall: out[1], subSpectrum: out[2],
                                 subWaterfall: out[3], terrain: out[4])
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
    let store: DisplayStore

    init(display: DisplaySnapshot, main: ReceiverSnapshot, sampleSpectrum: Bool, store: DisplayStore) {
        self.store = store
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
                    AudioTerrainView(store: store)
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
    DisplayAreaView(display: RadioSnapshot.sample.display, main: RadioSnapshot.sample.main, sampleSpectrum: true, store: DisplayStore())
        .environment(SpectrumBridge.mock())
        .frame(width: 940, height: 620)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Display 648x330") {
    DisplayAreaView(display: RadioSnapshot.sample.display, main: RadioSnapshot.sample.main, sampleSpectrum: true, store: DisplayStore())
        .environment(SpectrumBridge.mock())
        .frame(width: 648, height: 330)
        .padding(8).background(LyraDS.Palette.void)
}
