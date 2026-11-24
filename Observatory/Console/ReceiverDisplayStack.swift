import SwiftUI

/// One receiver's display stack: Metal spectrum with overlays and the Sample marker, the
/// frequency scale and the sample waterfall. A zero height omits that part; the frequency scale
/// always shows (above the waterfall when the spectrum is omitted, otherwise between the two).
/// Reads `SpectrumBridge` from the environment (via `NeonSpectrumView`).
struct ReceiverDisplayStack: View {
    @Environment(SpectrumBridge.self) private var bridge
    @Environment(\.displayScale) private var displayScale
    let display: DisplaySnapshot
    let receiver: ReceiverSnapshot
    /// "MAIN" / "SUB"; nil when Sub is off and there is nothing to tell apart.
    let label: String?
    let labelHighlighted: Bool
    let spectrumHeight: CGFloat
    let waterfallHeight: CGFloat
    /// Shows the "Sample" marker on the spectrum / waterfall (see `DisplayAreaView.showsSampleMarker`).
    let sampleSpectrum: Bool
    let sampleWaterfall: Bool
    /// Chooses the live waterfall over the sample image (see `usesLiveWaterfall`).
    let capabilities: BackendCapabilities
    /// Which stack this is; the gesture surface tunes accordingly.
    let receiverID: ReceiverID
    /// Console state the tuning gestures need, and where their commands go.
    let gestures: SpectrumGestureInputs

    /// The live Metal waterfall shows once the backend no longer mocks it; until then the sample
    /// image and its marker stay.
    nonisolated static func usesLiveWaterfall(_ capabilities: BackendCapabilities) -> Bool {
        capabilities.status(.waterfall) != .mocked
    }

    /// Live: ages from the real visible depth. Sample: the sample's labels, under its marker.
    private var waterfallLabels: [String] {
        Self.usesLiveWaterfall(capabilities)
            ? Self.liveWaterfallGutterLabels(height: waterfallHeight, pixelsPerPoint: displayScale,
                                             rowsPerSecond: display.waterfallRowsPerSecond)
            : Self.waterfallGutterLabels(height: waterfallHeight)
    }

    /// Covers a pump-fed pane while the radio is not streaming: the spectrum has gone blank and
    /// the waterfall history has stopped, and neither is a live reading.
    @ViewBuilder private func notStreamingCover(_ pane: String) -> some View {
        if !bridge.isStreaming {
            ZStack {
                LyraDS.Palette.void.opacity(0.55)
                Text("Not streaming")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LyraDS.Palette.textMuted)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(pane) paused: the radio is not streaming")
        }
    }

    private var sampleMarker: some View { SampleMarker(accessibilityName: "Sample spectrum") }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(0.8)
            .foregroundStyle(labelHighlighted ? LyraDS.Palette.cyan : LyraDS.Palette.textMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(LyraDS.Palette.void.opacity(0.7)))
            .padding(.leading, 4).padding(.top, 2)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(text.capitalized) receiver display")
    }

    /// The sample waterfall's time labels, shown only under its Sample marker: all three when
    /// tall, the middle one when short, none when squeezed.
    nonisolated static func waterfallGutterLabels(height: CGFloat) -> [String] {
        if height >= 56 { return [":25", ":15", ":05"] }
        if height >= 20 { return [":15"] }
        return []
    }

    /// Gutter label padding from the pane's top and bottom edges.
    nonisolated static let gutterLabelPadding: CGFloat = 8
    /// From the pane edge to the centre of the top or bottom label (padding plus half an 11 pt line).
    nonisolated static let gutterLabelCentreInset: CGFloat = gutterLabelPadding + 6.5

    /// The live waterfall's labels: how many seconds old the row under each label is. The renderer
    /// shows `WaterfallRenderer.history(forDrawableHeight:)` rows over the pane, newest on top, and
    /// pushes `rowsPerSecond` of them a second, so the pane is history / rowsPerSecond seconds deep.
    /// Same placement as the sample labels (top, middle, bottom; middle only when short).
    nonisolated static func liveWaterfallGutterLabels(height: CGFloat, pixelsPerPoint: CGFloat,
                                                      rowsPerSecond: Int) -> [String] {
        guard rowsPerSecond > 0, height >= 20 else { return [] }
        let rows = WaterfallRenderer.history(forDrawableHeight: Int((height * pixelsPerPoint).rounded()))
        let depth = Double(rows) / Double(rowsPerSecond)
        let edge = Double(gutterLabelCentreInset / height)
        let fractions: [Double] = height >= 56 ? [edge, 0.5, 1 - edge] : [0.5]
        return fractions.map { "\(Int((depth * $0).rounded()))s" }
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
        .frame(maxHeight: waterfallHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - DisplayAreaLayout.gutter, 0)
            let axis = FrequencyAxis(lowHz: display.spanLowHz, highHz: display.spanHighHz, width: w)
            VStack(spacing: 0) {
                if spectrumHeight > 0 {
                    spectrum(axis: axis, width: w)
                }
                frequencyScale(axis)
                if waterfallHeight > 0 {
                    waterfall(axis: axis, width: w)
                }
            }
            .onChange(of: display, initial: true) { bridge.apply(display) }
        }
    }

    /// Above the display-only overlays; only `SpectrumOverlayControls` sits higher.
    private func gestureSurface(_ surface: SpectrumSurface) -> some View {
        SpectrumInteractionView(stack: receiverID, display: display, inputs: gestures, surface: surface,
                                shownDbFloor: bridge.dbFloor, shownDbCeiling: bridge.dbCeiling)
            .help(gestures.help(for: receiverID, surface: surface))
            .accessibilityLabel("\(receiverID == .sub ? "Sub" : "Main") spectrum tuning surface")
    }

    private func spectrum(axis: FrequencyAxis, width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            // dB labels come from NeonSpectrumView itself; keep the gutter so rows stay aligned.
            Color.clear.frame(width: DisplayAreaLayout.gutter)
            ZStack(alignment: .topLeading) {
                NeonSpectrumView()
                notStreamingCover("Spectrum")
                SpectrumOverlays(display: display, main: receiver, axis: axis,
                                 notches: NotchModel.visible(gestures.notches, on: receiverID),
                                 bandPlanTrailingInset: sampleSpectrum ? DisplayAreaView.sampleMarkerWidth + 4 : 0,
                                 showsPassbandHandles: receiverID == .main && !display.txAxis,
                                 height: spectrumHeight)
                gestureSurface(.spectrum)
                // Above the gesture surface so its labels and channels are clickable; empty
                // elsewhere, so the surface still gets every other gesture.
                SpectrumOverlayControls(display: display, axis: axis, status: capabilities.status(.spots),
                                        bandPlanTrailingInset: sampleSpectrum ? DisplayAreaView.sampleMarkerWidth + 4 : 0,
                                        send: gestures.send)
            }
            .overlay(alignment: .bottomLeading) {
                // Bottom, right of the dB labels: clear of the band-plan row, spot labels and the Sample marker.
                if let label { tag(label).padding(.leading, 40).padding(.bottom, 2) }
            }
            .overlay(alignment: .topTrailing) {
                if sampleSpectrum { sampleMarker.padding(.trailing, 2) }
            }
            .frame(width: w, height: spectrumHeight)
            .clipped()
        }
        .frame(height: spectrumHeight)
    }

    private func waterfall(axis: FrequencyAxis, width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            gutterLabels(waterfallLabels,
                         padding: EdgeInsets(top: Self.gutterLabelPadding, leading: 0,
                                             bottom: Self.gutterLabelPadding, trailing: 3))
            ZStack(alignment: .topLeading) {
                if Self.usesLiveWaterfall(capabilities) {
                    WaterfallView()
                    notStreamingCover("Waterfall")
                } else {
                    SampleWaterfallImage(axis: { FrequencyAxis(lowHz: display.spanLowHz, highHz: display.spanHighHz, width: $0) },
                                         signals: display.spots.map(\.frequencyHz) + [receiver.frequencyHz])
                }
                Rectangle().fill(LyraDS.Palette.yellow.opacity(0.7))
                    .frame(width: 1).offset(x: axis.x(for: display.mainCarrierHz))
                gestureSurface(.waterfall)
            }
            .overlay(alignment: .topLeading) {
                if let label, spectrumHeight <= 0 { tag(label) }
            }
            .overlay(alignment: .topTrailing) {
                if sampleWaterfall { SampleMarker(accessibilityName: "Sample waterfall").padding(.trailing, 2) }
            }
            .frame(width: w, height: waterfallHeight)
            .clipped()
        }
        .frame(height: waterfallHeight)
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

/// The yellow "Sample" capsule shown on any display pane served from sample data.
struct SampleMarker: View {
    let accessibilityName: String

    var body: some View {
        Text("Sample")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LyraDS.Palette.yellow)
            .lineLimit(1)
            .frame(width: DisplayAreaView.sampleMarkerWidth, height: SpectrumOverlays.bandPlanHeight)
            .background(Capsule().fill(LyraDS.Palette.void.opacity(0.85)))
            .background(Capsule().fill(LyraDS.Palette.yellow.opacity(0.08)))
            .overlay(Capsule().strokeBorder(LyraDS.Palette.yellow, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(accessibilityName)
    }
}
