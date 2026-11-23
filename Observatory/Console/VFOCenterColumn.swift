import SwiftUI

/// Centre VFO column: focus, copy/swap, split, sub receiver, CTUN and lock.
/// Actions are empty in Milestone 1 (static console).
struct VFOCenterColumn: View {
    let session: SessionSnapshot
    let sub: ReceiverSnapshot

    init(session: SessionSnapshot, sub: ReceiverSnapshot) {
        self.session = session
        self.sub = sub
    }

    private func chip(_ label: String, _ help: String, _ kind: VFOChipStyle = .plain) -> some View {
        Button(label) {}
            .buttonStyle(VFOChipButtonStyle(kind, fullWidth: true))
            .accessibilityLabel(help)
            .help(help)
    }

    private func row(_ a: some View, _ b: some View) -> some View {
        HStack(spacing: 6) { a; b }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("\u{2014} VFO \u{2014}")
                .font(.system(size: 11, design: .monospaced))
                .tracking(1.76)
                .foregroundStyle(LyraDS.Palette.textMuted)
                .frame(maxWidth: .infinity)
            row(chip("MAIN", "Focus the main receiver", session.focused == .main ? .cyan : .plain),
                chip("SUB", "Focus the sub receiver", session.focused == .sub ? .cyan : .plain))
            row(chip("A \u{2192} B", "Copy VFO A to VFO B"),
                chip("B \u{2192} A", "Copy VFO B to VFO A"))
            row(chip("A \u{21C4} B", "Swap VFO A and VFO B"),
                chip("MEM \u{25BE}", "Open the memory list"))
            chip("SPLIT", "Toggle split operation")
            chip("SUB RX", "Toggle the sub receiver", sub.enabled ? .cyan : .plain)
            row(chip("CTUN", "Toggle click-to-tune", session.ctunEnabled ? .cyan : .plain),
                chip("LOCK", "Toggle VFO lock", session.vfoLocked ? .cyan : .plain))
        }
        .frame(maxHeight: .infinity)
        .vfoPanel(highlighted: false)
    }
}

#Preview("VFO centre column") {
    VFOCenterColumn(session: RadioSnapshot.sample.session, sub: RadioSnapshot.sample.sub)
        .frame(width: ConsoleLayout.vfoCenterWidth, height: ConsoleLayout.vfoRowHeight - 8)
        .padding(8)
        .background(LyraDS.Palette.void)
}
