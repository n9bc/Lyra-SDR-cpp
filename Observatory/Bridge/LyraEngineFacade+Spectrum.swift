#if LYRA_BRIDGE
// Compiled only in the CMake build. Wraps the facade's non-blocking analyzer read.
extension LyraEngineFacade: SpectrumSource {
    func copySpectrum(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        let result = copySpectrum(into: base, maxBins: Int32(min(buffer.count, Int(Int32.max))))
        return Int(max(0, result))
    }
}
#endif
