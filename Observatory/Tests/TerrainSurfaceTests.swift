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
        // 4 rows x 5 points onto 9 x 7: knots at x = 0, 2, 4, 6, 8 and y = 0, 2, 4, 6.
        let rows: [[Float]] = [[0.1, 0.5, 0.9, 0.3, 0.2],
                               [0.4, 0.8, 0.2, 0.6, 0.1],
                               [0.7, 0.3, 0.5, 0.9, 0.4],
                               [0.2, 0.6, 0.8, 0.1, 0.5]]
        let out = TerrainSurface.upsample(rows: rows, fraction: 0, width: 9, height: 7)
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
        let big = TerrainSurface.upsample(rows: smooth, fraction: 0.37)
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

    func testUpsampleFractionShiftsTime() {
        // Newest row (0) at 1, all older rows at 0. Width 2 keeps x trivial; height 4 = 1 knot/row.
        let rows: [[Float]] = [[1, 1], [0, 0], [0, 0], [0, 0]]
        let still = TerrainSurface.upsample(rows: rows, fraction: 0, width: 2, height: 4)
        XCTAssertEqual(still[0], 1, accuracy: 1e-4)
        XCTAssertEqual(still[2], 0, accuracy: 1e-4)
        // Half a row later the newest row has moved half way back: output row 1 lies between.
        let half = TerrainSurface.upsample(rows: rows, fraction: 0.5, width: 2, height: 4)
        XCTAssertGreaterThan(half[2], 0.2)
        XCTAssertLessThan(half[2], 0.8)
        // The front stays on the newest row (clamped, nothing invented ahead of it).
        XCTAssertEqual(half[0], 1, accuracy: 1e-4)
    }

    func testUpsampleNeverNegative() {
        // An impulse makes Catmull-Rom undershoot; the output is clamped at zero.
        var row = [Float](repeating: 0, count: 21)
        row[10] = 1
        var rows = [[Float]](repeating: [Float](repeating: 0, count: 21), count: 6)
        rows[2] = row
        for f: Float in [0, 0.25, 0.5, 0.75] {
            let out = TerrainSurface.upsample(rows: rows, fraction: f, width: 64, height: 32)
            XCTAssertTrue(out.allSatisfy { $0 >= 0 })
        }
    }

    func testUpsampleOfNoRowsIsFlat() {
        let out = TerrainSurface.upsample(rows: [], fraction: 0.3, width: 8, height: 4)
        XCTAssertEqual(out, [Float](repeating: 0, count: 32))
    }

    // MARK: - Temporal smoothing

    func testTemporalBlend() {
        XCTAssertEqual(TerrainSurface.blend(new: [1, 0], previous: nil), [1, 0])
        let b = TerrainSurface.blend(new: [1, 0], previous: [0, 1])
        XCTAssertEqual(b[0], 0.55, accuracy: 1e-6)
        XCTAssertEqual(b[1], 0.45, accuracy: 1e-6)

        // heightRows applies it oldest to newest, in dB above the reference: a 40 dB step reaches
        // 0.55 x 40 on its first row.
        let quiet = [Float](repeating: -100, count: 41), loud = [Float](repeating: -60, count: 41)
        let rows = TerrainSurface.heightRows(grid: [loud, quiet], referenceDb: -100)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][20], 0, accuracy: 1e-5)                 // oldest
        XCTAssertEqual(rows[0][20], 0.55 * 40, accuracy: 1e-3)         // newest, blended with the older
        let three = TerrainSurface.heightRows(grid: [loud, loud, quiet], referenceDb: -100)
        XCTAssertEqual(three[0][20], (0.55 + 0.45 * 0.55) * 40, accuracy: 1e-3)
    }

    /// The height rows are dB above a reference, clamped at it, so the level mapping can run per
    /// frame on the GPU. Smoothing and blending are affine-invariant, so mapping afterwards gives
    /// what mapping first gave, wherever nothing is clipped.
    func testHeightRowsAreDbAboveTheReference() {
        var row = [Float](repeating: -200, count: 41)                   // floor-clamped stopband
        row[20] = -40
        row[3] = .nan
        let h = TerrainSurface.heightRows(grid: [row], referenceDb: -90, sigmaPoints: 0.0001)
        XCTAssertEqual(h[0][0], 0)                                      // below the reference: 0
        XCTAssertEqual(h[0][3], 0)                                      // non-finite: 0
        XCTAssertEqual(h[0][20], 50, accuracy: 1e-3)

        let range = TerrainAutoRange()                                  // -100 ... -50
        let g: [[Float]] = [(0..<41).map { -100 + Float($0) }, (0..<41).map { -95 + Float($0) / 2 }]
        let heights = TerrainSurface.heightRows(grid: g, referenceDb: range.floorDb)
        // What the shader does per texel: the level of (height + reference) dBFS.
        let levels = heights.map { $0.map { range.level($0 + range.floorDb) } }
        var expected: [Float]?
        for age in [1, 0] {
            let smoothed = TerrainSurface.smoothRow(g[age].map { range.level($0) })
            expected = TerrainSurface.blend(new: smoothed, previous: expected)
            for i in 0..<41 { XCTAssertEqual(levels[age][i], expected![i], accuracy: 1e-4, "row \(age) bin \(i)") }
        }
    }

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

    func testScrollFractionFreezesWhenNotLive() {
        var clock = TerrainScrollClock()
        clock.rowArrived(at: 10)
        XCTAssertEqual(clock.fraction(now: 10 + TerrainScrollClock.rowPeriod / 2, live: true), 0.5, accuracy: 1e-6)
        let frozen = clock.fraction(now: 10 + TerrainScrollClock.rowPeriod * 0.6, live: false)
        XCTAssertEqual(frozen, 0.5, accuracy: 1e-6)
        XCTAssertEqual(clock.fraction(now: 50, live: false), 0.5, accuracy: 1e-6)
        // Resuming continues from the frozen value rather than jumping.
        XCTAssertEqual(clock.fraction(now: 60, live: true), 0.5, accuracy: 1e-6)
        XCTAssertLessThan(clock.fraction(now: 1_000, live: true), 1)
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
