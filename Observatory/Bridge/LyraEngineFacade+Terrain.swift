#if LYRA_BRIDGE
// Compiled only in the CMake build. The console's audio tap: the engine's own flag
// (`WdspEngine::setConsoleAudioStreaming`), never the TCI server's.
extension LyraEngineFacade: TerrainAudioSource {
    func onConsoleAudio(_ handler: (@Sendable (UnsafeBufferPointer<Float>, Int) -> Void)?) {
        guard let handler else {
            setConsoleAudioBlockHandler(nil)
            return
        }
        // Delivered on the main thread; `samples` is valid only during the call.
        setConsoleAudioBlockHandler { samples, count, rate in
            guard count > 0 else { return }
            handler(UnsafeBufferPointer(start: samples, count: count), rate)
        }
    }
}
#endif
