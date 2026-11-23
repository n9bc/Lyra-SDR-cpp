import XCTest
@testable import Observatory

final class MOXPresentationTests: XCTestCase {
    private let allStates: [TransmitState] = [.idle, .requested, .onAir, .releasing, .blocked("TX inhibit")]

    func testIdle() {
        let p = MOXPresentation(state: .idle)
        XCTAssertFalse(p.isLit)
        XCTAssertEqual(p.label, "MOX")
        XCTAssertNil(p.caption)
        XCTAssertFalse(p.metersLive)
        XCTAssertEqual(p.headerDetail, "Idle")
    }

    func testRequestedIsNotLitUntilRadioConfirms() {
        let p = MOXPresentation(state: .requested)
        XCTAssertFalse(p.isLit)
        XCTAssertEqual(p.caption, "KEYING\u{2026}")
        XCTAssertFalse(p.metersLive)
        XCTAssertEqual(p.headerDetail, "Keying\u{2026}")
    }

    func testOnAir() {
        let p = MOXPresentation(state: .onAir)
        XCTAssertTrue(p.isLit)
        XCTAssertNil(p.caption)
        XCTAssertTrue(p.metersLive)
        XCTAssertEqual(p.headerDetail, "On air")
    }

    func testReleasing() {
        let p = MOXPresentation(state: .releasing)
        XCTAssertFalse(p.isLit)
        XCTAssertEqual(p.caption, "RELEASING\u{2026}")
        XCTAssertFalse(p.metersLive)
        XCTAssertEqual(p.headerDetail, "Releasing\u{2026}")
    }

    func testBlockedShowsReason() {
        let p = MOXPresentation(state: .blocked("TX inhibit"))
        XCTAssertFalse(p.isLit)
        XCTAssertEqual(p.caption, "TX inhibit")
        XCTAssertFalse(p.metersLive)
        XCTAssertEqual(p.headerDetail, "Blocked")
    }

    func testOnlyOnAirIsLitOrLive() {
        for state in allStates {
            let p = MOXPresentation(state: state)
            XCTAssertEqual(p.isLit, state == .onAir, "\(state)")
            XCTAssertEqual(p.metersLive, state == .onAir, "\(state)")
            XCTAssertEqual(p.label, "MOX")
        }
    }
}
