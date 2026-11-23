import SwiftUI

/// Centre VFO column: focus, copy/swap, split, sub receiver, CTUN and lock.
/// MAIN, SUB and SUB RX send commands; the other chips have empty actions until Milestone 3.
struct VFOCenterColumn: View {
    let session: SessionSnapshot
    let sub: ReceiverSnapshot
    /// Split operation as the receivers report it (either VFO transmitting split).
    let splitTx: Bool
    let send: (RadioCommand) -> Void

    init(session: SessionSnapshot, sub: ReceiverSnapshot, splitTx: Bool, send: @escaping (RadioCommand) -> Void) {
        self.session = session
        self.sub = sub
        self.splitTx = splitTx
        self.send = send
    }

    /// The command that focuses `id`, or nil when it cannot be focused (Sub while Sub is off).
    nonisolated static func focusCommand(_ id: ReceiverID, sub: ReceiverSnapshot) -> RadioCommand? {
        id == .sub && !sub.enabled ? nil : .focus(id)
    }

    private func chip(_ label: String, _ help: String, _ kind: VFOChipStyle = .plain,
                      action: @escaping () -> Void = {}) -> some View {
        Button(label, action: action)
            .buttonStyle(VFOChipButtonStyle(kind, fullWidth: true))
            .accessibilityLabel(help)
            .help(help)
    }

    private func row(_ a: some View, _ b: some View) -> some View {
        HStack(spacing: 6) { a; b }
    }

    @ViewBuilder private var subFocusChip: some View {
        let command = Self.focusCommand(.sub, sub: sub)
        let help = command == nil ? "Turn on the sub receiver to focus it" : "Focus the sub receiver"
        Button("SUB") { if let command { send(command) } }
            .buttonStyle(VFOChipButtonStyle(session.focused == .sub ? .cyan : .plain, fullWidth: true))
            .disabled(command == nil)
            .accessibilityLabel(help)
            .help(help)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("\u{2014} VFO \u{2014}")
                .font(.system(size: 11, design: .monospaced))
                .tracking(1.76)
                .foregroundStyle(LyraDS.Palette.textMuted)
                .frame(maxWidth: .infinity)
            row(chip("MAIN", "Focus the main receiver", session.focused == .main ? .cyan : .plain) {
                    if let c = Self.focusCommand(.main, sub: sub) { send(c) }
                },
                subFocusChip)
            row(chip("A \u{2192} B", "Copy VFO A to VFO B"),
                chip("B \u{2192} A", "Copy VFO B to VFO A"))
            row(chip("A \u{21C4} B", "Swap VFO A and VFO B"),
                chip("MEM \u{25BE}", "Open the memory list"))
            chip("SPLIT", "Toggle split operation", splitTx ? .cyan : .plain)
            chip("SUB RX", "Toggle the sub receiver", sub.enabled ? .cyan : .plain) {
                send(.setSubEnabled(!sub.enabled))
            }
            row(chip("CTUN", "Toggle click-to-tune", session.ctunEnabled ? .cyan : .plain),
                chip("LOCK", "Toggle VFO lock", session.vfoLocked ? .cyan : .plain))
        }
        .frame(maxHeight: .infinity)
        .vfoPanel(highlighted: false)
    }
}

#Preview("VFO centre column") {
    VFOCenterColumn(session: RadioSnapshot.sample.session, sub: RadioSnapshot.sample.sub, splitTx: false, send: { _ in })
        .frame(width: ConsoleLayout.vfoCenterWidth, height: ConsoleLayout.vfoRowHeight - 8)
        .padding(8)
        .background(LyraDS.Palette.void)
}
