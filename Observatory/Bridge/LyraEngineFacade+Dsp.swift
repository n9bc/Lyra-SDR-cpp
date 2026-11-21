import Foundation

/// The slice of `LyraEngineFacade` that `DspBridge` consumes.
///
/// Same seam as `RadioFacade`: the Obj-C++ facade is only visible in the CMake
/// build, so `DspBridge` depends on this protocol. The real facade conforms
/// below (compiled only when `LYRA_BRIDGE` is defined); tests use a fake.
@MainActor
protocol DspFacade: AnyObject {
    var mode: String { get }
    /// Filter bandwidth in Hz. Named `bandwidthHz` (Int) because the Obj-C
    /// `bandwidth` property is `int` (Int32) and cannot be redeclared as Int.
    var bandwidthHz: Int { get }
    var nrEnabled: Bool { get }
    var nbEnabled: Bool { get }
    var anfEnabled: Bool { get }
    var agcMode: String { get }
    var squelchEnabled: Bool { get }
    var passbandLowHz: Double { get }
    var passbandHighHz: Double { get }

    func setMode(_ mode: String)
    func setBandwidthHz(_ hz: Int)
    func setNrEnabled(_ on: Bool)
    func setNbEnabled(_ on: Bool)
    func setAnfEnabled(_ on: Bool)
    func setAgcMode(_ mode: String)

    /// Registers the single DSP-state-changed callback (main thread). The
    /// callback re-reads the properties above.
    func observeDsp(_ onChange: @escaping @MainActor () -> Void)
}

#if LYRA_BRIDGE
// Compiled only in the CMake build, where the bridging header exposes
// LyraEngineFacade. Members not adapted here already match DspFacade.
extension LyraEngineFacade: DspFacade {
    var bandwidthHz: Int { Int(bandwidth) }

    func setBandwidthHz(_ hz: Int) { setBandwidth(Int32(clamping: hz)) }

    func observeDsp(_ onChange: @escaping @MainActor () -> Void) {
        // The facade invokes this block on the main thread.
        setDspCallback { _ in MainActor.assumeIsolated { onChange() } }
    }
}
#endif
