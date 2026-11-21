import Foundation

/// A provider of spectrum frames in dB, one value per FFT bin.
///
/// Same seam as `MeterFacade`: the Obj-C++ facade only exists in the CMake build,
/// so the spectrum bridge depends on this protocol. The real facade conforms in
/// `LyraEngineFacade+Spectrum.swift`; previews and tests use `SyntheticSpectrumSource`.
@MainActor
protocol SpectrumSource: AnyObject {
    /// Copies the latest frame into `buffer`. Returns bins written; 0 means no frame.
    func copySpectrum(into buffer: UnsafeMutableBufferPointer<Float>) -> Int
}

/// Deterministic-ish fake spectrum: noise floor plus three drifting carriers.
@MainActor
final class SyntheticSpectrumSource: SpectrumSource {
    static let binCount = 4096
    private var frame: UInt64 = 0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    init() {}

    private func nextNoise() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float((rng >> 40) & 0xFFFF) / 65535 * 2 - 1   // -1...1
    }

    func copySpectrum(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard buffer.baseAddress != nil else { return 0 }
        let n = min(buffer.count, Self.binCount)
        frame &+= 1
        let t = Float(frame % 1_000_000) * 0.004
        let peaks: [(center: Float, db: Float)] = [
            (1024 + 300 * sinf(t), -60),
            (2048 + 400 * sinf(t * 0.7 + 1), -75),
            (3000 + 350 * sinf(t * 0.5 + 2), -90),
        ]
        let sigma: Float = 6
        for i in 0..<n {
            var v: Float = -120 + 3 * nextNoise()
            for p in peaks {
                let d = (Float(i) - p.center) / sigma
                let g = p.db + 120 // height above floor
                v = max(v, -120 + g * expf(-0.5 * d * d))
            }
            buffer[i] = min(-50, max(-130, v))
        }
        return n
    }
}
