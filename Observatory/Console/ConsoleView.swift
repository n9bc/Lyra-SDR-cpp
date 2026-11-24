import SwiftUI

/// The native console: top bar, VFO row, body (receiver | display | band/mode),
/// transmit deck and status bar. Reads only the backend's snapshot and capabilities.
struct ConsoleView: View {
    let backend: any RadioBackend
    let displayStore: DisplayStore
    /// The top bar's gear runs this; nil leaves the gear disabled with its reason.
    let openSettings: (@MainActor () -> Void)?
    /// Held for the view's lifetime: `NeonSpectrumView`'s renderer binds to the first bridge it sees,
    /// so creating one per body evaluation would leave it reading a stale instance. Both bridges
    /// share one `SpectrumPump`, so the two stacks drawing in one frame make a single engine pull.
    @State private var spectrum: SpectrumBridge
    @State private var subSpectrum: SpectrumBridge
    /// Stops the shared pump while the console window cannot be seen.
    @State private var occlusion: SpectrumOcclusionGate

    /// `spectrumSource` is where frames come from: the engine's facade on the live console,
    /// sample data otherwise.
    init(backend: any RadioBackend, displayStore: DisplayStore = DisplayStore(),
         spectrumSource: any SpectrumSource = SyntheticSpectrumSource(),
         openSettings: (@MainActor () -> Void)? = nil) {
        self.backend = backend
        self.displayStore = displayStore
        self.openSettings = openSettings
        let pump = SpectrumPump(source: spectrumSource)
        _spectrum = State(initialValue: SpectrumBridge(pump: pump, receiver: .main))
        _subSpectrum = State(initialValue: SpectrumBridge(pump: pump, receiver: .sub))
        _occlusion = State(initialValue: SpectrumOcclusionGate(pump: pump))
    }

    var body: some View {
        let snapshot = backend.snapshot
        let gap = ConsoleLayout.gap
        VStack(spacing: gap) {
            TopBarView(snapshot: snapshot, capabilities: backend.capabilities, send: backend.send,
                       openSettings: openSettings)
                .frame(height: ConsoleLayout.topBarHeight)

            HStack(spacing: gap) {
                VFOPanelView(receiver: snapshot.main, title: "MAIN \u{00B7} \(snapshot.main.bandName)",
                             transmitState: snapshot.transmit.state,
                             focused: snapshot.session.focused == snapshot.main.id,
                             capabilities: backend.capabilities, send: backend.send)
                    .frame(maxHeight: .infinity)
                VFOCenterColumn(session: snapshot.session, sub: snapshot.sub,
                                splitTx: snapshot.main.splitTx || snapshot.sub.splitTx,
                                capabilities: backend.capabilities, send: backend.send)
                    .frame(width: ConsoleLayout.vfoCenterWidth)
                    .frame(maxHeight: .infinity)
                VFOPanelView(receiver: snapshot.sub, title: "SUB \u{00B7} \(snapshot.sub.bandName)",
                             transmitState: snapshot.transmit.state,
                             focused: snapshot.session.focused == snapshot.sub.id,
                             capabilities: backend.capabilities, send: backend.send)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: ConsoleLayout.vfoRowHeight)

            HStack(spacing: gap) {
                ReceiverColumnView(snapshot: snapshot, capabilities: backend.capabilities, send: backend.send)
                DisplayAreaView(display: snapshot.display, notches: snapshot.dsp.notches,
                                main: snapshot.main, sub: snapshot.sub,
                                capabilities: backend.capabilities,
                                focused: snapshot.session.focused, store: displayStore,
                                subSpectrum: subSpectrum,
                                sampleSpectrum: DisplayAreaView.showsSampleMarker(backend.capabilities),
                                sampleWaterfall: DisplayAreaView.showsSampleMarker(backend.capabilities, for: .waterfall),
                                sampleTerrain: DisplayAreaView.showsSampleMarker(backend.capabilities, for: .audioTerrain),
                                ctunEnabled: snapshot.session.ctunEnabled, send: backend.send)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BandModeColumnView(snapshot: snapshot, capabilities: backend.capabilities, send: backend.send)
            }
            .frame(maxHeight: .infinity)

            TransmitDeckView(transmit: snapshot.transmit, keyer: snapshot.keyer,
                             monitorTx: snapshot.audio.monitorTx,
                             capabilities: backend.capabilities)

            StatusBarView(snapshot: snapshot, capabilities: backend.capabilities)
                .frame(height: ConsoleLayout.statusBarHeight)
        }
        .padding(gap)
        .background(LyraDS.Palette.void)
        .background(ConsoleKeyMonitor(snapshot: { backend.snapshot }, send: backend.send))
        .background(ConsoleWindowAttachment { occlusion.watch($0) })
        // The pump pulls only from a streaming radio; otherwise the panes go blank and dim.
        .onChange(of: snapshot.connection.phase == .streaming, initial: true) { _, streaming in
            spectrum.setStreaming(streaming)
            subSpectrum.setStreaming(streaming)
        }
        .environment(spectrum)
        .preferredColorScheme(.dark)
        .frame(minWidth: ConsoleLayout.minWindow.width, minHeight: ConsoleLayout.minWindow.height)
    }
}

#Preview("Console 1600x1100") {
    ConsoleView(backend: MockRadioBackend())
        .frame(width: 1600, height: 1100)
}

#Preview("Console 1280x800") {
    ConsoleView(backend: MockRadioBackend())
        .frame(width: 1280, height: 800)
}
