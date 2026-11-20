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

    func setFrequency(_ hz: UInt32) { rx1FreqHz = hz }
    func toggleMox() { moxActive.toggle() }
    func start() { isRunning = true }
    func stop() { isRunning = false }
}
