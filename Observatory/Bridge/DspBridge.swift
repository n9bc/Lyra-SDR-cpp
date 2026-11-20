import Observation

/// DSP settings bridge. P0: mock data only (no C++ linkage yet).
@Observable
final class DspBridge {
    /// Changing the mode (via `setMode` or directly) resets bandwidth to the mode default.
    var mode: String = "USB" {
        didSet { bandwidth = Self.defaultBandwidth(for: mode) }
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

    static func mock() -> DspBridge { DspBridge() }

    /// Default filter bandwidth (Hz) for a mode.
    static func defaultBandwidth(for mode: String) -> Int {
        switch mode {
        case "CW", "CWL", "CWU": return 500
        case "AM", "SAM": return 6000
        case "FM", "FMN": return 12000
        default: return 2700 // USB, LSB, and other SSB-like modes
        }
    }

    /// Changes mode and resets bandwidth to that mode's default.
    func setMode(_ mode: String) {
        self.mode = mode
    }
    func setBandwidth(_ hz: Int) { bandwidth = hz }
    func toggleNR() { nrEnabled.toggle() }
    func toggleNB() { nbEnabled.toggle() }
    func toggleANF() { anfEnabled.toggle() }
    func setAgcMode(_ mode: String) { agcMode = mode }
}
