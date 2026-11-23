import SwiftUI

/// Left console column: front end, audio, AGC, noise and DSP. Local state only in Milestone 1.
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

    @State private var lna: Double
    @State private var autoLna: Bool
    @State private var input: String
    @State private var af: Double
    @State private var volume: Double
    @State private var muted: Bool
    @State private var volume2: Double
    @State private var muted2: Bool
    @State private var balance: Double
    @State private var output: String
    @State private var binaural: Bool
    @State private var monitorTx: Bool
    @State private var agc: AGCMode
    @State private var threshold: Double
    @State private var squelch: Bool
    @State private var toggles: [QuickToggle]
    @State private var nrMode: Double
    @State private var anf: Double
    @State private var nb: Double
    @State private var captureLength = "5 s"

    init(snapshot: RadioSnapshot) {
        self.snapshot = snapshot
        _lna = State(initialValue: Double(snapshot.frontEnd.lnaDb))
        _autoLna = State(initialValue: snapshot.frontEnd.autoLna)
        _input = State(initialValue: snapshot.frontEnd.selectedInput)
        _af = State(initialValue: snapshot.audio.afGainDb)
        _volume = State(initialValue: snapshot.audio.volume)
        _muted = State(initialValue: snapshot.audio.muted)
        _volume2 = State(initialValue: snapshot.audio.volume2)
        _muted2 = State(initialValue: snapshot.audio.muted2)
        _balance = State(initialValue: snapshot.audio.balance)
        _output = State(initialValue: snapshot.audio.outputDevice)
        _binaural = State(initialValue: snapshot.audio.binaural)
        _monitorTx = State(initialValue: snapshot.audio.monitorTx)
        _agc = State(initialValue: snapshot.main.agc)
        _threshold = State(initialValue: Double(snapshot.dsp.agcThresholdDbfs))
        _squelch = State(initialValue: snapshot.dsp.squelchOn)
        _toggles = State(initialValue: snapshot.dsp.toggles)
        _nrMode = State(initialValue: Double(snapshot.dsp.nrMode))
        _anf = State(initialValue: Double(snapshot.dsp.anfLevel))
        _nb = State(initialValue: Double(snapshot.dsp.nbLevel))
    }

    private static func signed(_ v: Double, _ unit: String) -> String {
        String(format: "%+.0f %@", v, unit).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    private var nbOn: Bool { toggles.first { $0.label == "NB" }?.isOn ?? false }
    private var balanceText: String {
        abs(balance) < 0.02 ? "C" : String(format: "%@%.0f", balance < 0 ? "L" : "R", abs(balance) * 100)
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
            ConsoleSliderRow(label: "LNA", help: "LNA gain", value: $lna,
                             range: Double(fe.lnaRange.lowerBound)...Double(fe.lnaRange.upperBound),
                             step: 1, readout: Self.signed(lna, "dB"))
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto", help: "Automatic LNA gain", kind: autoLna ? .on : .plain) { autoLna.toggle() }
                ConsoleLamp(color: fe.overload ? LyraDS.Palette.pink : LyraDS.Palette.green)
                Text(fe.overload ? "ADC overload" : "ADC ok")
                    .font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                Text("Input").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ForEach(fe.inputs, id: \.self) { name in
                    ConsoleChip(title: name, help: "Input \(name)", kind: input == name ? .on : .plain) { input = name }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: Audio

    private var audio: some View {
        let subOff = !snapshot.sub.enabled
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Audio", detail: output)
            ConsoleSliderRow(label: "AF", help: "AF gain", value: $af, range: -20...60, step: 1,
                             readout: Self.signed(af, "dB"))
            HStack(spacing: 6) {
                ConsoleSliderRow(label: "Vol", help: "RX1 volume", value: $volume, range: 0...1, step: 0.01,
                                 readout: String(format: "%.2f", volume))
                ConsoleChip(title: "Mute", help: "Mute RX1", kind: muted ? .hot : .plain) { muted.toggle() }
            }
            HStack(spacing: 6) {
                ConsoleSliderRow(label: "Vol 2", help: "RX2 volume", value: $volume2, range: 0...1, step: 0.01,
                                 readout: String(format: "%.2f", volume2), dimmed: subOff)
                ConsoleChip(title: "Mute 2", help: "Mute RX2", kind: subOff ? .dim : (muted2 ? .hot : .plain)) { muted2.toggle() }
            }
            ConsoleSliderRow(label: "Balance", help: "Balance", value: $balance, range: -1...1, step: 0.01,
                             readout: balanceText, tint: LyraDS.Palette.magenta)
            HStack(spacing: 5) {
                ConsoleMenuChip(label: "Output", help: "Audio output device", options: [snapshot.audio.outputDevice],
                                selection: $output)
                ConsoleChip(title: "Binaural", help: "Binaural audio", kind: binaural ? .on : .plain) { binaural.toggle() }
                Spacer(minLength: 0)
                ConsoleChip(title: "MON TX", help: "Monitor transmit audio", kind: monitorTx ? .on : .plain) { monitorTx.toggle() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: AGC

    private var agcSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("AGC", detail: "Gain \(snapshot.dsp.agcGainDb) dB")
            LyraSegmentedControl("AGC mode", selection: $agc, options: AGCMode.allCases, title: { $0.rawValue },
                                 accent: LyraDS.Palette.cyan)
            ConsoleSliderRow(label: "Thresh", help: "AGC threshold", value: $threshold, range: -140...0, step: 1,
                             readout: Self.signed(threshold, "dBFS"))
                .padding(.top, 6)
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto threshold", help: "Set AGC threshold automatically")
                Spacer(minLength: 0)
                Text("Squelch").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ConsoleChip(title: "SQ", help: "Squelch", kind: squelch ? .on : .plain) { squelch.toggle() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: Noise and DSP

    private var dsp: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Noise and DSP", detail: "\(snapshot.dsp.notchCount) notches")
            LazyVGrid(columns: consoleColumns(5), spacing: 5) {
                ForEach($toggles) { $t in
                    ConsoleChip(title: t.label, help: t.label, kind: t.isOn ? .on : .plain, fullWidth: true) { t.isOn.toggle() }
                }
            }
            ConsoleSliderRow(label: "NR mode", help: "NR mode", value: $nrMode, range: 1...4, step: 1,
                             readout: "\(Int(nrMode)) of 4").padding(.top, 8)
            ConsoleSliderRow(label: "ANF", help: "ANF level", value: $anf, range: 0...100, step: 1,
                             readout: "\(Int(anf))")
            ConsoleSliderRow(label: "NB", help: "Noise blanker level", value: $nb, range: 0...100, step: 1,
                             readout: "\(Int(nb))", dimmed: !nbOn)
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
