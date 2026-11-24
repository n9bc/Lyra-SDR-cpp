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

/// "Audio terrain" header and body: the received audio as one smooth, lit Metal surface
/// (`TerrainRenderer`), or the same surface drawn from the sample grid.
struct AudioTerrainView: View {
    @Bindable var store: DisplayStore
    let focused: ReceiverID
    /// Shows the "Sample" marker in the terrain's top-right corner (see `DisplayAreaView.showsSampleMarker`).
    let sample: Bool
    /// The live feed; nil (or `sample`) draws the sample grid.
    var feed: TerrainFeed?

    @State private var renderer: TerrainRenderer?
    @State private var rendererFailed = false

    nonisolated static let rows = 30
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

    /// Draws the engine's audio rather than the sample grid.
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
                ConsoleChip(title: "Orbit", help: "Orbit the terrain view")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DisplayAreaLayout.terrainHeaderHeight)
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
                    surface
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

    /// The Metal surface. Its MTKView exists only while the terrain is expanded; the renderer
    /// pauses it while the feed is not live and wakes it when the feed goes live or the grid changes.
    private var surface: some View {
        ZStack {
            Color.clear
            if let renderer {
                LyraMetalView(renderer: renderer)
            } else if rendererFailed {
                Text("Metal unavailable").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
            }
        }
        .accessibilityHidden(true)
        .onAppear(perform: makeRendererIfNeeded)
        .onChange(of: liveFeed.map(ObjectIdentifier.init)) { applySource() }
        .onChange(of: liveFeed?.isLive) { renderer?.wake() }
        .onChange(of: liveFeed?.grid.count) { renderer?.wake() }
    }

    private func makeRendererIfNeeded() {
        guard renderer == nil, !rendererFailed else { return }
        guard let ctx = MetalContext.shared, let r = try? TerrainRenderer(context: ctx) else {
            rendererFailed = true
            return
        }
        renderer = r
        applySource()
    }

    private func applySource() {
        guard let renderer else { return }
        if let liveFeed {
            renderer.setSource(.feed(liveFeed))
        } else {
            renderer.setSource(.sample(SampleImagery.terrainGrid()))
        }
    }
}
