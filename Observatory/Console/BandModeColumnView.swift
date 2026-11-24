import SwiftUI

/// Right console column: band, mode, filter, propagation. Engine-owned selections render from the
/// snapshot; only the band-list tab is local view state. Band, mode, filter and BW lock send commands.
struct BandModeColumnView: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities, send: @escaping (RadioCommand) -> Void) {
        self.snapshot = snapshot
        self.capabilities = capabilities
        self.send = send
    }

    /// Propagation header detail: "Sample" while only this feed is sample data (when the whole
    /// console is sample data the status bar badge already says so).
    nonisolated static func propagationDetail(_ capabilities: BackendCapabilities) -> String {
        capabilities.status(.propagation) == .mocked && capabilities.status(.connection) != .mocked
            ? "Sample" : "Follow off"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            BandModeColumnContent(snapshot: snapshot, capabilities: capabilities, send: send)
        }
        // Both columns overflow at 1280x800: show the scroller and flash it once so the cut-off reads as scrollable.
        .scrollIndicatorsFlash(onAppear: true)
        .frame(width: ConsoleLayout.sideColumnWidth)
    }
}

struct BandModeColumnContent: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void

    /// Which band list is shown (Ham, BC, Gen…) is presentation only, so it stays local.
    @State private var tab: String

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities, send: @escaping (RadioCommand) -> Void) {
        self.snapshot = snapshot
        self.capabilities = capabilities
        self.send = send
        _tab = State(initialValue: snapshot.band.selectedTab)
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
            let band = snapshot.band.selectedBand
            ConsoleSectionHeader("Band", detail: Int(band) != nil ? "\(band) m" : band)
            HStack(spacing: 4) {
                ForEach(snapshot.band.tabs, id: \.self) { name in
                    ConsoleChip(title: name, help: "\(name) bands", kind: tab == name ? .on : .plain,
                                height: 22, fullWidth: true,
                                status: name == "Ham" ? .available : capabilities.control(.bandTabs)) { tab = name }
                }
            }
            .padding(.bottom, 7)
            LazyVGrid(columns: consoleColumns(4), spacing: 5) {
                ForEach(snapshot.band.bands, id: \.self) { name in
                    ConsoleChip(title: name, help: "Band \(name)", kind: snapshot.band.selectedBand == name ? .on : .plain,
                                fullWidth: true, status: capabilities.control(.band)) { send(.selectBand(name)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Mode", detail: ConsoleFormat.focusDetail(snapshot.focusedReceiver.mode.rawValue,
                                                                        focused: snapshot.session.focused))
            LazyVGrid(columns: consoleColumns(5), spacing: 5) {
                ForEach(RadioMode.allCases, id: \.self) { m in
                    ConsoleChip(title: m.rawValue, help: "Mode \(m.rawValue)", kind: snapshot.focusedReceiver.mode == m ? .on : .plain,
                                fullWidth: true, status: capabilities.control(.mode)) {
                        send(.setMode(snapshot.session.focused, m))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private func field(_ text: Binding<String>, _ help: String, status: CapabilityStatus) -> some View {
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
            .disabled(ConsoleAvailability.isDisabled(status))
            .accessibilityLabel(help)
            .help(ConsoleAvailability.help(status, normal: help))
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).lineLimit(1)
    }

    private var filterSection: some View {
        let focused = snapshot.focusedReceiver
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Filter", detail: ConsoleFormat.focusDetail(
                String(format: "RX %.1f kHz", Double(snapshot.focusedReceiver.filterHz) / 1000),
                focused: snapshot.session.focused))
            LazyVGrid(columns: consoleColumns(4), spacing: 5) {
                ForEach(FilterPresets.entries(mode: focused.mode, currentHz: focused.filterHz), id: \.hz) { entry in
                    ConsoleChip(title: entry.chipTitle, help: entry.chipHelp,
                                kind: focused.filterHz == entry.hz ? .on : .plain, fullWidth: true,
                                status: capabilities.control(.filterPreset)) {
                        send(.setFilter(snapshot.session.focused, hz: entry.hz))
                    }
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    fieldLabel("RX lo").frame(width: 44, alignment: .leading)
                    field(.constant("\(snapshot.filter.rxLowHz) Hz"), "RX low cut",
                          status: capabilities.control(.filterEdges))
                    fieldLabel("TX lo").frame(width: 44, alignment: .leading)
                    field(.constant("\(snapshot.filter.txLowHz) Hz"), "TX low cut",
                          status: capabilities.control(.txBandwidth))
                }
            }
            .padding(.top, 8)
            HStack(spacing: 5) {
                let lockStatus = capabilities.control(.bwLock)
                Button { send(.setBandwidthLock(!snapshot.filter.bwLocked)) } label: {
                    HStack(spacing: 5) { Image(systemName: "link").font(.system(size: 11)); Text("BW lock") }
                }
                .buttonStyle(ConsoleChipButtonStyle(snapshot.filter.bwLocked ? .on : .plain))
                .disabled(ConsoleAvailability.isDisabled(lockStatus))
                .accessibilityLabel("Lock TX bandwidth to RX")
                .help(ConsoleAvailability.help(lockStatus, normal: "Lock TX bandwidth to RX"))
                Spacer(minLength: 0)
                fieldLabel("TX BW")
                ConsoleMenuChip(label: snapshot.filter.txBandwidthLabel, help: "TX bandwidth",
                                options: txBandwidthOptions, selection: .constant(snapshot.filter.txBandwidthLabel),
                                status: capabilities.control(.txBandwidth))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consolePanel()
    }

    private var propagationSection: some View {
        let p = snapshot.propagation
        return VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader("Propagation", detail: BandModeColumnView.propagationDetail(capabilities))
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
    BandModeColumnView(snapshot: .sample, capabilities: .allMocked, send: { _ in })
        .frame(height: 760)
        .background(LyraDS.Palette.void)
}

#Preview("Band and mode column, 330 pt") {
    BandModeColumnView(snapshot: .sample, capabilities: .allMocked, send: { _ in })
        .frame(height: 330)
        .background(LyraDS.Palette.void)
}
