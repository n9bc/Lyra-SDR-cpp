import SwiftUI

/// Transmit deck (122 pt): MOX, Tune/2-Tone/VOX, dials, protection, meters and the mode strip.
///
/// MOX fill, glow, caption, header detail and meter liveness come only from `MOXPresentation`,
/// so nothing indicates transmission until the radio reports `.onAir`. Every control reads the
/// snapshot directly (constant bindings, no local copies) and is gated on the backend's
/// `.transmit` availability; nothing here reaches the engine before Milestone 5b.
struct TransmitDeckView: View {
    let transmit: TransmitSnapshot
    let keyer: KeyerSnapshot
    /// MON TX state from the audio snapshot, the same value the receiver column shows.
    let monitorTx: Bool

    let capabilities: BackendCapabilities

    init(transmit: TransmitSnapshot, keyer: KeyerSnapshot, monitorTx: Bool,
         capabilities: BackendCapabilities) {
        self.transmit = transmit
        self.keyer = keyer
        self.monitorTx = monitorTx
        self.capabilities = capabilities
    }

    private var txStatus: CapabilityStatus { capabilities.control(.transmit) }
    private var protection: TransmitProtectionState { TransmitProtectionState(transmit) }
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
            MOXButton(presentation: mox, status: txStatus)
            VStack(spacing: 5) {
                ConsoleChip(title: "Tune", help: "Tune carrier", fullWidth: true, status: txStatus)
                ConsoleChip(title: "2-Tone", help: "Two-tone test", fullWidth: true, status: txStatus)
                ConsoleChip(title: "VOX", help: "Voice-operated transmit",
                            kind: transmit.voxEnabled ? .armed : .plain, fullWidth: true, status: txStatus)
                    .accessibilityValue(transmit.voxEnabled ? "On" : "Off")
            }
            .frame(width: 78)
            divider
            HStack(spacing: 10) {
                LyraRotaryDial("Drive", value: .constant(Double(transmit.drivePct)), in: 0...100, step: 1,
                               unit: "%", defaultValue: 100)
                    .consoleAvailability(txStatus, help: "Drive level")
                    .fixedSize()
                LyraRotaryDial("Tune pwr", value: .constant(Double(transmit.tunePct)), in: 0...100, step: 1,
                               unit: "%", defaultValue: 50)
                    .consoleAvailability(txStatus, help: "Tune power")
                    .fixedSize()
                LyraRotaryDial("Mic", value: .constant(transmit.micGainDb), in: -40...10, step: 1,
                               accent: LyraDS.Palette.magenta, defaultValue: 0,
                               format: ConsoleFormat.signedDb)
                    .consoleAvailability(txStatus, help: "Microphone gain")
                    .fixedSize()
                LyraRotaryDial("Monitor", value: .constant(transmit.monitorLevel), in: 0...1, step: 0.01,
                               accent: LyraDS.Palette.purple, defaultValue: 0.4,
                               format: { String(format: "%.2f", $0) })
                    .consoleAvailability(txStatus, help: "Transmit monitor level")
                    .fixedSize()
            }
            divider
            if protectionMenu {
                TransmitProtectionMenu(state: protection, monitorTx: monitorTx, feedback: transmit.psFeedback,
                                       status: txStatus)
            } else {
                TransmitProtectionGrid(state: protection, monitorTx: monitorTx, feedback: transmit.psFeedback,
                                       status: txStatus)
            }
            divider
            TransmitMeters(transmit: transmit, live: mox.metersLive, detail: mox.headerDetail)
            divider
            KeyerStrip(keyer: keyer, showCaption: showCaption, status: txStatus,
                       sample: capabilities.status(.keyer) == .mocked)
        }
    }

    private var divider: some View {
        Rectangle().fill(LyraDS.Palette.panelBorder).frame(width: 1).padding(.vertical, 4)
    }
}

/// 92 x 92 MOX key. Lit (filled, glowing) only when the presentation says so.
/// The action is empty until Milestone 5b, so the key is gated on `.transmit`: the live console
/// disables it with the Milestone 5b reason as its only tooltip.
struct MOXButton: View {
    let presentation: MOXPresentation
    let status: CapabilityStatus

    nonisolated static let normalHelp = "Transmit (Space) \u{2014} keys only after the radio confirms"

    /// The key's one tooltip: the unavailability reason while disabled, else how to key.
    nonisolated static func help(_ status: CapabilityStatus) -> String {
        ConsoleAvailability.help(status, normal: normalHelp)
    }

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
        .disabled(ConsoleAvailability.isDisabled(status))
        .help(Self.help(status))
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
    return TransmitDeckView(transmit: s.transmit, keyer: s.keyer, monitorTx: s.audio.monitorTx,
                            capabilities: .allMocked)
        .frame(width: width)
        .padding(8)
        .background(LyraDS.Palette.void)
}
