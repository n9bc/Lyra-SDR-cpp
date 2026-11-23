import SwiftUI

/// Sample waterfall image cached per pixel size; regenerated only when the size changes.
struct SampleWaterfallImage: View {
    let axis: (_ width: CGFloat) -> FrequencyAxis
    let signals: [Int64]
    var traceWidthHz: Int64 = 5_000
    @State private var cached: (size: CGSize, image: CGImage)?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let cached {
                    Image(decorative: cached.image, scale: 1)
                        .resizable().interpolation(.none)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .onChange(of: geo.size, initial: true) { _, size in
                let w = Int(size.width.rounded()), h = Int(size.height.rounded())
                guard w > 0, h > 0, cached?.size != size else { return }
                cached = (size, SampleImagery.waterfall(width: w, height: h, axis: axis(size.width), signals: signals,
                                                          traceWidthHz: traceWidthHz))
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// "Audio terrain" header and body: ridges (3D), a sample waterfall of the audio band, or both.
struct AudioTerrainView: View {
    @Bindable var store: DisplayStore
    let focused: ReceiverID
    /// Shows the "Sample" marker in the terrain's top-right corner (see `DisplayAreaView.showsSampleMarker`).
    let sample: Bool

    nonisolated static let rows = 30
    nonisolated static let points = 201
    nonisolated static let audioLabels = ["0", "500", "1 k", "1.5 k", "2 k", "2.5 k", "3 k Hz"]

    init(store: DisplayStore, focused: ReceiverID, sample: Bool) {
        self.store = store
        self.focused = focused
        self.sample = sample
    }

    nonisolated static func detailText(focused: ReceiverID) -> String {
        "received audio \u{00B7} \(focused == .main ? "MAIN" : "SUB") \u{00B7} 0\u{2013}3 kHz \u{00B7} last 4 s"
    }

    private var chevron: some View {
        let title = store.terrainExpanded ? "Hide audio terrain" : "Show audio terrain"
        return Button { store.terrainExpanded.toggle() } label: {
            Image(systemName: store.terrainExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LyraDS.Palette.textMuted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).help(title)
    }

    private func header(showDetail: Bool) -> some View {
        HStack(spacing: 6) {
            chevron
            Text("AUDIO TERRAIN")
                .font(.system(size: 11, weight: .semibold)).tracking(0.99)
                .foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
            if showDetail {
                Text(Self.detailText(focused: focused))
                    .font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if store.terrainExpanded {
                LyraSegmentedControl("Terrain view", selection: $store.terrainView, options: TerrainView.allCases,
                                     title: { $0.rawValue }, accent: LyraDS.Palette.cyan)
                Text("Mix").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                Slider(value: $store.terrainMix, in: 0...1).controlSize(.small).tint(LyraDS.Palette.purple).frame(width: 80)
                    .accessibilityLabel("Combined opacity").help("Combined opacity")
                ConsoleChip(title: "Orbit", help: "Orbit the terrain view")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DisplayAreaLayout.terrainHeaderHeight)
    }

    private var audioAxis: (CGFloat) -> FrequencyAxis {
        { FrequencyAxis(lowHz: 0, highHz: 3000, width: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(showDetail: true)
                header(showDetail: false)
            }
            .frame(height: DisplayAreaLayout.terrainHeaderHeight)
            if store.terrainExpanded {
                ZStack(alignment: .bottom) {
                    LyraDS.Palette.void
                    if store.terrainView != .threeD {
                        SampleWaterfallImage(axis: audioAxis, signals: [520, 1500, 2450], traceWidthHz: 70)
                            .opacity(store.terrainView == .both ? store.terrainMix : 1)
                    }
                    if store.terrainView != .waterfall { ridgeCanvas }
                    HStack {
                        ForEach(Self.audioLabels, id: \.self) { l in
                            Text(l).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                            if l != Self.audioLabels.last { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .topTrailing) {
                    if sample { SampleMarker(accessibilityName: "Sample audio terrain").padding(.top, 4).padding(.trailing, 8) }
                }
                .clipped()
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(LyraDS.Palette.border).frame(height: 1) }
    }

    private var ridgeCanvas: some View {
        GeometryReader { geo in
            // Pure and static: re-evaluated only when the size or the view state changes, never per frame.
            let ridges = SampleImagery.terrainRidges(rows: Self.rows, points: Self.points, size: geo.size)
            Canvas { ctx, size in
                let n = ridges.count
                for (i, ridge) in ridges.enumerated() where ridge.count > 1 {
                    let t = n > 1 ? Double(i) / Double(n - 1) : 1
                    let base = SampleImagery.ridgeBase(row: i, rows: n, height: size.height)
                    let amp = SampleImagery.ridgeAmpScale(row: i, rows: n)
                    var line = Path()
                    line.move(to: ridge[0])
                    for p in ridge.dropFirst() { line.addLine(to: p) }
                    var fill = line
                    fill.addLine(to: CGPoint(x: ridge[ridge.count - 1].x, y: size.height))
                    fill.addLine(to: CGPoint(x: ridge[0].x, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(LyraDS.Palette.void.opacity(0.93)))
                    let top = max(base - 0.54 * size.height * amp, 0)
                    ctx.opacity = 0.25 + 0.75 * t
                    ctx.stroke(line,
                               with: .linearGradient(LyraDS.Palette.spectrumGradient,
                                                     startPoint: CGPoint(x: 0, y: min(base, size.height)),
                                                     endPoint: CGPoint(x: 0, y: top)),
                               lineWidth: 1.3)
                    ctx.opacity = 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}
