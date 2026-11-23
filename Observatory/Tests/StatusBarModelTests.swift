import XCTest
@testable import Observatory

@MainActor final class StatusBarModelTests: XCTestCase {
    func testSampleBadgeFirstAndVoltsNotReported() {
        let m = StatusBarModel(snapshot: .sample, capabilities: .allMocked)
        XCTAssertEqual(m.badges.first, "Sample data")
        XCTAssertTrue(m.badges.contains { $0.contains("V not reported") })
        XCTAssertEqual(m.leftMessage, "Tuned to 7.128 500 LSB")
    }
}
