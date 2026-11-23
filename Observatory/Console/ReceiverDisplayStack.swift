import SwiftUI

/// One receiver's display stack: Metal spectrum with overlays and the Sample marker, the
/// frequency scale and the sample waterfall. A zero height omits that part; the frequency scale
/// always shows (above the waterfall when the spectrum is omitted, otherwise between the two).
/// Reads `SpectrumBridge` from the environment (via `NeonSpectrumView`).
struct ReceiverDisplayStack: View {
    let display: DisplaySnapshot
    let receiver: ReceiverSnapshot
    /// "MAIN" / "SUB"; nil when Sub is off and there is nothing to tell apart.
    let label: String?
    let labelHighlighted: Bool
    let spectrumHeight: CGFloat
    let waterfallHeight: CGFloat
    /// Shows the "Sample" marker on the spectrum (see `DisplayAreaView.showsSampleMarker`).
    let sampleSpectrum: Bool

    private var sampleMarker: some View {
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
            .accessibilityLabel("Sample spectrum")
    }

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
        }
    }

    private func spectrum(axis: FrequencyAxis, width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            // dB labels come from NeonSpectrumView itself; keep the gutter so rows stay aligned.
            Color.clear.frame(width: DisplayAreaLayout.gutter)
            ZStack(alignment: .topLeading) {
                NeonSpectrumView()
                SpectrumOverlays(display: display, main: receiver, axis: axis,
                                 bandPlanTrailingInset: sampleSpectrum ? DisplayAreaView.sampleMarkerWidth + 4 : 0)
            }
            .overlay(alignment: .topLeading) {
                if let label { tag(label).padding(.top, SpectrumOverlays.bandPlanHeight + 2) }
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
            gutterLabels([":25", ":15", ":05"], padding: EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 3))
            ZStack(alignment: .topLeading) {
                SampleWaterfallImage(axis: { FrequencyAxis(lowHz: display.spanLowHz, highHz: display.spanHighHz, width: $0) },
                                     signals: display.spots.map(\.frequencyHz) + [receiver.frequencyHz])
                Rectangle().fill(LyraDS.Palette.yellow.opacity(0.7))
                    .frame(width: 1).offset(x: axis.x(for: receiver.frequencyHz))
            }
            .overlay(alignment: .topLeading) {
                if let label, spectrumHeight <= 0 { tag(label) }
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
