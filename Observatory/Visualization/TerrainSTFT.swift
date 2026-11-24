import Accelerate
import Foundation

/// One audio-terrain row: Hann-windowed FFT of the newest samples, magnitude in dB (dBFS for a
/// full-scale sine), linearly resampled from 0...`maxHz` onto `points` values.
/// Pure and allocation-free apart from the returned row. Run it off the main thread.
struct TerrainSTFT {
    nonisolated static let floorDb: Float = -200

    let sampleRate: Double
    let fftSize: Int
    let maxHz: Double
    let points: Int

    private let log2n: vDSP_Length
    private let owner: SetupOwner
    private let window: [Float]
    private let windowSum: Float
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private let binPositions: [(lo: Int, frac: Float)]

    init(sampleRate: Double = 48_000, fftSize: Int = 4096, maxHz: Double = 3_000, points: Int = 201) {
        precondition(fftSize > 0 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two")
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.maxHz = maxHz
        self.points = points
        log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        owner = SetupOwner(vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: fftSize, isHalfWindow: false)
        windowSum = vDSP.sum(window)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mags = [Float](repeating: 0, count: fftSize / 2 + 1)
        let binHz = sampleRate / Double(fftSize)
        binPositions = (0..<points).map { p in
            let hz = points > 1 ? maxHz * Double(p) / Double(points - 1) : 0
            let pos = min(hz / binHz, Double(fftSize / 2 - 1))
            let lo = Int(pos)
            return (lo, Float(pos - Double(lo)))
        }
    }

    private final class SetupOwner {
        let setup: FFTSetup
        init(_ s: FFTSetup) { setup = s }
        deinit { vDSP_destroy_fftsetup(setup) }
    }
    /// `samples` is the newest `fftSize` samples (oldest first). Shorter input is zero-padded at
    /// the front; longer input uses its last `fftSize` samples.
    mutating func row(from samples: UnsafeBufferPointer<Float>) -> [Float] {
        let n = fftSize
        let have = min(samples.count, n)
        windowed.withUnsafeMutableBufferPointer { w in
            let pad = n - have
            if pad > 0 { for i in 0..<pad { w[i] = 0 } }
            if have > 0, let base = samples.baseAddress {
                (w.baseAddress! + pad).update(from: base + (samples.count - have), count: have)
            }
        }
        // In place through one pointer: aliasing the array as input and `&` output would copy it.
        windowed.withUnsafeMutableBufferPointer { w in
            window.withUnsafeBufferPointer { win in
                vDSP_vmul(w.baseAddress!, 1, win.baseAddress!, 1, w.baseAddress!, 1, vDSP_Length(n))
            }
        }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(owner.setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // Bin 0 packs DC (real) and Nyquist (imag); only bins 1..<n/2 are used here.
                ip[0] = 0
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        // zrip output is 2x the DFT; a full-scale sine of amplitude A gives |X| = A * sum(w) / 2.
        var scale = 1 / windowSum
        var eps: Float = 1e-10
        var one: Float = 1
        mags.withUnsafeMutableBufferPointer { mp in
            let m = mp.baseAddress!
            vDSP_vsmul(m, 1, &scale, m, 1, vDSP_Length(n / 2))
            vDSP_vsadd(m, 1, &eps, m, 1, vDSP_Length(n / 2))
            vDSP_vdbcon(m, 1, &one, m, 1, vDSP_Length(n / 2), 1)
        }

        var out = [Float](repeating: Self.floorDb, count: points)
        for p in 0..<points {
            let (lo, f) = binPositions[p]
            let hi = min(lo + 1, n / 2 - 1)
            out[p] = max(Self.floorDb, mags[lo] + (mags[hi] - mags[lo]) * f)
        }
        return out
    }
}

/// The last 4 s of terrain rows, newest first. One row per 4/30 s.
struct TerrainHistory {
    nonisolated static let rows = AudioTerrainView.rows
    private(set) var grid: [[Float]] = []

    mutating func push(_ row: [Float]) {
        grid.insert(row, at: 0)
        if grid.count > Self.rows { grid.removeLast(grid.count - Self.rows) }
    }

    mutating func reset() { grid.removeAll(keepingCapacity: true) }
}
