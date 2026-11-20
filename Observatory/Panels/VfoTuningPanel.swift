import SwiftUI

struct VfoTuningPanel: LyraPanel {
    let id = "vfo-tuning"
    let title = "VFO / Tuning"
    let systemImage = "dial.min"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { VfoTuningPanelContent() }
}

private struct VfoTuningPanelContent: View {
    nonisolated init() {}

    @Environment(RadioBridge.self) private var radio
    // RIT/XIT are not yet modelled by RadioBridge (P0 mock); held locally until the C++ facade lands.
    @State private var ritOn = false
    @State private var xitOn = false
    @State private var ritHz = 0
    @State private var xitHz = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            vfoRow("VFO A", hz: radio.rx1FreqHz)
            if radio.splitEnabled { vfoRow("VFO B", hz: radio.vfoBHz) }

            HStack(spacing: 8) {
                Button("A↔B") { swapVfos() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassButton()
                Button("A→B") { radio.setVfoBFrequency(radio.rx1FreqHz) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassButton()
            }
            .font(.system(size: 10, weight: .semibold))

            offsetRow("RIT", isOn: $ritOn, hz: $ritHz)
            offsetRow("XIT", isOn: $xitOn, hz: $xitHz)
        }
    }

    private func swapVfos() {
        let a = radio.rx1FreqHz
        radio.setFrequency(radio.vfoBHz)
        radio.setVfoBFrequency(a)
    }

    private func vfoRow(_ name: String, hz: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 9, weight: .medium)).tracking(1)
                .foregroundStyle(LyraTheme.textMuted)
            FrequencyDisplay(frequencyHz: hz, fontSize: 26)
        }
    }

    private func offsetRow(_ label: String, isOn: Binding<Bool>, hz: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            IlluminatedToggle(label: label, isOn: isOn, accentColor: LyraTheme.amber)
            TextField("Hz", value: hz, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 70)
                .disabled(!isOn.wrappedValue)
            Text("Hz").font(.system(size: 9)).foregroundStyle(LyraTheme.textMuted)
        }
    }
}
