import SwiftUI

/// Left console column: front end, audio, AGC, noise and DSP. Every engine-owned value renders
/// from the snapshot. The AGC mode, squelch and DSP toggles send commands; the rest has no action
/// yet and is gated on its `ConsoleControl`, so the live console disables it with the reason.
struct ReceiverColumnView: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities, send: @escaping (RadioCommand) -> Void) {
        self.snapshot = snapshot
        self.capabilities = capabilities
        self.send = send
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            ReceiverColumnContent(snapshot: snapshot, capabilities: capabilities, send: send)
        }
        // Both columns overflow at 1280x800: show the scroller and flash it once so the cut-off reads as scrollable.
        .scrollIndicatorsFlash(onAppear: true)
        .frame(width: ConsoleLayout.sideColumnWidth)
    }
}

struct ReceiverColumnContent: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void

    /// Capture length is a local choice made before a capture, not an engine value.
    @State private var captureLength = "5 s"

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities, send: @escaping (RadioCommand) -> Void) {
        self.snapshot = snapshot
        self.capabilities = capabilities
        self.send = send
    }

    /// The AGC selection: read from the focused receiver, written by sending `.setAGC`.
    private var agcSelection: Binding<AGCMode> {
        Binding(get: { snapshot.focusedReceiver.agc }, set: { send(.setAGC($0)) })
    }

    private static func signed(_ v: Double, _ unit: String) -> String {
        String(format: "%+.0f %@", v, unit).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    private var nbOn: Bool { snapshot.dsp.toggles.first { $0.id == "NB" }?.isOn ?? false }
    nonisolated static func balanceText(_ balance: Double) -> String {
        abs(balance) < 0.02 ? "C" : String(format: "%@%.0f", balance < 0 ? "L" : "R", abs(balance) * 100)
    }

    /// The output device menu: reads the engine's device, writes its index.
    private var outputSelection: Binding<String> {
        Binding(
            get: { snapshot.audio.outputDevice },
            set: { name in
                if let index = snapshot.audio.outputDevices.firstIndex(of: name) { send(.setOutputDevice(index)) }
            })
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

    /// Header detail and lamp text for the ADC overload reading; nil is "not reported".
    nonisolated static func overloadText(_ overload: Bool?) -> (detail: String, lamp: String) {
        switch overload {
        case true?: ("Overload", "ADC overload")
        case false?: ("No overload", "ADC ok")
        case nil: ("Overload not reported", "ADC \u{2014}")
        }
    }

    private var frontEnd: some View {
        let fe = snapshot.frontEnd
        let status = capabilities.control(.frontEnd)
        let overload = Self.overloadText(fe.overload)
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Front end", detail: overload.detail)
            ConsoleSliderRow(label: "LNA", help: "LNA gain", value: .constant(Double(fe.lnaDb)),
                             range: Double(fe.lnaRange.lowerBound)...Double(fe.lnaRange.upperBound),
                             step: 1, readout: Self.signed(Double(fe.lnaDb), "dB"), status: status)
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto", help: "Automatic LNA gain", kind: fe.autoLna ? .on : .plain,
                            status: status)
                ConsoleLamp(color: fe.overload == nil ? LyraDS.Palette.textDim
                            : (fe.overload == true ? LyraDS.Palette.pink : LyraDS.Palette.green))
                Text(overload.lamp)
                    .font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                Text("Input").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ForEach(fe.inputs, id: \.self) { name in
                    ConsoleChip(title: name, help: "Input \(name)", kind: fe.selectedInput == name ? .on : .plain,
                                status: status)
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
        let status = capabilities.control(.audio)
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Audio", detail: a.outputDevice)
            ConsoleThrottledSliderRow(
                label: "AF", help: "AF gain, both receivers", value: a.afGainDb, range: 0...40, step: 1,
                readout: { Self.signed($0, "dB") }, status: status) { send(.setAFGain($0)) }
            HStack(spacing: 6) {
                ConsoleThrottledSliderRow(
                    label: "Vol", help: "RX1 volume", value: a.volume, range: 0...1, step: 0.01,
                    readout: { String(format: "%.2f", $0) }, status: status) { send(.setVolume(.main, $0)) }
                ConsoleChip(title: "Mute", help: "Mute RX1", kind: a.muted ? .hot : .plain, status: status) {
                    send(.setMute(.main, !a.muted))
                }
            }
            HStack(spacing: 6) {
                ConsoleThrottledSliderRow(
                    label: "Vol 2", help: "RX2 volume", value: a.volume2, range: 0...1, step: 0.01,
                    readout: { String(format: "%.2f", $0) }, dimmed: subOff, status: status) {
                    send(.setVolume(.sub, $0))
                }
                ConsoleChip(title: "Mute 2", help: "Mute RX2", kind: subOff ? .dim : (a.muted2 ? .hot : .plain),
                            status: status) { send(.setMute(.sub, !a.muted2)) }
            }
            ConsoleThrottledSliderRow(
                label: "Balance", help: "Balance, left to right", value: a.balance, range: -1...1, step: 0.01,
                readout: { Self.balanceText($0) }, tint: LyraDS.Palette.magenta, status: status) {
                send(.setBalance($0))
            }
            HStack(spacing: 5) {
                ConsoleMenuChip(label: "Output", help: "Audio output device",
                                options: a.outputDevices.isEmpty ? [a.outputDevice] : a.outputDevices,
                                selection: outputSelection, status: status)
                ConsoleChip(title: "Binaural", help: "Binaural audio", kind: a.binaural ? .on : .plain,
                            status: status)
                Spacer(minLength: 0)
                ConsoleChip(title: "MON TX", help: "Monitor transmit audio, heard only while keyed",
                            kind: a.monitorTx ? .on : .plain, status: status) { send(.setMonitor(!a.monitorTx)) }
            }
            .padding(.top, 4)
            ConsoleThrottledSliderRow(
                label: "MON", help: "Monitor level, heard only while keyed", value: a.monLevel, range: 0...1,
                step: 0.01, readout: { String(format: "%.2f", $0) }, dimmed: !a.monitorTx, status: status) {
                send(.setMonitorLevel($0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    // MARK: AGC

    private var agcSection: some View {
        let threshold = snapshot.dsp.agcThresholdDbfs.map(Double.init)
        let levels = capabilities.control(.agcLevels)
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("AGC", detail: ConsoleFormat.agcGainDetail(snapshot.dsp.agcGainDb))
            let agcStatus = capabilities.control(.agcMode)
            LyraSegmentedControl("AGC mode", selection: agcSelection, options: AGCMode.allCases,
                                 title: { $0.rawValue }, accent: LyraDS.Palette.cyan,
                                 help: ConsoleAvailability.help(agcStatus, normal: "AGC mode: \(snapshot.focusedReceiver.agc.rawValue)"))
                .disabled(ConsoleAvailability.isDisabled(agcStatus))
            ConsoleSliderRow(label: "Thresh", help: "AGC threshold", value: .constant(threshold ?? -140),
                             range: -140...0, step: 1,
                             readout: threshold.map { Self.signed($0, "dBFS") } ?? "\u{2014}", status: levels)
                .padding(.top, 6)
            HStack(spacing: 5) {
                ConsoleChip(title: "Auto threshold", help: "Set AGC threshold automatically", status: levels)
                Spacer(minLength: 0)
                Text("Squelch").font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                ConsoleChip(title: "SQ", help: "Squelch", kind: snapshot.dsp.squelchOn ? .on : .plain,
                            status: capabilities.control(.dsp(.sq))) { send(.setDSP(.sq, !snapshot.dsp.squelchOn)) }
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
                    let function = DSPFunction(rawValue: t.id)
                    ConsoleChip(title: t.label, help: t.label, kind: t.isOn ? .on : .plain, fullWidth: true,
                                status: function.map { capabilities.control(.dsp($0)) }
                                    ?? .unavailable("No engine control for \(t.label)")) {
                        if let function { send(.setDSP(function, !t.isOn)) }
                    }
                }
            }
            let levels = capabilities.control(.dspLevels)
            let capture = capabilities.control(.noiseCapture)
            ConsoleSliderRow(label: "NR mode", help: "NR mode", value: .constant(Double(d.nrMode)), range: 1...4,
                             step: 1, readout: "\(d.nrMode) of 4", status: levels).padding(.top, 8)
            ConsoleSliderRow(label: "ANF", help: "ANF level", value: .constant(Double(d.anfLevel)), range: 0...100,
                             step: 1, readout: "\(d.anfLevel)", status: levels)
            ConsoleSliderRow(label: "NB", help: "Noise blanker level", value: .constant(Double(d.nbLevel ?? 0)),
                             range: 0...100, step: 1, readout: d.nbLevel.map { "\($0)" } ?? "\u{2014}",
                             dimmed: !nbOn, status: levels)
            HStack(spacing: 5) {
                ConsoleChip(title: "Capture noise", help: "Capture a noise profile", status: capture)
                ConsoleMenuChip(label: captureLength, help: "Capture length", options: ["5 s", "10 s", "20 s"],
                                selection: $captureLength, status: capture)
                ConsoleChip(title: "NR-C", help: "Apply captured noise reduction", status: capture)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }
}

#Preview("Receiver column, full height") {
    ReceiverColumnView(snapshot: .sample, capabilities: .allMocked, send: { _ in })
        .frame(height: 760)
        .background(LyraDS.Palette.void)
}

#Preview("Receiver column, 330 pt") {
    ReceiverColumnView(snapshot: .sample, capabilities: .allMocked, send: { _ in })
        .frame(height: 330)
        .background(LyraDS.Palette.void)
}
