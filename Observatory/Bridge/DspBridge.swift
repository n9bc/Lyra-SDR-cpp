import Observation

/// DSP settings bridge. With a facade, state mirrors live WdspEngine values and
/// actions are forwarded; without one (`mock()`), state is local.
@MainActor
@Observable
final class DspBridge {
    /// In mock mode, changing the mode resets bandwidth to the mode default. In
    /// facade mode bandwidth comes from the backend, so syncs skip the reset.
    var mode: String = "USB" {
        didSet {
            if !isSyncing { bandwidth = Self.defaultBandwidth(for: mode) }
        }
    }
    var bandwidth: Int = 3000
    var nrEnabled: Bool = true
    var nbEnabled: Bool = true
    var anfEnabled: Bool = false
    var agcMode: String = "MED"
    var squelchEnabled: Bool = false
    var squelchThreshold: Double = -100.0
    var passbandLowHz: Double = 150.0
    var passbandHighHz: Double = 2850.0

    @ObservationIgnored private let facade: (any DspFacade)?
    @ObservationIgnored private var isSyncing = false

    private init(facade: (any DspFacade)?) {
        self.facade = facade
    }

    /// Standalone instance with local state (SPM builds, tests, previews).
    static func mock() -> DspBridge { DspBridge(facade: nil) }

    /// Live instance mirroring `facade` and forwarding actions to it.
    convenience init(facade: some DspFacade) {
        self.init(facade: Optional(facade))
        sync(from: facade)
        facade.observeDsp { [weak self, weak facade] in
            guard let self, let facade else { return }
            self.sync(from: facade)
        }
    }

    private func sync(from f: any DspFacade) {
        isSyncing = true
        defer { isSyncing = false }
        mode = f.mode
        bandwidth = f.bandwidthHz
        nrEnabled = f.nrEnabled
        nbEnabled = f.nbEnabled
        anfEnabled = f.anfEnabled
        agcMode = f.agcMode
        squelchEnabled = f.squelchEnabled
        passbandLowHz = f.passbandLowHz
        passbandHighHz = f.passbandHighHz
    }

    /// Default filter bandwidth (Hz) for a mode.
    static func defaultBandwidth(for mode: String) -> Int {
        switch mode {
        case "CW", "CWL", "CWU": return 500
        case "AM", "SAM": return 6000
        case "FM", "FMN": return 12000
        default: return 2700 // USB, LSB, and other SSB-like modes
        }
    }

    /// Mock: changes mode and resets bandwidth to that mode's default.
    /// Facade: forwards to the backend, which owns the resulting bandwidth.
    func setMode(_ mode: String) {
        if let facade { facade.setMode(mode) } else { self.mode = mode }
    }

    func setBandwidth(_ hz: Int) {
        if let facade { facade.setBandwidthHz(hz) } else { bandwidth = hz }
    }

    func toggleNR() {
        if let facade { facade.setNrEnabled(!nrEnabled) } else { nrEnabled.toggle() }
    }

    func toggleNB() {
        if let facade { facade.setNbEnabled(!nbEnabled) } else { nbEnabled.toggle() }
    }

    func toggleANF() {
        if let facade { facade.setAnfEnabled(!anfEnabled) } else { anfEnabled.toggle() }
    }

    func setAgcMode(_ mode: String) {
        if let facade { facade.setAgcMode(mode) } else { agcMode = mode }
    }
}
