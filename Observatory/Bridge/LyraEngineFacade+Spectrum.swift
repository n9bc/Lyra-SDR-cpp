#if LYRA_BRIDGE
// Compiled only in the CMake build. Wraps the facade's non-blocking analyzer reads; only
// `SpectrumPump` calls these, on the main thread.
extension LyraEngineFacade: SpectrumSource {
    /// Main: `WdspEngine::copySpectrum`. Sub: `copySpectrumRx2`, which returns 0 on a single-ADC
    /// radio (0 means "keep the last frame").
    func copySpectrum(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        let n = Int32(clamping: buffer.count)
        let written = rx == .main ? copySpectrum(into: base, maxBins: n)
                                  : copySpectrumRx2(into: base, maxBins: n)
        return Int(max(0, written))
    }

    /// Main: `WdspEngine::copyWaterfallSpectrum` (the TX analyzer's slower waterfall output while
    /// keyed). Sub: `copySpectrumRx2`, as the Qt waterfall did.
    func copyWaterfallRow(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        let n = Int32(clamping: buffer.count)
        let written = rx == .main ? copyWaterfall(into: base, maxBins: n)
                                  : copySpectrumRx2(into: base, maxBins: n)
        return Int(max(0, written))
    }
}
#endif
