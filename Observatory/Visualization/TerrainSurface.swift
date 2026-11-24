import Foundation

/// The audio terrain's dB scale. The floor follows the noise (the 20th percentile of the visible
/// grid) and the ceiling follows the strongest signal as drawn (the peak + 3 dB), so a strong
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
    /// Where the scale is heading: set by `retarget` when a row arrives, reached by `advance`.
    private(set) var targetFloorDb: Float = -100
    private(set) var targetCeilingDb: Float = -50

    /// `retarget` then `advance`: moves the scale toward `grid` by at most `dt` seconds of slew.
    mutating func update(grid: [[Float]], dt: TimeInterval) {
        retarget(grid: grid)
        advance(dt: dt)
    }

    /// Points the scale at `grid` as the terrain draws it, without moving it. The floor comes from
    /// the raw noise, the ceiling from the peak of the smoothed, blended heights (`TerrainSurface
    /// .heightRows` measured from `referenceDb`). Smoothing lowers a narrow peak by about 14 dB, so
    /// a ceiling set from the raw peak would leave the strongest signal well short of the top. The floor
    /// stays raw: a floor read from heights clamped at the reference
    /// would sit on the reference and drag it lower on every row.
    mutating func retarget(drawnGrid grid: [[Float]], referenceDb: Float) {
        let heights = TerrainSurface.heightRows(grid: grid, referenceDb: referenceDb)
        let peak = heights.lazy.compactMap { $0.max() }.max()
        retarget(grid: grid, peakDb: peak.map { $0 + referenceDb })
    }

    /// Points the scale at `grid` (any row order) without moving it. The ceiling sits `headroomDb`
    /// above `peakDb` when given, else above the grid's maximum. A grid with no finite value keeps
    /// the previous targets.
    mutating func retarget(grid: [[Float]], peakDb: Float? = nil) {
        var values: [Float] = []
        values.reserveCapacity(grid.reduce(0) { $0 + $1.count })
        for row in grid { for v in row where v.isFinite { values.append(v) } }
        guard !values.isEmpty else { return }
        values.sort()
        let k = min(Int(Float(values.count - 1) * Self.floorPercentile), values.count - 1)
        let peak = peakDb.flatMap { $0.isFinite ? $0 : nil } ?? values[values.count - 1]
        let peakCeiling = peak + Self.headroomDb
        targetFloorDb = max(values[k], peakCeiling - Self.maxSpanDb)
        targetCeilingDb = max(peakCeiling, targetFloorDb + Self.minSpanDb)
    }

    /// Moves the scale toward its targets by at most `dt` seconds of slew. Called every frame, so
    /// a rescale glides instead of stepping at each row.
    mutating func advance(dt: TimeInterval) {
        guard dt > 0 else { return }
        let up = Self.riseDbPerSecond * Float(dt), down = Self.fallDbPerSecond * Float(dt)
        let newFloor = Self.slew(floorDb, toward: targetFloorDb, up: up, down: down)
        let slewedCeiling = Self.slew(ceilingDb, toward: targetCeilingDb, up: up, down: down)
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
/// temporal blend between rows, and monotone cubic upsampling in both axes.
enum TerrainSurface {
    nonisolated static let width = 320
    nonisolated static let height = 120
    /// Weight of the new row in the temporal blend; the rest is the previous smoothed row.
    nonisolated static let newRowWeight: Float = 0.55

    /// The power-smoothed peak path in `heightRows`: its sigma in points (15 Hz each), how far its
    /// kernel reaches in sigmas, and how many dB below the dB-smoothed surface it is weighted. A
    /// Gaussian on power falls 2.17 r^2 dB r sigmas out, so the kernel runs to 8 sigma (139 dB
    /// down): heights stay under that even while the scale is still catching up with a sudden
    /// strong signal, so the kernel leaves no step where it stops.
    nonisolated static let peakSigmaPoints: Float = 1
    nonisolated static let peakRadiusSigmas: Float = 8
    nonisolated static let peakWeightDb: Float = 10

    /// A Gaussian across frequency (radius `radiusSigmas` sigma) with clamped edges. A flat row
    /// stays flat and the total of an interior impulse is kept.
    nonisolated static func smoothRow(_ levels: [Float], sigmaPoints: Float = 3, radiusSigmas: Float = 3) -> [Float] {
        let n = levels.count
        guard n > 1, sigmaPoints > 0 else { return levels }
        let radius = max(1, Int((sigmaPoints * radiusSigmas).rounded(.up)))
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

    /// `grid` (dBFS, newest row first) as smoothed, temporally blended heights in dB above
    /// `referenceDb` (clamped at 0; non-finite is 0), newest first. The blend runs oldest to newest
    /// on dB, so each row carries its predecessors as the stored rows would and a signal that stops
    /// fades by 0.45 of its height per row. The level mapping happens later, per frame, in the
    /// shader (`TerrainAutoRange.level` of height + reference), so the scale glides every frame
    /// without rebuilding these rows.
    ///
    /// Each row is `shapeRow`: smoothed on dB for the noise, with a narrow power-smoothed path that
    /// keeps a strong signal's crest.
    nonisolated static func heightRows(grid: [[Float]], referenceDb: Float, sigmaPoints: Float = 3,
                                       peakSigmaPoints: Float = TerrainSurface.peakSigmaPoints) -> [[Float]] {
        var out = [[Float]](repeating: [], count: grid.count)
        var previous: [Float]?
        for age in stride(from: grid.count - 1, through: 0, by: -1) {
            let above = grid[age].map { $0.isFinite ? max($0 - referenceDb, 0) : 0 }
            let blended = blend(new: shapeRow(above, sigmaPoints: sigmaPoints, peakSigmaPoints: peakSigmaPoints),
                                previous: previous)
            out[age] = blended
            previous = blended
        }
        return out
    }

    /// One row of dB heights (>= 0) smoothed across frequency. An average of dB is a geometric
    /// mean: it gives the noise a smooth, even surface, but pulls a narrow peak most of the way down
    /// to the noise around it (a CW note 70 dB over the noise stood barely 22 dB high). An average
    /// of power keeps the crest within a few dB, but on its own it makes the noise rough and gives
    /// strong signals wide skirts. So the two are mixed on power: the dB-smoothed row plus a narrow
    /// power-smoothed row weighted `peakWeightDb` down, normalised so a flat row stays exactly
    /// where it is (and 0 stays 0). The noise follows the dB path and a strong crest follows the
    /// power path; the mix is smooth everywhere, so it adds no crease where one takes over.
    nonisolated static func shapeRow(_ above: [Float], sigmaPoints: Float = 3,
                                     peakSigmaPoints: Float = TerrainSurface.peakSigmaPoints) -> [Float] {
        let smooth = smoothRow(above, sigmaPoints: sigmaPoints)
        // Heights are measured from the reference, so these powers start at 1 and stay in range.
        let peak = smoothRow(above.map { powf(10, $0 / 10) }, sigmaPoints: peakSigmaPoints,
                             radiusSigmas: peakRadiusSigmas)
        let c = powf(10, -peakWeightDb / 10)
        var out = smooth
        for i in out.indices {
            out[i] = max(10 * log10f((powf(10, smooth[i] / 10) + c * peak[i]) / (1 + c)), 0)
        }
        return out
    }

    /// How many rows of `count` the time axis shows: every row except the `maxLag` rows the
    /// scroll can sit behind the newest one, so the back edge never runs past the oldest row.
    nonisolated static func visibleRows(count: Int) -> Float {
        max(Float(count - 1) - TerrainScrollClock.maxLag, 0)
    }

    /// Monotone cubic in both axes onto `width` x `height`, row-major. Output row 0 is the front.
    /// The front edge sits `lag` rows behind the newest row (row 0) and the time axis spans
    /// `span` rows from there (default `visibleRows`), so as `lag` shrinks between row arrivals the
    /// surface scrolls toward the back, and when a row lands `lag` grows by one and nothing moves.
    /// The front is always real data between two rows: no row is extruded and nothing is invented
    /// ahead of the newest one. The interpolation cannot overshoot its knots, so inputs >= 0 give
    /// outputs >= 0 with no clamp, and the surface is C1 (no creases). No rows give a flat 0.
    nonisolated static func upsample(rows: [[Float]], lag: Float, span: Float? = nil,
                                     width: Int = TerrainSurface.width,
                                     height: Int = TerrainSurface.height) -> [Float] {
        var out = [Float](repeating: 0, count: max(width, 0) * max(height, 0))
        let columns = rows.map { upsampleRow($0, width: width) }
        out.withUnsafeMutableBufferPointer {
            upsampleTime(columns: columns, lag: lag, span: span, height: height, into: $0)
        }
        return out
    }

    /// One row onto `width` points with the monotone cubic. The knots land exactly on output
    /// samples when `(width - 1)` is a multiple of `(row.count - 1)`.
    nonisolated static func upsampleRow(_ row: [Float], width: Int) -> [Float] {
        guard width > 0 else { return [] }
        guard row.count > 1 else { return [Float](repeating: row.first ?? 0, count: width) }
        var out = [Float](repeating: 0, count: width)
        let last = row.count - 1
        let scale = width > 1 ? Float(last) / Float(width - 1) : 0
        for x in 0..<width {
            let s = min(Float(x) * scale, Float(last))
            let i = min(Int(s.rounded(.down)), last - 1)
            out[x] = monotoneCubic(i > 0 ? row[i - 1] : nil, row[i], row[i + 1],
                                   i + 2 <= last ? row[i + 2] : nil, s - Float(i))
        }
        return out
    }

    /// The time axis of `upsample`: `columns` (each already `width` long, newest first) onto
    /// `height` output rows written into `out` (`width * height`). Allocation-free.
    nonisolated static func upsampleTime(columns: [[Float]], lag: Float, span: Float? = nil, height: Int,
                                         into out: UnsafeMutableBufferPointer<Float>) {
        guard height > 0, let width = columns.first?.count, width > 0,
              out.count >= width * height else {
            for i in out.indices { out[i] = 0 }
            return
        }
        let count = columns.count
        guard count > 1 else {
            for y in 0..<height { for x in 0..<width { out[y * width + x] = columns[0][x] } }
            return
        }
        let last = count - 1
        let rows = max(span ?? visibleRows(count: count), 0)
        let scale = height > 1 ? rows / Float(height - 1) : 0
        let l = lag.isFinite ? lag : 0
        for y in 0..<height {
            // Only a lag or span past the rows the caller has reaches this clamp; the clock keeps
            // `lag` within `0...maxLag`, which `visibleRows` leaves room for.
            let s = min(max(l + Float(y) * scale, 0), Float(last))
            let i = min(Int(s.rounded(.down)), last - 1)
            let t = s - Float(i)
            let b = columns[i], c = columns[i + 1]
            let a = i > 0 ? columns[i - 1] : nil, d = i + 2 <= last ? columns[i + 2] : nil
            let base = y * width
            for x in 0..<width {
                out[base + x] = monotoneCubic(a?[x], b[x], c[x], d?[x], t)
            }
        }
    }

    /// The tangent at a knot between secants `left` and `right`: their harmonic mean when they
    /// agree in sign, 0 at a local extremum (Fritsch-Butland). It is never more than twice the
    /// smaller secant, which is inside the Fritsch-Carlson monotone region.
    @inline(__always)
    nonisolated static func knotTangent(_ left: Float, _ right: Float) -> Float {
        let p = left * right
        return p > 0 ? 2 * p / (left + right) : 0
    }

    /// A monotone cubic Hermite between `p1` (t = 0) and `p2` (t = 1). `p0` and `p3` are the
    /// neighbouring knots; a missing one (an end of the data) uses the one-sided secant, which
    /// continues a straight run straight. Each knot's tangent depends only on that knot and its two
    /// neighbours, so the curve is C1 across knots, and it stays within `p1...p2`: it never
    /// undershoots below the lower knot, so it needs no clamp.
    @inline(__always)
    nonisolated static func monotoneCubic(_ p0: Float?, _ p1: Float, _ p2: Float, _ p3: Float?, _ t: Float) -> Float {
        let d1 = p2 - p1
        let m1 = knotTangent(p0.map { p1 - $0 } ?? d1, d1)
        let m2 = knotTangent(d1, p3.map { $0 - p2 } ?? d1)
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
        let h01 = 3 * t2 - 2 * t3, h11 = t3 - t2
        return h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
    }
}

/// How far the terrain's front edge sits behind the newest row, in rows. Between row arrivals
/// the lag shrinks at the measured row rate, so the surface rolls back continuously; when rows
/// land the lag grows by that many rows, which leaves the picture exactly where it was. The row
/// period is measured from the arrivals (an exponential average of the inter-arrival time), since
/// the feed's real cadence is slower than its nominal 4/30 s, and a slow servo keeps the lag
/// centred so it neither runs dry (a stall) nor fills up (a jump). Arrivals then land while the
/// front is at least a row back, where a new row does not change the interpolated surface.
/// The lag freezes while the feed is not live and resumes from there.
struct TerrainScrollClock: Sendable {
    /// One row per 4/30 s: `TerrainHistory.rows` rows over the terrain's 4 s. Only the start value.
    nonisolated static let nominalPeriod: TimeInterval = 4.0 / 30
    nonisolated static let maxLag: Float = 3
    /// The mean lag the servo holds: the sawtooth between arrivals runs about 1...2.
    nonisolated static let targetLag: Float = 1.5
    /// Weight of each new inter-arrival interval in the period average.
    nonisolated static let periodWeight: Double = 0.2
    /// Servo: speed = (1 + gain * (mean lag - target)) rows per period, within `speedBounds`.
    nonisolated static let servoGain: Float = 0.5
    nonisolated static let speedBounds: ClosedRange<Float> = 0.5...1.5
    /// Time constant of the mean lag the servo looks at; long against one row, so the sawtooth
    /// within a row does not modulate the speed.
    nonisolated static let meanLagSeconds: Double = 1
    /// The longest frame step counted; a longer gap (a stall or a wake) moves at most this much.
    nonisolated static let maxStep: TimeInterval = 0.25

    private(set) var lag: Float = TerrainScrollClock.targetLag
    private(set) var period: TimeInterval = TerrainScrollClock.nominalPeriod
    private var meanLag: Float = TerrainScrollClock.targetLag
    private var lastArrival: TimeInterval?
    private var lastTick: TimeInterval?

    /// `rows` new rows landed at `time`. The lag takes them up, so the picture does not move.
    mutating func rowsArrived(_ rows: Int = 1, at time: TimeInterval) {
        guard rows > 0 else { return }
        if let last = lastArrival {
            let interval = (time - last) / Double(rows)
            // Ignore gaps that are not the feed's cadence (a pause, a burst).
            if interval > Self.nominalPeriod / 4, interval < Self.nominalPeriod * 4 {
                period += Self.periodWeight * (interval - period)
            }
        }
        lastArrival = time
        lag = min(lag + Float(rows), Self.maxLag)
    }

    /// Advances to `now` and returns the lag. Not live: frozen, and the period measurement
    /// restarts, so a pause is not counted as a slow row.
    mutating func advance(now: TimeInterval, live: Bool) -> Float {
        guard live else {
            lastTick = nil
            lastArrival = nil
            return lag
        }
        let dt = lastTick.map { min(max(now - $0, 0), Self.maxStep) } ?? 0
        lastTick = now
        guard dt > 0 else { return lag }
        meanLag += (lag - meanLag) * Float(min(dt / Self.meanLagSeconds, 1))
        let speed = min(max(1 + Self.servoGain * (meanLag - Self.targetLag), Self.speedBounds.lowerBound),
                        Self.speedBounds.upperBound)
        lag = max(lag - speed * Float(dt / period), 0)
        return lag
    }
}
