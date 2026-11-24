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
    /// The live feed; nil (or `sample`) draws the sample imagery.
    var feed: TerrainFeed?

    nonisolated static let rows = 30
    nonisolated static let points = 201
    nonisolated static let audioLabels = ["0", "500", "1 k", "1.5 k", "2 k", "2.5 k", "3 k Hz"]

    init(store: DisplayStore, focused: ReceiverID, sample: Bool, feed: TerrainFeed? = nil) {
        self.store = store
        self.focused = focused
        self.sample = sample
        self.feed = feed
    }

    /// The terrain is fed from Main's received audio whichever receiver has focus, so it always
    /// says MAIN. `focused` stays in the signature for the callers that pass it.
    nonisolated static func detailText(focused: ReceiverID) -> String {
        "received audio \u{00B7} MAIN \u{00B7} 0\u{2013}3 kHz \u{00B7} last 4 s"
    }

    /// Draws the engine's audio rather than the sample imagery.
    private var liveFeed: TerrainFeed? { sample ? nil : feed }

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
                        Group {
                            if let liveFeed {
                                LiveTerrainWaterfall(grid: liveFeed.grid)
                            } else {
                                SampleWaterfallImage(axis: audioAxis, signals: [520, 1500, 2450], traceWidthHz: 70)
                            }
                        }
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
                .opacity(liveFeed.map { $0.isLive ? 1 : 0.35 } ?? 1)
                .overlay {
                    if let liveFeed, !liveFeed.isLive {
                        let label = liveFeed.isReceiving ? "No audio" : "Paused \u{2014} transmitting"
                        Text(label).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LyraDS.Palette.textMuted)
                            .accessibilityLabel(label)
                    }
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
            let ridges = liveFeed.map { TerrainRendering.ridges(grid: $0.grid, size: geo.size, rows: Self.rows) }
                ?? SampleImagery.terrainRidges(rows: Self.rows, points: Self.points, size: geo.size)
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

/// The live terrain as a waterfall: one pixel row per STFT row, newest at the top, scaled to fill.
struct LiveTerrainWaterfall: View {
    let grid: [[Float]]

    var body: some View {
        GeometryReader { geo in
            if let image = Self.image(grid: grid) {
                Image(decorative: image, scale: 1)
                    .resizable().interpolation(.medium)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    nonisolated static func image(grid: [[Float]]) -> CGImage? {
        guard let width = grid.first?.count, width > 0 else { return nil }
        let height = grid.count
        var buf = [UInt8](repeating: 255, count: width * height * 4)
        for (y, row) in grid.enumerated() where row.count == width {
            for x in 0..<width {
                let c = LyraDS.Palette.sample(LyraDS.Palette.spectrumStops, at: TerrainRendering.level(row[x]))
                let o = (y * width + x) * 4
                buf[o] = UInt8(min(max(c.x, 0), 1) * 255 + 0.5)
                buf[o + 1] = UInt8(min(max(c.y, 0), 1) * 255 + 0.5)
                buf[o + 2] = UInt8(min(max(c.z, 0), 1) * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
