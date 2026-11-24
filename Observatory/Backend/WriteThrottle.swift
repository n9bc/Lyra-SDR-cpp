import Foundation

/// Caps one control's engine writes (map H14: at most one per 33 ms) and keeps the final value
/// so a release can flush it. Pure and clock-injected: callers pass `now` in seconds from any
/// monotonic clock, so tests need no real time.
struct WriteThrottle<Value: Equatable> {
    let interval: TimeInterval
    private var lastSent: Value?
    private var lastSentAt: TimeInterval?
    private var held: Value?

    init(interval: TimeInterval = 1.0 / 30) {
        self.interval = interval
    }

    /// The value to send now, or nil when it is held back until the interval has passed (the
    /// next `offer` after that, or `flush`, delivers it).
    mutating func offer(_ v: Value, now: TimeInterval) -> Value? {
        if let at = lastSentAt, now - at < interval, now >= at {
            held = v
            return nil
        }
        lastSent = v
        lastSentAt = now
        held = nil
        return v
    }

    /// The held value, if it differs from the last one sent (call on release).
    mutating func flush() -> Value? {
        defer { held = nil }
        guard let v = held, v != lastSent else { return nil }
        lastSent = v
        return v
    }
}

extension WriteThrottle: Sendable where Value: Sendable {}
