import SwiftUI

/// Right console column: band, mode, filter, propagation. Local state only in Milestone 1.
struct BandModeColumnView: View {
    let snapshot: RadioSnapshot

    init(snapshot: RadioSnapshot) { self.snapshot = snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            BandModeColumnContent(snapshot: snapshot)
        }
        .frame(width: ConsoleLayout.sideColumnWidth)
    }
}

struct BandModeColumnContent: View {
    let snapshot: RadioSnapshot

    @State private var tab: String
    @State private var band: String
    @State private var mode: RadioMode
    @State private var preset: String
    @State private var rxLow: String
    @State private var txLow: String
    @State private var bwLocked: Bool
    @State private var txBandwidth: String

    init(snapshot: RadioSnapshot) {
        self.snapshot = snapshot
        _tab = State(initialValue: snapshot.band.selectedTab)
        _band = State(initialValue: snapshot.band.selectedBand)
        _mode = State(initialValue: snapshot.main.mode)
        _preset = State(initialValue: snapshot.filter.selectedPreset)
        _rxLow = State(initialValue: "\(snapshot.filter.rxLowHz) Hz")
        _txLow = State(initialValue: "\(snapshot.filter.txLowHz) Hz")
        _bwLocked = State(initialValue: snapshot.filter.bwLocked)
        _txBandwidth = State(initialValue: snapshot.filter.txBandwidthLabel)
    }

    private static func color(_ q: PropagationQuality) -> Color {
        switch q {
        case .good: LyraDS.Palette.green
        case .fair: LyraDS.Palette.yellow
        case .poor: LyraDS.Palette.pink
        }
    }

    private var txBandwidthOptions: [String] {
        let base = ["2.1 kHz", "2.4 kHz", "2.7 kHz", "3.0 kHz"]
        return base.contains(snapshot.filter.txBandwidthLabel) ? base : [snapshot.filter.txBandwidthLabel] + base
    }

    var body: some View {
        VStack(spacing: ConsoleLayout.gap) {
            bandSection
            modeSection
            filterSection
            propagationSection
        }
        .frame(width: ConsoleLayout.sideColumnWidth)
    }

    private var bandSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Band", detail: Int(band) != nil ? "\(band) m" : band)
            HStack(spacing: 4) {
                ForEach(snapshot.band.tabs, id: \.self) { name in
                    ConsoleChip(title: name, help: "\(name) bands", kind: tab == name ? .on : .plain,
                                height: 22, fullWidth: true) { tab = name }
                }
            }
            .padding(.bottom, 7)
            LazyVGrid(columns: consoleColumns(4), spacing: 5) {
                ForEach(snapshot.band.bands, id: \.self) { name in
                    ConsoleChip(title: name, help: "Band \(name)", kind: band == name ? .on : .plain,
                                fullWidth: true) { band = name }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Mode", detail: mode.rawValue)
            LazyVGrid(columns: consoleColumns(5), spacing: 5) {
                ForEach(RadioMode.allCases, id: \.self) { m in
                    ConsoleChip(title: m.rawValue, help: "Mode \(m.rawValue)", kind: mode == m ? .on : .plain,
                                fullWidth: true) { mode = m }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private func field(_ text: Binding<String>, _ help: String) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(LyraDS.Palette.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LyraDS.Palette.barFill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LyraDS.Palette.chipBorder, lineWidth: 1))
            .accessibilityLabel(help)
            .help(help)
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Filter", detail: String(format: "RX %.1f kHz", Double(snapshot.main.filterHz) / 1000))
            LazyVGrid(columns: consoleColumns(4), spacing: 5) {
                ForEach(snapshot.filter.presets, id: \.self) { name in
                    ConsoleChip(title: name, help: "Filter \(name)", kind: preset == name ? .on : .plain,
                                fullWidth: true) { preset = name }
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    fieldLabel("RX lo").frame(width: 44, alignment: .leading)
                    field($rxLow, "RX low cut")
                    fieldLabel("TX lo").frame(width: 44, alignment: .leading)
                    field($txLow, "TX low cut")
                }
            }
            .padding(.top, 8)
            HStack(spacing: 5) {
                Button { bwLocked.toggle() } label: {
                    HStack(spacing: 5) { Image(systemName: "link").font(.system(size: 11)); Text("BW lock") }
                }
                .buttonStyle(ConsoleChipButtonStyle(bwLocked ? .on : .plain))
                .accessibilityLabel("Lock TX bandwidth to RX")
                .help("Lock TX bandwidth to RX")
                Spacer(minLength: 0)
                fieldLabel("TX BW")
                ConsoleMenuChip(label: txBandwidth, help: "TX bandwidth", options: txBandwidthOptions,
                                selection: $txBandwidth)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private var propagationSection: some View {
        let p = snapshot.propagation
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Propagation", detail: "Follow off")
            HStack(spacing: 14) {
                ForEach([("SFI", p.sfi), ("A", p.aIndex), ("K", p.kIndex)], id: \.0) { item in
                    HStack(spacing: 4) {
                        Text(item.0).foregroundStyle(LyraDS.Palette.textMuted)
                        Text("\(item.1)").foregroundStyle(LyraDS.Palette.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(.bottom, 8)
            LazyVGrid(columns: consoleColumns(5), spacing: 5) {
                ForEach(p.bands, id: \.band) { c in
                    let color = Self.color(c.quality)
                    Button {} label: {
                        VStack(spacing: 0) {
                            Text(c.band).font(.system(size: 11))
                            Text(c.quality.rawValue).font(.system(size: 11)).foregroundStyle(color)
                        }
                        .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .buttonStyle(ConsoleChipButtonStyle(.plain, height: 30, fullWidth: true))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color, lineWidth: 1))
                    .accessibilityLabel("\(c.band) metre propagation \(c.quality.rawValue)")
                    .help("\(c.band) m: \(c.quality.rawValue)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }
}

#Preview("Band and mode column, full height") {
    BandModeColumnView(snapshot: .sample)
        .frame(height: 760)
        .background(LyraDS.Palette.void)
}

#Preview("Band and mode column, 330 pt") {
    BandModeColumnView(snapshot: .sample)
        .frame(height: 330)
        .background(LyraDS.Palette.void)
}
