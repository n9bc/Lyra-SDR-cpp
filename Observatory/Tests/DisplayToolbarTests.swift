import XCTest
@testable import Observatory

final class DisplayToolbarTests: XCTestCase {
    func testWheelLabelMatchesTheMenuOptions() {
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 50), "50 Hz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 500), "500 Hz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 1000), "1 kHz")
        XCTAssertEqual(DisplayToolbarView.wheelLabel(hz: 2500), "2.5 kHz")
        for hz in [50, 100, 500, 1000] {
            XCTAssertTrue(DisplayToolbarView.wheelOptions.contains(DisplayToolbarView.wheelLabel(hz: hz)), "\(hz)")
        }
    }
}
