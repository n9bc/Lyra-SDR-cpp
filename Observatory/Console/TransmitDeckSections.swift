import SwiftUI

/// Protection toggles (ATT on TX, SWR prot, PA cap, MON TX, PS on) plus the PureSignal feedback readout.
/// Local state seeded from the snapshot; the actions do not reach an engine in Milestone 1.
struct TransmitProtectionState: Equatable {
    var attOnTx: Bool
    var swrProtect: Bool
    var paCap: Bool
    var monTx = false
    var psOn: Bool

    init(_ t: TransmitSnapshot) {
        attOnTx = t.attOnTx
        swrProtect = t.swrProtectArmed
        paCap = t.paCapture
        psOn = t.psEnabled
    }
}

struct TransmitProtectionGrid: View {
    @Binding var state: TransmitProtectionState
    let feedback: Int?

    var body: some View {
        LazyVGrid(columns: consoleColumns(2), spacing: 5) {
            toggle("ATT on TX", "Attenuate on transmit", $state.attOnTx, .on)
            toggle("SWR prot", "SWR protection", $state.swrProtect, .armed)
            toggle("PA cap", "PA capture", $state.paCap, .on)
            toggle("MON TX", "Monitor transmit audio", $state.monTx, .on)
            toggle("PS on", "PureSignal", $state.psOn, .on)
            TransmitFeedbackReadout(feedback: feedback)
        }
        .frame(width: 170)
    }

    private func toggle(_ title: String, _ help: String, _ isOn: Binding<Bool>,
                        _ onKind: ConsoleChipStyle) -> some View {
        ConsoleChip(title: title, help: help, kind: isOn.wrappedValue ? onKind : .plain,
                    fullWidth: true) { isOn.wrappedValue.toggle() }
            .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }
}

struct TransmitFeedbackReadout: View {
    let feedback: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text("FB").foregroundStyle(LyraDS.Palette.textMuted)
            Text(feedback.map(String.init) ?? "\u{2014}")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(feedback == nil ? LyraDS.Palette.chipDimText : LyraDS.Palette.green)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LyraDS.Palette.chipFill))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(LyraDS.Palette.chipBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PureSignal feedback level")
        .accessibilityValue(feedback.map(String.init) ?? "not reported")
        .help("PureSignal feedback level")
    }
}

/// Fallback when the deck is too narrow for the protection grid: the same toggles in a menu.
struct TransmitProtectionMenu: View {
    @Binding var state: TransmitProtectionState
    let feedback: Int?

    var body: some View {
        Menu {
            Toggle("ATT on TX", isOn: $state.attOnTx)
            Toggle("SWR prot", isOn: $state.swrProtect)
            Toggle("PA cap", isOn: $state.paCap)
            Toggle("MON TX", isOn: $state.monTx)
            Toggle("PS on", isOn: $state.psOn)
            Text("PS feedback \(feedback.map(String.init) ?? "\u{2014}")")
        } label: {
            HStack(spacing: 5) {
                Text("Protection").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ConsoleChipButtonStyle(.plain))
        .fixedSize()
        .accessibilityLabel("Transmit protection")
        .help("Transmit protection and PureSignal toggles")
    }
}

/// PWR / SWR / ALC / Mic bars. When `live` is false the bars are empty and the readouts are "\u{2014}":
/// sample numbers must never look like measurements from a keyed transmitter.
struct TransmitMeters: View {
    let transmit: TransmitSnapshot
    let live: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConsoleSectionHeader("Transmit", detail: detail).padding(.bottom, 0)
            row("PWR", fraction: transmit.fwdPowerW / 100, readout: String(format: "%.1f W", transmit.fwdPowerW),
                fill: AnyShapeStyle(LyraDS.Palette.pink))
            row("SWR", fraction: (transmit.swr - 1) / 2, readout: String(format: "%.2f", transmit.swr),
                fill: AnyShapeStyle(LyraDS.Palette.green))
            row("ALC", fraction: (transmit.alcDb + 30) / 30, readout: ConsoleFormat.signedDb(transmit.alcDb),
                fill: AnyShapeStyle(LyraDS.Palette.yellow))
            row("Mic", fraction: (transmit.micLevelDb + 60) / 60, readout: ConsoleFormat.signedDb(transmit.micLevelDb),
                fill: AnyShapeStyle(LinearGradient(
                    colors: [LyraDS.Palette.electricBlue, LyraDS.Palette.cyan],
                    startPoint: .leading, endPoint: .trailing)))
        }
        .frame(width: 210)
    }

    private func row(_ label: String, fraction: Double, readout: String, fill: AnyShapeStyle) -> some View {
        let shown = live ? min(max(fraction.isFinite ? fraction : 0, 0), 1) : 0
        let text = live ? readout : "\u{2014}"
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LyraDS.Palette.meterTrack)
                    Capsule().fill(fill).frame(width: geo.size.width * shown)
                }
            }
            .frame(height: 6)
            Text(text).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LyraDS.Palette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    }
}

/// Mode strip: title, optional explanatory caption, Rec / Stop / TX enabled, and a 3-wide clip grid.
struct KeyerStrip: View {
    let keyer: KeyerSnapshot
    let showCaption: Bool
    @Binding var txEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(keyer.title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.99)
                    .foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                if showCaption {
                    Text("changes with mode: CW macros and WPM in CW \u{00B7} repeater and CTCSS in FM")
                        .font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                ConsoleChip(title: "Rec", help: "Record a clip")
                ConsoleChip(title: "Stop", help: "Stop playback or recording")
                ConsoleChip(title: "TX enabled", help: "Allow the keyer to transmit",
                            kind: txEnabled ? .armed : .plain) { txEnabled.toggle() }
                    .accessibilityValue(txEnabled ? "On" : "Off")
            }
            LazyVGrid(columns: consoleColumns(3), spacing: 5) {
                ForEach(keyer.clips) { clip in
                    Button {} label: {
                        HStack(spacing: 5) {
                            Text(clip.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LyraDS.Palette.cyan)
                                .padding(.horizontal, 4)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(LyraDS.Palette.cyan.opacity(0.4), lineWidth: 1))
                            Text(clip.name).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(ConsoleChipButtonStyle(.plain, height: 30, fullWidth: true))
                    .accessibilityLabel("\(clip.key) \(clip.name)")
                    .help("Play \(clip.name) (\(clip.key))")
                }
            }
        }
        .frame(minWidth: 330, maxWidth: .infinity)
    }
}
