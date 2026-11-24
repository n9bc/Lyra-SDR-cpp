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

    /// Rounds to the 100 Hz grid, else to the step grid when the step is above 1 Hz (QML `snapCarrier`).
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

    /// Middle (or option) click: toggles focus, putting VFO B on the snapped frequency under the cursor.
    nonisolated static func middleClick(atX x: Double, context c: SpectrumGestureContext) -> RadioCommand {
        let hz = hz(atX: x, width: c.width, centreHz: c.centreHz, spanHz: c.spanHz)
        return .spectrumFocusToggle(hz: snapCarrier(hz, stepHz: c.stepHz, round100: c.round100))
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

private extension Int64 {
    /// Floor division, so negative frequencies round the same way as positive ones.
    nonisolated func quotientAndRemainderFloor(by d: Int64) -> (Int64, Int64) {
        var q = self / d, r = self % d
        if r != 0 && (r < 0) != (d < 0) { q -= 1; r += d }
        return (q, r)
    }
}
