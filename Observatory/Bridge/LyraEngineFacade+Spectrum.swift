#if LYRA_BRIDGE
// Compiled only in the CMake build. Wraps the facade's non-blocking analyzer read.
extension LyraEngineFacade: SpectrumSource {
    func copySpectrum(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        // TODO(M4 Task 7): .main -> copySpectrum, .sub -> copySpectrumRx2 once the facade has them.
        // Until then the live console reads no spectrum (0 means "keep the last frame").
        0
    }

    func copyWaterfallRow(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        // TODO(M4 Task 7): .main -> copyWaterfallSpectrum, .sub -> copySpectrumRx2.
        0
    }
}
#endif
