import Foundation

/// Derives the console's connection phase from the engine's running flags and datagram rate.
///
/// The engine's "running" flag can turn true before any data arrives, so on P1 only
/// `datagramsPerSec > 0` proves streaming; on P2 `p2Running` does. `stalled` is adapter logic:
/// it is entered after `stallAfter` seconds without data. Pure and clock-free: callers pass `now`.
struct ConnectionTracker: Equatable, Sendable {
    /// Matches MainWindow's connect watchdog.
    static let connectTimeout: TimeInterval = 8
    /// Silence after which an open connection counts as stalled.
    static let stallAfter: TimeInterval = 2

    private(set) var phase: ConnectionPhase = .disconnected

    private var requestedIP: String?
    private var connectRequestedAt: Date?
    private var disconnectRequested = false
    private var wasUp = false
    /// When the engine first reported running for the current session.
    private var openedAt: Date?
    /// The last update that carried data.
    private var lastDataAt: Date?
    /// Whether any data has arrived since the last connect request.
    private var hadData = false
    /// The requested connect got a socket but no datagram within `connectTimeout`.
    private var timedOut = false

    mutating func requestConnect(ip: String, at: Date) {
        requestedIP = ip
        connectRequestedAt = at
        disconnectRequested = false
        hadData = false
        timedOut = false
        lastDataAt = nil
        phase = .connecting
    }

    /// Records that the user asked to disconnect, so the next drop is not reported as an error.
    mutating func requestDisconnect() {
        switch phase {
        case .disconnected:
            return
        case .error:
            if wasUp {
                // The error can show while the engine is still up (connect timeout).
                disconnectRequested = true
            } else {
                clearSession()
                phase = .disconnected
            }
        default:
            disconnectRequested = true
        }
    }

    mutating func update(running: Bool, p2Running: Bool, datagramsPerSec: Double, now: Date) {
        let isUp = running || p2Running
        defer { wasUp = isUp }

        guard isUp else {
            updateDown(now: now)
            return
        }

        if !wasUp {
            openedAt = now
            lastDataAt = nil
        }
        // Waiting for the engine to finish closing after a user disconnect.
        if disconnectRequested { return }

        if p2Running || datagramsPerSec > 0 {
            lastDataAt = now
            hadData = true
            timedOut = false
            connectRequestedAt = nil
            phase = .streaming
            return
        }

        // A requested connect whose socket opened but never got data: the radio is off or
        // unreachable (the engine reports running before any radio contact).
        if !hadData, let at = connectRequestedAt {
            if timedOut || now.timeIntervalSince(at) >= Self.connectTimeout {
                timedOut = true
                phase = .error(noAnswerMessage)
                return
            }
        }

        let silentSince = lastDataAt ?? openedAt ?? now
        if now.timeIntervalSince(silentSince) >= Self.stallAfter {
            phase = .stalled
        } else if lastDataAt == nil {
            phase = .socketOpen
        }
        // Otherwise keep streaming: a brief gap is not yet a stall.
    }

    private mutating func updateDown(now: Date) {
        if disconnectRequested {
            disconnectRequested = false
            clearSession()
            phase = .disconnected
        } else if wasUp {
            clearSession()
            phase = .error("Connection closed")
        } else if phase == .connecting, let at = connectRequestedAt,
                  now.timeIntervalSince(at) >= Self.connectTimeout {
            connectRequestedAt = nil
            phase = .error(noAnswerMessage)
        }
    }

    /// With no known address (discovery) the text carries no " at ..." suffix.
    private var noAnswerMessage: String {
        let ip = (requestedIP ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? "No radio answered" : "No radio answered at \(ip)"
    }

    private mutating func clearSession() {
        openedAt = nil
        lastDataAt = nil
        hadData = false
        timedOut = false
        connectRequestedAt = nil
    }
}
