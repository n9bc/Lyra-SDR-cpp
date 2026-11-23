import SwiftUI

/// Left console column: front end, audio, AGC, noise and DSP. Every engine-owned value renders
/// from the snapshot; actions are empty in Milestone 1.
struct ReceiverColumnView: View {
    let snapshot: RadioSnapshot

    init(snapshot: RadioSnapshot) { self.snapshot = snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ReceiverColumnContent(snapshot: snapshot)
        }
        .frame(width: ConsoleLayout.sideColumnWidth)
    }
}

struct ReceiverColumnContent: View {
    let snapshot: RadioSnapshot

    /// Capture length is a local choice made before a capture, not an engine value.
    @State private var captureLength = "5 s"

    init(snapshot: RadioSnapshot) {
        self.snapshot = snapshot
    }

    private static func signed(_ v: Double, _ unit: String) -> String {
        String(format: "%+.0f %@", v, unit).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    private var nbOn: Bool { snapshot.dsp.toggles.first { $0.label == "NB" }?.isOn ?? false }
    private var balanceText: String {
        let balance = snapshot.audio.balance
        return abs(balance) < 0.02 ? "C" : String(format: "%@%.0f", balance < 0 ? "L" : "R", abs(balance) * 100)
    }

    var body: some View {
        VStack(spacing: ConsoleLayout.gap) {
            frontEnd
            audio
            agcSection
            dsp
        }
        .frame(width: ConsoleLayout.sideColumnWidth)
    }

    // MARK: Front end

    private var frontEnd: some View {
        let fe = snapshot.frontEnd
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Front end", detail: fe.overload ? "Overload" : "No overload")
            ConsoleSliderRow(label: "LNA", help: "LNA gain", value: .constant(Double(fe.lnaDb)),
                             range: Double(fe.lnaRange.lowerBound)...Double(fe.lnaRange.upperBound),
                             step: 1, readout: Self.signed(Double(fe.lnaDb), "dB"))
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto", help: "Automatic LNA gain", kind: fe.autoLna ? .on : .plain)
                ConsoleLamp(color: fe.overload ? LyraDS.Palette.pink : LyraDS.Palette.green)
                Text(fe.overload ? "ADC overload" : "ADC ok")
                    .font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                Text("Input").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ForEach(fe.inputs, id: \.self) { name in
                    ConsoleChip(title: name, help: "Input \(name)", kind: fe.selectedInput == name ? .on : .plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: Audio

    private var audio: some View {
        let a = snapshot.audio
        let subOff = !snapshot.sub.enabled
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Audio", detail: a.outputDevice)
            ConsoleSliderRow(label: "AF", help: "AF gain", value: .constant(a.afGainDb), range: -20...60, step: 1,
                             readout: Self.signed(a.afGainDb, "dB"))
            HStack(spacing: 6) {
                ConsoleSliderRow(label: "Vol", help: "RX1 volume", value: .constant(a.volume), range: 0...1,
                                 step: 0.01, readout: String(format: "%.2f", a.volume))
                ConsoleChip(title: "Mute", help: "Mute RX1", kind: a.muted ? .hot : .plain)
            }
            HStack(spacing: 6) {
                ConsoleSliderRow(label: "Vol 2", help: "RX2 volume", value: .constant(a.volume2), range: 0...1,
                                 step: 0.01, readout: String(format: "%.2f", a.volume2), dimmed: subOff)
                ConsoleChip(title: "Mute 2", help: "Mute RX2", kind: subOff ? .dim : (a.muted2 ? .hot : .plain))
            }
            ConsoleSliderRow(label: "Balance", help: "Balance", value: .constant(a.balance), range: -1...1,
                             step: 0.01, readout: balanceText, tint: LyraDS.Palette.magenta)
            HStack(spacing: 5) {
                ConsoleMenuChip(label: "Output", help: "Audio output device", options: [a.outputDevice],
                                selection: .constant(a.outputDevice))
                ConsoleChip(title: "Binaural", help: "Binaural audio", kind: a.binaural ? .on : .plain)
                Spacer(minLength: 0)
                ConsoleChip(title: "MON TX", help: "Monitor transmit audio", kind: a.monitorTx ? .on : .plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: AGC

    private var agcSection: some View {
        let threshold = Double(snapshot.dsp.agcThresholdDbfs)
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("AGC", detail: ConsoleFormat.focusDetail("Gain \(snapshot.dsp.agcGainDb) dB",
                                                                         focused: snapshot.session.focused))
            LyraSegmentedControl("AGC mode", selection: .constant(snapshot.focusedReceiver.agc), options: AGCMode.allCases,
                                 title: { $0.rawValue }, accent: LyraDS.Palette.cyan)
            ConsoleSliderRow(label: "Thresh", help: "AGC threshold", value: .constant(threshold), range: -140...0,
                             step: 1, readout: Self.signed(threshold, "dBFS"))
                .padding(.top, 6)
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto threshold", help: "Set AGC threshold automatically")
                Spacer(minLength: 0)
                Text("Squelch").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ConsoleChip(title: "SQ", help: "Squelch", kind: snapshot.dsp.squelchOn ? .on : .plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: Noise and DSP

    private var dsp: some View {
        let d = snapshot.dsp
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Noise and DSP", detail: "\(d.notchCount) notches")
            LazyVGrid(columns: consoleColumns(5), spacing: 5) {
                ForEach(d.toggles) { t in
                    ConsoleChip(title: t.label, help: t.label, kind: t.isOn ? .on : .plain, fullWidth: true)
                }
            }
            ConsoleSliderRow(label: "NR mode", help: "NR mode", value: .constant(Double(d.nrMode)), range: 1...4,
                             step: 1, readout: "\(d.nrMode) of 4").padding(.top, 8)
            ConsoleSliderRow(label: "ANF", help: "ANF level", value: .constant(Double(d.anfLevel)), range: 0...100,
                             step: 1, readout: "\(d.anfLevel)")
            ConsoleSliderRow(label: "NB", help: "Noise blanker level", value: .constant(Double(d.nbLevel)),
                             range: 0...100, step: 1, readout: "\(d.nbLevel)", dimmed: !nbOn)
            HStack(spacing: 5) {
                ConsoleChip(title: "Capture noise", help: "Capture a noise profile")
                ConsoleMenuChip(label: captureLength, help: "Capture length", options: ["5 s", "10 s", "20 s"],
                                selection: $captureLength)
                ConsoleChip(title: "NR-C", help: "Apply captured noise reduction")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }
}

#Preview("Receiver column, full height") {
    ReceiverColumnView(snapshot: .sample)
        .frame(height: 760)
        .background(LyraDS.Palette.void)
}

#Preview("Receiver column, 330 pt") {
    ReceiverColumnView(snapshot: .sample)
        .frame(height: 330)
        .background(LyraDS.Palette.void)
}
