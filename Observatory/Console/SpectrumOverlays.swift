import SwiftUI

/// Band-plan, passband, VFO line, VFO label and spot labels laid over the Metal spectrum.
/// All positions come from `FrequencyAxis`.
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
    nonisolated static let spotRowY: [CGFloat] = [26, 44]

    nonisolated static func color(for kind: BandPlanKind) -> Color {
        switch kind {
        case .digital: LyraDS.Palette.purple
        case .ft8: LyraDS.Palette.yellow
        case .phoneExtra: LyraDS.Palette.electricBlue
        case .phoneGeneral: LyraDS.Palette.cyan
        case .phoneAll: LyraDS.Palette.green
        }
    }

    nonisolated static func color(for kind: SpotKind) -> Color {
        switch kind {
        case .dx: LyraDS.Palette.cyan
        case .watering: LyraDS.Palette.yellow
        case .own: LyraDS.Palette.magenta
        }
    }

    /// Passband edges in Hz: below the VFO for lower-sideband modes, above for the rest,
    /// centred for the symmetric modes.
    nonisolated static func passband(main: ReceiverSnapshot) -> ClosedRange<Int64> {
        let f = main.frequencyHz, bw = Int64(main.filterHz)
        switch main.mode {
        case .lsb, .cwl, .digl: return (f - bw)...f
        case .am, .sam, .dsb, .fm: return (f - bw / 2)...(f + bw / 2)
        case .usb, .cwu, .digu: return f...(f + bw)
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

    var body: some View {
        let w = axis.width
        let pb = Self.passband(main: main)
        let pbX = max(axis.x(for: pb.lowerBound), 0)
        let pbEnd = min(axis.x(for: pb.upperBound), w)
        let vfoX = axis.x(for: main.frequencyHz)
        let visible = display.spots.filter { axis.contains($0.frequencyHz) }
        let rows = Self.spotRows(visible.map { ($0.call, axis.x(for: $0.frequencyHz)) })
        ZStack(alignment: .topLeading) {
            if pbEnd > pbX {
                Rectangle().fill(LyraDS.Palette.cyan.opacity(0.10))
                    .frame(width: pbEnd - pbX).offset(x: pbX, y: Self.bandPlanHeight)
            }
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
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, spot in
                let c = Self.color(for: spot.kind)
                Text(spot.call)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(c).lineLimit(1).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(LyraDS.Palette.void.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(c, lineWidth: 1))
                    .position(x: axis.x(for: spot.frequencyHz), y: Self.spotRowY[rows[i]] + 9)
                    .accessibilityLabel("Spot \(spot.call)")
            }
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
