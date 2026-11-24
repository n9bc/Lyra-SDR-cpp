import XCTest
import simd
@testable import Observatory

final class TerrainSurfaceTests: XCTestCase {
    // MARK: - Helpers

    /// `rows` rows of `points` values at `db`, with `peak` written at bin `peakBin` of every row.
    private func grid(noise db: Float, peak: Float? = nil, peakBin: Int = 100,
                      rows: Int = 30, points: Int = 201) -> [[Float]] {
        var row = [Float](repeating: db, count: points)
        if let peak { row[peakBin] = peak }
        return [[Float]](repeating: row, count: rows)
    }

    private func steadyState(_ g: [[Float]], seconds: Double = 60) -> TerrainAutoRange {
        var r = TerrainAutoRange()
        for _ in 0..<Int(seconds / 0.1) { r.update(grid: g, dt: 0.1) }
        return r
    }

    // MARK: - Auto range

    func testAutoRangeStartsAtTheBriefValues() {
        let r = TerrainAutoRange()
        XCTAssertEqual(r.floorDb, -100)
        XCTAssertEqual(r.ceilingDb, -50)
    }

    func testAutoRangeLiftsSignalAboveFloor() {
        // The brief's case: noise at -40 dBFS, one bin at -10. The peak is 30 dB above the floor,
        // so the 40 dB minimum span holds the ceiling at floor + 40 and the peak sits at 30/40.
        let r = steadyState(grid(noise: -40, peak: -10))
        XCTAssertEqual(r.floorDb, -40, accuracy: 0.01)
        XCTAssertEqual(r.ceilingDb, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(r.level(-40), 0.3)
        XCTAssertEqual(r.level(-10), 0.75, accuracy: 0.01)
        XCTAssertLessThan(r.level(-10), 1)

        // When the span is not clamped, the peak sits just below the top: max + 3 dB headroom.
        let wide = steadyState(grid(noise: -40, peak: 5))
        XCTAssertLessThanOrEqual(wide.level(-40), 0.3)
        XCTAssertGreaterThanOrEqual(wide.level(5), 0.85)
        XCTAssertLessThanOrEqual(wide.level(5), 0.97)
    }

    /// An S9+ CW note: 70 dB over the noise and three points wide, as the audio STFT draws a tone.
    /// Smoothing lowers a peak that narrow by about 14 dB, so a ceiling set from the raw peak would
    /// leave the drawn crest short of the top. The scale follows the drawn peak, so it reaches it.
    func testStrongNarrowSignalReachesTheTopAsDrawn() {
        var row = [Float](repeating: -100, count: 201)
        row[99] = -36; row[100] = -30; row[101] = -36
        let g = [[Float]](repeating: row, count: 30)
        func drawnPeakLevel(_ r: TerrainAutoRange) -> Float {
            let ref = min(r.floorDb, r.targetFloorDb) - TerrainAutoRange.fallDbPerSecond
            let peak = TerrainSurface.heightRows(grid: g, referenceDb: ref).compactMap { $0.max() }.max()!
            return r.level(peak + ref)
        }

        var drawn = TerrainAutoRange()
        for _ in 0..<200 {
            drawn.retarget(drawnGrid: g, referenceDb: min(drawn.floorDb, drawn.targetFloorDb)
                                                      - TerrainAutoRange.fallDbPerSecond)
            drawn.advance(dt: 0.1)
        }
        XCTAssertGreaterThanOrEqual(drawnPeakLevel(drawn), 0.9)
        XCTAssertLessThan(drawnPeakLevel(drawn), 1)
        XCTAssertEqual(drawn.floorDb, -100, accuracy: 0.01)
        XCTAssertLessThanOrEqual(drawn.level(-100), 0.1)

        // The drawn crest stands well above what dB smoothing alone left (about 22 dB)...
        let ref = min(drawn.floorDb, drawn.targetFloorDb) - TerrainAutoRange.fallDbPerSecond
        let drawnPeak = TerrainSurface.heightRows(grid: g, referenceDb: ref).compactMap { $0.max() }.max()! + ref
        XCTAssertGreaterThan(drawnPeak, -50)
        XCTAssertLessThan(drawnPeak, -30)
        // ...and a scale topped from the raw peak would leave it short of the top.
        XCTAssertLessThan(drawnPeakLevel(steadyState(g)), 0.85)
    }

    func testStrongSignalNeverFlatTops() {
        let r = steadyState(grid(noise: -30, peak: 6))
        XCTAssertLessThan(r.level(6), 1)
        XCTAssertLessThanOrEqual(r.level(-30), 0.3)
        // Above 0 dBFS is handled: there is no fixed 0 dBFS cap.
        XCTAssertGreaterThan(r.ceilingDb, 6)
    }

    /// A narrow receive filter: most of 0-3 kHz is filter stopband far below the in-band noise,
    /// so the 20th percentile lands in the stopband and the spread to a strong carrier passes 90 dB.
    /// The ceiling must stay on the carrier (the floor gives way), so the carrier is not a plateau.
    func testNarrowFilterCarrierNeverFlatTops() {
        var row = [Float](repeating: -140, count: 201)          // stopband
        for p in 20...53 { row[p] = -95 }                       // ~300-800 Hz passband noise
        row[40] = -10; row[41] = -12                            // a strong CW carrier
        let r = steadyState([[Float]](repeating: row, count: 30))
        XCTAssertEqual(r.ceilingDb, -7, accuracy: 0.01)
        XCTAssertEqual(r.ceilingDb - r.floorDb, 90, accuracy: 0.01)
        XCTAssertLessThan(r.level(-10), 1)
        XCTAssertGreaterThan(r.level(-10), r.level(-12))       // the crest keeps its shape
        XCTAssertLessThanOrEqual(r.level(-95), 0.1)
    }

    /// While the ceiling is still rising toward a new, much stronger signal, values above it are
    /// compressed (a soft knee), never clipped: different levels above the ceiling stay different.
    func testOnsetAboveCeilingIsCompressedNotClipped() {
        let r = steadyState(grid(noise: -60, peak: -30))       // ceiling settles near -20
        XCTAssertLessThan(r.ceilingDb, 0)
        let a = r.level(0), b = r.level(10), c = r.level(30)
        XCTAssertLessThan(a, b); XCTAssertLessThan(b, c)
        XCTAssertLessThan(c, 1)
        XCTAssertGreaterThan(a, TerrainAutoRange.kneeLevel)
        // Below the knee the mapping is the plain linear scale.
        XCTAssertEqual(r.level(r.floorDb + 0.5 * (r.ceilingDb - r.floorDb)), 0.5, accuracy: 1e-5)
        // The curve is continuous at the knee.
        let kneeDb = r.floorDb + TerrainAutoRange.kneeLevel * (r.ceilingDb - r.floorDb)
        XCTAssertEqual(r.level(kneeDb + 0.001), TerrainAutoRange.kneeLevel, accuracy: 1e-4)
    }

    func testAutoRangeSlewLimits() {
        var up = TerrainAutoRange()
        up.update(grid: grid(noise: 20, peak: 40), dt: 0.1)
        XCTAssertLessThanOrEqual(up.floorDb - -100, 3 + 1e-4)
        XCTAssertLessThanOrEqual(up.ceilingDb - -50, 3 + 1e-4)
        XCTAssertGreaterThan(up.floorDb, -100)
        XCTAssertGreaterThan(up.ceilingDb, -50)

        var down = TerrainAutoRange()
        down.update(grid: grid(noise: -190), dt: 0.1)
        XCTAssertGreaterThanOrEqual(down.floorDb - -100, -0.6 - 1e-4)
        XCTAssertGreaterThanOrEqual(down.ceilingDb - -50, -0.6 - 1e-4)
        XCTAssertLessThan(down.floorDb, -100)
        XCTAssertLessThan(down.ceilingDb, -50)

        // Mixed directions: the floor rises while the peak is gone. Every step stays in limits.
        var mixed = steadyState(grid(noise: -60, peak: 20))
        for _ in 0..<100 {
            let before = mixed
            mixed.update(grid: grid(noise: -20), dt: 0.1)
            XCTAssertLessThanOrEqual(mixed.floorDb - before.floorDb, 3 + 1e-4)
            XCTAssertGreaterThanOrEqual(mixed.floorDb - before.floorDb, -0.6 - 1e-4)
            XCTAssertLessThanOrEqual(mixed.ceilingDb - before.ceilingDb, 3 + 1e-4)
            XCTAssertGreaterThanOrEqual(mixed.ceilingDb - before.ceilingDb, -0.6 - 1e-4)
        }
    }

    func testSpanClampedTo40to90() {
        // Flat noise: span would be 3 dB; it is held at 40 by moving the ceiling, not the floor.
        let narrow = steadyState(grid(noise: -70))
        XCTAssertEqual(narrow.floorDb, -70, accuracy: 0.01)
        XCTAssertEqual(narrow.ceilingDb - narrow.floorDb, 40, accuracy: 0.01)

        // A 140 dB spread: span held at 90 by lifting the floor; the ceiling stays on the peak.
        let wide = steadyState(grid(noise: -150, peak: -10))
        XCTAssertEqual(wide.ceilingDb, -7, accuracy: 0.01)
        XCTAssertEqual(wide.ceilingDb - wide.floorDb, 90, accuracy: 0.01)
        XCTAssertLessThan(wide.level(-10), 1)

        // The span holds on every step on the way there too.
        var r = TerrainAutoRange()
        for g in [grid(noise: -150, peak: -10), grid(noise: -20), grid(noise: -90, peak: 10)] {
            for _ in 0..<50 {
                r.update(grid: g, dt: 0.1)
                XCTAssertGreaterThanOrEqual(r.ceilingDb - r.floorDb, 40 - 1e-3)
                XCTAssertLessThanOrEqual(r.ceilingDb - r.floorDb, 90 + 1e-3)
            }
        }
    }

    func testNonFiniteMapsToZero() {
        let r = TerrainAutoRange()
        XCTAssertEqual(r.level(.nan), 0)
        XCTAssertEqual(r.level(.infinity), 0)
        XCTAssertEqual(r.level(-.infinity), 0)
        // Non-finite values in the grid do not poison the range.
        var g = grid(noise: -40, peak: -10)
        g[0][3] = .nan; g[1][4] = .infinity; g[2][5] = -.infinity
        var s = TerrainAutoRange()
        for _ in 0..<600 { s.update(grid: g, dt: 0.1) }
        XCTAssertTrue(s.floorDb.isFinite); XCTAssertTrue(s.ceilingDb.isFinite)
        XCTAssertEqual(s.floorDb, -40, accuracy: 0.01)
    }

    /// The scale moves every frame toward targets set when a row arrives, so a rescale is a glide
    /// at 60 fps rather than a jump at each of the feed's 7.5 rows per second.
    func testAdvanceGlidesBetweenRows() {
        var r = TerrainAutoRange()
        r.retarget(grid: grid(noise: -30, peak: 20))
        XCTAssertEqual(r.targetCeilingDb, 23, accuracy: 0.01)
        XCTAssertEqual(r.ceilingDb, -50)                       // retarget alone moves nothing
        let frame = 1.0 / 60
        for _ in 0..<8 {
            let before = r
            r.advance(dt: frame)
            XCTAssertGreaterThan(r.ceilingDb, before.ceilingDb)
            XCTAssertLessThanOrEqual(r.ceilingDb - before.ceilingDb, 0.5 + 1e-4)
            XCTAssertLessThanOrEqual(r.floorDb - before.floorDb, 0.5 + 1e-4)
        }
        // Eight frames land where one row-period update would.
        var once = TerrainAutoRange()
        once.update(grid: grid(noise: -30, peak: 20), dt: 8 * frame)
        XCTAssertEqual(r.floorDb, once.floorDb, accuracy: 1e-3)
        XCTAssertEqual(r.ceilingDb, once.ceilingDb, accuracy: 1e-3)
    }

    func testEmptyGridHoldsTheRange() {
        var r = TerrainAutoRange()
        r.update(grid: [], dt: 1)
        XCTAssertEqual(r.floorDb, -100); XCTAssertEqual(r.ceilingDb, -50)
    }

    // MARK: - Smoothing

    func testSmoothRowPreservesFlatAndSpreadsImpulse() {
        let flat = [Float](repeating: 0.4, count: 201)
        for v in TerrainSurface.smoothRow(flat) { XCTAssertEqual(v, 0.4, accuracy: 1e-5) }

        var impulse = [Float](repeating: 0, count: 201)
        impulse[100] = 1
        let s = TerrainSurface.smoothRow(impulse)
        XCTAssertEqual(s.count, 201)
        XCTAssertLessThan(s[100], 1)
        XCTAssertGreaterThan(s[97], 0)
        for d in 1...12 { XCTAssertEqual(s[100 - d], s[100 + d], accuracy: 1e-6) }
        XCTAssertEqual(s.reduce(0, +), 1, accuracy: 0.01)
    }

    func testSmoothRowClampsEdges() {
        // A step at the edge: clamped edges mean the edge value is not pulled toward zero.
        let ramp = [Float](repeating: 1, count: 50)
        let s = TerrainSurface.smoothRow(ramp)
        XCTAssertEqual(s[0], 1, accuracy: 1e-5)
        XCTAssertEqual(s[49], 1, accuracy: 1e-5)
    }

    // MARK: - Upsampling

    func testUpsampleHitsKnotsAndIsContinuous() {
        // 4 rows x 5 points onto 9 x 7 over all 3 row gaps: knots at x = 0, 2, 4, 6, 8 and y = 0, 2, 4, 6.
        let rows: [[Float]] = [[0.1, 0.5, 0.9, 0.3, 0.2],
                               [0.4, 0.8, 0.2, 0.6, 0.1],
                               [0.7, 0.3, 0.5, 0.9, 0.4],
                               [0.2, 0.6, 0.8, 0.1, 0.5]]
        let out = TerrainSurface.upsample(rows: rows, lag: 0, span: 3, width: 9, height: 7)
        XCTAssertEqual(out.count, 63)
        for (r, row) in rows.enumerated() {
            for (p, v) in row.enumerated() {
                XCTAssertEqual(out[(r * 2) * 9 + p * 2], v, accuracy: 1e-4, "row \(r) point \(p)")
            }
        }

        // A smooth 30 x 201 input onto the renderer's 320 x 120 surface.
        let smooth: [[Float]] = (0..<30).map { r in
            (0..<201).map { p in
                0.5 + 0.4 * sin(Float(p) / 200 * 2 * .pi * 2) * cos(Float(r) / 29 * .pi)
            }
        }
        let big = TerrainSurface.upsample(rows: smooth, lag: 1.37)
        XCTAssertEqual(big.count, 320 * 120)
        var worst: Float = 0
        for y in 0..<120 {
            for x in 0..<320 {
                let v = big[y * 320 + x]
                if x > 0 { worst = max(worst, abs(v - big[y * 320 + x - 1])) }
                if y > 0 { worst = max(worst, abs(v - big[(y - 1) * 320 + x])) }
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.05)
    }

    func testUpsampleLagShiftsTime() {
        // Newest row (0) at 1, all older rows at 0. Width 2 keeps x trivial; 1 output row per row.
        let rows: [[Float]] = [[1, 1], [0, 0], [0, 0], [0, 0], [0, 0]]
        let front = TerrainSurface.upsample(rows: rows, lag: 0, span: 3, width: 2, height: 4)
        XCTAssertEqual(front[0], 1, accuracy: 1e-4)
        XCTAssertEqual(front[2], 0, accuracy: 1e-4)
        // Half a row behind the newest row: the front lies between rows 0 and 1.
        let half = TerrainSurface.upsample(rows: rows, lag: 0.5, span: 3, width: 2, height: 4)
        XCTAssertGreaterThan(half[0], 0.2)
        XCTAssertLessThan(half[0], 0.8)
        // A row landing adds 1 to the lag, and the picture is unchanged: what was row k is now row k + 1.
        // From one row back the interpolation does not depend on the newest row (only the newest
        // gap's tangent at old row 0 would change), so with the front at lag >= 1 nothing moves.
        let landed = [[Float]]([[0.3, 0.3]]) + rows
        let before = TerrainSurface.upsample(rows: rows, lag: 1.2, span: 2, width: 2, height: 4)
        let after = TerrainSurface.upsample(rows: landed, lag: 2.2, span: 2, width: 2, height: 4)
        for i in before.indices { XCTAssertEqual(after[i], before[i], accuracy: 1e-6) }
    }

    func testUpsampleNeverNegative() {
        // An impulse made the old Catmull-Rom undershoot below 0; the monotone cubic cannot, so the
        // output stays >= 0 without any clamp.
        var row = [Float](repeating: 0, count: 21)
        row[10] = 1
        var rows = [[Float]](repeating: [Float](repeating: 0, count: 21), count: 8)
        rows[2] = row
        rows[5] = [Float](repeating: 0.7, count: 21)
        for lag: Float in [0, 0.25, 0.5, 0.75, 1, 1.5, 2.25, 3] {
            let out = TerrainSurface.upsample(rows: rows, lag: lag, width: 64, height: 32)
            XCTAssertTrue(out.allSatisfy { $0 >= 0 }, "lag \(lag)")
        }
        // Every segment of the interpolant stays between its two knots, for arbitrary knots >= 0.
        var seed: UInt64 = 0x1234_5678
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<2000 {
            let p = (0..<4).map { _ in rnd() < 0.3 ? 0 : rnd() }
            for k in 0...20 {
                let t = Float(k) / 20
                let v = TerrainSurface.monotoneCubic(p[0], p[1], p[2], p[3], t)
                XCTAssertGreaterThanOrEqual(v, min(p[1], p[2]) - 1e-6)
                XCTAssertLessThanOrEqual(v, max(p[1], p[2]) + 1e-6)
            }
        }
    }

    /// The largest jump in first difference along `samples`, relative to the step squared. A C1
    /// curve sampled at step h has second differences of about h^2 f'', so this stays near |f''|;
    /// a kink (a slope break of J) gives about J / h, which grows without bound as h shrinks.
    private func kinkiness(_ samples: [Float], step: Float) -> Float {
        var worst: Float = 0
        for i in 1..<(samples.count - 1) {
            let d2 = (samples[i + 1] - samples[i]) - (samples[i] - samples[i - 1])
            worst = max(worst, abs(d2) / (step * step))
        }
        return worst
    }

    /// The front of the surface is real data, not the newest row extruded: no flat band and no
    /// slope break anywhere near the front edge, at any lag the clock can produce.
    func testFrontEdgeHasNoFlatBandOrKink() {
        // A straight ramp in time is reproduced exactly: every first difference along time is the
        // same, right up to the front edge.
        let ramp: [[Float]] = (0..<10).map { r in [Float](repeating: 2 - 0.2 * Float(r), count: 3) }
        let height = 200
        for lag: Float in stride(from: 0, through: TerrainScrollClock.maxLag, by: 0.125) {
            let out = TerrainSurface.upsample(rows: ramp, lag: lag, width: 3, height: height)
            let column = (0..<height).map { out[$0 * 3 + 1] }
            let first = column[1] - column[0]
            XCTAssertLessThan(first, 0, "lag \(lag): the front is not a flat extrusion")
            for y in 1..<(height - 1) {
                XCTAssertEqual(column[y + 1] - column[y], first, accuracy: 1e-5, "lag \(lag) y \(y)")
            }
        }

        // A sharp onset at the newest row (loud newest row over quiet history): the time profile
        // near the front stays C1, with no crease where a clamp or extrusion would have been.
        var onset = [[Float]](repeating: [Float](repeating: 0.05, count: 3), count: 10)
        onset[0] = [Float](repeating: 1, count: 3)
        onset[1] = [Float](repeating: 0.6, count: 3)
        let fine = 1201
        let span = TerrainSurface.visibleRows(count: onset.count)
        let step = span / Float(fine - 1)
        for lag: Float in [0, 0.1, 0.5, 0.9, 1, 1.5, 2.5] {
            let out = TerrainSurface.upsample(rows: onset, lag: lag, width: 3, height: fine)
            let column = (0..<fine).map { out[$0 * 3 + 1] }
            // |f''| of these Hermite segments is at most a few units per row^2; a slope break of
            // even 0.05 would read 0.05 / step ~ 17 here.
            XCTAssertLessThan(kinkiness(column, step: step), 8, "lag \(lag)")
            XCTAssertTrue(column.allSatisfy { $0 >= 0 })
        }
    }

    /// The foot of a sharp onset across frequency: the monotone cubic goes flat into the floor
    /// instead of undershooting and being clamped, so there is no crease there.
    func testSharpOnsetHasNoKinkAndNoUndershoot() {
        var row = [Float](repeating: 0, count: 41)
        for p in 20...24 { row[p] = 1 }               // a narrow plateau: a hard onset either side
        row[19] = 0.02; row[25] = 0.4
        let width = 4001
        let step = Float(40) / Float(width - 1)
        let up = TerrainSurface.upsampleRow(row, width: width)
        XCTAssertTrue(up.allSatisfy { $0 >= 0 })
        XCTAssertLessThan(kinkiness(up, step: step), 8)
        // The same in time.
        let rows = row.map { [Float](repeating: $0, count: 2) }
        let fine = 2001
        let span = TerrainSurface.visibleRows(count: rows.count)
        let out = TerrainSurface.upsample(rows: rows, lag: 1.3, width: 2, height: fine)
        let column = (0..<fine).map { out[$0 * 2] }
        XCTAssertTrue(column.allSatisfy { $0 >= 0 })
        XCTAssertLessThan(kinkiness(column, step: span / Float(fine - 1)), 8)
    }

    func testUpsampleOfNoRowsIsFlat() {
        let out = TerrainSurface.upsample(rows: [], lag: 0.3, width: 8, height: 4)
        XCTAssertEqual(out, [Float](repeating: 0, count: 32))
    }

    // MARK: - Temporal smoothing

    func testTemporalBlend() {
        XCTAssertEqual(TerrainSurface.blend(new: [1, 0], previous: nil), [1, 0])
        let b = TerrainSurface.blend(new: [1, 0], previous: [0, 1])
        XCTAssertEqual(b[0], 0.55, accuracy: 1e-6)
        XCTAssertEqual(b[1], 0.45, accuracy: 1e-6)

        // heightRows applies it oldest to newest, on dB above the reference: a 40 dB step reaches
        // 0.55 x 40 on its first row, and when it stops it fades by 0.45 of its height per row.
        let quiet = [Float](repeating: -100, count: 41), loud = [Float](repeating: -60, count: 41)
        let rows = TerrainSurface.heightRows(grid: [loud, quiet], referenceDb: -100)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][20], 0, accuracy: 1e-5)                 // oldest
        XCTAssertEqual(rows[0][20], 0.55 * 40, accuracy: 1e-3)         // newest, blended with the older
        let three = TerrainSurface.heightRows(grid: [loud, loud, quiet], referenceDb: -100)
        XCTAssertEqual(three[0][20], (0.55 + 0.45 * 0.55) * 40, accuracy: 1e-3)
        let fading = TerrainSurface.heightRows(grid: [quiet, quiet, loud], referenceDb: -100)
        XCTAssertEqual(fading[0][20], 0.45 * 0.45 * 40, accuracy: 1e-3) // two rows after it stopped
    }

    /// The height rows are dB above a reference, clamped at it, so the level mapping can run per
    /// frame on the GPU. A flat row stays exactly flat; a narrow peak keeps most of its height
    /// instead of being averaged down toward the noise in dB, and falls away smoothly.
    func testHeightRowsAreDbAboveTheReference() {
        var row = [Float](repeating: -200, count: 41)                   // floor-clamped stopband
        row[20] = -40
        row[3] = .nan
        let h = TerrainSurface.heightRows(grid: [row], referenceDb: -90, sigmaPoints: 0.0001,
                                          peakSigmaPoints: 0.0001)
        XCTAssertEqual(h[0][0], 0)                                      // below the reference: 0
        XCTAssertEqual(h[0][3], 0)                                      // non-finite: 0
        XCTAssertEqual(h[0][20], 50, accuracy: 1e-3)

        let flat = TerrainSurface.heightRows(grid: [[Float](repeating: -70, count: 41)], referenceDb: -100)
        for v in flat[0] { XCTAssertEqual(v, 30, accuracy: 1e-3) }

        // One point 60 dB over the noise: it keeps a crest of over 40 dB (averaged on dB alone it
        // stood 8 dB high), falls away monotonically, and past the peak path's reach it eases into
        // the dB-smoothed shoulder with no step where either kernel ends.
        var spike = [Float](repeating: -100, count: 201)
        spike[100] = -40
        let s = TerrainSurface.heightRows(grid: [spike], referenceDb: -100)[0]
        XCTAssertGreaterThan(s[100], 40)
        for x in 100..<200 { XCTAssertLessThanOrEqual(s[x + 1], s[x] + 1e-4, "falls away at \(x)") }
        for x in 106..<200 { XCTAssertLessThan(s[x] - s[x + 1], 1, "no step at \(x)") }
        XCTAssertEqual(s[150], 0, accuracy: 0.01)

        // A spike 140 dB high, as an onset can be while the scale is still catching up: the cut-off
        // peak kernel draws the same flank as one that never stops (radius 20 sigma), so there is no
        // step where it ends.
        var tall = [Float](repeating: 0, count: 201)
        tall[100] = 140
        let cut = TerrainSurface.shapeRow(tall)
        let c = powf(10, -TerrainSurface.peakWeightDb / 10)
        let smooth = TerrainSurface.smoothRow(tall)
        let full = TerrainSurface.smoothRow(tall.map { powf(10, $0 / 10) },
                                            sigmaPoints: TerrainSurface.peakSigmaPoints, radiusSigmas: 20)
        for x in 0..<201 {
            let untruncated = max(10 * log10f((powf(10, smooth[x] / 10) + c * full[x]) / (1 + c)), 0)
            XCTAssertEqual(cut[x], untruncated, accuracy: 0.1, "flank at \(x)")
        }
    }

}

/// A terrain source that never delivers audio.
@MainActor private final class SilentTerrainSource: TerrainAudioSource {
    func setConsoleAudioStreaming(_ on: Bool) {}
    func onConsoleAudio(_ handler: (@Sendable (UnsafeBufferPointer<Float>, Int) -> Void)?) {}
}

@MainActor final class TerrainRendererTests: XCTestCase {
    func testRangeUniformCarriesTheScaleRelativeToTheTexture() {
        var range = TerrainAutoRange()
        for _ in 0..<50 { range.update(grid: [[Float]](repeating: [Float](repeating: -80, count: 4), count: 2), dt: 1) }
        let u = TerrainRenderer.rangeUniform(range, referenceDb: -90)
        XCTAssertEqual(u.x, range.floorDb + 90, accuracy: 1e-4)
        XCTAssertEqual(u.y, range.ceilingDb + 90, accuracy: 1e-4)
        XCTAssertEqual(u.z, TerrainAutoRange.kneeLevel)
    }

    /// The surface's front (newest) edge spans the same axis as the frequency labels at any pane
    /// size, sits just above the label row, and the back crest stays inside the pane.
    func testFramingPutsTheFrontEdgeOnTheLabelAxis() {
        for size in [CGSize(width: 1100, height: 260), CGSize(width: 600, height: 120),
                     CGSize(width: 1400, height: 300), CGSize(width: 900, height: 90)] {
            let m = TerrainRenderer.framing(viewSize: size)
            func pixel(_ p: SIMD3<Float>) -> CGPoint {
                let c: SIMD4<Float> = m * SIMD4<Float>(p, 1)
                let nx: Float = c.x / c.w, ny: Float = c.y / c.w
                let x = CGFloat((nx + 1) / 2) * size.width
                let y = CGFloat((1 - ny) / 2) * size.height
                return CGPoint(x: x, y: y)
            }
            let halfW = TerrainRenderer.surfaceWidth / 2, front = TerrainRenderer.surfaceDepth / 2
            for i in 0..<AudioTerrainView.audioLabels.count {
                let f = Float(i) / Float(AudioTerrainView.audioLabels.count - 1)
                let p = pixel(SIMD3<Float>((f - 0.5) * 2 * halfW, 0, front))
                XCTAssertEqual(p.x, AudioTerrainView.labelX(index: i, width: size.width), accuracy: 0.5,
                               "\(size) label \(i)")
                XCTAssertEqual(p.y, size.height - TerrainRenderer.labelBandPt, accuracy: 0.5, "\(size)")
            }
            XCTAssertEqual(pixel(SIMD3<Float>(-halfW, 0, front)).x, TerrainRenderer.axisInsetPt, accuracy: 0.5)
            XCTAssertEqual(pixel(SIMD3<Float>(halfW, 0, front)).x, size.width - TerrainRenderer.axisInsetPt,
                           accuracy: 0.5)
            let backCrest = pixel(SIMD3<Float>(0, TerrainRenderer.heightScale, -front))
            XCTAssertEqual(backCrest.y, TerrainRenderer.topMarginPt, accuracy: 0.5, "\(size)")
        }
    }

    func testUniformsLayoutMatchesShader() {
        // MSL: float4x4 (64) + 7 x float4 (112) = 176 bytes, then 5 x 32-byte stops.
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.viewProjection), 0)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.light), 64)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.eye), 80)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.fog), 96)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.surface), 112)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.shading), 128)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.grid), 144)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.range), 160)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.offset(of: \.stops), 176)
        XCTAssertEqual(MemoryLayout<TerrainGPUUniforms>.stride, 336)
    }

    func testColourMapIsDarkToBright() {
        let stops = TerrainPalette.stops
        XCTAssertEqual(stops.count, 5)
        func luma(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        for i in 1..<stops.count {
            XCTAssertGreaterThan(stops[i].position, stops[i - 1].position)
            XCTAssertGreaterThan(luma(stops[i].rgba), luma(stops[i - 1].rgba))
        }
    }

    func testSampleGridHasTheFeedShape() {
        let g = SampleImagery.terrainGrid()
        XCTAssertEqual(g.count, TerrainHistory.rows)
        XCTAssertTrue(g.allSatisfy { $0.count == 201 })
        XCTAssertEqual(g, SampleImagery.terrainGrid())
        // The 700 Hz tone (point 700/15 ~ 47) stands above its neighbourhood in every row.
        for row in g { XCTAssertGreaterThan(row[47], row[40] + 10) }
    }

    func testPaddingKeepsTheFeedHonest() {
        // Missing (young) rows draw flat at the back; the newest row stays at the front.
        let padded = TerrainRenderer.padded([[Float](repeating: 0.8, count: 4)], rows: 3, points: 4)
        XCTAssertEqual(padded.count, 3)
        XCTAssertEqual(padded[0], [0.8, 0.8, 0.8, 0.8])
        XCTAssertEqual(padded[2], [0, 0, 0, 0])
        XCTAssertEqual(TerrainRenderer.padded([], rows: 2, points: 3), [[0, 0, 0], [0, 0, 0]])
    }

    func testScrollLagFreezesWhenNotLive() {
        var clock = TerrainScrollClock()
        let p = TerrainScrollClock.nominalPeriod
        XCTAssertEqual(clock.advance(now: 10, live: true), TerrainScrollClock.targetLag)
        let moving = clock.advance(now: 10 + p / 2, live: true)
        XCTAssertEqual(moving, TerrainScrollClock.targetLag - 0.5, accuracy: 1e-3)
        XCTAssertEqual(clock.advance(now: 10 + p, live: false), moving)
        XCTAssertEqual(clock.advance(now: 50, live: false), moving)
        // Resuming continues from the frozen value rather than jumping.
        XCTAssertEqual(clock.advance(now: 60, live: true), moving)
        XCTAssertLessThan(clock.advance(now: 60 + 1.0 / 60, live: true), moving)
    }

    /// A row landing grows the lag by one row, so the picture holds still at the arrival; bursts
    /// are counted by row.
    func testRowArrivalTakesUpTheLag() {
        var clock = TerrainScrollClock()
        _ = clock.advance(now: 0, live: true)
        let before = clock.advance(now: 0.1, live: true)
        clock.rowsArrived(at: 0.1)
        XCTAssertEqual(clock.lag, before + 1, accuracy: 1e-6)
        clock.rowsArrived(5, at: 0.11)
        XCTAssertEqual(clock.lag, TerrainScrollClock.maxLag)

        let a: [Float] = [1, 2], b: [Float] = [3, 4], c: [Float] = [5, 6]
        XCTAssertEqual(TerrainRenderer.arrivedRows([b, a], previousNewest: a), 1)
        XCTAssertEqual(TerrainRenderer.arrivedRows([c, b, a], previousNewest: a), 2)
        XCTAssertEqual(TerrainRenderer.arrivedRows([b, a], previousNewest: b), 0)
        XCTAssertEqual(TerrainRenderer.arrivedRows([b], previousNewest: nil), 0)
        XCTAssertEqual(TerrainRenderer.arrivedRows([c, b], previousNewest: a), 1)
    }

    /// Rows that arrive slower than the nominal 4/30 s (and with jitter): the measured period
    /// follows them, the scroll position only ever moves forward, it moves every frame at a
    /// near-constant speed, and the lag never runs dry (it does not sit at its stop and wait).
    func testScrollKeepsRollingWhenRowsArriveSlow() {
        for nominal in [0.18, 0.2, 0.1] {
            var clock = TerrainScrollClock()
            let frame = 1.0 / 60
            var nextRow = nominal, arrived = 0
            var seed: UInt64 = 42
            var lastPosition: Float?
            var steps: [Float] = []
            var minLag = Float.infinity, maxLag = -Float.infinity
            var t = 0.0
            while t < 12 {
                t += frame
                while t >= nextRow {
                    clock.rowsArrived(at: nextRow)
                    arrived += 1
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let jitter = (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.2 * nominal
                    nextRow += nominal + jitter
                }
                let lag = clock.advance(now: t, live: true)
                // Where the front is in the stream of rows: rows arrived minus the lag.
                let position = Float(arrived) - lag
                if t > 4 {                                      // after the period has settled
                    if let lastPosition { steps.append(position - lastPosition) }
                    minLag = min(minLag, lag); maxLag = max(maxLag, lag)
                }
                lastPosition = position
            }
            XCTAssertEqual(clock.period, nominal, accuracy: nominal * 0.1, "\(nominal)")
            XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "\(nominal): moves forward every frame")
            let expected = Float(frame / nominal)
            XCTAssertGreaterThan(steps.min()!, expected * 0.7, "\(nominal): no stall")
            XCTAssertLessThan(steps.max()!, expected * 1.3, "\(nominal): no lurch")
            XCTAssertGreaterThan(minLag, 0.2, "\(nominal): never sits at its stop")
            XCTAssertLessThan(maxLag, TerrainScrollClock.maxLag, "\(nominal): never fills up")
        }
    }

    func testSwitchingToTheFeedRestartsTheScale() throws {
        guard let ctx = MetalContext.shared else { throw XCTSkip("No Metal device") }
        let r = try TerrainRenderer(context: ctx)
        r.setSource(.sample([[Float]](repeating: [Float](repeating: -20, count: 201), count: 30)))
        XCTAssertNotEqual(r.autoRange, TerrainAutoRange())
        r.setSource(.feed(TerrainFeed(source: SilentTerrainSource())))
        XCTAssertEqual(r.autoRange, TerrainAutoRange())
        XCTAssertEqual(r.autoRange.floorDb, -100)
        XCTAssertEqual(r.autoRange.ceilingDb, -50)
    }

    func testShaderCompilesAndOffscreenFrameRenders() throws {
        guard let ctx = MetalContext.shared else { throw XCTSkip("No Metal device") }
        let lib = try ctx.library(named: "terrain", source: TerrainShaders.source)
        for f in ["terrain_vertex", "terrain_fragment"] { XCTAssertNotNil(lib.makeFunction(name: f), f) }

        let r = try TerrainRenderer(context: ctx)
        // A flat (empty) grid: the surface still draws, dark, over the void.
        let flat = try r.renderOffscreen(grid: [], size: MTLSize(width: 160, height: 80, depth: 1))
        // A loud ridge down the middle of the band: the centre of the frame lights up.
        var row = [Float](repeating: -90, count: 201)
        for p in 90...110 { row[p] = -20 }
        let ridge = try r.renderOffscreen(grid: [[Float]](repeating: row, count: 30),
                                          size: MTLSize(width: 160, height: 80, depth: 1))
        func brightest(_ t: MTLTexture) -> Int {
            var best = 0
            var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                best = max(best, Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]))
            }
            return best
        }
        XCTAssertGreaterThan(brightest(ridge), brightest(flat) + 150)
    }
}
