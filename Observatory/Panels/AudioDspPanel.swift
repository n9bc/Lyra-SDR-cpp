import SwiftUI

struct AudioDspPanel: LyraPanel {
    let id = "audio-dsp"
    let title = "Audio / DSP"
    let systemImage = "speaker.wave.3"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { AudioDspPanelContent() }
}

private struct AudioDspPanelContent: View {
    nonisolated init() {}

    @Environment(DspBridge.self) private var dsp
    @Environment(AudioBridge.self) private var audio
    // Sub-settings not yet modelled by the bridges (P0 mock); local until the C++ facade lands.
    @State private var nrMode = "NR1"
    @State private var nbStrength = 0.5

    var body: some View {
        @Bindable var dsp = dsp
        @Bindable var audio = audio
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                GlowRingKnob(value: $audio.afGain, range: 0...100, label: "AF",
                             accentColor: LyraTheme.cyan, size: 88) { String(format: "%.0f", $0) }
                GlowRingKnob(value: $audio.rfGain, range: -40...20, label: "RF",
                             accentColor: LyraTheme.violet, size: 88) { String(format: "%.0f", $0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                IlluminatedToggle(label: "NR", isOn: $dsp.nrEnabled, accentColor: LyraTheme.cyan)
                ModeSelector(modes: ["NR1", "NR2", "NNR"], selected: $nrMode)
            }
            VStack(alignment: .leading, spacing: 4) {
                IlluminatedToggle(label: "NB", isOn: $dsp.nbEnabled, accentColor: LyraTheme.cyan)
                Slider(value: $nbStrength, in: 0...1).disabled(!dsp.nbEnabled)
            }
            IlluminatedToggle(label: "ANF", isOn: $dsp.anfEnabled, accentColor: LyraTheme.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("AGC").font(.system(size: 9, weight: .medium)).tracking(1)
                    .foregroundStyle(LyraTheme.textMuted)
                ModeSelector(modes: ["SLOW", "MED", "FAST", "OFF"], selected: $dsp.agcMode)
            }
        }
    }
}
