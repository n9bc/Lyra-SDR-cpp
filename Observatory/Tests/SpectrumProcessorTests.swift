import XCTest
@testable import Observatory

final class SpectrumProcessorTests: XCTestCase {
    func testColumnCountClamps() {
        XCTAssertEqual(SpectrumFrameProcessor.columnCount(forDrawableWidth: 0), 64)
        XCTAssertEqual(SpectrumFrameProcessor.columnCount(forDrawableWidth: 40), 64)
        XCTAssertEqual(SpectrumFrameProcessor.columnCount(forDrawableWidth: 2000), 1000)
        XCTAssertEqual(SpectrumFrameProcessor.columnCount(forDrawableWidth: 12_000), 2048)
    }
    func testNonFiniteInputMapsToFloor() {
        for v: Float in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(SpectrumFrameProcessor.normalize(v, floor: -130, ceiling: -20), 0)
        }
    }
    func testInvertedRangeIsSafe() {
        let n = SpectrumFrameProcessor.normalize(-50, floor: -20, ceiling: -130)
        XCTAssertTrue(n.isFinite); XCTAssertTrue((0...1).contains(n))
    }
    func testPeakReductionKeepsNarrowCarrier() {
        var p = SpectrumFrameProcessor(); p.resize(columns: 64)
        var bins = [Float](repeating: -130, count: 4096); bins[2050] = -20
        for _ in 0..<40 { bins.withUnsafeBufferPointer { p.ingest($0, floor: -130, ceiling: -20) } }
        XCTAssertEqual(p.heights[32], 1, accuracy: 1e-3)
        XCTAssertEqual(p.heights[0], 0, accuracy: 1e-3)
    }
    func testAttackFasterThanRelease() {
        var p = SpectrumFrameProcessor(); p.resize(columns: 64)
        let hi = [Float](repeating: -20, count: 4096)
        hi.withUnsafeBufferPointer { p.ingest($0, floor: -130, ceiling: -20) }
        XCTAssertEqual(p.heights[0], 0.6, accuracy: 1e-5)
        let lo = [Float](repeating: -130, count: 4096)
        lo.withUnsafeBufferPointer { p.ingest($0, floor: -130, ceiling: -20) }
        XCTAssertEqual(p.heights[0], 0.6 * 0.85, accuracy: 1e-5)
    }
    func testEmptyFrameDecaysTowardFloor() {
        var p = SpectrumFrameProcessor(); p.resize(columns: 64)
        let hi = [Float](repeating: -20, count: 4096)
        for _ in 0..<20 { hi.withUnsafeBufferPointer { p.ingest($0, floor: -130, ceiling: -20) } }
        for _ in 0..<60 { p.ingest(UnsafeBufferPointer(start: nil, count: 0), floor: -130, ceiling: -20) }
        XCTAssertLessThan(p.heights.max()!, 0.01)
    }
    @MainActor func testSyntheticSourceFillsBuffer() {
        let s = SyntheticSpectrumSource()
        var buf = [Float](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { s.copySpectrum(into: $0) }
        XCTAssertEqual(n, 4096)
        XCTAssertTrue(buf.allSatisfy { $0.isFinite && $0 <= -50 && $0 >= -130 })
    }
}
