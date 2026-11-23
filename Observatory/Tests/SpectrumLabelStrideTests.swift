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
}
