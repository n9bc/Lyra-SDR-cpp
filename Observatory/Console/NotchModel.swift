import CoreGraphics
import Foundation

/// Pure maths and gestures for the manual notch filters drawn on the Main spectrum, ported from
/// `PanadapterPanel.qml` (map section 3).
///
/// Notch offsets are relative to the DISPLAY CENTRE (H17): the overlay uses `offsetHz` as the
/// engine reports it and never adds the CTUN dial offset, unlike the passband.
enum NotchModel {
    /// Movement below this many points is a click (QML notch delegate, not the 6 px spectrum one).
    nonisolated static let moveThresholdPx = 4.0
    /// The narrowest a notch is drawn.
    nonisolated static let minDrawWidthPx: CGFloat = 3
    /// The smallest hit area, so a thin notch can still be grabbed.
    nonisolated static let minHitWidthPx: CGFloat = 14
    /// Width a new notch is added with.
    nonisolated static let defaultWidthHz = 200.0
    nonisolated static let widthRange = 10.0...20_000.0
    /// Why the notch gestures do nothing on the Sub stack (notches act on RX1 only, H13).
    nonisolated static let subStackReason = "Notches are on the main receiver"
    /// A scroll step that is not yet in the snapshot is built on for this long.
    nonisolated static let staleAfter: TimeInterval = 0.5

    /// Horizontal position of a notch centre.
    nonisolated static func x(offsetHz: Double, width: Double, spanHz: Double) -> CGFloat {
        guard spanHz > 0 else { return CGFloat(width / 2) }
        return CGFloat(width * (0.5 + offsetHz / spanHz))
    }

    /// The offset from the display centre at horizontal position `x`.
    nonisolated static func offset(atX x: Double, width: Double, spanHz: Double) -> Double {
        guard width > 0 else { return 0 }
        return (x / width - 0.5) * spanHz
    }

    nonisolated static func drawWidth(widthHz: Double, width: Double, spanHz: Double) -> CGFloat {
        guard spanHz > 0 else { return minDrawWidthPx }
        return max(minDrawWidthPx, CGFloat(width * widthHz / spanHz))
    }

    /// The notch under `x`: hit area `max(drawWidth, 14)` centred on the notch, nearest centre wins.
    nonisolated static func hitIndex(x: Double, notches: [NotchInfo], width: Double, spanHz: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (i, n) in notches.enumerated() {
            let cx = Double(Self.x(offsetHz: n.offsetHz, width: width, spanHz: spanHz))
            let half = Double(max(drawWidth(widthHz: n.widthHz, width: width, spanHz: spanHz), minHitWidthPx)) / 2
            let d = abs(x - cx)
            if d <= half, best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// Wheel notches to a width factor: up narrows (x0.8), down widens (x1.25).
    nonisolated static func widthFactor(ticks: Int) -> Double {
        ticks >= 0 ? pow(0.8, Double(ticks)) : pow(1.25, Double(-ticks))
    }

    nonisolated static func clampedWidth(_ hz: Double) -> Double {
        min(max(hz, widthRange.lowerBound), widthRange.upperBound)
    }

    /// The notches a stack draws: Main only, since they act on RX1 (H13).
    nonisolated static func visible(_ notches: [NotchInfo], on stack: ReceiverID) -> [NotchInfo] {
        stack == .main ? notches : []
    }

    /// Whether the notch gestures work on `stack`, given the `.notches` control's availability.
    nonisolated static func availability(stack: ReceiverID, status: CapabilityStatus) -> CapabilityStatus {
        stack == .sub ? .unavailable(subStackReason) : status
    }

    /// A wheel tick over a notch widens or narrows it (the wheel is consumed: no tune). Nil when
    /// no notch is under `x`, so the caller tunes as usual.
    nonisolated static func scrollCommand(ticks: Int, x: Double, notches: [NotchInfo], width: Double,
                                          spanHz: Double, accumulator: inout NotchWidthAccumulator,
                                          now: TimeInterval) -> RadioCommand? {
        guard ticks != 0, let i = hitIndex(x: x, notches: notches, width: width, spanHz: spanHz) else { return nil }
        let w = accumulator.next(index: i, snapshotWidth: notches[i].widthHz,
                                 factor: widthFactor(ticks: ticks), now: now)
        return .setNotchWidth(index: i, widthHz: w)
    }
}

/// Scrolling over a notch to change its width, throttled per notch to one write per 33 ms (H14):
/// each wheel tick builds on the width last asked for (`NotchWidthAccumulator`), the throttle
/// holds back what comes too soon, and `flush` sends the held widths when the scroll ends. A
/// width equal to the snapshot's is never written (a notch already at its clamp stays quiet), and
/// a held width is dropped if the notch list changed under it (H16: indices shift on every edit).
struct NotchWidthScroll: Sendable {
    private var accumulator = NotchWidthAccumulator()
    private var throttles: [Int: WriteThrottle<Double>] = [:]
    /// The notch offsets the held widths' indices refer to.
    private var offsetsAtOffer: [Double] = []

    nonisolated init() {}

    /// One scroll event of `ticks`. `consumed` is false when no notch is under `x` (the caller
    /// tunes); otherwise `command` is the write to send now, if any.
    nonisolated mutating func scrolled(ticks: Int, x: Double, notches: [NotchInfo], width: Double, spanHz: Double,
                                       now: TimeInterval) -> (consumed: Bool, command: RadioCommand?) {
        guard let command = NotchModel.scrollCommand(ticks: ticks, x: x, notches: notches, width: width,
                                                     spanHz: spanHz, accumulator: &accumulator, now: now),
              case .setNotchWidth(let index, let target) = command else { return (false, nil) }
        let offsets = notches.map(\.offsetHz)
        if offsets != offsetsAtOffer {
            throttles = [:]
            offsetsAtOffer = offsets
        }
        var throttle = throttles[index] ?? WriteThrottle<Double>(interval: SpectrumGestureModel.dragThrottle)
        defer { throttles[index] = throttle }
        guard let v = throttle.offer(target, now: now), v != notches[index].widthHz else { return (true, nil) }
        return (true, .setNotchWidth(index: index, widthHz: v))
    }

    /// The held widths, for the scroll's end (phase ended, momentum ended, or a short idle after a
    /// discrete wheel). Each counts as a write for the throttle.
    nonisolated mutating func flush(notches: [NotchInfo], now: TimeInterval) -> [RadioCommand] {
        let intact = notches.map(\.offsetHz) == offsetsAtOffer
        var out: [RadioCommand] = []
        for index in throttles.keys.sorted() {
            guard let v = throttles[index]?.flush(now: now) else { continue }
            guard intact, index < notches.count, v != notches[index].widthHz else { continue }
            out.append(.setNotchWidth(index: index, widthHz: v))
        }
        return out
    }
}

/// Builds fast wheel steps on the width last asked for until the snapshot reports it, so steps
/// sent between two snapshots are not lost by scaling the same stale width.
struct NotchWidthAccumulator: Sendable {
    private var requested: (index: Int, width: Double, at: TimeInterval)?

    nonisolated init() {}

    nonisolated mutating func next(index: Int, snapshotWidth: Double, factor: Double, now: TimeInterval) -> Double {
        var base = snapshotWidth
        if let r = requested, r.index == index {
            let caughtUp = abs(snapshotWidth - r.width) <= 1e-6 * max(1, r.width)
            if !caughtUp, now >= r.at, now - r.at < NotchModel.staleAfter { base = r.width }
        }
        let target = NotchModel.clampedWidth(base * factor)
        requested = (index, target, now)
        return target
    }
}

/// One left or right button press-drag-release that began on a notch, or a right press on empty
/// spectrum (which adds one). Indices are taken from the notch list at the press; if the engine's
/// list changes under the gesture in any way but the dragged notch's own offset, the gesture ends
/// with no further command (H16: indices shift on every edit).
struct NotchGesture {
    enum Button: Sendable { case left, right }
    private enum Target { case notch(Int), empty }

    private let button: Button
    private let target: Target
    private let startX: Double
    private let width: Double
    private let spanHz: Double
    private let notchesAtStart: [NotchInfo]
    private var dragging = false
    private var movedPastAddThreshold = false
    private var dead = false
    private var finished = false
    private var throttle = WriteThrottle<Double>(interval: SpectrumGestureModel.dragThrottle)
    private var lastSent: Double?

    /// Nil for a left press that is not on a notch: that is a tuning gesture.
    nonisolated init?(button: Button, x: Double, notches: [NotchInfo], width: Double, spanHz: Double) {
        if let i = NotchModel.hitIndex(x: x, notches: notches, width: width, spanHz: spanHz) {
            target = .notch(i)
        } else if button == .right {
            target = .empty
        } else {
            return nil
        }
        self.button = button
        self.startX = x
        self.width = width
        self.spanHz = spanHz
        self.notchesAtStart = notches
    }

    /// Whether the engine's list is still the one the press saw. Only the dragged notch's offset
    /// may differ (that is our own move coming back).
    private nonisolated func intact(_ current: [NotchInfo]) -> Bool {
        guard current.count == notchesAtStart.count else { return false }
        for i in current.indices {
            if case .notch(let dragged) = target, dragged == i {
                if current[i].widthHz != notchesAtStart[i].widthHz
                    || current[i].active != notchesAtStart[i].active { return false }
            } else if current[i] != notchesAtStart[i] {
                return false
            }
        }
        return true
    }

    private nonisolated func offset(atX x: Double) -> Double {
        NotchModel.offset(atX: min(max(x, 0), width), width: width, spanHz: spanHz)
    }

    /// The command for a cursor move: nil below the threshold, inside the throttle window, or
    /// once the list has changed.
    nonisolated mutating func moved(toX x: Double, at time: TimeInterval, notches current: [NotchInfo]) -> RadioCommand? {
        guard !dead, !finished else { return nil }
        guard intact(current) else { dead = true; return nil }
        if abs(x - startX) >= SpectrumGestureModel.dragThresholdPx { movedPastAddThreshold = true }
        guard case .notch(let index) = target else { return nil }
        if !dragging {
            guard abs(x - startX) >= NotchModel.moveThresholdPx else { return nil }
            dragging = true
        }
        guard let v = throttle.offer(offset(atX: x), now: time) else { return nil }
        lastSent = v
        return .moveNotch(index: index, offsetHz: v)
    }

    /// The command for the release: a drag flushes what the throttle held, a right click removes
    /// the notch under it or adds one on empty spectrum, a left click does nothing.
    nonisolated mutating func ended(atX x: Double, at time: TimeInterval, notches current: [NotchInfo]) -> RadioCommand? {
        guard !finished else { return nil }
        finished = true
        guard !dead, intact(current) else { return nil }
        switch target {
        case .notch(let index):
            if dragging {
                guard let v = throttle.offer(offset(atX: x), now: time) ?? throttle.flush(), v != lastSent else { return nil }
                return .moveNotch(index: index, offsetHz: v)
            }
            return button == .right ? .removeNotch(index: index) : nil
        case .empty:
            if abs(x - startX) >= SpectrumGestureModel.dragThresholdPx { movedPastAddThreshold = true }
            guard !movedPastAddThreshold else { return nil }
            return .addNotch(offsetHz: offset(atX: startX))
        }
    }
}
