import Foundation

/// The slice of `LyraEngineFacade` that `MeterBridge` consumes.
///
/// Same seam as `RadioFacade`/`DspFacade`: the Obj-C++ facade is only visible in
/// the CMake build, so `MeterBridge` depends on this protocol. The real facade
/// conforms below (compiled only when `LYRA_BRIDGE` is defined); tests use a fake.
@MainActor
protocol MeterFacade: AnyObject {
    /// Normalised 0...1 along the S-meter scale (not dBm).
    var meterLevel: Double { get }
    var meterPeak: Double { get }
    /// 0...1 position of S9 on the scale.
    var meterNormAtS9: Double { get }
    /// Pre-formatted S-unit text ("S9", "S9+20").
    var meterText: String { get }
    /// Pre-formatted dBm text ("-53 dBm").
    var meterDbmText: String { get }
    var liveSwr: Double { get }
    var noiseFloorDbm: Double { get }
    var rxSnrDb: Double { get }

    /// Registers the single meter-updated callback (main thread). The callback
    /// re-reads the properties above.
    func observeMeter(_ onChange: @escaping @MainActor () -> Void)
}

#if LYRA_BRIDGE
// Compiled only in the CMake build. Members already match MeterFacade.
extension LyraEngineFacade: MeterFacade {
    func observeMeter(_ onChange: @escaping @MainActor () -> Void) {
        // The facade invokes this block on the main thread.
        setMeterCallback { _ in MainActor.assumeIsolated { onChange() } }
    }
}
#endif
