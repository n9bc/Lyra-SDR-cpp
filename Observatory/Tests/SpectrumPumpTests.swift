import XCTest
@testable import Observatory

/// Records every pull and answers from a script.
@MainActor
final class FakeSpectrumSource: SpectrumSource {
    struct Call: Equatable { var rx: ReceiverID; var waterfall: Bool; var requested: Int }
    var calls: [Call] = []
    /// Bins to return and the value to fill with; `returned` nil means "fill the whole buffer".
    var returned: Int?
    var fill: Float = -80

    private func answer(_ rx: ReceiverID, _ waterfall: Bool, _ buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        calls.append(Call(rx: rx, waterfall: waterfall, requested: buffer.count))
        let n = min(returned ?? buffer.count, buffer.count)
        for i in 0..<n { buffer[i] = fill }
        return returned ?? buffer.count
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
        let serial = pump.frameSerial
        XCTAssertGreaterThan(serial, 0)
        src.returned = 0
        src.fill = -10
        pump.tick(now: 1, sub: false)
        let frame = try XCTUnwrap(pump.spectrum(.main))
        XCTAssertEqual(frame.count, 4096)
        XCTAssertEqual(frame[0], -80)
        XCTAssertEqual(pump.frameSerial, serial)
    }

    func testShortReturnIsNotAFrame() {
        let src = FakeSpectrumSource()
        src.returned = 1024
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        XCTAssertNil(pump.spectrum(.main))
        XCTAssertEqual(pump.frameSerial, 0)
    }

    func testFloorFrameIsNotAFrame() {
        let src = FakeSpectrumSource()
        src.fill = -200
        let pump = SpectrumPump(source: src)
        pump.tick(now: 0, sub: false)
        XCTAssertNil(pump.spectrum(.main))
        XCTAssertNil(pump.waterfallRow(.main))
        XCTAssertEqual(pump.frameSerial, 0)
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
        let a = pump.frameSerial
        pump.tick(now: 1, sub: false)
        XCTAssertGreaterThan(pump.frameSerial, a)
    }
}
