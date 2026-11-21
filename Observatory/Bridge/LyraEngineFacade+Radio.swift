#if LYRA_BRIDGE
// Compiled only in the CMake build, where the bridging header exposes
// LyraEngineFacade. The facade's members already match RadioFacade.
extension LyraEngineFacade: RadioFacade {
    func observeRadio(_ onChange: @escaping @MainActor () -> Void) {
        // The facade invokes this block on the main thread.
        setRadioCallback { _ in MainActor.assumeIsolated { onChange() } }
    }
}
#endif
