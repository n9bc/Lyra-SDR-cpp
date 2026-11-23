import SwiftUI

/// Top bar (46 pt): power, radio, profile, DSP chips, tools, apps, REC, spot, clocks, settings.
/// Actions are empty in Milestone 1 (static console). Narrow widths degrade in three levels:
/// everything inline, Tools in a menu, then Tools and the TX DSP / RX chips in menus.
struct TopBarView: View {
    let snapshot: RadioSnapshot
    let capabilities: BackendCapabilities

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities) {
        self.snapshot = snapshot
        self.capabilities = capabilities
    }

    private static let txDSP = ["Speech", "EQ", "Combinator", "Plating"]

    private var session: SessionSnapshot { snapshot.session }

    // MARK: Power

    private var phaseName: String {
        switch snapshot.connection.phase {
        case .disconnected: "Disconnected"
        case .discovering: "Discovering"
        case .connecting: "Connecting"
        case .socketOpen: "Socket open"
        case .streaming: "Running"
        case .stalled: "Stalled"
        case .error: "Error"
        }
    }

    /// Truthfulness: sample data never reads as a running radio.
    private var powerLabel: String { capabilities.isSampleData ? "Sample data" : phaseName }

    private var powerStyle: ConsoleChipStyle {
        if capabilities.isSampleData { return .warn }
        return snapshot.connection.phase == .streaming ? .armed : .plain
    }

    private var power: some View {
        let help = capabilities.isSampleData
            ? "Sample data: no radio is connected" : "Radio connection: \(phaseName)"
        return Button {} label: {
            HStack(spacing: 5) {
                Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                Text(powerLabel)
            }
            .padding(.horizontal, 3)
        }
        .buttonStyle(ConsoleChipButtonStyle(powerStyle, height: 30))
        .accessibilityLabel("Radio power, \(powerLabel)")
        .help(help)
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

    private func chip(_ title: String, _ style: ConsoleChipStyle = .plain, help: String) -> some View {
        Button(title) {}
            .buttonStyle(ConsoleChipButtonStyle(style))
            .accessibilityLabel(help)
            .help(help)
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
        _ title: String, help: String, items: [String], isOn: @escaping (String) -> Bool = { _ in false }
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
        .help(help)
    }

    private var profile: some View {
        HStack(spacing: 8) {
            label("Profile")
            menu(session.profileName, help: "Operating profile", items: [session.profileName],
                 isOn: { _ in true })
            Circle()
                .fill(session.profileModified ? LyraDS.Palette.yellow : LyraDS.Palette.textDim)
                .frame(width: 7, height: 7)
                .shadow(color: session.profileModified ? LyraDS.Palette.yellow : .clear, radius: 3)
                .help(session.profileModified ? "Profile modified" : "Profile unchanged")
                .accessibilityLabel(session.profileModified ? "Profile modified" : "Profile unchanged")
            chip("Save", help: "Save the profile")
        }
    }

    private func dspOn(_ name: String) -> Bool { session.txDSPOn[name] ?? false }

    @ViewBuilder private func dsp(collapsed: Bool) -> some View {
        if collapsed {
            menu("DSP", help: "TX DSP and RX equaliser", items: Self.txDSP + ["RX EQ"], isOn: dspOn)
        } else {
            HStack(spacing: 8) {
                label("TX DSP")
                ForEach(Self.txDSP, id: \.self) {
                    chip($0, dspOn($0) ? .on : .plain, help: "Toggle TX \($0)")
                }
                label("RX").padding(.leading, 4)
                chip("RX EQ", dspOn("RX EQ") ? .on : .plain, help: "Toggle the receive equaliser")
            }
        }
    }

    @ViewBuilder private func tools(collapsed: Bool) -> some View {
        if collapsed {
            menu("Tools", help: "Tools", items: session.tools)
        } else {
            HStack(spacing: 8) {
                label("Tools")
                ForEach(session.tools, id: \.self) { chip($0, help: "Open \($0)") }
            }
        }
    }

    private var clocks: some View {
        let t = snapshot.telemetry
        return VStack(alignment: .trailing, spacing: 0) {
            Text(ConsoleFormat.clock(t.utc, in: t.timeZone, utc: true))
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(LyraDS.Palette.cyan)
                .shadow(color: LyraDS.Palette.cyan.opacity(0.5), radius: 4)
            Text("\(ConsoleFormat.clock(t.utc, in: t.timeZone, utc: false)) local")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LyraDS.Palette.yellow)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
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
            Button {} label: {
                Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 12)
            }
            .buttonStyle(ConsoleChipButtonStyle(.plain, height: 30))
            .accessibilityLabel("Settings")
            .help("Settings")
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
            menu("Apps", help: "Apps", items: ["No apps configured"])
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
    TopBarView(snapshot: .sample, capabilities: .allMocked)
        .frame(width: 1280)
        .background(LyraDS.Palette.void)
}

#Preview("Top bar, sample, 1600") {
    TopBarView(snapshot: .sample, capabilities: .allMocked)
        .frame(width: 1600)
        .background(LyraDS.Palette.void)
}
