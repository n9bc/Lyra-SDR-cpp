import XCTest
@testable import Observatory

@MainActor final class VFOCenterColumnTests: XCTestCase {
    func testFocusCommand() {
        var sub = RadioSnapshot.sample.sub
        XCTAssertNil(VFOCenterColumn.focusCommand(.sub, sub: sub))
        XCTAssertEqual(VFOCenterColumn.focusCommand(.main, sub: sub), .focus(.main))
        sub.enabled = true
        XCTAssertEqual(VFOCenterColumn.focusCommand(.sub, sub: sub), .focus(.sub))
    }
}
