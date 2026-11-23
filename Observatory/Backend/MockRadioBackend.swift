import Foundation
import Observation

/// Serves sample data and applies commands to it, standing in for the engine's
/// confirmation. Every capability is `.mocked`, so the console labels it as such.
@Observable @MainActor
final class MockRadioBackend: RadioBackend {
    @ObservationIgnored let capabilities: BackendCapabilities = .allMocked
    private(set) var snapshot: RadioSnapshot

    init(snapshot: RadioSnapshot = .sample) {
        self.snapshot = snapshot
    }

    func send(_ command: RadioCommand) {
        snapshot = Self.applying(command, to: snapshot)
    }

    /// The mock's stand-in for engine behaviour: what the snapshot becomes after `command`.
    nonisolated static func applying(_ command: RadioCommand, to s: RadioSnapshot) -> RadioSnapshot {
        var s = s
        switch command {
        case .focus(let id):
            guard id == .main || s.sub.enabled else { return s }
            s.session.focused = id
        case .setSubEnabled(let on):
            s.sub.enabled = on
            if !on && s.session.focused == .sub { s.session.focused = .main }
        case .tune(let id, let delta):
            guard s.receiver(id).enabled else { return s }
            let f = max(0, s.receiver(id).frequencyHz + delta)
            var low = id == .main ? s.display.spanLowHz : s.display.subSpanLowHz
            var high = id == .main ? s.display.spanHighHz : s.display.subSpanHighHz
            if f < low || f > high {
                let width = high - low
                low = f - width / 2
                if low < 0 { low = 0 }
                high = low + width
            }
            if id == .main {
                s.main.frequencyHz = f
                s.display.spanLowHz = low; s.display.spanHighHz = high
            } else {
                s.sub.frequencyHz = f
                s.display.subSpanLowHz = low; s.display.subSpanHighHz = high
            }
        }
        return s
    }
}
