import SwiftUI

/// Neon arc S-meter: S1-S9 then +20/+40/+60 ticks, glowing needle, peak-hold marker and dBm text.
struct LyraSMeter: View {
    let dbm: Double
    let label: String

    @State private var peak = PeakHold(peakDbm: -127, heldAt: 0)

    init(dbm: Double, label: String = "S") {
        self.dbm = dbm
        self.label = label
    }

    // MARK: Scale math

    nonisolated private static let s0Dbm = -127.0
    nonisolated private static let s9Dbm = -73.0
    nonisolated private static let topDbm = -13.0

    /// S0 (-127 dBm) = 0, S9 (-73 dBm) = 0.6, S9+60 (-13 dBm) = 1.0; linear in between, clamped.
    nonisolated static func fraction(dbm: Double) -> Double {
        guard !dbm.isNaN else { return 0 }
        let f: Double
        if dbm <= s9Dbm {
            f = (dbm - s0Dbm) / (s9Dbm - s0Dbm) * 0.6
        } else {
            f = 0.6 + (dbm - s9Dbm) / (topDbm - s9Dbm) * 0.4
        }
        return min(max(f, 0), 1)
    }

    /// Peak marker: holds a new maximum for 1 s, then falls at 20 dB/s, never below the reading.
    struct PeakHold {
        var peakDbm: Double
        var heldAt: TimeInterval
        private var lastNow: TimeInterval

        nonisolated private static let holdSeconds = 1.0
        nonisolated private static let fallDbPerSecond = 20.0

        nonisolated init(peakDbm: Double, heldAt: TimeInterval) {
            self.peakDbm = peakDbm
            self.heldAt = heldAt
            self.lastNow = heldAt
        }

        nonisolated mutating func update(dbm: Double, now: TimeInterval) -> Double {
            if dbm >= peakDbm {
                peakDbm = dbm
                heldAt = now
            } else {
                let fallStart = max(lastNow, heldAt + Self.holdSeconds)
                if now > fallStart {
                    peakDbm = max(dbm, peakDbm - Self.fallDbPerSecond * (now - fallStart))
                }
            }
            lastNow = now
            return peakDbm
        }
    }

    private var sText: String {
        if dbm <= Self.s9Dbm {
            let s = min(max(Int(((dbm - Self.s0Dbm) / 6).rounded(.down)), 0), 9)
            return "\(label)\(s)"
        }
        return "\(label)9+\(Int((dbm - Self.s9Dbm).rounded()))"
    }
    private var dbmText: String { String(format: "%.0f dBm", dbm.isNaN ? Self.s0Dbm : dbm) }

    // MARK: Drawing

    private static let startDeg = 210.0
    private static let sweepDeg = 120.0

    private static func point(_ c: CGPoint, _ r: CGFloat, _ f: Double) -> CGPoint {
        let a = (startDeg + sweepDeg * f) * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, peakDbm: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height * 0.95)
        let r = min(size.width * 0.5, size.height * 0.85) - 6
        let f = Self.fraction(dbm: dbm)

        func arc(_ from: Double, _ to: Double, radius: CGFloat) -> Path {
            Path { p in
                p.addArc(center: c, radius: radius,
                         startAngle: .degrees(Self.startDeg + Self.sweepDeg * from),
                         endAngle: .degrees(Self.startDeg + Self.sweepDeg * to), clockwise: false)
            }
        }

        // Track, S portion (cyan) and over-S9 portion (magenta).
        ctx.stroke(arc(0, 1, radius: r), with: .color(LyraDS.Palette.textDim.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 4, lineCap: .round))
        if f > 0 {
            var glow = ctx
            glow.addFilter(.shadow(color: LyraDS.Palette.cyan.opacity(0.7), radius: 5))
            glow.stroke(arc(0, min(f, 0.6), radius: r), with: .color(LyraDS.Palette.cyan),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if f > 0.6 {
                glow.addFilter(.shadow(color: LyraDS.Palette.magenta.opacity(0.7), radius: 5))
                glow.stroke(arc(0.6, f, radius: r), with: .color(LyraDS.Palette.magenta),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }

        // Ticks and labels: S1...S9 then +20/+40/+60.
        var ticks: [(Double, String)] = []
        for n in 1...9 {
            ticks.append((Self.fraction(dbm: Self.s0Dbm + Double(n) * 6), n % 2 == 1 ? "\(n)" : ""))
        }
        for over in [20, 40, 60] {
            ticks.append((Self.fraction(dbm: Self.s9Dbm + Double(over)), "+\(over)"))
        }
        for (t, text) in ticks {
            var tick = Path()
            tick.move(to: Self.point(c, r - 8, t))
            tick.addLine(to: Self.point(c, r - 3, t))
            let over = t > 0.6
            ctx.stroke(tick, with: .color(over ? LyraDS.Palette.magenta : LyraDS.Palette.textMuted),
                       lineWidth: 1)
            if !text.isEmpty {
                ctx.draw(Text(text).font(LyraDS.Font.label(size: 9))
                            .foregroundStyle(over ? LyraDS.Palette.magenta : LyraDS.Palette.textMuted),
                         at: Self.point(c, r - 17, t))
            }
        }

        // Peak-hold marker.
        let pf = Self.fraction(dbm: peakDbm)
        var pk = Path()
        pk.move(to: Self.point(c, r - 5, pf))
        pk.addLine(to: Self.point(c, r + 5, pf))
        ctx.stroke(pk, with: .color(LyraDS.Palette.yellow), lineWidth: 2)

        // Needle with glowing tip.
        let tip = Self.point(c, r - 4, f)
        var needle = Path()
        needle.move(to: c)
        needle.addLine(to: tip)
        ctx.stroke(needle, with: .color(LyraDS.Palette.textPrimary), lineWidth: 1.5)
        var tipCtx = ctx
        tipCtx.addFilter(.shadow(color: LyraDS.Palette.cyan, radius: 6))
        tipCtx.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)),
                    with: .color(LyraDS.Palette.cyan))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                 with: .color(LyraDS.Palette.surfaceElevated))
    }

    var body: some View {
        VStack(spacing: LyraDS.Space.xs) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in draw(ctx, size, peakDbm: peak.peakDbm) }
                    .onChange(of: timeline.date) { _, date in
                        _ = peak.update(dbm: dbm.isNaN ? Self.s0Dbm : dbm,
                                        now: date.timeIntervalSinceReferenceDate)
                    }
            }
            .frame(width: 200, height: 110)
            Text("\(sText)  \(dbmText)")
                .font(LyraDS.Font.frequency(size: 12))
                .foregroundStyle(LyraDS.Palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("S-meter")
        .accessibilityValue("\(sText), \(dbmText)")
        .help("S-meter: \(sText), \(dbmText)")
    }
}

#Preview {
    VStack(spacing: LyraDS.Space.lg) {
        LyraSMeter(dbm: -90)
        LyraSMeter(dbm: -45)
    }
    .padding(LyraDS.Space.xl)
    .background(LyraDS.Palette.void)
}
