import Foundation

/// The only reader of the engine's spectrum and waterfall data. Pulls each stream at most once
/// per `minInterval` (so two stacks drawing in the same frame share one pull), always asks for
/// the full 4096 bins, and keeps the last good frame when the engine has nothing new.
///
/// Main thread only (the facade's spectrum read is not thread safe). No allocation after init.
@MainActor
final class SpectrumPump {
    nonisolated static let bins = 4096
    /// Below this the analyzer is reporting its floor, not a signal.
    nonisolated static let floorDb: Float = -199

    private let source: any SpectrumSource
    private let minInterval: TimeInterval
    /// One allocation: staging, then Main/Sub spectrum, then Main/Sub waterfall row (4096 each).
    /// Freed in `deinit`, which is nonisolated, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) let storage: UnsafeMutablePointer<Float>
    private var hasSpectrum = [false, false]
    private var hasRow = [false, false]
    private var lastPull: TimeInterval?

    /// Bumps only when a good frame arrived.
    private(set) var frameSerial: UInt64 = 0
    /// Bumps when a good spectrum (not waterfall row) arrived for that receiver, so a renderer
    /// ingests each frame once.
    private var spectrumSerials: [UInt64] = [0, 0]

    init(source: any SpectrumSource, minInterval: TimeInterval = 1.0 / 120) {
        self.source = source
        self.minInterval = minInterval
        let count = 5 * Self.bins
        storage = .allocate(capacity: count)
        storage.initialize(repeating: -200, count: count)
    }

    deinit { storage.deallocate() }

    private var staging: UnsafeMutablePointer<Float> { storage }
    private func spectrumPointer(_ i: Int) -> UnsafeMutablePointer<Float> { storage + (1 + i) * Self.bins }
    private func rowPointer(_ i: Int) -> UnsafeMutablePointer<Float> { storage + (3 + i) * Self.bins }

    private static func index(_ rx: ReceiverID) -> Int { rx == .main ? 0 : 1 }

    /// Pulls the Main streams, and the Sub streams when `sub`, unless one was pulled less than
    /// `minInterval` ago. Call from the display tick (the MTKView draw callback).
    func tick(now: TimeInterval, sub: Bool) {
        if let last = lastPull, now - last < minInterval, now >= last { return }
        lastPull = now
        pull(.main, waterfall: false)
        pull(.main, waterfall: true)
        if sub {
            pull(.sub, waterfall: false)
            pull(.sub, waterfall: true)
        }
    }

    private func pull(_ rx: ReceiverID, waterfall: Bool) {
        let buffer = UnsafeMutableBufferPointer(start: staging, count: Self.bins)
        let n = waterfall ? source.copyWaterfallRow(rx, into: buffer) : source.copySpectrum(rx, into: buffer)
        guard Self.isGood(UnsafeBufferPointer(buffer), count: n) else { return }
        let i = Self.index(rx)
        if waterfall {
            rowPointer(i).update(from: staging, count: Self.bins)
            hasRow[i] = true
        } else {
            spectrumPointer(i).update(from: staging, count: Self.bins)
            hasSpectrum[i] = true
            spectrumSerials[i] &+= 1
        }
        frameSerial &+= 1
    }

    /// Good means exactly 4096 bins with at least one above -199 dB. A short or empty return is the
    /// analyzer mid-reopen; an all -200 frame is its floor before the first real data.
    nonisolated static func isGood(_ frame: UnsafeBufferPointer<Float>, count: Int) -> Bool {
        guard count == bins, frame.count >= bins else { return false }
        for i in 0..<bins where frame[i] > floorDb { return true }
        return false
    }

    func spectrumSerial(_ rx: ReceiverID) -> UInt64 { spectrumSerials[Self.index(rx)] }

    /// The last good spectrum for `rx` (4096 dB values), or nil before the first.
    func spectrum(_ rx: ReceiverID) -> UnsafeBufferPointer<Float>? {
        let i = Self.index(rx)
        return hasSpectrum[i] ? UnsafeBufferPointer(start: spectrumPointer(i), count: Self.bins) : nil
    }

    /// The last good waterfall row for `rx` (4096 dB values), or nil before the first.
    func waterfallRow(_ rx: ReceiverID) -> UnsafeBufferPointer<Float>? {
        let i = Self.index(rx)
        return hasRow[i] ? UnsafeBufferPointer(start: rowPointer(i), count: Self.bins) : nil
    }
}
