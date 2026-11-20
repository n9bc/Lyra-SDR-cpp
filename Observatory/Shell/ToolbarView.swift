import SwiftUI

/// Large frequency readout, mode selector and Start/Stop.
struct ToolbarView: View {
    @Environment(RadioBridge.self) private var radio
    @Environment(DspBridge.self) private var dsp

    var body: some View {
        @Bindable var dsp = dsp
        HStack(spacing: 16) {
            FrequencyDisplay(frequencyHz: radio.rx1FreqHz, fontSize: 36)
            Rectangle().fill(LyraTheme.border).frame(width: 1, height: 32)
            ModeSelector(modes: ["USB", "LSB", "CW", "AM", "FM"], selected: $dsp.mode)
            Spacer()
            Button {
                if radio.isRunning { radio.stop() } else { radio.start() }
            } label: {
                Text(radio.isRunning ? "STOP" : "START")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButton(isActive: radio.isRunning, accentColor: LyraTheme.cyan)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
