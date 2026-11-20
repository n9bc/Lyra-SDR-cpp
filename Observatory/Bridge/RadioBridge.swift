import Observation

/// Radio state bridge. P0: mock data only (no C++ linkage yet).
@Observable
final class RadioBridge {
    var isRunning: Bool = false
    var rx1FreqHz: UInt32 = 14_074_000
    var rx2FreqHz: UInt32 = 14_074_000
    var moxActive: Bool = false
    var splitEnabled: Bool = false
    var vfoBHz: UInt32 = 14_074_000
    var txDisplayActive: Bool = false

    static func mock() -> RadioBridge { RadioBridge() }

    /// Ceiling for tunable frequency; keeps UInt32.max (a common sentinel) out of the
    /// state downstream consumers read. Real band-edge limits belong to the backend.
    static let maxFrequencyHz: UInt32 = 500_000_000

    func setFrequency(_ hz: UInt32) { rx1FreqHz = min(hz, Self.maxFrequencyHz) }
    func toggleMox() { moxActive.toggle() }
    func start() { isRunning = true }
    func stop() { isRunning = false }
}
