import XCTest
@testable import Observatory

final class WindowFrameRulesTests: XCTestCase {
    let minSize = CGSize(width: 1280, height: 828)
    func testInsideIsUnchanged() {
        let f = CGRect(x: 100, y: 100, width: 1600, height: 1000)
        XCTAssertEqual(WindowFrameRules.clamp(f, into: CGRect(x: 0, y: 0, width: 3000, height: 1800), minSize: minSize), f)
    }
    func testFrameFromDisconnectedDisplayComesBack() {
        let f = CGRect(x: 3500, y: 200, width: 1600, height: 1000)
        XCTAssertEqual(WindowFrameRules.clamp(f, into: CGRect(x: 0, y: 0, width: 1512, height: 944), minSize: minSize),
                       CGRect(x: 0, y: 0, width: 1512, height: 944))
    }
    func testPartlyOffscreenIsPulledIn() {
        let f = CGRect(x: 1000, y: 100, width: 1300, height: 850)
        XCTAssertEqual(WindowFrameRules.clamp(f, into: CGRect(x: 0, y: 0, width: 1512, height: 944), minSize: minSize),
                       CGRect(x: 212, y: 94, width: 1300, height: 850))
    }
    func testTooSmallGrowsToMinimum() {
        let f = CGRect(x: 10, y: 10, width: 900, height: 600)
        XCTAssertEqual(WindowFrameRules.clamp(f, into: CGRect(x: 0, y: 0, width: 3000, height: 1800), minSize: minSize),
                       CGRect(x: 10, y: 10, width: 1280, height: 828))
    }
    func testScreenSmallerThanMinimumKeepsTitleBarVisible() {
        let f = CGRect(x: 0, y: 0, width: 1280, height: 828)
        XCTAssertEqual(WindowFrameRules.clamp(f, into: CGRect(x: 0, y: 0, width: 1024, height: 700), minSize: minSize),
                       CGRect(x: 0, y: -128, width: 1280, height: 828))
    }
    func testInitialContentSize() {
        XCTAssertEqual(WindowFrameRules.initialContentSize(visible: CGSize(width: 2000, height: 1400)), CGSize(width: 1600, height: 1100))
        XCTAssertEqual(WindowFrameRules.initialContentSize(visible: CGSize(width: 1470, height: 900)), CGSize(width: 1470, height: 900))
        XCTAssertEqual(WindowFrameRules.initialContentSize(visible: CGSize(width: 1000, height: 700)), CGSize(width: 1280, height: 800))
    }
}
