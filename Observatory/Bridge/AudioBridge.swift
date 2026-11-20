import Observation

/// Audio controls bridge. P0: mock data only (no C++ linkage yet).
@Observable
final class AudioBridge {
    var afGain: Double = 42.0
    var rfGain: Double = -12.0
    var muted: Bool = false
    var balance: Double = 0.0
    var volume: Double = 0.7

    static func mock() -> AudioBridge { AudioBridge() }

    func setAfGain(_ value: Double) { afGain = value }
    func setRfGain(_ value: Double) { rfGain = value }
    func toggleMute() { muted.toggle() }
}
