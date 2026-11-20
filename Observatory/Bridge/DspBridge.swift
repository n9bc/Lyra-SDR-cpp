import Observation

/// DSP settings bridge. P0: mock data only (no C++ linkage yet).
@Observable
final class DspBridge {
    var mode: String = "USB"
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

    func setMode(_ mode: String) { self.mode = mode }
    func setBandwidth(_ hz: Int) { bandwidth = hz }
    func toggleNR() { nrEnabled.toggle() }
    func toggleNB() { nbEnabled.toggle() }
    func toggleANF() { anfEnabled.toggle() }
    func setAgcMode(_ mode: String) { agcMode = mode }
}
