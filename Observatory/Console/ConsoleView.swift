import SwiftUI

/// The native console: top bar, VFO row, body (receiver | display | band/mode),
/// transmit deck and status bar. Reads only the backend's snapshot and capabilities.
struct ConsoleView: View {
    let backend: any RadioBackend
    /// Held for the view's lifetime: `NeonSpectrumView`'s renderer binds to the first bridge it sees,
    /// so creating one per body evaluation would leave it reading a stale instance.
    @State private var spectrum = SpectrumBridge.mock()

    init(backend: any RadioBackend) {
        self.backend = backend
    }

    var body: some View {
        let snapshot = backend.snapshot
        let gap = ConsoleLayout.gap
        VStack(spacing: gap) {
            TopBarView(snapshot: snapshot, capabilities: backend.capabilities)
                .frame(height: ConsoleLayout.topBarHeight)

            HStack(spacing: gap) {
                VFOPanelView(receiver: snapshot.main, title: "MAIN \u{00B7} \(snapshot.main.bandName)",
                             transmitState: snapshot.transmit.state)
                    .frame(maxHeight: .infinity)
                VFOCenterColumn(session: snapshot.session, sub: snapshot.sub)
                    .frame(width: ConsoleLayout.vfoCenterWidth)
                    .frame(maxHeight: .infinity)
                VFOPanelView(receiver: snapshot.sub, title: "SUB \u{00B7} \(snapshot.sub.bandName)",
                             transmitState: snapshot.transmit.state)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: ConsoleLayout.vfoRowHeight)

            HStack(spacing: gap) {
                ReceiverColumnView(snapshot: snapshot)
                DisplayAreaView(display: snapshot.display, main: snapshot.main,
                                sampleSpectrum: DisplayAreaView.showsSampleMarker(backend.capabilities))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BandModeColumnView(snapshot: snapshot)
            }
            .frame(maxHeight: .infinity)

            TransmitDeckView(transmit: snapshot.transmit, keyer: snapshot.keyer)

            StatusBarView(snapshot: snapshot, capabilities: backend.capabilities)
                .frame(height: ConsoleLayout.statusBarHeight)
        }
        .padding(gap)
        .background(LyraDS.Palette.void)
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
