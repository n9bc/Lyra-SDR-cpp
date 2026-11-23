import SwiftUI

/// Transmit deck (122 pt): MOX, Tune/2-Tone/VOX, dials, protection, meters and the mode strip.
///
/// MOX fill, glow, caption, header detail and meter liveness come only from `MOXPresentation`,
/// so nothing indicates transmission until the radio reports `.onAir`. Controls are local state
/// seeded from the snapshot; no engine calls in Milestone 1.
struct TransmitDeckView: View {
    let transmit: TransmitSnapshot
    let keyer: KeyerSnapshot

    @State private var drive: Double
    @State private var tune: Double
    @State private var mic: Double
    @State private var monitor: Double
    @State private var vox: Bool
    @State private var protection: TransmitProtectionState
    @State private var keyerTxEnabled: Bool

    init(transmit: TransmitSnapshot, keyer: KeyerSnapshot) {
        self.transmit = transmit
        self.keyer = keyer
        _drive = State(initialValue: Double(transmit.drivePct))
        _tune = State(initialValue: Double(transmit.tunePct))
        _mic = State(initialValue: transmit.micGainDb)
        _monitor = State(initialValue: transmit.monitorLevel)
        _vox = State(initialValue: transmit.voxEnabled)
        _protection = State(initialValue: TransmitProtectionState(transmit))
        _keyerTxEnabled = State(initialValue: keyer.txEnabled)
    }

    private var mox: MOXPresentation { MOXPresentation(state: transmit.state) }

    var body: some View {
        // Fallbacks, widest first: full; hide the keyer caption; protection grid into a menu.
        ViewThatFits(in: .horizontal) {
            deck(showCaption: true, protectionMenu: false)
            deck(showCaption: false, protectionMenu: false)
            deck(showCaption: false, protectionMenu: true)
        }
        .padding(.horizontal, 14)
        .frame(height: ConsoleLayout.txDeckHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LyraDS.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LyraDS.Palette.panelBorder, lineWidth: 1))
    }

    /// One fallback level. Internal so tests can measure the narrowest level's ideal width.
    func deck(showCaption: Bool, protectionMenu: Bool) -> some View {
        HStack(spacing: 10) {
            MOXButton(presentation: mox)
            VStack(spacing: 5) {
                ConsoleChip(title: "Tune", help: "Tune carrier", fullWidth: true)
                ConsoleChip(title: "2-Tone", help: "Two-tone test", fullWidth: true)
                ConsoleChip(title: "VOX", help: "Voice-operated transmit", kind: vox ? .armed : .plain,
                            fullWidth: true) { vox.toggle() }
                    .accessibilityValue(vox ? "On" : "Off")
            }
            .frame(width: 78)
            divider
            HStack(spacing: 10) {
                LyraRotaryDial("Drive", value: $drive, in: 0...100, step: 1, unit: "%", defaultValue: 100)
                    .help("Drive level")
                    .fixedSize()
                LyraRotaryDial("Tune pwr", value: $tune, in: 0...100, step: 1, unit: "%", defaultValue: 50)
                    .help("Tune power")
                    .fixedSize()
                LyraRotaryDial("Mic", value: $mic, in: -40...10, step: 1,
                               accent: LyraDS.Palette.magenta, defaultValue: 0,
                               format: ConsoleFormat.signedDb)
                    .help("Microphone gain")
                    .fixedSize()
                LyraRotaryDial("Monitor", value: $monitor, in: 0...1, step: 0.01,
                               accent: LyraDS.Palette.purple, defaultValue: 0.4,
                               format: { String(format: "%.2f", $0) })
                    .help("Transmit monitor level")
                    .fixedSize()
            }
            divider
            if protectionMenu {
                TransmitProtectionMenu(state: $protection, feedback: transmit.psFeedback)
            } else {
                TransmitProtectionGrid(state: $protection, feedback: transmit.psFeedback)
            }
            divider
            TransmitMeters(transmit: transmit, live: mox.metersLive, detail: mox.headerDetail)
            divider
            KeyerStrip(keyer: keyer, showCaption: showCaption, txEnabled: $keyerTxEnabled)
        }
    }

    private var divider: some View {
        Rectangle().fill(LyraDS.Palette.panelBorder).frame(width: 1).padding(.vertical, 4)
    }
}

/// 92 x 92 MOX key. Lit (filled, glowing) only when the presentation says so.
/// The action is empty in Milestone 1; shortcuts are bound elsewhere.
struct MOXButton: View {
    let presentation: MOXPresentation

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {} label: {
            VStack(spacing: 2) {
                Text(presentation.label)
                    .font(.system(size: 22, weight: .semibold)).tracking(1.32)
                Text(presentation.caption ?? "Space")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(presentation.isLit ? LyraDS.Palette.txText : LyraDS.Palette.moxHint)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(presentation.isLit ? LyraDS.Palette.txText : LyraDS.Palette.pink)
            .padding(.horizontal, 4)
            .frame(width: 92, height: 92)
            .background(shape.fill(presentation.isLit ? LyraDS.Palette.txFill : LyraDS.Palette.moxIdleFill))
            .overlay(shape.strokeBorder(LyraDS.Palette.pink, lineWidth: 2))
            .shadow(color: presentation.isLit ? LyraDS.Palette.pink.opacity(0.45) : .clear, radius: 12)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.label)
        .accessibilityValue(presentation.headerDetail)
        .help("Transmit (Space) \u{2014} keys only after the radio confirms")
    }
}

#Preview("TX idle") { txDeckPreview(.idle) }
#Preview("TX requested") { txDeckPreview(.requested) }
#Preview("TX on air") { txDeckPreview(.onAir) }
#Preview("TX releasing") { txDeckPreview(.releasing) }
#Preview("TX blocked") { txDeckPreview(.blocked("TX inhibit")) }
#Preview("TX 1264 wide") { txDeckPreview(.idle, width: 1264) }

@MainActor private func txDeckPreview(_ state: TransmitState, width: CGFloat = 1584) -> some View {
    var s = RadioSnapshot.sample
    s.transmit.state = state
    if state == .onAir { s.transmit.fwdPowerW = 62; s.transmit.swr = 1.3; s.transmit.alcDb = -8; s.transmit.micLevelDb = -14 }
    return TransmitDeckView(transmit: s.transmit, keyer: s.keyer)
        .frame(width: width)
        .padding(8)
        .background(LyraDS.Palette.void)
}
