import XCTest
import Metal
@testable import Observatory

@MainActor final class WaterfallTests: XCTestCase {
    private let bins = 16

    private func row(_ value: Float, bin: Int? = nil, base: Float = -150) -> [Float] {
        var r = [Float](repeating: base, count: bins)
        if let bin { r[bin] = value } else { r = [Float](repeating: value, count: bins) }
        return r
    }

    private func ingest(_ b: inout WaterfallRowBuilder, _ r: [Float], serial: UInt64) {
        r.withUnsafeBufferPointer { b.ingest($0, serial: serial) }
    }

    /// Runs a builder the way the renderer does and counts emitted rows.
    private func emitted(ticks: Int, duration: Double, rowsPerSecond: Int) -> Int {
        var b = WaterfallRowBuilder(bins: bins)
        var total = 0
        for i in 0..<ticks {
            let now = 100 + duration * Double(i) / Double(ticks)
            ingest(&b, row(-100), serial: UInt64(i + 1))
            if b.hasPending {
                let n = b.rowsDue(now: now, rowsPerSecond: rowsPerSecond)
                if n > 0 { total += n; b.didEmitRow() }
            }
        }
        return total
    }

    func testRowsAreTimeBased() {
        XCTAssertEqual(emitted(ticks: 120, duration: 1.0, rowsPerSecond: 20), 20)
    }

    func testPeakHeldBetweenRows() {
        var b = WaterfallRowBuilder(bins: bins)
        ingest(&b, row(-60, bin: 3), serial: 1)
        ingest(&b, row(-90, bin: 3), serial: 2)
        XCTAssertEqual(b.pendingRow()[3], -60)
        XCTAssertEqual(b.pendingRow()[4], -150)
        b.didEmitRow()
        XCTAssertFalse(b.hasPending)
        ingest(&b, row(-90, bin: 3), serial: 3)
        XCTAssertEqual(b.pendingRow()[3], -90)
    }

    func testMaxEightRowsPerTick() {
        var b = WaterfallRowBuilder(bins: bins)
        XCTAssertEqual(b.rowsDue(now: 10, rowsPerSecond: 20), 1)   // first call pushes one
        XCTAssertEqual(b.rowsDue(now: 12, rowsPerSecond: 20), 8)
    }

    func testNoFrameNoRow() {
        var b = WaterfallRowBuilder(bins: bins)
        XCTAssertGreaterThan(b.rowsDue(now: 10, rowsPerSecond: 20), 0)
        XCTAssertFalse(b.hasPending)
    }

    func testRepeatedSerialIgnored() {
        var b = WaterfallRowBuilder(bins: bins)
        ingest(&b, row(-60, bin: 1), serial: 5)
        b.didEmitRow()
        ingest(&b, row(-60, bin: 1), serial: 5)
        XCTAssertFalse(b.hasPending)
        ingest(&b, row(-60, bin: 1), serial: 6)
        XCTAssertTrue(b.hasPending)
    }

    func testResetForgetsSerialAndPending() {
        var b = WaterfallRowBuilder(bins: bins)
        ingest(&b, row(-60, bin: 1), serial: 5)
        b.reset()
        XCTAssertFalse(b.hasPending)
        ingest(&b, row(-60, bin: 1), serial: 5)
        XCTAssertTrue(b.hasPending)
    }

    func testColourIndexRounding() {
        XCTAssertEqual(WaterfallColorMap.index(db: -120, floor: -120, ceiling: -20), 0)
        XCTAssertEqual(WaterfallColorMap.index(db: -20, floor: -120, ceiling: -20), 255)
        XCTAssertEqual(WaterfallColorMap.index(db: -70, floor: -120, ceiling: -20), 128)
        XCTAssertEqual(WaterfallColorMap.index(db: -300, floor: -120, ceiling: -20), 0)
        XCTAssertEqual(WaterfallColorMap.index(db: 50, floor: -120, ceiling: -20), 255)
        XCTAssertEqual(WaterfallColorMap.index(db: .nan, floor: -120, ceiling: -20), 0)
    }

    func testCustomRampMatchesQt() {
        let ramp = WaterfallColorMap.customRamp(baseRGB: 0x30B0FF)
        XCTAssertEqual(ramp.count, 768)
        XCTAssertEqual(Array(ramp[0..<3]), [0, 0, 0])
        XCTAssertEqual(Array(ramp[166 * 3..<166 * 3 + 3]), [0x30, 0xB0, 0xFF])
        // base + (255 - base) * 0.7, truncated.
        XCTAssertEqual(Array(ramp[255 * 3..<255 * 3 + 3]), [0x30 + Int(Double(255 - 0x30) * 0.7) , 0xB0 + Int(Double(255 - 0xB0) * 0.7), 0xFF].map { UInt8($0) })
        XCTAssertEqual(Int(ramp[83 * 3 + 2]), Int(255.0 * (83.0 / 255.0 / 0.65)))   // mid-rise blue
    }

    func testHistoryClearsOnTxEdgeAndSpanChange() {
        let a = RadioSnapshot.sample.display
        XCTAssertFalse(WaterfallHistoryPolicy.shouldClear(old: a, new: a))
        var tx = a; tx.txAxis.toggle()
        XCTAssertTrue(WaterfallHistoryPolicy.shouldClear(old: a, new: tx))
        var lo = a; lo.spanLowHz += 1000
        XCTAssertTrue(WaterfallHistoryPolicy.shouldClear(old: a, new: lo))
        var hi = a; hi.spanHighHz += 1000
        XCTAssertTrue(WaterfallHistoryPolicy.shouldClear(old: a, new: hi))
        var other = a; other.waterfallRowsPerSecond += 5
        XCTAssertFalse(WaterfallHistoryPolicy.shouldClear(old: a, new: other))
    }

    func testStackUsesLiveWaterfallUnlessMocked() {
        XCTAssertFalse(ReceiverDisplayStack.usesLiveWaterfall(.allMocked))
        XCTAssertTrue(ReceiverDisplayStack.usesLiveWaterfall(BackendCapabilities(statuses: [.waterfall: .available], fallback: .mocked)))
    }

    // MARK: - Renderer

    func testNewestRowIsOnTopAndOlderScrollsDown() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let bridge = SpectrumBridge.mock()
        let r = try WaterfallRenderer(bridge: bridge, context: ctx)
        let lut: [UInt8] = (0..<256).flatMap { [UInt8($0), 0, 0] as [UInt8] }   // red ramp
        r.setColors(.lut(lut))
        let bins = SpectrumPump.bins
        let cold = [Float](repeating: -120, count: bins), hot = [Float](repeating: -20, count: bins)
        cold.withUnsafeBufferPointer { r.emit($0, floor: -120, ceiling: -20, count: 1) }
        hot.withUnsafeBufferPointer { r.emit($0, floor: -120, ceiling: -20, count: 1) }
        let tex = try r.renderOffscreen(size: MTLSize(width: 64, height: 64, depth: 1))
        XCTAssertEqual(pixel(tex, x: 32, y: 0).r, 255)   // newest, hottest, on top
        XCTAssertEqual(pixel(tex, x: 32, y: 1).r, 0)     // older, coldest
        r.clear()
        let cleared = try r.renderOffscreen(size: MTLSize(width: 64, height: 64, depth: 1))
        XCTAssertEqual(pixel(cleared, x: 32, y: 0).r, pixel(cleared, x: 32, y: 40).r)
    }

    func testHistoryIsClampedToDrawableHeight() {
        XCTAssertEqual(WaterfallRenderer.history(forDrawableHeight: 10), 64)
        XCTAssertEqual(WaterfallRenderer.history(forDrawableHeight: 500), 500)
        XCTAssertEqual(WaterfallRenderer.history(forDrawableHeight: 5000), 2048)
    }

    func testShaderSourceCompiles() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let lib = try ctx.library(named: "waterfall", source: WaterfallShaders.source)
        for f in ["waterfall_vertex", "waterfall_fragment"] { XCTAssertNotNil(lib.makeFunction(name: f), f) }
    }

    func testWaterfallViewRendersWithSyntheticSource() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let bridge = SpectrumBridge.mock()
        let r = try WaterfallRenderer(bridge: bridge, context: ctx)
        for i in 0..<40 { r.advance(now: 100 + Double(i) / 30) }
        let tex = try r.renderOffscreen(size: MTLSize(width: 64, height: 64, depth: 1))
        var lit = false
        for x in 0..<64 { let p = pixel(tex, x: x, y: 0); if Int(p.r) + Int(p.g) + Int(p.b) > 90 { lit = true } }
        XCTAssertTrue(lit)
    }

    private func pixel(_ tex: MTLTexture, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (bytes[2], bytes[1], bytes[0])
    }
}
