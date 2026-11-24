import Foundation

/// What a gesture needs to know about the display it happens on. All Hz are on the display axis.
struct SpectrumGestureContext: Equatable, Sendable {
    /// The receiver the gesture tunes (see `SpectrumGestureModel.tuneReceiver`).
    var receiver: ReceiverID
    var centreHz: Int64
    var spanHz: Int64
    var width: Double
    /// The tuned receiver's VFO line.
    var carrierHz: Int64
    var passband: ClosedRange<Int64>
    var ctuneEnabled: Bool
    /// The grid clicks snap to (the wheel step).
    var stepHz: Int
    var round100: Bool

    var hzPerPixel: Double { Double(spanHz) / max(1, width) }
}

/// Where a press on the spectrum lands (see `SpectrumGestureModel.hitTarget`).
enum SpectrumHitTarget: Equatable, Sendable {
    /// The right-edge dB scale strip (see `SpectrumGestureModel.dbZone`).
    case dbScale(DbZone)
    /// A passband edge handle.
    case edge(PassbandEdge)
    case notch(Int)
    /// CTUN pan strip or click-to-tune.
    case tune
}

/// What a left press (or Control-click, a right press) tries first, before tuning.
enum SpectrumPressRoute: Equatable, Sendable {
    /// A dB-scale or passband-edge drag.
    case grab
    /// A notch gesture, as this button.
    case notch(NotchGesture.Button)
    /// Click-to-tune and drags, or with Option the focus toggle.
    case tune
}

/// The two edges of the Main passband.
enum PassbandEdge: Equatable, Sendable { case low, high }

/// Which part of the dB scale a press grabs: the top third moves the ceiling, the bottom third the
/// floor, the middle both.
enum DbZone: Equatable, Sendable { case ceiling, floor, both }

/// Pure maths for the spectrum and waterfall tuning gestures, ported from `PanadapterPanel.qml`
/// (map §4) and `vfo_snap.h`.
enum SpectrumGestureModel {
    /// Movement below this many points is a click.
    nonisolated static let dragThresholdPx = 6.0
    /// Drags send at most 30 commands a second.
    nonisolated static let dragThrottle = 1.0 / 30
    /// With CTUN on, a press in the top strip pans the display centre; below it grabs the VFO.
    nonisolated static let ctunPanStripPx = 15.0
    /// Points of precise (trackpad) scrolling per wheel notch.
    nonisolated static let preciseScrollPointsPerTick = 12.0

    /// The frequency under `x` (QML `freqAtX`).
    nonisolated static func hz(atX x: Double, width: Double, centreHz: Int64, spanHz: Int64) -> Int64 {
        guard width > 0 else { return centreHz }
        return centreHz + Int64(((x / width - 0.5) * Double(spanHz)).rounded())
    }

    /// The wheel's step: the scroll step, never finer than 100 Hz while exact tuning is on.
    nonisolated static func effectiveStep(stepHz: Int, round100: Bool) -> Int {
        round100 ? max(100, stepHz) : stepHz
    }

    /// Click snap (QML `snapCarrier`): the 100 Hz grid when exact tuning is on, else the scroll
    /// step grid when the step is above 1 Hz. Unlike the wheel, a coarser step does not apply.
    nonisolated static func snapCarrier(_ hz: Int64, stepHz: Int, round100: Bool) -> Int64 {
        let grid = round100 ? 100 : Int64(stepHz)
        guard grid > 1 else { return hz }
        let (q, _) = (hz + grid / 2).quotientAndRemainderFloor(by: grid)
        return q * grid
    }

    /// The receiver a click or wheel on the Main display tunes (QML `panTuneRx`).
    nonisolated static func tuneReceiver(subEnabled: Bool, splitEnabled: Bool, focusedRx: Int) -> ReceiverID {
        (subEnabled || splitEnabled) && focusedRx == 2 ? .sub : .main
    }

    /// `lyra::ui::nextWheelHz`: sticky wheels snap the first notch to the step grid, then add.
    nonisolated static func nextWheelHz(_ freqHz: Int64, stepHz: Int, ticks: Int, sticky: Bool) -> Int64 {
        let limit = Int64(Int32.max)
        func clamp(_ v: Int64) -> Int64 { min(max(v, 0), limit) }
        let freq = max(freqHz, 0)
        guard ticks != 0 else { return freq }
        let step = Int64(max(stepHz, 1))
        let n = Int64(ticks)
        if !sticky || step <= 1 { return clamp(freq &+ n &* step) }
        let dir: Int64 = ticks > 0 ? 1 : -1
        let rem = freq % step
        let first = rem == 0 ? freq + dir * step : (dir > 0 ? freq - rem + step : freq - rem)
        return clamp(first &+ dir &* step &* (abs(n) - 1))
    }

    /// QML `inPassband`: the cursor is strictly inside the filter.
    nonisolated static func isInsidePassband(hz: Int64, passband: ClosedRange<Int64>) -> Bool {
        hz > passband.lowerBound && hz < passband.upperBound
    }

    /// Wheel notches for one scroll event. A precise (trackpad) device accumulates one notch per
    /// 12 points, a line wheel gives one per event. Vertical wins; horizontal is inverted.
    nonisolated static func wheelTicks(deltaY: Double, deltaX: Double, precise: Bool,
                                       accumulator: inout Double) -> Int {
        let delta = deltaY != 0 ? deltaY : -deltaX
        guard delta != 0 else { return 0 }
        guard precise else { return delta > 0 ? 1 : -1 }
        accumulator += delta
        let ticks = Int((accumulator / preciseScrollPointsPerTick + (accumulator < 0 ? -1e-9 : 1e-9))
            .rounded(.towardZero))
        accumulator -= Double(ticks) * preciseScrollPointsPerTick
        return ticks
    }

    /// Zoom multiplier for wheel notches: x1.25 per notch up, x0.8 per notch down.
    nonisolated static func zoomFactor(ticks: Int) -> Double {
        ticks >= 0 ? pow(1.25, Double(ticks)) : pow(0.8, Double(-ticks))
    }

    /// Width of the passband edge hit area, centred on the edge.
    nonisolated static let edgeHandleWidthPx = 9.0
    /// The dB scale strip at the spectrum's right edge, and the strip at the top it leaves alone.
    nonisolated static let dbZoneWidthPx = 50.0
    nonisolated static let dbZoneTopInsetPx = 24.0

    /// The passband edge under `x`, nearest first when the handles overlap (QML passband handles).
    nonisolated static func edgeHit(x: Double, loX: Double, hiX: Double) -> PassbandEdge? {
        let half = edgeHandleWidthPx / 2
        let dLo = abs(x - loX), dHi = abs(x - hiX)
        let lo = dLo <= half, hi = dHi <= half
        if lo && hi { return dLo <= dHi ? .low : .high }
        return lo ? .low : (hi ? .high : nil)
    }

    /// The dB scale zone under a press (QML `dbModeAt`): the right 50 px, below the top 24 px,
    /// cut into thirds of the spectrum's height.
    nonisolated static func dbZone(x: Double, y: Double, width: Double, height: Double) -> DbZone? {
        guard width > 0, height > 0, x >= width - dbZoneWidthPx, y >= dbZoneTopInsetPx else { return nil }
        let third = height / 3
        if y < third { return .ceiling }
        if y > 2 * third { return .floor }
        return .both
    }

    /// The range after dragging the scale `dy` points down from where it began (QML dB drag).
    /// Down lowers it; a drag of the full height moves it by its own span. The floor stays within
    /// -150...-3 and the ceiling within floor + 3 ... 30.
    nonisolated static func dbDrag(startFloor: Double, startCeiling: Double, dy: Double, height: Double,
                                   zone: DbZone) -> (floor: Double, ceiling: Double) {
        let delta = -dy * (startCeiling - startFloor) / max(1, height)
        var floor = startFloor, ceiling = startCeiling
        switch zone {
        case .ceiling: ceiling += delta
        case .floor: floor += delta
        case .both: floor += delta; ceiling += delta
        }
        return clampedDbRange(floor: floor, ceiling: ceiling)
    }

    /// The engine's limits on the dB range: floor -150...-3, ceiling floor + 3 ... 30.
    nonisolated static func clampedDbRange(floor: Double, ceiling: Double) -> (floor: Double, ceiling: Double) {
        let f = max(-150, min(-3, floor))
        return (f, max(f + 3, min(30, ceiling)))
    }

    /// `WdspEngine::bandwidthForModeEdge`: the filter width that puts a passband edge `off` Hz
    /// from the dial. SSB and digital take the edge as the cutoff, CW centres on the pitch, every
    /// other mode is symmetric about the dial. Whole Hz, 50...20000. `cwPitchHz` is the engine's
    /// CW pitch (default 600).
    nonisolated static func bandwidthForEdge(_ off: Double, mode: String, cwPitchHz: Int = 600) -> Int {
        guard off.isFinite else { return 50 }
        let bw: Double
        switch mode {
        case "USB", "DIGU", "LSB", "DIGL": bw = abs(off)
        case "CWU": bw = 2 * abs(off - Double(cwPitchHz))
        case "CWL": bw = 2 * abs(off + Double(cwPitchHz))
        default: bw = 2 * abs(off)
        }
        return Int(min(max(bw + 0.5, 50), 20_000))
    }

    /// Whether the dB scale and passband edges can be grabbed: the live Main spectrum, and never
    /// while TX owns the axis (ruling R4).
    nonisolated static func grabsEnabled(stack: ReceiverID, surface: SpectrumSurface, live: Bool,
                                         txAxis: Bool) -> Bool {
        stack == .main && surface == .spectrum && live && !txAxis
    }

    /// What a press on the spectrum grabs, in controller ruling R1's priority order: dB-scale
    /// zone, passband-edge handle, notch, then the CTUN pan strip and click-to-tune.
    /// `dbZoneEnabled` and `edges` are off for surfaces without them (the waterfall, the Sub stack).
    nonisolated static func hitTarget(x: Double, y: Double, notches: [NotchInfo], width: Double,
                                      spanHz: Double, notchesEnabled: Bool, height: Double = 0,
                                      dbZoneEnabled: Bool = false,
                                      edges: (lo: Double, hi: Double)? = nil) -> SpectrumHitTarget {
        if dbZoneEnabled, let zone = dbZone(x: x, y: y, width: width, height: height) {
            return .dbScale(zone)
        }
        if let edges, let edge = edgeHit(x: x, loX: edges.lo, hiX: edges.hi) { return .edge(edge) }
        if notchesEnabled, let i = NotchModel.hitIndex(x: x, notches: notches, width: width, spanHz: spanHz) {
            return .notch(i)
        }
        return .tune
    }

    /// Where a left press goes (`SpectrumInteractionView`'s `mouseDown`). An Option press always
    /// takes the focus-toggle path, whatever is under it; Control makes it a right press (notch add
    /// or remove); otherwise the dB scale and passband edges, then a notch, then tuning (R1).
    nonisolated static func pressRoute(target: SpectrumHitTarget, control: Bool, option: Bool) -> SpectrumPressRoute {
        if option { return .tune }
        if control { return .notch(.right) }
        switch target {
        case .dbScale, .edge: return .grab
        case .notch: return .notch(.left)
        case .tune: return .tune
        }
    }

    /// Middle (or option) click: toggles focus, putting VFO B on the snapped frequency under the cursor.
    nonisolated static func middleClick(atX x: Double, context c: SpectrumGestureContext) -> RadioCommand {
        let hz = hz(atX: x, width: c.width, centreHz: c.centreHz, spanHz: c.spanHz)
        return .spectrumFocusToggle(hz: snapCarrier(hz, stepHz: c.stepHz, round100: c.round100))
    }
}

/// Builds fast zoom gestures (Command-scroll, pinch) on the zoom last asked for until the snapshot
/// reports it, so steps sent between two snapshots are not lost by multiplying the same stale zoom.
/// The snapshot wins again once it matches the request, or after `staleAfter` seconds (the engine
/// settled elsewhere). Clamped to the engine's 1...16.
struct SpectrumZoomAccumulator: Sendable {
    nonisolated static let range = 1.0...16.0
    nonisolated static let staleAfter: TimeInterval = 0.5

    private var requested: Double?
    private var requestedAt: TimeInterval = 0

    nonisolated init() {}

    /// The zoom to send for a gesture of `factor` at `now` (seconds, any monotonic clock).
    nonisolated mutating func next(snapshotZoom: Double, factor: Double, now: TimeInterval) -> Double {
        let shown = snapshotZoom.isFinite ? snapshotZoom : Self.range.lowerBound
        var base = shown
        if let requested {
            let caughtUp = abs(shown - requested) <= 1e-6 * max(1, requested)
            if !caughtUp, now - requestedAt < Self.staleAfter, now >= requestedAt { base = requested }
        }
        let target = min(max(base * factor, Self.range.lowerBound), Self.range.upperBound)
        requested = target
        requestedAt = now
        return target
    }
}

/// One left-button press-drag-release. Below the drag threshold it is a click; beyond it, it pans
/// the spectrum (CTUN off) or, with CTUN on, pans the locked centre (top strip) or grabs the VFO.
struct SpectrumGestureSession: Sendable {
    private enum Mode { case spectrumPan, ctunPan, grab }

    private let context: SpectrumGestureContext
    private let mode: Mode
    private let startX: Double
    private var lastX: Double
    private var dragging = false
    private var lastSend: TimeInterval?
    private var finished = false

    nonisolated init(startX: Double, startY: Double, context: SpectrumGestureContext) {
        self.context = context
        self.startX = startX
        self.lastX = startX
        if context.ctuneEnabled && context.receiver == .main {
            mode = startY < SpectrumGestureModel.ctunPanStripPx ? .ctunPan : .grab
        } else {
            mode = .spectrumPan
        }
    }

    /// The command for a cursor move, or nil below the threshold or inside the throttle window.
    nonisolated mutating func moved(toX x: Double, at time: TimeInterval) -> RadioCommand? {
        if !dragging {
            guard abs(x - startX) >= SpectrumGestureModel.dragThresholdPx else { return nil }
            dragging = true
        }
        if let last = lastSend, time - last < SpectrumGestureModel.dragThrottle { return nil }
        lastSend = time
        return command(toX: x)
    }

    /// The command for the release: a click tunes (or is ignored), a drag flushes what the
    /// throttle held back.
    nonisolated mutating func ended(atX x: Double) -> RadioCommand? {
        guard !finished else { return nil }
        defer { finished = true }
        if dragging { return mode == .spectrumPan && x == lastX ? nil : command(toX: x) }
        let c = context
        let hz = SpectrumGestureModel.hz(atX: startX, width: c.width, centreHz: c.centreHz, spanHz: c.spanHz)
        if c.ctuneEnabled && c.receiver == .main
            && SpectrumGestureModel.isInsidePassband(hz: hz, passband: c.passband) { return nil }
        return .tuneCarrier(c.receiver, hz: SpectrumGestureModel.snapCarrier(hz, stepHz: c.stepHz, round100: c.round100))
    }

    private nonisolated mutating func command(toX x: Double) -> RadioCommand? {
        let c = context
        switch mode {
        case .spectrumPan:
            // The spectrum follows the finger: dragging right lowers the dial.
            let shift = Int64(((x - startX) * c.hzPerPixel).rounded())
            lastX = x
            return .tuneCarrier(c.receiver, hz: c.carrierHz - shift)
        case .ctunPan, .grab:
            let delta = Int64(((x - lastX) * c.hzPerPixel).rounded())
            guard delta != 0 else { return nil }
            lastX = x
            return mode == .ctunPan ? .ctunPan(deltaHz: delta) : .grabVfo(deltaHz: delta)
        }
    }
}

/// One press-drag-release on the dB scale. A press while auto is on first seeds the manual range
/// from the range shown and turns auto off (a Prefs write puts the pair in the live RX or TX
/// slot). Writes go out at most every 1/30 s and the release flushes the final value.
struct SpectrumDbDrag: Sendable {
    private let zone: DbZone
    private let startY: Double
    private let startFloor: Double
    private let startCeiling: Double
    private let seeds: [RadioCommand]
    private var throttle = WriteThrottle<DbPair>(interval: SpectrumGestureModel.dragThrottle)
    private var lastTime: TimeInterval = 0
    private var sent: DbPair?

    private struct DbPair: Equatable, Sendable { var floor: Double; var ceiling: Double }

    nonisolated init(zone: DbZone, startY: Double, shownFloor: Double, shownCeiling: Double, auto: Bool) {
        self.zone = zone
        self.startY = startY
        if auto {
            startFloor = shownFloor.rounded()
            startCeiling = shownCeiling.rounded()
            seeds = [.setDbRange(floor: startFloor, ceiling: startCeiling), .setDbAuto(false)]
        } else {
            startFloor = shownFloor
            startCeiling = shownCeiling
            seeds = []
        }
    }

    /// What the press itself sends: the seed and auto off, when auto was on.
    nonisolated var beginCommands: [RadioCommand] { seeds }

    private nonisolated func pair(atY y: Double, height: Double) -> DbPair {
        let r = SpectrumGestureModel.dbDrag(startFloor: startFloor, startCeiling: startCeiling,
                                            dy: y - startY, height: height, zone: zone)
        return DbPair(floor: r.floor, ceiling: r.ceiling)
    }

    nonisolated mutating func moved(toY y: Double, height: Double, at time: TimeInterval) -> RadioCommand? {
        lastTime = time
        guard let p = throttle.offer(pair(atY: y, height: height), now: time) else { return nil }
        sent = p
        return .setDbRange(floor: p.floor, ceiling: p.ceiling)
    }

    /// The release: the range at the release point, unless it is already what was last sent.
    nonisolated mutating func ended(atY y: Double, height: Double) -> RadioCommand? {
        let p = pair(atY: y, height: height)
        _ = throttle.flush()
        guard p != sent else { return nil }
        sent = p
        return .setDbRange(floor: p.floor, ceiling: p.ceiling)
    }
}

/// One press-drag-release on a passband edge handle. Offsets are from the display centre; the
/// planner makes them dial-relative. Throttled to 1/30 s, flushed on release. A press and release
/// with no movement writes nothing (Qt wrote only on a position change).
struct SpectrumEdgeDrag: Sendable {
    private let edge: PassbandEdge
    private let width: Double
    private let spanHz: Double
    private var throttle = WriteThrottle<Double>(interval: SpectrumGestureModel.dragThrottle)
    private var sent: Double?
    private var moved = false

    nonisolated init(edge: PassbandEdge, width: Double, spanHz: Double) {
        self.edge = edge
        self.width = width
        self.spanHz = spanHz
    }

    private nonisolated func offset(atX x: Double) -> Double { (x / max(1, width) - 0.5) * spanHz }

    nonisolated mutating func moved(toX x: Double, at time: TimeInterval) -> RadioCommand? {
        moved = true
        guard let off = throttle.offer(offset(atX: x), now: time) else { return nil }
        sent = off
        return .dragPassbandEdge(edge, offsetHz: off)
    }

    /// The release: the offset at the release point once the handle has moved, unless it is
    /// already what was last sent; nothing for a plain click.
    nonisolated mutating func ended(atX x: Double) -> RadioCommand? {
        guard moved else { return nil }
        let off = offset(atX: x)
        _ = throttle.flush()
        guard off != sent else { return nil }
        sent = off
        return .dragPassbandEdge(edge, offsetHz: off)
    }
}

private extension Int64 {
    /// Floor division, so negative frequencies round the same way as positive ones.
    nonisolated func quotientAndRemainderFloor(by d: Int64) -> (Int64, Int64) {
        var q = self / d, r = self % d
        if r != 0 && (r < 0) != (d < 0) { q -= 1; r += d }
        return (q, r)
    }
}
