import SwiftUI

/// Large frequency readout, mode selector and Start/Stop.
struct ToolbarView: View {
    @Environment(RadioBridge.self) private var radio
    @Environment(DspBridge.self) private var dsp
    @Environment(AudioBridge.self) private var audio

    var body: some View {
        @Bindable var dsp = dsp
        HStack(spacing: 16) {
            FrequencyDisplay(frequencyHz: radio.rx1FreqHz, fontSize: 36)
            Rectangle().fill(LyraTheme.border).frame(width: 1, height: 32)
            ModeSelector(modes: ["USB", "LSB", "CW", "AM", "FM"], selected: Binding(get: { dsp.mode }, set: { dsp.setMode($0) }))
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
            .keyboardShortcut("s", modifiers: .command)
            Button("Mute") { audio.toggleMute() }
                .keyboardShortcut("m", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
