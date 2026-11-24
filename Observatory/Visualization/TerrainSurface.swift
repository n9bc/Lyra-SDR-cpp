import Foundation

/// The audio terrain's dB scale. The floor follows the noise (the 20th percentile of the visible
/// grid) and the ceiling follows the strongest signal (the grid's maximum + 3 dB), so a strong
/// carrier is absorbed into the scale instead of flat-topping. Pure; one value per terrain.
///
/// The span is held to 40...90 dB. A span under 40 raises the ceiling; a span over 90 raises the
/// floor, so the ceiling always stays on the strongest signal. (With a narrow receive filter most
/// of 0-3 kHz is filter stopband, the percentile floor lands far below the in-band noise, and
/// pulling the ceiling down to floor + 90 would flat-top every strong carrier.) Both ends are
/// slew-limited: they rise at most 30 dB/s, so a new strong signal is absorbed within about a
/// second, and fall at most 6 dB/s, so the scale relaxes slowly after the signal goes. While the
/// ceiling is still catching up, `level` compresses values above it with a soft knee rather than
/// clipping them, so a crest never turns into a plateau.
struct TerrainAutoRange: Equatable, Sendable {
    nonisolated static let minSpanDb: Float = 40
    nonisolated static let maxSpanDb: Float = 90
    nonisolated static let riseDbPerSecond: Float = 30
    nonisolated static let fallDbPerSecond: Float = 6
    nonisolated static let headroomDb: Float = 3
    nonisolated static let floorPercentile: Float = 0.2
    /// `level` is linear up to here; above it a soft knee approaches (never reaches) 1.
    nonisolated static let kneeLevel: Float = 0.9

    private(set) var floorDb: Float = -100
    private(set) var ceilingDb: Float = -50

    /// Moves the scale toward `grid` (any row order) by at most `dt` seconds of slew. A grid with no
    /// finite value leaves the scale where it is.
    mutating func update(grid: [[Float]], dt: TimeInterval) {
        var values: [Float] = []
        values.reserveCapacity(grid.reduce(0) { $0 + $1.count })
        for row in grid { for v in row where v.isFinite { values.append(v) } }
        guard !values.isEmpty, dt > 0 else { return }
        values.sort()
        let k = min(Int(Float(values.count - 1) * Self.floorPercentile), values.count - 1)
        let peakCeiling = values[values.count - 1] + Self.headroomDb
        let targetFloor = max(values[k], peakCeiling - Self.maxSpanDb)
        let targetCeiling = max(peakCeiling, targetFloor + Self.minSpanDb)

        let up = Self.riseDbPerSecond * Float(dt), down = Self.fallDbPerSecond * Float(dt)
        let newFloor = Self.slew(floorDb, toward: targetFloor, up: up, down: down)
        let slewedCeiling = Self.slew(ceilingDb, toward: targetCeiling, up: up, down: down)
        // Holding the span on every step only ever moves one end up by as much as the other end
        // moved up, so it stays inside the slew limits while the previous state was a legal span.
        floorDb = max(newFloor, slewedCeiling - Self.maxSpanDb)
        ceilingDb = max(slewedCeiling, floorDb + Self.minSpanDb)
    }

    /// dBFS onto 0..<1 of the current scale. Non-finite input is 0. Nothing is capped at 0 dBFS.
    func level(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return Self.knee((db - floorDb) / (ceilingDb - floorDb))
    }

    /// The linear scale position `x` with negatives at 0 and a soft knee above `kneeLevel`:
    /// continuous with slope 1 at the knee, strictly increasing, and always below 1.
    nonisolated static func knee(_ x: Float) -> Float {
        guard x > 0 else { return 0 }
        guard x > kneeLevel else { return x }
        let room = 1 - kneeLevel
        // u / (1 + u) rather than tanh: tanh rounds to 1 in Float a few spans above the ceiling,
        // which would bring the plateau back for a large onset.
        let u = (x - kneeLevel) / room
        return kneeLevel + room * u / (1 + u)
    }

    nonisolated private static func slew(_ value: Float, toward target: Float, up: Float, down: Float) -> Float {
        target > value ? min(target, value + up) : max(target, value - down)
    }
}

/// Pure shaping for the audio terrain's height field: Gaussian smoothing across frequency, a
/// temporal blend between rows, and Catmull-Rom upsampling in both axes.
enum TerrainSurface {
    nonisolated static let width = 320
    nonisolated static let height = 120
    /// Weight of the new row in the temporal blend; the rest is the previous smoothed row.
    nonisolated static let newRowWeight: Float = 0.55

    /// A Gaussian across frequency (radius 3 sigma) with clamped edges. A flat row stays flat and
    /// the total of an interior impulse is kept.
    nonisolated static func smoothRow(_ levels: [Float], sigmaPoints: Float = 3) -> [Float] {
        let n = levels.count
        guard n > 1, sigmaPoints > 0 else { return levels }
        let radius = max(1, Int((sigmaPoints * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let w = expf(-Float(i * i) / (2 * sigmaPoints * sigmaPoints))
            kernel[i + radius] = w
            sum += w
        }
        for i in kernel.indices { kernel[i] /= sum }
        var out = [Float](repeating: 0, count: n)
        for x in 0..<n {
            var acc: Float = 0
            for i in -radius...radius {
                acc += kernel[i + radius] * levels[min(max(x + i, 0), n - 1)]
            }
            out[x] = acc
        }
        return out
    }

    /// `newRowWeight` of `new` plus the rest of `previous`; no previous row returns `new`.
    nonisolated static func blend(new: [Float], previous: [Float]?) -> [Float] {
        guard let previous, previous.count == new.count else { return new }
        var out = new
        for i in out.indices { out[i] = newRowWeight * new[i] + (1 - newRowWeight) * previous[i] }
        return out
    }

    /// `grid` (dBFS, newest row first) as smoothed, temporally blended levels, newest first. The
    /// blend runs oldest to newest, so each row carries its predecessors as the stored rows would.
    nonisolated static func levelRows(grid: [[Float]], range: TerrainAutoRange, sigmaPoints: Float = 3) -> [[Float]] {
        var out = [[Float]](repeating: [], count: grid.count)
        var previous: [Float]?
        for age in stride(from: grid.count - 1, through: 0, by: -1) {
            let smoothed = smoothRow(grid[age].map { range.level($0) }, sigmaPoints: sigmaPoints)
            let blended = blend(new: smoothed, previous: previous)
            out[age] = blended
            previous = blended
        }
        return out
    }

    /// Catmull-Rom in both axes onto `width` x `height`, row-major. Output row 0 is the front (the
    /// newest row); `fraction` in [0, 1) moves every row that part of a row toward the back, so the
    /// surface scrolls continuously between row arrivals. The front edge holds the newest row
    /// (nothing is invented ahead of it). Every value is clamped at >= 0. No rows give a flat 0.
    nonisolated static func upsample(rows: [[Float]], fraction: Float,
                                     width: Int = TerrainSurface.width,
                                     height: Int = TerrainSurface.height) -> [Float] {
        var out = [Float](repeating: 0, count: max(width, 0) * max(height, 0))
        let columns = rows.map { upsampleRow($0, width: width) }
        out.withUnsafeMutableBufferPointer { upsampleTime(columns: columns, fraction: fraction, height: height, into: $0) }
        return out
    }

    /// One row onto `width` points with Catmull-Rom (clamped ends). The knots land exactly on
    /// output samples when `(width - 1)` is a multiple of `(row.count - 1)`.
    nonisolated static func upsampleRow(_ row: [Float], width: Int) -> [Float] {
        guard width > 0 else { return [] }
        guard row.count > 1 else { return [Float](repeating: row.first ?? 0, count: width) }
        var out = [Float](repeating: 0, count: width)
        let last = row.count - 1
        let scale = width > 1 ? Float(last) / Float(width - 1) : 0
        for x in 0..<width {
            out[x] = catmullRom(at: Float(x) * scale, count: row.count) { row[$0] }
        }
        return out
    }

    /// The time axis of `upsample`: `columns` (each already `width` long, newest first) onto
    /// `height` output rows written into `out` (`width * height`). Allocation-free.
    nonisolated static func upsampleTime(columns: [[Float]], fraction: Float, height: Int,
                                         into out: UnsafeMutableBufferPointer<Float>) {
        guard height > 0, let width = columns.first?.count, width > 0,
              out.count >= width * height else {
            for i in out.indices { out[i] = 0 }
            return
        }
        let count = columns.count
        let last = Float(count - 1)
        let scale = height > 1 ? last / Float(height - 1) : 0
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        for y in 0..<height {
            let s = min(max(Float(y) * scale - f, 0), last)
            let i = Int(s.rounded(.down))
            let t = s - Float(i)
            let a = columns[min(max(i - 1, 0), count - 1)], b = columns[min(i, count - 1)]
            let c = columns[min(i + 1, count - 1)], d = columns[min(i + 2, count - 1)]
            let base = y * width
            for x in 0..<width {
                out[base + x] = max(0, catmullRom(a[x], b[x], c[x], d[x], t))
            }
        }
    }

    nonisolated private static func catmullRom(at s: Float, count: Int, value: (Int) -> Float) -> Float {
        let i = Int(s.rounded(.down))
        let t = s - Float(i)
        func v(_ k: Int) -> Float { value(min(max(k, 0), count - 1)) }
        return max(0, catmullRom(v(i - 1), v(i), v(i + 1), v(i + 2), t))
    }

    /// Uniform Catmull-Rom between `p1` (t = 0) and `p2` (t = 1).
    @inline(__always)
    nonisolated static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }
}

/// The terrain's scroll position between row arrivals, as a fraction of a row. It freezes at its
/// current value while the feed is not live, and resumes from there.
struct TerrainScrollClock: Sendable {
    /// One row per 4/30 s: `TerrainHistory.rows` rows over the terrain's 4 s.
    nonisolated static let rowPeriod: TimeInterval = 4.0 / 30
    nonisolated static let maxFraction: Float = 0.999

    private var lastRow: TimeInterval?
    private var current: Float = 0
    private var running = false

    /// A new row arrived: the scroll restarts from the front.
    mutating func rowArrived(at time: TimeInterval) {
        lastRow = time
        current = 0
        running = true
    }

    mutating func fraction(now: TimeInterval, live: Bool) -> Float {
        guard live, let last = lastRow else {
            running = false
            return current
        }
        if !running {
            // Resume where it froze rather than jumping to the time since the last row.
            lastRow = now - Double(current) * Self.rowPeriod
            running = true
            return current
        }
        current = min(max(Float((now - last) / Self.rowPeriod), 0), Self.maxFraction)
        return current
    }
}
