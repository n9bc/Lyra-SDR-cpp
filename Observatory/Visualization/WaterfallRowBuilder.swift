import Foundation

/// Turns engine waterfall rows into history rows the way the Qt waterfall does: each incoming
/// frame is peak-held per bin into a pending row, and rows are pushed on a clock of
/// `rowsPerSecond`, not once per frame, so a short signal between pushes survives and the
/// scroll speed does not depend on the display rate (`src/waterfall.cpp`).
///
/// No allocation after `init`. Main thread only (it is driven from the draw callback).
struct WaterfallRowBuilder {
    /// Most rows pushed in one tick, so a stall cannot dump a burst.
    nonisolated static let maxRowsPerTick = 8
    nonisolated static let emptyDb: Float = -200

    /// Owns the pending row so `pendingRow()` can hand out a stable pointer.
    private final class Storage {
        let pointer: UnsafeMutablePointer<Float>
        let count: Int
        init(count: Int) {
            self.count = count
            pointer = .allocate(capacity: max(count, 1))
            pointer.initialize(repeating: WaterfallRowBuilder.emptyDb, count: max(count, 1))
        }
        deinit { pointer.deallocate() }
    }

    private let storage: Storage
    private var lastSerial: UInt64?
    private var lastRowMs: Int64?
    private(set) var hasPending = false

    nonisolated init(bins: Int) { storage = Storage(count: bins) }

    var bins: Int { storage.count }

    /// Peak-holds `row` into the pending row. A serial equal to the previous one is the same frame
    /// again and is ignored.
    mutating func ingest(_ row: UnsafeBufferPointer<Float>, serial: UInt64) {
        guard serial != lastSerial else { return }
        lastSerial = serial
        let n = min(row.count, storage.count)
        guard n > 0, let src = row.baseAddress else { return }
        let dst = storage.pointer
        for i in 0..<n where src[i] > dst[i] { dst[i] = src[i] }
        hasPending = true
    }

    /// How many rows are due at `now` (seconds, any monotonic clock), 0...8. The first call is
    /// due one row. Advances the row clock by what it returns.
    mutating func rowsDue(now: TimeInterval, rowsPerSecond: Int) -> Int {
        let nowMs = Int64((now * 1000).rounded())
        let interval = max(1, 1000 / Int64(max(1, rowsPerSecond)))
        let last = lastRowMs ?? nowMs - interval
        let due = min(Int((nowMs - last) / interval), Self.maxRowsPerTick)
        guard due >= 1 else {
            lastRowMs = last
            return 0
        }
        lastRowMs = last + Int64(due) * interval
        return due
    }

    /// The peak-held row to paint (`bins` values).
    func pendingRow() -> UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: storage.pointer, count: storage.count)
    }

    /// Call after painting the pending row: empties it for the next interval.
    mutating func didEmitRow() {
        storage.pointer.update(repeating: Self.emptyDb, count: storage.count)
        hasPending = false
    }

    /// Forgets pending data, the frame serial and the row clock (after a history clear).
    mutating func reset() {
        didEmitRow()
        lastSerial = nil
        lastRowMs = nil
    }
}

/// When the history must be thrown away: the rows no longer line up with the axis.
enum WaterfallHistoryPolicy {
    nonisolated static func shouldClear(old: DisplaySnapshot, new: DisplaySnapshot) -> Bool {
        old.txAxis != new.txAxis || old.spanLowHz != new.spanLowHz || old.spanHighHz != new.spanHighHz
    }
}
