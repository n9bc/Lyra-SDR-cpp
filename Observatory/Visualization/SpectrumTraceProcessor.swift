import Foundation

/// The Qt panadapter's display processing over one spectrum frame: time-based EWMA
/// smoothing, then per-bin peak hold over the smoothed trace. Pure CPU; allocation-free after
/// `resize`. Bins are dB, in the engine's 4096-bin order.
struct SpectrumTraceProcessor {
    /// Smoothed dB trace, one value per bin.
    private(set) var trace: [Float] = []
    /// Peak-hold trace; nil while peak hold is off.
    var peaks: [Float]? { peakActive ? peakStore : nil }

    private var peakStore: [Float] = []
    /// Seconds each bin's peak has sat above the trace without being refreshed.
    private var peakAge: [Double] = []
    private var peakActive = false
    private var lastPeak: PeakHoldSetting = .off
    private var seeded = false

    nonisolated init() {}

    /// Smoothing time constant, in seconds, for Prefs smoothing 1...10 (map section 7):
    /// `tau_frames = 1.2 * (12 / 1.2)^((s - 1) / 9)` at the Qt panadapter's nominal 60 fps.
    nonisolated static func smoothingTau(_ smoothing: Int) -> Double {
        let s = Double(min(max(smoothing, 1), 10))
        return 1.2 * pow(10.0, (s - 1) / 9) / 60
    }

    nonisolated mutating func resize(bins: Int) {
        guard bins != trace.count else { return }
        trace = [Float](repeating: -200, count: bins)
        peakStore = [Float](repeating: -200, count: bins)
        peakAge = [Double](repeating: 0, count: bins)
        seeded = false
        peakActive = false
    }

    /// Forgets the smoothed trace and the peaks; the next frame seeds both.
    nonisolated mutating func reset() {
        seeded = false
        peakActive = false
        lastPeak = .off
    }

    /// `dt` is the time since the previous ingest, so smoothing and decay do not depend on frame rate.
    nonisolated mutating func ingest(_ frame: UnsafeBufferPointer<Float>, dt: Double, smoothing: Int,
                                     peak: PeakHoldSetting, decayDbps: Double) {
        let n = trace.count
        guard n > 0, frame.count >= n, let src = frame.baseAddress else { return }
        let dt = max(dt, 0)

        // Smoothing.
        if !seeded || smoothing <= 0 {
            for i in 0..<n { trace[i] = src[i] }
        } else {
            let alpha = Float(1 - exp(-dt / Self.smoothingTau(smoothing)))
            for i in 0..<n { trace[i] += alpha * (src[i] - trace[i]) }
        }

        // Peaks. A mode change (or the first frame) re-seeds from the trace.
        guard peak != .off else {
            peakActive = false
            lastPeak = .off
            seeded = true
            return
        }
        let reseed = !seeded || !peakActive || peak != lastPeak
        peakActive = true
        lastPeak = peak
        seeded = true

        if reseed {
            for i in 0..<n { peakStore[i] = trace[i]; peakAge[i] = 0 }
            return
        }
        switch peak {
        case .off:
            break
        case .live:
            for i in 0..<n { peakStore[i] = trace[i] }
        case .hold:
            for i in 0..<n where trace[i] > peakStore[i] { peakStore[i] = trace[i] }
        case .seconds(let hold):
            let decay = Float(max(decayDbps, 0))
            for i in 0..<n {
                if trace[i] >= peakStore[i] {
                    peakStore[i] = trace[i]
                    peakAge[i] = 0
                    continue
                }
                let age = peakAge[i] + dt
                peakAge[i] = age
                if age > hold {
                    // Only the time past the hold window decays.
                    let t = Float(min(dt, age - hold))
                    peakStore[i] = max(trace[i], peakStore[i] - decay * t)
                }
            }
        }
    }
}
