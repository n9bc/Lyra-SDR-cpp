import SwiftUI

/// One receiver's VFO panel: header chips, S-meter, mode/AGC, RIT/XIT, frequency, quick toggles.
/// Static in Milestone 1: every button has an empty action.
struct VFOPanelView: View {
    let receiver: ReceiverSnapshot
    let title: String
    /// Drives the TX tag: filled only while on air (spec §5.2).
    let transmitState: TransmitState

    init(receiver: ReceiverSnapshot, title: String, transmitState: TransmitState) {
        self.receiver = receiver
        self.title = title
        self.transmitState = transmitState
    }

    private var on: Bool { receiver.enabled }
    private var isMain: Bool { receiver.id == .main }

    struct SScaleMark: Equatable, Sendable {
        let label: String
        let fraction: Double
    }

    /// Scale labels placed where the (nonlinear) meter puts their S-value: S0 = −127 dBm,
    /// S1…S9 = −121…−73 dBm in 6 dB steps, then +20/+40/+60 dB over S9.
    nonisolated static let sScale: [SScaleMark] = {
        let s9 = -73.0
        var marks = [SScaleMark(label: "S", fraction: ConsoleFormat.meterFraction(dbm: s9 - 54))]
        for n in stride(from: 1, through: 9, by: 2) {
            marks.append(SScaleMark(label: "\(n)", fraction: ConsoleFormat.meterFraction(dbm: s9 - Double(9 - n) * 6)))
        }
        for over in [20, 40, 60] {
            marks.append(SScaleMark(label: "+\(over)", fraction: ConsoleFormat.meterFraction(dbm: s9 + Double(over))))
        }
        return marks
    }()
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
                let digits = geo.size.width - left - 14 - Self.mhzReserve
                HStack(alignment: .top, spacing: 14) {
                    leftColumn.frame(width: left)
                    rightColumn(fontSize: Self.frequencyFontSize(width: digits))
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
                 VFOChipStyle.txTag(isTxVFO: receiver.isTxVFO, state: transmitState))
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
            sScaleRow
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

    /// Labels over the segment meter, each at its S-value's meter fraction. The first and last
    /// are edge-aligned so they stay inside the meter's width.
    private var sScaleRow: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let last = Self.sScale.count - 1
            ZStack(alignment: .leading) {
                ForEach(Array(Self.sScale.enumerated()), id: \.offset) { i, mark in
                    let anchor: CGFloat = i == 0 ? 0 : (i == last ? 1 : 0.5)
                    Text(mark.label)
                        .fixedSize()
                        .foregroundStyle(mark.fraction > 0.6 && on ? LyraDS.Palette.pink
                                         : (on ? LyraDS.Palette.textMuted : LyraDS.Palette.chipDimText))
                        .alignmentGuide(.leading) { d in d.width * anchor - w * mark.fraction }
                }
            }
            .frame(width: w, alignment: .leading)
        }
        .font(mono(10))
        .frame(maxWidth: 262)
        .frame(height: 13)
        .accessibilityHidden(true)
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

    private func rightColumn(fontSize: CGFloat) -> some View {
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
                frequency(fontSize: fontSize)
                Text("MHz").font(mono(12)).foregroundStyle(LyraDS.Palette.textMuted)
                    .fixedSize().layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Frequency sizing

    /// SF Mono digit (and dot) advance, in ems (measured: 0.618).
    nonisolated static let digitAdvanceEm: CGFloat = 0.618
    /// Tracking in ems (-1.24 pt at 62 pt).
    nonisolated static let trackingEm: CGFloat = -0.02
    /// The widest readout the panel must hold (up to 999.999.999, i.e. below 1 GHz).
    nonisolated static let frequencyTemplate = "000.000.000"
    nonisolated static let maxFrequencyFontSize: CGFloat = 62
    nonisolated static let minFrequencyFontSize: CGFloat = 31
    /// "MHz" label (12 pt mono, about 22 pt) plus the 7 pt gap before it.
    nonisolated static let mhzReserve: CGFloat = 30

    /// Width the 11-character template occupies at `fontSize`.
    nonisolated static func frequencyTemplateWidth(fontSize: CGFloat) -> CGFloat {
        CGFloat(frequencyTemplate.count) * fontSize * (digitAdvanceEm + trackingEm)
    }

    /// One font size per available width, sized for the 11-character template so every
    /// frequency (Main, Sub, any band) renders at the same digit size and never jumps when it
    /// crosses 10 or 100 MHz. Capped at 62 pt, floored at 31 pt.
    nonisolated static func frequencyFontSize(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return minFrequencyFontSize }
        let fit = width / frequencyTemplateWidth(fontSize: 1)
        return min(max(fit, minFrequencyFontSize), maxFrequencyFontSize)
    }

    private func frequency(fontSize: CGFloat) -> some View {
        let text = ConsoleFormat.frequency(receiver.frequencyHz)
        // Size comes from the panel width alone (see `frequencyFontSize`), not from the digits,
        // so no scale factor: Main and Sub always match.
        return Text(text)
            .font(.system(size: fontSize, weight: .light, design: .monospaced))
            .tracking(fontSize * Self.trackingEm)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(on ? LyraDS.Palette.freqGlow : LyraDS.Palette.freqSub)
            .shadow(color: on ? LyraDS.Palette.cyan.opacity(0.55) : LyraDS.Palette.purple.opacity(0.25),
                    radius: on ? 9 : 6)
            .shadow(color: on ? LyraDS.Palette.freqGlow.opacity(0.8) : .clear, radius: 1)
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
    VFOPanelView(receiver: RadioSnapshot.sample.main, title: "MAIN \u{00B7} 40M", transmitState: .idle)
        .frame(width: 640, height: ConsoleLayout.vfoRowHeight)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Sub VFO (disabled)") {
    VFOPanelView(receiver: RadioSnapshot.sample.sub, title: "SUB \u{00B7} 20M", transmitState: .idle)
        .frame(width: 640, height: ConsoleLayout.vfoRowHeight)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Main VFO on air") {
    VFOPanelView(receiver: RadioSnapshot.sample.main, title: "MAIN \u{00B7} 40M", transmitState: .onAir)
        .frame(width: 640, height: ConsoleLayout.vfoRowHeight)
        .padding(8).background(LyraDS.Palette.void)
}

#Preview("Main VFO at minimum window") {
    VFOPanelView(receiver: RadioSnapshot.sample.main, title: "MAIN \u{00B7} 40M", transmitState: .idle)
        .frame(width: 529, height: 212)
        .background(LyraDS.Palette.void)
}
