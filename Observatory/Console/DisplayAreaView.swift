import SwiftUI

/// Vertical budget for the display panel. Panes: main spectrum, main waterfall, Sub spectrum,
/// Sub waterfall (each only when its layout and stack are visible) and the audio terrain (only
/// when expanded). Panes keep their minimums while there is room; below that, every pane (the
/// terrain included) shrinks in proportion to its minimum, so the terrain can drop under 120 pt
/// (about 88 pt at 1280x800 with Sub on).
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

/// Centre display panel: toolbar, the Main (and, when on, Sub) display stack and the audio
/// terrain, sized by `DisplayAreaLayout.compute`. Reads `SpectrumBridge` from the environment
/// for Main; the Sub stack injects its own bridge. Sample imagery only in Milestone 1.
struct DisplayAreaView: View {
    let display: DisplaySnapshot
    /// The engine's manual notches (RX1 only; the Main stack draws and edits them).
    var notches: [NotchInfo] = []
    let main: ReceiverSnapshot
    let sub: ReceiverSnapshot
    /// Gates the toolbar's controls.
    let capabilities: BackendCapabilities
    let focused: ReceiverID
    let store: DisplayStore
    /// Shows the "Sample" marker on the spectrum, waterfall and audio terrain (see `showsSampleMarker`).
    let sampleSpectrum: Bool
    let sampleWaterfall: Bool
    let sampleTerrain: Bool
    /// The live audio terrain; nil keeps the sample imagery.
    let terrain: TerrainFeed?
    /// Console state and command sink for the spectrum and waterfall tuning gestures.
    let ctunEnabled: Bool
    let send: (RadioCommand) -> Void
    /// One bridge per Metal view (a second view on the main bridge would bind the wrong receiver);
    /// `ConsoleView` builds it on the same pump as the main bridge.
    let subSpectrum: SpectrumBridge
    @Environment(SpectrumBridge.self) private var mainSpectrum

    init(display: DisplaySnapshot, notches: [NotchInfo] = [], main: ReceiverSnapshot, sub: ReceiverSnapshot,
         capabilities: BackendCapabilities, focused: ReceiverID,
         store: DisplayStore, subSpectrum: SpectrumBridge = .mock(receiver: .sub),
         sampleSpectrum: Bool, sampleWaterfall: Bool, sampleTerrain: Bool,
         terrain: TerrainFeed? = nil, ctunEnabled: Bool, send: @escaping (RadioCommand) -> Void) {
        self.subSpectrum = subSpectrum
        self.display = display
        self.notches = notches
        self.main = main
        self.sub = sub
        self.capabilities = capabilities
        self.focused = focused
        self.store = store
        self.sampleSpectrum = sampleSpectrum
        self.sampleWaterfall = sampleWaterfall
        self.sampleTerrain = sampleTerrain
        self.terrain = terrain
        self.ctunEnabled = ctunEnabled
        self.send = send
    }

    /// Width of the "Sample" marker; the band plan stops short of it so the two never overlap.
    static let sampleMarkerWidth: CGFloat = 56

    /// Truthfulness: a display feature (spectrum, waterfall, audio terrain) is marked as sample
    /// whenever the backend mocks it.
    nonisolated static func showsSampleMarker(_ capabilities: BackendCapabilities,
                                              for feature: BackendFeature = .spectrum) -> Bool {
        capabilities.status(feature) == .mocked
    }

    var body: some View {
        GeometryReader { geo in
            let subStack = display.showsSubStack(subEnabled: sub.enabled)
            let lay = DisplayAreaLayout.compute(height: geo.size.height, layout: store.layout,
                                                subVisible: subStack, terrainExpanded: store.terrainExpanded)
            let inputs = SpectrumGestureInputs(
                ctuneEnabled: ctunEnabled, subEnabled: sub.enabled, splitEnabled: main.splitTx,
                focused: focused, status: capabilities.control(.spectrumTuning), send: send,
                notches: notches, notchStatus: capabilities.control(.notches))
            VStack(spacing: 0) {
                DisplayToolbarView(display: display, capabilities: capabilities, send: send)
                ReceiverDisplayStack(display: display, receiver: main, label: subStack ? "MAIN" : nil,
                                     labelHighlighted: focused == .main,
                                     spectrumHeight: lay.spectrum, waterfallHeight: lay.waterfall,
                                     sampleSpectrum: sampleSpectrum, sampleWaterfall: sampleWaterfall,
                                     capabilities: capabilities, receiverID: .main, gestures: inputs)
                    .frame(height: lay.spectrum + lay.waterfall + DisplayAreaLayout.scaleHeight)
                if subStack {
                    ReceiverDisplayStack(display: display.view(for: .sub), receiver: sub, label: "SUB",
                                         labelHighlighted: focused == .sub,
                                         spectrumHeight: lay.subSpectrum, waterfallHeight: lay.subWaterfall,
                                         sampleSpectrum: sampleSpectrum, sampleWaterfall: sampleWaterfall,
                                     capabilities: capabilities, receiverID: .sub, gestures: inputs)
                        .environment(subSpectrum)
                        .frame(height: lay.subSpectrum + lay.subWaterfall + DisplayAreaLayout.scaleHeight)
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: DisplayAreaLayout.gutter)
                    AudioTerrainView(store: store, focused: focused, sample: sampleTerrain, feed: terrain)
                }
                .frame(height: lay.terrain + DisplayAreaLayout.terrainHeaderHeight)
            }
            // Both bridges must agree, or whichever stack draws first would decide whether the
            // pump's shared pull includes the Sub streams.
            .onChange(of: subStack, initial: true) {
                mainSpectrum.pullsSub = subStack
                subSpectrum.pullsSub = subStack
            }
        }
        .background(LyraDS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LyraDS.Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display")
    }
}

#if DEBUG
@MainActor private func previewArea(width: CGFloat, height: CGFloat, subOn: Bool = false,
                         layout: DisplayLayout = .spectrumAndWaterfall, terrain: Bool = true) -> some View {
    let store = DisplayStore(defaults: UserDefaults(suiteName: "lyra.preview.display") ?? .standard)
    store.layout = layout
    store.terrainExpanded = terrain
    var snap = RadioSnapshot.sample
    snap.sub.enabled = subOn
    return DisplayAreaView(display: snap.display, main: snap.main, sub: snap.sub,
                           capabilities: .allMocked, focused: .main,
                           store: store, sampleSpectrum: true, sampleWaterfall: true, sampleTerrain: true,
                           ctunEnabled: snap.session.ctunEnabled, send: { _ in })
        .environment(SpectrumBridge.mock())
        .frame(width: width, height: height)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Sub on 940x620") { previewArea(width: 940, height: 620, subOn: true) }
#Preview("Spectrum only 940x620") { previewArea(width: 940, height: 620, layout: .spectrumOnly) }
#Preview("Waterfall only 940x620") { previewArea(width: 940, height: 620, layout: .waterfallOnly) }
#Preview("Terrain hidden 940x620") { previewArea(width: 940, height: 620, terrain: false) }
#Preview("Sub on 648x346") { previewArea(width: 648, height: 346, subOn: true) }
#endif
