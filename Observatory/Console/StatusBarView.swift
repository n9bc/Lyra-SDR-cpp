import SwiftUI

/// Content of the status bar: a left message and right-aligned badges.
struct StatusBarModel {
    enum BadgeKind: Hashable { case sample, tci(clients: Int), telemetry, cpu, graphics }

    struct Badge: Equatable {
        let kind: BadgeKind
        let text: String
    }

    let leftMessage: String
    let items: [Badge]

    var badges: [String] { items.map(\.text) }

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities) {
        let t = snapshot.telemetry
        leftMessage = snapshot.session.statusMessage

        let temp = t.temperatureC.map { String(format: "T %.1f °C", $0) } ?? "T not reported"
        let volts = t.supplyV.map { ConsoleFormat.telemetry(volts: $0) } ?? "V not reported"
        let pa = t.paCurrentA.map { String(format: "PA %.2f A", $0) } ?? "PA not reported"
        let clients = "TCI \u{00B7} \(t.tciClients) \(t.tciClients == 1 ? "client" : "clients")"

        var list: [Badge] = []
        if capabilities.isSampleData { list.append(Badge(kind: .sample, text: "Sample data")) }
        list.append(Badge(kind: .tci(clients: t.tciClients), text: clients))
        list.append(Badge(kind: .telemetry, text: "HL2 \(temp) \u{00B7} \(volts) \u{00B7} \(pa)"))
        list.append(Badge(kind: .cpu, text: "CPU \(t.cpuPct) %"))
        list.append(Badge(kind: .graphics, text: t.graphics))
        items = list
    }
}

/// Bottom status bar (26 pt): tuned message on the left, badges on the right.
struct StatusBarView: View {
    private let model: StatusBarModel

    init(snapshot: RadioSnapshot, capabilities: BackendCapabilities) {
        model = StatusBarModel(snapshot: snapshot, capabilities: capabilities)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder private func badge(_ b: StatusBarModel.Badge) -> some View {
        switch b.kind {
        case .sample:
            Text(b.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LyraDS.Palette.yellow)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(LyraDS.Palette.yellow.opacity(0.08)))
                .overlay(Capsule().strokeBorder(LyraDS.Palette.yellow, lineWidth: 1))
                .help("Values are sample data; no radio is connected")
        case .tci(let clients):
            HStack(spacing: 5) {
                Circle()
                    .fill(clients > 0 ? LyraDS.Palette.green : LyraDS.Palette.textDim)
                    .frame(width: 7, height: 7)
                Text(b.text)
            }
        case .telemetry, .cpu:
            mono(b.text)
        case .graphics:
            Text(b.text)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(model.leftMessage)
            Spacer(minLength: 16)
            ForEach(model.items, id: \.kind) { badge($0) }
        }
        .font(.system(size: 11))
        .foregroundStyle(LyraDS.Palette.textMuted)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: ConsoleLayout.statusBarHeight)
        .background(LyraDS.Palette.barFill)
        .overlay(alignment: .top) {
            Rectangle().fill(LyraDS.Palette.barBorder).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status bar")
        .accessibilityValue(([model.leftMessage] + model.badges).joined(separator: ", "))
    }
}

#Preview("Status bar, sample") {
    StatusBarView(snapshot: .sample, capabilities: .allMocked)
        .frame(width: 1280)
        .background(LyraDS.Palette.void)
}
