import SwiftUI

/// One receiver's VFO panel: header chips, S-meter, mode/AGC, RIT/XIT, frequency, quick toggles.
/// Static in Milestone 1: every button has an empty action.
struct VFOPanelView: View {
    let receiver: ReceiverSnapshot
    let title: String

    init(receiver: ReceiverSnapshot, title: String) {
        self.receiver = receiver
        self.title = title
    }

    private var on: Bool { receiver.enabled }
    private var isMain: Bool { receiver.id == .main }

    private static let sLabels = ["S", "1", "3", "5", "7", "9", "+20", "+40", "+60"]
    /// Placeholder zero-beat marker position (sample data has no tuning-error field yet).
    private static let zeroBeatPosition = 0.46

    private func chip(_ label: String, _ help: String, _ kind: VFOChipStyle = .plain) -> some View {
        Button(label) {}
            .buttonStyle(VFOChipButtonStyle(kind))
            .accessibilityLabel(help)
            .help(help)
    }

    private func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    private var filterText: String { String(format: "%.1fk", Double(receiver.filterHz) / 1000) }

    private var readout: String {
        guard on else { return "Sub receiver off" }
        var s = String(format: "%.1f", receiver.signalDbm).replacingOccurrences(of: "-", with: "\u{2212}")
        s += " dBm"
        if let snr = receiver.snrDb { s += " \u{00B7} SNR \(Int(snr.rounded())) dB" }
        return s
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            GeometryReader { geo in
                let left = min(290, max(230, geo.size.width - 350))
                HStack(alignment: .top, spacing: 14) {
                    leftColumn.frame(width: left)
                    rightColumn
                }
            }
            .frame(maxHeight: .infinity)
            toggleRow
        }
        .vfoPanel(highlighted: isMain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            chip(receiver.isTxVFO ? "TX" : "RX",
                 receiver.isTxVFO ? "Transmit VFO" : "Receive-only VFO",
                 receiver.isTxVFO ? .tx : .plain)
            chip(receiver.antenna, "Select antenna input")
            chip("BW \(filterText.uppercased())", "Set filter bandwidth")
            chip("STEP \(receiver.stepHz)", "Set tuning step")
            Spacer(minLength: 0)
            Text(title)
                .font(mono(13)).tracking(1.82).lineLimit(1)
                .foregroundStyle(isMain ? LyraDS.Palette.textPrimary : LyraDS.Palette.textMuted)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(Array(Self.sLabels.enumerated()), id: \.offset) { i, label in
                    if i > 0 { Spacer(minLength: 0) }
                    Text(label)
                        .foregroundStyle(i >= 6 && on ? LyraDS.Palette.pink : (on ? LyraDS.Palette.textMuted : LyraDS.Palette.chipDimText))
                }
            }
            .font(mono(11))
            .frame(maxWidth: 262)
            SegmentMeterView(dbm: receiver.signalDbm, enabled: on)
            Text(readout).font(mono(11)).lineLimit(1)
                .foregroundStyle(on ? LyraDS.Palette.textMuted : LyraDS.Palette.chipDimText)
            HStack(spacing: 7) {
                Text("VFO").font(mono(12)).tracking(0.96).foregroundStyle(LyraDS.Palette.textMuted)
                Text(isMain ? "A" : "B").font(mono(17))
                    .foregroundStyle(on ? LyraDS.Palette.textPrimary : LyraDS.Palette.chipText)
                chip(receiver.mode.rawValue, "Select mode", on ? .cyan : .plain)
                Text("FIL").font(mono(12)).tracking(0.96).foregroundStyle(LyraDS.Palette.textMuted)
                Text(filterText).font(mono(14))
                    .foregroundStyle(on ? LyraDS.Palette.textPrimary : LyraDS.Palette.chipText)
            }
            .padding(.top, 4)
            HStack(spacing: 7) {
                chip("AGC \(receiver.agc.rawValue.uppercased())", "Select AGC mode", on ? .cyan : .plain)
                if on {
                    chip("ZERO BEAT", "Zero-beat the received signal")
                    zeroBeatBar
                }
            }
        }
    }

    private var zeroBeatBar: some View {
        Capsule().fill(LyraDS.Palette.zeroBeatTrack)
            .frame(width: 54, height: 5)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(LyraDS.Palette.green)
                    .frame(width: 3, height: 11)
                    .shadow(color: LyraDS.Palette.green, radius: 3)
                    .offset(x: 54 * Self.zeroBeatPosition)
            }
            .accessibilityHidden(true)
    }

    private func ghost(_ label: String, _ value: String, lit: Bool, help: String) -> some View {
        Button {} label: {
            HStack(spacing: 6) {
                Text(label).frame(width: 70, alignment: .trailing)
                Text(value).frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.72)
            .foregroundStyle(lit ? LyraDS.Palette.cyan : LyraDS.Palette.chipDimText)
            .shadow(color: lit ? LyraDS.Palette.cyan.opacity(0.5) : .clear, radius: 4)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    ghost("RIT", ConsoleFormat.offsetKHz(receiver.ritOffsetHz), lit: receiver.ritEnabled,
                          help: "Toggle receive incremental tuning")
                    ghost("XIT", ConsoleFormat.offsetKHz(receiver.xitOffsetHz), lit: receiver.xitEnabled,
                          help: "Toggle transmit incremental tuning")
                    ghost("SPLIT TX", receiver.splitTx ? "ON" : "\u{2014}", lit: receiver.splitTx,
                          help: "Toggle split transmit")
                }
                Text(on ? ConsoleFormat.sUnits(dbm: receiver.signalDbm) : "S0")
                    .font(mono(15)).lineLimit(1)
                    .foregroundStyle(on ? LyraDS.Palette.yellow : LyraDS.Palette.chipDimText)
                    .shadow(color: on ? LyraDS.Palette.yellow.opacity(0.45) : .clear, radius: 4)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(on ? LyraDS.Palette.sBoxBorder : LyraDS.Palette.sBoxBorderOff, lineWidth: 1))
                    .accessibilityLabel("S-unit reading")
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                frequency
                Text("MHz").font(mono(12)).foregroundStyle(LyraDS.Palette.textMuted)
                    .fixedSize().layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var frequency: some View {
        let text = ConsoleFormat.frequency(receiver.frequencyHz)
        // Hidden template of the same digit count keeps the frame steady as digits change.
        let template = String(text.map { $0 == "." ? "." : "0" })
        let font = Font.system(size: 62, weight: .light, design: .monospaced)
        return ZStack(alignment: .trailing) {
            Text(template).hidden()
            Text(text)
                .foregroundStyle(on ? LyraDS.Palette.freqGlow : LyraDS.Palette.freqSub)
                .shadow(color: on ? LyraDS.Palette.cyan.opacity(0.55) : LyraDS.Palette.purple.opacity(0.25),
                        radius: on ? 9 : 6)
                .shadow(color: on ? LyraDS.Palette.freqGlow.opacity(0.8) : .clear, radius: 1)
        }
        .font(font).tracking(-1.24)
        .lineLimit(1).minimumScaleFactor(0.5)
        .accessibilityElement()
        .accessibilityLabel("Frequency")
        .accessibilityValue("\(text) megahertz")
    }

    private var toggleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(receiver.quickToggles) { t in
                    chip(t.label, "Toggle \(t.label)", t.isOn && on ? .active : .plain)
                }
            }
        }
        .frame(height: 22)
    }
}

#Preview("Main VFO") {
    VFOPanelView(receiver: RadioSnapshot.sample.main, title: "MAIN \u{00B7} 40M")
        .frame(width: 640, height: ConsoleLayout.vfoRowHeight)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Sub VFO (disabled)") {
    VFOPanelView(receiver: RadioSnapshot.sample.sub, title: "SUB \u{00B7} 20M")
        .frame(width: 640, height: ConsoleLayout.vfoRowHeight)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Main VFO at minimum window") {
    VFOPanelView(receiver: RadioSnapshot.sample.main, title: "MAIN \u{00B7} 40M")
        .frame(width: 529, height: 212)
        .background(LyraDS.Palette.void)
}
