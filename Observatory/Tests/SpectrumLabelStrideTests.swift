import XCTest
@testable import Observatory

@MainActor
final class SpectrumLabelStrideTests: XCTestCase {
    func testTallViewLabelsEveryLine() {
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 400, range: 90, step: 10), 1)
    }

    func testShortViewSkipsEveryOtherLine() {
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 114, range: 90, step: 10), 2)
    }

    func testTinyHeightsNeedLargerStride() {
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 40, range: 90, step: 10), 4)
        XCTAssertGreaterThan(NeonSpectrumView.labelStride(height: 20, range: 90, step: 10), 4)
    }

    func testDegenerateInputReturnsOne() {
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 0, range: 90, step: 10), 1)
        XCTAssertEqual(NeonSpectrumView.labelStride(height: -5, range: 90, step: 10), 1)
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 114, range: 0, step: 10), 1)
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 114, range: -3, step: 10), 1)
        XCTAssertEqual(NeonSpectrumView.labelStride(height: 114, range: 90, step: 0), 1)
    }

    private func assertSpaced(height: CGFloat, floor: Double = -130, ceiling: Double = -20,
                              file: StaticString = #filePath, line: UInt = #line) {
        let p = NeonSpectrumView.labelPositions(height: height, floor: floor, ceiling: ceiling, step: 10)
        XCTAssertFalse(p.isEmpty, file: file, line: line)
        for (a, b) in zip(p, p.dropFirst()) {
            XCTAssertGreaterThanOrEqual(abs(b.y - a.y), 14, "\(a.db) vs \(b.db) at \(height)",
                                        file: file, line: line)
        }
    }

    func testPositionsSpacedAtMinWindowHeight() {
        assertSpaced(height: 114)
        let p = NeonSpectrumView.labelPositions(height: 114, floor: -130, ceiling: -20, step: 10)
        XCTAssertEqual(p.first?.db, -20, "ceiling label is kept")
    }

    func testPositionsSpacedAcrossHeights() {
        for h in [20, 40, 80, 114, 150, 250, 400, 800] { assertSpaced(height: CGFloat(h)) }
    }

    func testTallViewPositionsLabelEveryLine() {
        let p = NeonSpectrumView.labelPositions(height: 400, floor: -130, ceiling: -20, step: 10)
        XCTAssertEqual(p.count, 12)
        assertSpaced(height: 400)
    }

    func testPositionsDegenerate() {
        XCTAssertTrue(NeonSpectrumView.labelPositions(height: 0, floor: -130, ceiling: -20, step: 10).isEmpty)
        XCTAssertTrue(NeonSpectrumView.labelPositions(height: 100, floor: -20, ceiling: -130, step: 10).isEmpty)
    }
}
