import Observation

/// The slice of `LyraEngineFacade` that `RadioBridge` consumes.
///
/// The Obj-C++ facade is only visible in the CMake build (via the bridging
/// header), not to the standalone SPM build, so `RadioBridge` depends on this
/// protocol instead. The real facade conforms in `LyraEngineFacade+Radio.swift`
/// (compiled only when `LYRA_BRIDGE` is defined); tests use a fake.
@MainActor
protocol RadioFacade: AnyObject {
    var isRunning: Bool { get }
    var rx1FreqHz: UInt32 { get }
    var moxActive: Bool { get }
    var splitEnabled: Bool { get }
    var vfoBHz: UInt32 { get }
    var txDisplayActive: Bool { get }

    func setRx1FreqHz(_ hz: UInt32)
    func setVfoBHz(_ hz: UInt32)
    func setMox(_ on: Bool)
    func setSplitEnabled(_ on: Bool)
    func start(withIp ip: String)
    func startSavedRadio()
    func stop()
    var savedRadioIp: String { get }

    /// Registers the single radio-state-changed callback (main thread). The
    /// callback re-reads the properties above.
    func observeRadio(_ onChange: @escaping @MainActor () -> Void)
}

/// Radio state bridge. With a facade, state mirrors live HL2Stream values and
/// actions are forwarded; without one (`mock()`), state is local.
@MainActor
@Observable
final class RadioBridge {
    var isRunning: Bool = false
    var rx1FreqHz: UInt32 = 14_074_000
    var rx2FreqHz: UInt32 = 14_074_000
    var moxActive: Bool = false
    var splitEnabled: Bool = false
    var vfoBHz: UInt32 = 14_074_000
    var txDisplayActive: Bool = false

    /// Ceiling for tunable frequency; keeps UInt32.max (a common sentinel) out of the
    /// state downstream consumers read. Real band-edge limits belong to the backend.
    static let maxFrequencyHz: UInt32 = 500_000_000

    @ObservationIgnored private let facade: (any RadioFacade)?

    private init(facade: (any RadioFacade)?) {
        self.facade = facade
    }

    /// Standalone instance with local state (SPM builds, tests, previews).
    static func mock() -> RadioBridge { RadioBridge(facade: nil) }

    /// Live instance mirroring `facade` and forwarding actions to it.
    convenience init(facade: some RadioFacade) {
        self.init(facade: Optional(facade))
        sync(from: facade)
        facade.observeRadio { [weak self, weak facade] in
            guard let self, let facade else { return }
            self.sync(from: facade)
        }
    }

    private func sync(from f: any RadioFacade) {
        isRunning = f.isRunning
        rx1FreqHz = f.rx1FreqHz
        moxActive = f.moxActive
        splitEnabled = f.splitEnabled
        vfoBHz = f.vfoBHz
        txDisplayActive = f.txDisplayActive
    }

    func setFrequency(_ hz: UInt32) {
        let clamped = min(hz, Self.maxFrequencyHz)
        if let facade { facade.setRx1FreqHz(clamped) } else { rx1FreqHz = clamped }
    }

    func setVfoBFrequency(_ hz: UInt32) {
        let clamped = min(hz, Self.maxFrequencyHz)
        if let facade { facade.setVfoBHz(clamped) } else { vfoBHz = clamped }
    }

    func toggleMox() {
        if let facade { facade.setMox(!moxActive) } else { moxActive.toggle() }
    }

    func start() {
        if let facade { facade.startSavedRadio() } else { isRunning = true }
    }

    func stop() {
        if let facade { facade.stop() } else { isRunning = false }
    }
}
