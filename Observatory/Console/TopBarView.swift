import SwiftUI

/// Label, style and help for the top bar's power chip. Keyed on the connection capability alone:
/// another mocked feature must not hide a real connection, and a mocked connection never reads
/// as a running radio.
struct PowerChipModel: Equatable, Sendable {
    nonisolated let label: String
    nonisolated let style: ConsoleChipStyle
    nonisolated let help: String

    nonisolated static func phaseName(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .disconnected: "Disconnected"
        case .discovering: "Discovering"
        case .connecting: "Connecting"
        case .socketOpen: "Socket open"
        case .streaming: "Running"
        case .stalled: "Stalled"
        case .error: "Error"
        }
    }

    nonisolated init(phase: ConnectionPhase, connectionStatus: CapabilityStatus) {
        let name = Self.phaseName(phase)
        switch connectionStatus {
        case .mocked:
            label = "Sample data"; style = .warn; help = "Sample data: no radio is connected"
        case .available:
            label = name; style = phase == .streaming ? .armed : .plain; help = "Radio connection: \(name)"
        case .unavailable(let reason):
            label = name; style = .plain; help = "Radio connection unavailable: \(reason)"
        }
    }
}

/// Top bar (46 pt): power, radio, profile, DSP chips, tools, apps, REC, spot, clocks, settings.
/// Power sends connect/disconnect and the gear opens the engine's Settings; the profile, DSP,
/// tools and apps controls have no engine path yet and are gated on their `ConsoleControl`.
/// Narrow widths degrade in three levels: everything inline, Tools in a menu, then Tools and the
/// TX DSP / RX chips in menus.
struct TopBarView: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities
    let send: (RadioCommand) -> Void
    /// Opens the engine's Settings window; nil (previews, tests) leaves the gear disabled.
    let openSettings: (@MainActor () -> Void)?
    /// Fixed time for previews and tests only; nil (the app) shows the current time.
    let clockOverride: Date?

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities,
         send: @escaping (RadioCommand) -> Void, openSettings: (@MainActor () -> Void)? = nil,
         clockOverride: Date? = nil) {
        self.snapshot = snapshot
        self.capabilities = capabilities
        self.send = send
        self.openSettings = openSettings
        self.clockOverride = clockOverride
    }

    /// The gear is usable only when it has a Settings action to run.
    nonisolated static func settingsStatus(hasAction: Bool) -> CapabilityStatus {
        hasAction ? .available : .unavailable("Settings need the radio engine")
    }

    private static let txDSP = ["Speech", "EQ", "Combinator", "Plating"]

    private var session: SessionSnapshot { snapshot.session }

    // MARK: Power

    private var powerChip: PowerChipModel {
        PowerChipModel(phase: snapshot.connection.phase, connectionStatus: capabilities.status(.connection))
    }

    private var power: some View {
        let chip = powerChip
        let status = capabilities.control(.connect)
        return Button { send(snapshot.connection.phase.powerCommand) } label: {
            HStack(spacing: 5) {
                Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                Text(chip.label)
            }
            .padding(.horizontal, 3)
        }
        .buttonStyle(ConsoleChipButtonStyle(chip.style, height: 30))
        .disabled(ConsoleAvailability.isDisabled(status))
        .accessibilityLabel("Radio power, \(chip.label)")
        .help(ConsoleAvailability.help(status, normal: chip.help))
    }

    private var radio: some View {
        let c = snapshot.connection
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(c.radioName) \u{00B7} \(c.address)")
                .font(.system(size: 12))
                .foregroundStyle(LyraDS.Palette.textPrimary)
            Text("\(c.sampleRateHz / 1000) kHz \u{00B7} Protocol \(c.protocolVersion)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LyraDS.Palette.textMuted)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private var sep: some View {
        Rectangle().fill(LyraDS.Palette.panelBorder).frame(width: 1, height: 28)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LyraDS.Palette.textMuted).fixedSize()
    }

    private func chip(_ title: String, _ style: ConsoleChipStyle = .plain, help: String,
                      status: CapabilityStatus) -> some View {
        Button(title) {}
            .buttonStyle(ConsoleChipButtonStyle(style))
            .accessibilityLabel(help)
            .consoleAvailability(status, help: help)
    }

    private func menuLabel(_ title: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return HStack(spacing: 5) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(LyraDS.Palette.textPrimary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(shape.fill(LyraDS.Palette.chipFill))
        .overlay(shape.strokeBorder(LyraDS.Palette.chipBorder, lineWidth: 1))
        .fixedSize()
    }

    private func menu(
        _ title: String, help: String, items: [String], status: CapabilityStatus,
        isOn: @escaping (String) -> Bool = { _ in false }
    ) -> some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {} label: {
                    if isOn(item) { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
        } label: {
            menuLabel(title)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(help)
        .consoleAvailability(status, help: help)
    }

    private var profile: some View {
        let status = capabilities.control(.profile)
        return HStack(spacing: 8) {
            label("Profile")
            menu(session.profileName, help: "Operating profile", items: [session.profileName],
                 status: status, isOn: { _ in true })
            Circle()
                .fill(session.profileModified ? LyraDS.Palette.yellow : LyraDS.Palette.textDim)
                .frame(width: 7, height: 7)
                .shadow(color: session.profileModified ? LyraDS.Palette.yellow : .clear, radius: 3)
                .help(session.profileModified ? "Profile modified" : "Profile unchanged")
                .accessibilityLabel(session.profileModified ? "Profile modified" : "Profile unchanged")
            chip("Save", help: "Save the profile", status: status)
        }
    }

    private func dspOn(_ name: String) -> Bool { session.txDSPOn[name] ?? false }

    @ViewBuilder private func dsp(collapsed: Bool) -> some View {
        let tx = capabilities.control(.txDSP)
        if collapsed {
            // One menu holds both; it is usable when either part is.
            let rx = capabilities.control(.rxEqualizer)
            menu("DSP", help: "TX DSP and RX equaliser", items: Self.txDSP + ["RX EQ"],
                 status: ConsoleAvailability.isDisabled(tx) ? rx : tx, isOn: dspOn)
        } else {
            HStack(spacing: 8) {
                label("TX DSP")
                ForEach(Self.txDSP, id: \.self) {
                    chip($0, dspOn($0) ? .on : .plain, help: "Toggle TX \($0)", status: tx)
                }
                label("RX").padding(.leading, 4)
                chip("RX EQ", dspOn("RX EQ") ? .on : .plain, help: "Toggle the receive equaliser",
                     status: capabilities.control(.rxEqualizer))
            }
        }
    }

    @ViewBuilder private func tools(collapsed: Bool) -> some View {
        let status = capabilities.control(.tools)
        if collapsed {
            menu("Tools", help: "Tools", items: session.tools, status: status)
        } else {
            HStack(spacing: 8) {
                label("Tools")
                ForEach(session.tools, id: \.self) { chip($0, help: "Open \($0)", status: status) }
            }
        }
    }

    /// UTC line ("09:17:29Z") and local line ("10:17:29 local") for `date`.
    nonisolated static func clockText(_ date: Date, localZone: TimeZone) -> (utc: String, local: String) {
        (ConsoleFormat.clock(date, in: localZone, utc: true),
         "\(ConsoleFormat.clock(date, in: localZone, utc: false)) local")
    }

    /// Live clocks, ticking once a second. "Local" is this Mac's time zone.
    private var clocks: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text = Self.clockText(clockOverride ?? context.date, localZone: .current)
            VStack(alignment: .trailing, spacing: 0) {
                Text(text.utc)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(LyraDS.Palette.cyan)
                    .shadow(color: LyraDS.Palette.cyan.opacity(0.5), radius: 4)
                Text(text.local)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LyraDS.Palette.yellow)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if let rec = session.recordingElapsed {
                Button("REC \(Self.hms(rec))") {}
                    .buttonStyle(ConsoleChipButtonStyle(.hot))
                    .accessibilityLabel("Recording, \(Self.hms(rec)) elapsed")
                    .help("Recording elapsed time")
            }
            if let spot = session.lastSpot {
                Button("Spot \(spot)") {}
                    .buttonStyle(ConsoleChipButtonStyle(.plain))
                    .foregroundStyle(LyraDS.Palette.yellow)
                    .accessibilityLabel("Last spot, \(spot)")
                    .help("Last spot: \(spot)")
            }
            clocks
            Button { openSettings?() } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 12)
            }
            .buttonStyle(ConsoleChipButtonStyle(.plain, height: 30))
            .accessibilityLabel("Settings")
            .consoleAvailability(Self.settingsStatus(hasAction: openSettings != nil), help: "Settings")
        }
    }

    nonisolated static func hms(_ interval: TimeInterval) -> String {
        let s = max(Int(interval), 0)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: Body

    private func bar(toolsCollapsed: Bool, dspCollapsed: Bool) -> some View {
        HStack(spacing: 8) {
            power
            radio
            sep
            profile
            sep
            dsp(collapsed: dspCollapsed)
            sep
            tools(collapsed: toolsCollapsed)
            menu("Apps", help: "Apps", items: ["No apps configured"], status: capabilities.control(.tools))
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(toolsCollapsed: false, dspCollapsed: false)
            bar(toolsCollapsed: true, dspCollapsed: false)
            bar(toolsCollapsed: true, dspCollapsed: true)
        }
        .frame(height: ConsoleLayout.topBarHeight)
        .background(LyraDS.Palette.barFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LyraDS.Palette.barBorder).frame(height: 1)
        }
    }
}

#Preview("Top bar, sample, 1280") {
    TopBarView(snapshot: .sample, capabilities: .allMocked, send: { _ in }, clockOverride: RadioSnapshot.sample.telemetry.utc)
        .frame(width: 1280)
        .background(LyraDS.Palette.void)
}

#Preview("Top bar, sample, 1600") {
    TopBarView(snapshot: .sample, capabilities: .allMocked, send: { _ in })
        .frame(width: 1600)
        .background(LyraDS.Palette.void)
}
