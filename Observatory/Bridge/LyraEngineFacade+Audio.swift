import Foundation

/// The slice of `LyraEngineFacade` that `AudioBridge` consumes.
///
/// Same seam as `RadioFacade`/`DspFacade`; see `DspFacade` for the rationale.
@MainActor
protocol AudioFacade: AnyObject {
    var volume: Double { get }
    var muted: Bool { get }
    var afGainDb: Double { get }
    var balance: Double { get }

    func setVolume(_ volume: Double)
    func setMuted(_ on: Bool)
    func setAfGainDb(_ db: Double)

    /// Registers the single audio-state-changed callback (main thread). The
    /// callback re-reads the properties above.
    func observeAudio(_ onChange: @escaping @MainActor () -> Void)
}

#if LYRA_BRIDGE
// Compiled only in the CMake build. Members already match AudioFacade.
extension LyraEngineFacade: AudioFacade {
    func observeAudio(_ onChange: @escaping @MainActor () -> Void) {
        // The facade invokes this block on the main thread.
        setAudioCallback { _ in MainActor.assumeIsolated { onChange() } }
    }
}
#endif
