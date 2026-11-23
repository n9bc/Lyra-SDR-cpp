import XCTest
@testable import Observatory

final class FrequencyAxisTests: XCTestCase {
    let axis = FrequencyAxis(lowHz: 7_060_000, highHz: 7_200_000, width: 940)

    func testEndsAndCentre() {
        XCTAssertEqual(axis.x(for: 7_060_000), 0, accuracy: 0.001)
        XCTAssertEqual(axis.x(for: 7_200_000), 940, accuracy: 0.001)
        XCTAssertEqual(axis.x(for: 7_130_000), 470, accuracy: 0.001)
    }

    func testRoundTrip() {
        XCTAssertEqual(axis.hz(at: axis.x(for: 7_128_500)), 7_128_500)
    }

    func testTicks() {
        XCTAssertEqual(axis.ticks(every: 20_000).map(\.hz).first, 7_060_000)
        XCTAssertEqual(axis.ticks(every: 20_000).count, 8)
    }
}
