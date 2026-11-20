import SwiftUI

/// Gain/squelch knobs, DSP toggles and filter-width pills.
struct ControlStripView: View {
    @Environment(DspBridge.self) private var dsp
    @Environment(AudioBridge.self) private var audio

    /// Filter-width pills for the current mode.
    private var widths: [(label: String, hz: Int)] {
        switch dsp.mode {
        case "CW", "CWL", "CWU":
            return [("200", 200), ("300", 300), ("500", 500), ("800", 800), ("1k", 1000)]
        case "AM", "SAM":
            return [("4k", 4000), ("6k", 6000), ("8k", 8000), ("10k", 10000)]
        case "FM", "FMN":
            return [("8k", 8000), ("12k", 12000), ("16k", 16000)]
        default:
            return [("1.8k", 1800), ("2.4k", 2400), ("2.7k", 2700), ("3.0k", 3000), ("3.3k", 3300)]
        }
    }

    var body: some View {
        @Bindable var dsp = dsp
        @Bindable var audio = audio
        HStack(spacing: 20) {
            GlowRingKnob(value: $audio.afGain, range: 0...100, label: "AF GAIN",
                         accentColor: LyraTheme.cyan) { String(format: "%.0f", $0) }
            GlowRingKnob(value: $audio.rfGain, range: -20...60, label: "RF GAIN",
                         accentColor: LyraTheme.amber) { String(format: "%.0f", $0) }
            GlowRingKnob(value: $dsp.squelchThreshold, range: -140...0, label: "SQUELCH",
                         accentColor: LyraTheme.violet) { String(format: "%.0f", $0) }
            Rectangle().fill(LyraTheme.border).frame(width: 1, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IlluminatedToggle(label: "NR", isOn: $dsp.nrEnabled, accentColor: LyraTheme.cyan)
                    IlluminatedToggle(label: "NB", isOn: $dsp.nbEnabled, accentColor: LyraTheme.cyan)
                    IlluminatedToggle(label: "ANF", isOn: $dsp.anfEnabled, accentColor: LyraTheme.cyan)
                    IlluminatedToggle(label: "AGC", isOn: agcBinding, accentColor: LyraTheme.amber)
                }
                HStack(spacing: 6) {
                    ForEach(widths, id: \.hz) { width in
                        BandChip(label: width.label, isActive: dsp.bandwidth == width.hz) {
                            dsp.setBandwidth(width.hz)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard()
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// AGC is a mode string ("OFF"/"MED"/...); the toggle treats anything but OFF as on.
    private var agcBinding: Binding<Bool> {
        Binding(get: { dsp.agcMode != "OFF" },
                set: { dsp.setAgcMode($0 ? "MED" : "OFF") })
    }
}
