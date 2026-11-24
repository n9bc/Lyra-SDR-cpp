import XCTest
@testable import Observatory

/// Records every pull and answers from a script.
@MainActor
final class FakeSpectrumSource: SpectrumSource {
    struct Call: Equatable { var rx: ReceiverID; var waterfall: Bool; var requested: Int }
    var calls: [Call] = []
    /// Bins to return and the value to fill with; `returned` nil means "fill the whole buffer".
    var returned: Int?
    /// Overrides `returned` for waterfall rows only, when set.
    var rowsReturned: Int?
    var fill: Float = -80

    private func answer(_ rx: ReceiverID, _ waterfall: Bool, _ buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        calls.append(Call(rx: rx, waterfall: waterfall, requested: buffer.count))
        let count = (waterfall ? rowsReturned : nil) ?? returned ?? buffer.count
        let n = min(count, buffer.count)
        for i in 0..<n { buffer[i] = fill }
        return count
    }
    func copySpectrum(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        answer(rx, false, buffer)
    }
    func copyWaterfallRow(_ rx: ReceiverID, into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        answer(rx, true, buffer)
    }
}

@MainActor
final class SpectrumPumpTests: XCTestCase {
    func testPumpPullsOncePerInterval() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        let afterFirst = src.calls.count
        XCTAssertGreaterThan(afterFirst, 0)
        pump.tick(now: 0.002, sub: false)
        pump.tick(now: 0.004, sub: false)
        XCTAssertEqual(src.calls.count, afterFirst)
        XCTAssertEqual(src.calls.filter { $0.rx == .main && !$0.waterfall }.count, 1)
        XCTAssertEqual(src.calls.filter { $0.rx == .main && $0.waterfall }.count, 1)
        pump.tick(now: 0.02, sub: false)
        XCTAssertEqual(src.calls.filter { $0.rx == .main && !$0.waterfall }.count, 2)
    }

    func testPumpRequestsFullBins() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: true)
        XCTAssertFalse(src.calls.isEmpty)
        XCTAssertTrue(src.calls.allSatisfy { $0.requested == 4096 })
    }

    func testZeroReturnKeepsLastFrame() throws {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        let serial = pump.spectrumSerial(.main), rowSerial = pump.waterfallSerial(.main)
        XCTAssertGreaterThan(serial, 0)
        XCTAssertGreaterThan(rowSerial, 0)
        src.returned = 0
        src.fill = -10
        pump.tick(now: 1, sub: false)
        let frame = try XCTUnwrap(pump.spectrum(.main))
        XCTAssertEqual(frame.count, 4096)
        XCTAssertEqual(frame[0], -80)
        XCTAssertEqual(pump.spectrumSerial(.main), serial)
        XCTAssertEqual(pump.waterfallSerial(.main), rowSerial)
    }

    func testShortReturnIsNotAFrame() {
        let src = FakeSpectrumSource()
        src.returned = 1024
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        XCTAssertNil(pump.spectrum(.main))
        XCTAssertEqual(pump.spectrumSerial(.main), 0)
        XCTAssertEqual(pump.waterfallSerial(.main), 0)
    }

    func testFloorFrameIsNotAFrame() {
        let src = FakeSpectrumSource()
        src.fill = -200
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        XCTAssertNil(pump.spectrum(.main))
        XCTAssertNil(pump.waterfallRow(.main))
        XCTAssertEqual(pump.spectrumSerial(.main), 0)
        XCTAssertEqual(pump.waterfallSerial(.main), 0)
    }

    func testSubNotPulledWhenSubOff() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        XCTAssertTrue(src.calls.filter { $0.rx == .sub }.isEmpty)
        pump.tick(now: 1, sub: true)
        XCTAssertFalse(src.calls.filter { $0.rx == .sub }.isEmpty)
        XCTAssertNotNil(pump.spectrum(.sub))
    }

    func testSerialBumpsOnGoodFrame() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        let a = pump.spectrumSerial(.main), b = pump.waterfallSerial(.main)
        pump.tick(now: 1, sub: false)
        XCTAssertGreaterThan(pump.spectrumSerial(.main), a)
        XCTAssertGreaterThan(pump.waterfallSerial(.main), b)
    }

    /// A Sub row or any spectrum frame must not look like a new Main row (final review, M1).
    func testWaterfallSerialIsPerReceiverAndPerStream() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        let mainRow = pump.waterfallSerial(.main)
        XCTAssertEqual(pump.waterfallSerial(.sub), 0)
        // Only spectra are good from here on: no waterfall serial moves.
        src.rowsReturned = 0
        pump.tick(now: 1, sub: true)
        XCTAssertEqual(pump.waterfallSerial(.main), mainRow)
        XCTAssertEqual(pump.waterfallSerial(.sub), 0)
        XCTAssertGreaterThan(pump.spectrumSerial(.sub), 0)
        src.rowsReturned = nil
        pump.tick(now: 2, sub: true)
        XCTAssertGreaterThan(pump.waterfallSerial(.sub), 0)
        XCTAssertEqual(pump.waterfallSerial(.main), mainRow + 1)
    }
}

/// The engine's copy calls hand back the last frame forever, so only a streaming radio's frames
/// are new (final review, Important 3).
@MainActor
final class SpectrumStreamingTests: XCTestCase {
    func testPumpDoesNotPullWhileNotStreaming() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.isStreaming = false
        pump.tick(now: 0, sub: true)
        pump.tick(now: 1, sub: true)
        XCTAssertTrue(src.calls.isEmpty)
        XCTAssertNil(pump.spectrum(.main))
        pump.isStreaming = true
        pump.tick(now: 2, sub: false)
        XCTAssertFalse(src.calls.isEmpty)
        XCTAssertNotNil(pump.spectrum(.main))
    }

    func testLeavingStreamingForgetsTheLastFrames() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: true)
        XCTAssertNotNil(pump.spectrum(.main))
        XCTAssertNotNil(pump.waterfallRow(.sub))
        let serial = pump.waterfallSerial(.main)
        pump.isStreaming = false
        XCTAssertNil(pump.spectrum(.main))
        XCTAssertNil(pump.spectrum(.sub))
        XCTAssertNil(pump.waterfallRow(.main))
        XCTAssertNil(pump.waterfallRow(.sub))
        pump.tick(now: 1, sub: true)
        XCTAssertEqual(pump.waterfallSerial(.main), serial)
    }

    func testOcclusionAndStreamingSuspendIndependently() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.isSuspended = true
        pump.isStreaming = true
        pump.tick(now: 0, sub: false)
        XCTAssertTrue(src.calls.isEmpty)
        pump.isSuspended = false
        pump.isStreaming = false
        pump.tick(now: 1, sub: false)
        XCTAssertTrue(src.calls.isEmpty)
        pump.isStreaming = true
        pump.tick(now: 2, sub: false)
        XCTAssertFalse(src.calls.isEmpty)
    }

    func testBridgeForwardsStreamingToTheSharedPump() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        let main = SpectrumBridge(pump: pump, receiver: .main)
        XCTAssertTrue(main.isStreaming)
        main.setStreaming(false)
        XCTAssertFalse(main.isStreaming)
        XCTAssertFalse(pump.isStreaming)
        main.setStreaming(true)
        XCTAssertTrue(pump.isStreaming)
    }

    func testWaterfallEmitsNoRowWhileNotStreaming() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let src = FakeSpectrumSource()
        let bridge = SpectrumBridge(pump: SpectrumPump(source: src), receiver: .main)
        let r = try WaterfallRenderer(bridge: bridge, context: ctx)
        for i in 0..<10 { r.advance(now: 100 + Double(i) / 10) }
        let filled = r.filled
        XCTAssertGreaterThan(filled, 0)
        bridge.setStreaming(false)
        for i in 0..<30 { r.advance(now: 102 + Double(i) / 10) }
        XCTAssertEqual(r.filled, filled)
    }

    func testWaterfallEmitsNoRowWhenTheRowSerialDoesNotAdvance() throws {
        let ctx = try XCTUnwrap(MetalContext.shared)
        let src = FakeSpectrumSource()
        let bridge = SpectrumBridge(pump: SpectrumPump(source: src), receiver: .main)
        let r = try WaterfallRenderer(bridge: bridge, context: ctx)
        for i in 0..<10 { r.advance(now: 100 + Double(i) / 10) }
        let filled = r.filled
        // Spectra keep arriving but no new waterfall row does: nothing new to push.
        src.rowsReturned = 0
        for i in 0..<30 { r.advance(now: 102 + Double(i) / 10) }
        XCTAssertEqual(r.filled, filled)
    }

    func testSpectrumDrawsNoTraceWithoutAFrame() {
        XCTAssertEqual(NeonSpectrumRenderer.traceColumns(800, hasFrame: false), 0)
        XCTAssertEqual(NeonSpectrumRenderer.traceColumns(800, hasFrame: true), 800)
    }
}

@MainActor
final class SpectrumOcclusionTests: XCTestCase {
    func testSuspendedPumpPullsNothingAndKeepsTheLastFrame() {
        let src = FakeSpectrumSource()
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        let pulls = src.calls.count
        XCTAssertNotNil(pump.spectrum(.main))
        pump.isSuspended = true
        pump.tick(now: 1, sub: true)
        XCTAssertEqual(src.calls.count, pulls)
        XCTAssertNotNil(pump.spectrum(.main))
        pump.isSuspended = false
        pump.tick(now: 2, sub: false)
        XCTAssertGreaterThan(src.calls.count, pulls)
    }

    func testOnlyAFullyHiddenWindowSuspendsThePump() {
        XCTAssertTrue(SpectrumOcclusionGate.suspends([]))
        XCTAssertFalse(SpectrumOcclusionGate.suspends(.visible))
    }
}
