import Observation

/// Audio controls bridge. With a facade, state mirrors live WdspEngine values
/// and actions are forwarded; without one (`mock()`), state is local.
@MainActor
@Observable
final class AudioBridge {
    /// AF gain. In facade mode this is the backend's `afGainDb`; assigning it
    /// (e.g. through a knob binding) forwards to the backend.
    var afGain: Double = 42.0 {
        didSet { if !isSyncing { facade?.setAfGainDb(afGain) } }
    }
    /// RF gain. Local only: the facade does not expose RF gain yet.
    var rfGain: Double = -12.0
    var muted: Bool = false
    var balance: Double = 0.0
    var volume: Double = 0.7

    @ObservationIgnored private let facade: (any AudioFacade)?
    @ObservationIgnored private var isSyncing = false

    private init(facade: (any AudioFacade)?) {
        self.facade = facade
    }

    /// Standalone instance with local state (SPM builds, tests, previews).
    static func mock() -> AudioBridge { AudioBridge(facade: nil) }

    /// Live instance mirroring `facade` and forwarding actions to it.
    convenience init(facade: some AudioFacade) {
        self.init(facade: Optional(facade))
        sync(from: facade)
        facade.observeAudio { [weak self, weak facade] in
            guard let self, let facade else { return }
            self.sync(from: facade)
        }
    }

    private func sync(from f: any AudioFacade) {
        isSyncing = true
        defer { isSyncing = false }
        volume = f.volume
        muted = f.muted
        afGain = f.afGainDb
        balance = f.balance
    }

    func setAfGain(_ value: Double) {
        if let facade { facade.setAfGainDb(value) } else { afGain = value }
    }

    func setRfGain(_ value: Double) { rfGain = value }

    func setVolume(_ value: Double) {
        if let facade { facade.setVolume(value) } else { volume = value }
    }

    func toggleMute() {
        if let facade { facade.setMuted(!muted) } else { muted.toggle() }
    }
}
