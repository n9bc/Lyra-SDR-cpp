import Foundation
import Observation

/// Where the audio terrain's samples come from: the engine's console audio tap. The facade
/// conforms (in `LyraEngineFacade+Terrain.swift`); tests use a fake. Main thread only, except
/// that the block handler runs wherever the source delivers (the facade: main), so it must be
/// thread safe.
@MainActor
protocol TerrainAudioSource: AnyObject {
    /// Turns the console's own audio tap on or off. It is a separate engine flag from the TCI
    /// server's, so this never touches a TCI client's stream.
    func setConsoleAudioStreaming(_ on: Bool)
    /// Replaces the one handler that receives each block of received audio (mono float32 and its
    /// sample rate); nil removes it. The samples are valid only during the call.
    func onConsoleAudio(_ handler: (@Sendable (UnsafeBufferPointer<Float>, Int) -> Void)?)
}

/// The live audio terrain: received audio from the engine into an `AudioRing`, one STFT row every
/// 133 ms on a background task, published as `grid` (newest row first) on the main thread.
///
/// The engine tap runs only while the terrain is expanded, the console window is visible and the
/// radio is streaming, as `SpectrumPump` does for the spectrum; otherwise it is off.
@Observable @MainActor
final class TerrainFeed {
    nonisolated static let rowInterval: Duration = .milliseconds(133)
    /// A block must have arrived this recently for the terrain to count as live.
    nonisolated static let liveWindow: TimeInterval = 0.5
    nonisolated static let sampleRate = 48_000

    /// Newest row first, at most `TerrainHistory.rows`. Each row is `TerrainSTFT` dBFS values.
    private(set) var grid: [[Float]] = []
    /// True only after an audio block arrived within `liveWindow`. Refreshed on every row tick.
    private(set) var isLive = false

    /// The terrain is expanded. Defaults true, as the display store does.
    var isExpanded = true { didSet { apply() } }
    /// The window is covered or minimised.
    var isOccluded = false { didSet { apply() } }
    /// The connection phase is streaming.
    var isStreaming = false { didSet { apply() } }
    /// The radio's confirmed transmit state is plain RX. While false the tap carries the TX monitor
    /// (or zeros), not received audio: blocks are discarded, no rows are made and the view says so.
    var isReceiving = true {
        didSet {
            guard isReceiving != oldValue else { return }
            arrivals.setReceiving(isReceiving)
            // Nothing from either side of the change may pass for current received audio.
            ring.reset()
            arrivals.reset()
            isLive = false
        }
    }

    /// Only `.idle` is plain RX. `.blocked` is TX inhibit while not keyed, so the radio is still
    /// receiving; keying, on-air and releasing are not.
    nonisolated static func receives(_ state: TransmitState) -> Bool {
        switch state {
        case .idle, .blocked: true
        case .requested, .onAir, .releasing: false
        }
    }

    @ObservationIgnored private let source: any TerrainAudioSource
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let ring = AudioRing()
    @ObservationIgnored private let arrivals = Arrivals()
    @ObservationIgnored private var history = TerrainHistory()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tapOn = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(source: any TerrainAudioSource,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.clock = clock
    }

    /// Whether the engine tap should be on right now.
    var wantsAudio: Bool { started && isExpanded && !isOccluded && isStreaming }

    func start() {
        guard !started else { return }
        started = true
        let ring = ring, arrivals = arrivals, clock = clock
        source.onConsoleAudio { samples, rate in
            guard arrivals.receiving else { return }
            ring.append(samples)
            arrivals.record(at: clock(), rate: rate)
        }
        apply()
    }

    /// Detaches from the engine and sets the console flag false.
    func stop() {
        guard started else { return }
        let wasOn = tapOn
        started = false
        apply()
        // A feed that never turned the tap on still leaves the engine flag false.
        if !wasOn { source.setConsoleAudioStreaming(false) }
        source.onConsoleAudio(nil)
    }

    private func apply() {
        let want = wantsAudio
        if want != tapOn {
            tapOn = want
            source.setConsoleAudioStreaming(want)
            if want {
                // A fresh run: nothing from before the gap may pass for current audio.
                ring.reset()
                arrivals.reset()
                history.reset()
                grid = []
                isLive = false
                runRows()
            } else {
                task?.cancel()
                task = nil
                isLive = false
            }
        }
    }

    /// Re-evaluates `isLive` against the clock (the row task does this each tick).
    func refreshLiveness() {
        let live = tapOn && isReceiving && arrivals.isRecent(now: clock(), within: Self.liveWindow)
        if live != isLive { isLive = live }
    }

    private func runRows() {
        task?.cancel()
        let ring = ring, arrivals = arrivals
        task = Task.detached(priority: .utility) { [weak self] in
            var stft = TerrainSTFT()
            var rate = Self.sampleRate
            var buffer = [Float](repeating: 0, count: stft.fftSize)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rowInterval)
                if Task.isCancelled { break }
                if let r = arrivals.rate, r != rate, r > 0 {
                    rate = r
                    stft = TerrainSTFT(sampleRate: Double(r))
                }
                // Only rows made from audio that is still arriving.
                let row: [Float]? = await self?.isCurrentlyLive() == true
                    ? buffer.withUnsafeMutableBufferPointer { b in
                        let n = ring.read(latest: b.count, into: b)
                        return stft.row(from: UnsafeBufferPointer(rebasing: b[0..<n]))
                    }
                    : nil
                await self?.ingest(row)
            }
        }
    }

    private func isCurrentlyLive() -> Bool {
        refreshLiveness()
        return isLive
    }

    private func ingest(_ row: [Float]?) {
        refreshLiveness()
        guard let row, tapOn, isReceiving else { return }
        history.push(row)
        grid = history.grid
    }

    /// Thread-safe record of the newest block's arrival time and sample rate.
    private final class Arrivals: @unchecked Sendable {
        private let lock = NSLock()
        private var last: TimeInterval?
        private var rateHz: Int?
        private var isReceiving = true

        var receiving: Bool { lock.lock(); defer { lock.unlock() }; return isReceiving }
        func setReceiving(_ on: Bool) { lock.lock(); isReceiving = on; lock.unlock() }

        func record(at time: TimeInterval, rate: Int) {
            lock.lock(); last = time; rateHz = rate; lock.unlock()
        }
        func reset() { lock.lock(); last = nil; lock.unlock() }
        func isRecent(now: TimeInterval, within window: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let last else { return false }
            return now - last <= window
        }
        var rate: Int? { lock.lock(); defer { lock.unlock() }; return rateHz }
    }
}
