import Foundation

/// Fixed-capacity ring of the most recent received audio (4 s at 48 kHz).
/// One producer (main thread) appends; one consumer (a background task) reads the latest
/// samples. A lock guards the indices and storage; critical sections are short memcpy's.
final class AudioRing: @unchecked Sendable {
    nonisolated static let capacity = 4 * 48_000

    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var filled = 0

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { storage.deallocate() }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        // Only the newest `capacity` samples can survive.
        var src = base
        var count = samples.count
        if count > Self.capacity {
            src += count - Self.capacity
            count = Self.capacity
        }
        lock.lock()
        defer { lock.unlock() }
        let first = min(count, Self.capacity - writeIndex)
        (storage + writeIndex).update(from: src, count: first)
        if count > first { storage.update(from: src + first, count: count - first) }
        writeIndex = (writeIndex + count) % Self.capacity
        filled = min(Self.capacity, filled + count)
    }

    /// Copies the newest `n` samples, oldest first, to the front of `into`. Returns how many were
    /// copied: fewer than `n` while the ring has not filled that far or `into` is smaller.
    func read(latest n: Int, into: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let dst = into.baseAddress, n > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let count = min(n, filled, into.count)
        guard count > 0 else { return 0 }
        let start = (writeIndex - count + Self.capacity) % Self.capacity
        let first = min(count, Self.capacity - start)
        dst.update(from: storage + start, count: first)
        if count > first { (dst + first).update(from: storage, count: count - first) }
        return count
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        filled = 0
        lock.unlock()
    }
}
