import SwiftUI

/// The native console: top bar, VFO row, body (receiver | display | band/mode),
/// transmit deck and status bar. Reads only the backend's snapshot and capabilities.
struct ConsoleView: View {
    let backend: any RadioBackend
    let displayStore: DisplayStore
    /// Held for the view's lifetime: `NeonSpectrumView`'s renderer binds to the first bridge it sees,
    /// so creating one per body evaluation would leave it reading a stale instance.
    @State private var spectrum = SpectrumBridge.mock()

    init(backend: any RadioBackend, displayStore: DisplayStore = DisplayStore()) {
        self.backend = backend
        self.displayStore = displayStore
    }

    var body: some View {
        let snapshot = backend.snapshot
        let gap = ConsoleLayout.gap
        VStack(spacing: gap) {
            TopBarView(snapshot: snapshot, capabilities: backend.capabilities)
                .frame(height: ConsoleLayout.topBarHeight)

            HStack(spacing: gap) {
                VFOPanelView(receiver: snapshot.main, title: "MAIN \u{00B7} \(snapshot.main.bandName)",
                             transmitState: snapshot.transmit.state,
                             focused: snapshot.session.focused == snapshot.main.id,
                             capabilities: backend.capabilities)
                    .frame(maxHeight: .infinity)
                VFOCenterColumn(session: snapshot.session, sub: snapshot.sub,
                                splitTx: snapshot.main.splitTx || snapshot.sub.splitTx,
                                send: backend.send)
                    .frame(width: ConsoleLayout.vfoCenterWidth)
                    .frame(maxHeight: .infinity)
                VFOPanelView(receiver: snapshot.sub, title: "SUB \u{00B7} \(snapshot.sub.bandName)",
                             transmitState: snapshot.transmit.state,
                             focused: snapshot.session.focused == snapshot.sub.id,
                             capabilities: backend.capabilities)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: ConsoleLayout.vfoRowHeight)

            HStack(spacing: gap) {
                ReceiverColumnView(snapshot: snapshot)
                DisplayAreaView(display: snapshot.display, main: snapshot.main, sub: snapshot.sub,
                                focused: snapshot.session.focused, store: displayStore,
                                sampleSpectrum: DisplayAreaView.showsSampleMarker(backend.capabilities),
                                sampleWaterfall: DisplayAreaView.showsSampleMarker(backend.capabilities, for: .waterfall),
                                sampleTerrain: DisplayAreaView.showsSampleMarker(backend.capabilities, for: .audioTerrain))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BandModeColumnView(snapshot: snapshot, capabilities: backend.capabilities)
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
