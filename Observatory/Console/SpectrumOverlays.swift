import SwiftUI

/// Band-plan strip, passband, VFO line and VFO label laid over the Metal spectrum. Display-only:
/// the clickable parts (spot and landmark labels, channel segments) are `SpectrumOverlayControls`,
/// which sits above the gesture surface. All positions come from `FrequencyAxis`.
struct SpectrumOverlays: View {
    let display: DisplaySnapshot
    let main: ReceiverSnapshot
    let axis: FrequencyAxis
    /// Room kept clear at the right end of the band-plan strip (for the "Sample" marker).
    var bandPlanTrailingInset: CGFloat = 0

    /// Pane height; the VFO readout is dropped when it would not fit whole below the spot rows.
    var height: CGFloat = .infinity

    static let bandPlanHeight: CGFloat = 14
    nonisolated static let vfoLabelY: CGFloat = 56
    nonisolated static let vfoLabelHeight: CGFloat = 20
    nonisolated static func showsVFOLabel(height: CGFloat) -> Bool { height >= vfoLabelY + vfoLabelHeight }
    nonisolated static let subCueY: CGFloat = 80
    nonisolated static let spotRowY: [CGFloat] = [26, 44]

    nonisolated static func color(for kind: BandPlanKind) -> Color {
        switch kind {
        case .cw: LyraDS.Palette.electricBlue
        case .digital: LyraDS.Palette.purple
        case .cwDigital: LyraDS.Palette.pink
        case .phone: LyraDS.Palette.green
        case .fm: LyraDS.Palette.yellow
        case .mixed: LyraDS.Palette.textMuted
        case .channel: LyraDS.Palette.cyan
        }
    }

    nonisolated static func color(for kind: SpotKind) -> Color {
        switch kind {
        case .dx: LyraDS.Palette.cyan
        case .watering: LyraDS.Palette.yellow
        case .beacon: LyraDS.Palette.green
        case .own: LyraDS.Palette.magenta
        }
    }

    /// Row (0 or 1) per visible spot: row 0 unless it would overlap the previous label there.
    nonisolated static func spotRows(_ spots: [(call: String, x: CGFloat)]) -> [Int] {
        var rightEdge: [CGFloat] = [-.infinity, -.infinity]
        var rows = Array(repeating: 0, count: spots.count)
        for i in spots.indices.sorted(by: { spots[$0].x < spots[$1].x }) {
            let half = CGFloat(spots[i].call.count) * 7 / 2 + 8
            let row = spots[i].x - half > rightEdge[0] + 2 ? 0 : (spots[i].x - half > rightEdge[1] + 2 ? 1 : 0)
            rows[i] = row
            rightEdge[row] = spots[i].x + half
        }
        return rows
    }

    private var vfoLabel: String {
        var s = ConsoleFormat.frequency(main.frequencyHz)
        if let dot = s.lastIndex(of: ".") { s.replaceSubrange(dot...dot, with: " ") }
        return "\(s) \(main.mode.rawValue)"
    }

    /// Sub drawn on the Main spectrum (no RX2 spectrum): a green carrier line and passband box,
    /// or an edge cue when the carrier is outside the span.
    @ViewBuilder
    private func subOverlay(_ sub: SubOverlay, width w: CGFloat) -> some View {
        let green = LyraDS.Palette.green
        if let cue = sub.offSpan {
            Text(cue == .left ? "\u{25C0} SUB" : "SUB \u{25B6}")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(green).lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(LyraDS.Palette.void.opacity(0.85)))
                .frame(width: w, alignment: cue == .left ? .leading : .trailing)
                .offset(y: Self.subCueY)
                .accessibilityLabel(cue == .left ? "Sub receiver is below the span" : "Sub receiver is above the span")
        } else {
            let x0 = max(axis.x(for: sub.passband.lowerBound), 0)
            let x1 = min(axis.x(for: sub.passband.upperBound), w)
            if x1 > x0 {
                Rectangle().fill(green.opacity(0.12))
                    .frame(width: x1 - x0).offset(x: x0, y: Self.bandPlanHeight)
            }
            Rectangle().fill(green)
                .frame(width: 1.5).offset(x: axis.x(for: sub.carrierHz) - 0.75, y: Self.bandPlanHeight)
        }
    }

    var body: some View {
        let w = axis.width
        let pb = display.mainPassband
        let pbX = max(axis.x(for: pb.lowerBound), 0)
        let pbEnd = min(axis.x(for: pb.upperBound), w)
        let vfoX = axis.x(for: display.mainCarrierHz)
        ZStack(alignment: .topLeading) {
            if pbEnd > pbX {
                Rectangle().fill(LyraDS.Palette.cyan.opacity(0.10))
                    .frame(width: pbEnd - pbX).offset(x: pbX, y: Self.bandPlanHeight)
            }
            if let sub = display.subOverlay { subOverlay(sub, width: w) }
            if display.bandPlanVisible {
                ForEach(Array(display.bandPlan.enumerated()), id: \.offset) { _, seg in
                    let x0 = max(axis.x(for: seg.lowHz), 0)
                    let x1 = min(axis.x(for: seg.highHz), w - bandPlanTrailingInset)
                    if x1 > x0 {
                        Text(seg.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LyraDS.Palette.void)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .padding(.horizontal, 4)
                            .frame(width: x1 - x0, height: Self.bandPlanHeight, alignment: .leading)
                            .background(Self.color(for: seg.kind))
                            .clipped()
                            .offset(x: x0)
                            .accessibilityHidden(true)
                    }
                }
            }
            Rectangle().fill(LyraDS.Palette.yellow)
                .frame(width: 1.5).offset(x: vfoX - 0.75, y: Self.bandPlanHeight)
            if Self.showsVFOLabel(height: height) {
            Text(vfoLabel)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(LyraDS.Palette.yellow)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(LyraDS.Palette.void.opacity(0.85)))
                .frame(width: max(w - vfoX - 6, 0) > 110 ? nil : max(vfoX - 6, 0),
                       alignment: .trailing)
                .offset(x: max(w - vfoX - 6, 0) > 110 ? vfoX + 6 : 0, y: Self.vfoLabelY)
            }
        }
        .frame(width: w, alignment: .topLeading)
        .clipped()
    }
}

/// The clickable overlay items: spot and landmark labels, and 60 m channel segments. It is laid
/// ABOVE the gesture surface in the stack's ZStack, so its items win the hit test where they are;
/// everywhere else it is empty (every child is individually positioned and the container has no
/// background or content shape), so clicks, drags and scrolls fall through to the surface below.
/// Clicks send commands through `send`; when `status` is unavailable the items are disabled and
/// carry the reason as their tooltip.
struct SpectrumOverlayControls: View {
    let display: DisplaySnapshot
    let axis: FrequencyAxis
    /// The `.spots` capability.
    let status: CapabilityStatus
    var bandPlanTrailingInset: CGFloat = 0
    let send: (RadioCommand) -> Void

    /// The command a spot or landmark label sends: a landmark tunes (guarded), a spot activates.
    nonisolated static func command(for spot: Spot) -> RadioCommand {
        switch spot.kind {
        case .watering, .beacon: .tuneLandmark(hz: spot.frequencyHz, mode: spot.mode ?? "")
        case .dx, .own: .activateSpot(call: spot.call)
        }
    }

    nonisolated static func help(for spot: Spot) -> String {
        switch spot.kind {
        case .watering, .beacon:
            "Tune to \(spot.label) at \(ConsoleFormat.frequency(spot.frequencyHz))\(spot.mode.map { " " + $0 } ?? "")"
        case .dx, .own: "Tune to \(spot.call) at \(ConsoleFormat.frequency(spot.frequencyHz))"
        }
    }

    private func tooltip(_ normal: String) -> String { ConsoleAvailability.help(status, normal: normal) }

    var body: some View {
        let w = axis.width
        // Live, the mapper already applied the flags; in sample mode the Spots chip hides spots
        // but not landmarks.
        let shown = display.spots.filter {
            axis.contains($0.frequencyHz) && (display.spotsVisible || $0.kind == .watering || $0.kind == .beacon)
        }
        let rows = SpectrumOverlays.spotRows(shown.map { ($0.label, axis.x(for: $0.frequencyHz)) })
        ZStack(alignment: .topLeading) {
            if display.bandPlanVisible {
                ForEach(Array(display.bandPlan.enumerated()), id: \.offset) { _, seg in
                    if seg.kind == .channel, let qsy = seg.channelQsyHz {
                        let x0 = max(axis.x(for: seg.lowHz), 0)
                        let x1 = min(axis.x(for: seg.highHz), w - bandPlanTrailingInset)
                        if x1 > x0 {
                            Button { send(.tuneChannel(qsyHz: qsy)) } label: {
                                Color.clear.frame(width: x1 - x0, height: SpectrumOverlays.bandPlanHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: x0)
                            .disabled(ConsoleAvailability.isDisabled(status))
                            .help(tooltip("Tune to \(seg.label) at \(ConsoleFormat.frequency(qsy)) USB"))
                            .accessibilityLabel("Channel \(seg.label), \(ConsoleFormat.frequency(qsy))")
                        }
                    }
                }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, spot in
                let c = SpectrumOverlays.color(for: spot.kind)
                Button { send(Self.command(for: spot)) } label: {
                    Text(spot.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(c).lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(LyraDS.Palette.void.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(c, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .position(x: axis.x(for: spot.frequencyHz), y: SpectrumOverlays.spotRowY[rows[i]] + 9)
                .disabled(ConsoleAvailability.isDisabled(status))
                .help(tooltip(Self.help(for: spot)))
                .accessibilityLabel(spot.kind == .watering || spot.kind == .beacon
                                    ? "Landmark \(spot.label)" : "Spot \(spot.call)")
            }
        }
        .frame(width: w, alignment: .topLeading)
        .clipped()
    }
}
