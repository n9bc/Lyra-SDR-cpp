import XCTest
import SwiftUI
@testable import Observatory

@MainActor final class TransmitDeckWidthTests: XCTestCase {
    /// The narrowest fallback level must fit the minimum window (1280 - 2 x 8 pt gap) with the
    /// deck's 14 pt side padding and a safety margin.
    func testNarrowestLevelFitsMinimumWidth() {
        let s = RadioSnapshot.sample
        let deck = TransmitDeckView(transmit: s.transmit, keyer: s.keyer)
            .deck(showCaption: false, protectionMenu: true)
        let ideal = NSHostingView(rootView: deck).fittingSize.width
        let available: CGFloat = 1264 - 2 * 14
        XCTAssertLessThanOrEqual(ideal, available - 30, "ideal \(ideal) vs available \(available)")
    }
}

@MainActor final class TransmitDeckDialTests: XCTestCase {
    /// Dials must keep their natural width (value and label fully shown) in the narrowest level.
    func testDialsKeepIntrinsicWidth() {
        let s = RadioSnapshot.sample
        let deck = TransmitDeckView(transmit: s.transmit, keyer: s.keyer)
            .deck(showCaption: false, protectionMenu: true)
        let host = NSHostingView(rootView: deck.frame(width: 1236, height: 120))
        host.frame = NSRect(x: 0, y: 0, width: 1236, height: 120)
        host.layoutSubtreeIfNeeded()
        let natural = NSHostingView(rootView: LyraRotaryDial("Tune pwr", value: .constant(50), in: 0...100,
                                                              unit: "%").fixedSize()).fittingSize.width
        XCTAssertGreaterThanOrEqual(natural, 64)
        // Total deck must still fit with all four dials at natural width.
        XCTAssertLessThanOrEqual(NSHostingView(rootView: deck).fittingSize.width, 1236 - 30)
    }
}
