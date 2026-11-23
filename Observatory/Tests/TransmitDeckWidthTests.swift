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
