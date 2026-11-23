import XCTest
import SwiftUI
@testable import Observatory

@MainActor
final class ConsoleLayoutTests: XCTestCase {
    func testMinimumWindowFitsEveryFixedRegion() {
        XCTAssertTrue(ConsoleLayout.fits(ConsoleLayout.minWindow))
    }

    func testTooSmallDoesNotFit() {
        XCTAssertFalse(ConsoleLayout.fits(CGSize(width: 1100, height: 800)))
        XCTAssertFalse(ConsoleLayout.fits(CGSize(width: 1280, height: 640)))
    }

    func testFitsThresholdsMatchFixedRegionSums() {
        // width = 2*300 + 640 + 4*8 = 1272; height = 46+212+122+26+330 + 4*8 = 768
        XCTAssertTrue(ConsoleLayout.fits(CGSize(width: 1272, height: 768)))
        XCTAssertFalse(ConsoleLayout.fits(CGSize(width: 1271, height: 768)))
        XCTAssertFalse(ConsoleLayout.fits(CGSize(width: 1272, height: 767)))
    }

    func testNewTokensAreDistinct() {
        XCTAssertNotEqual(LyraDS.Palette.freqGlow, LyraDS.Palette.freqSub)
    }
}
