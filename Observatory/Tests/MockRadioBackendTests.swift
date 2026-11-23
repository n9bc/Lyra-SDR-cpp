import XCTest
@testable import Observatory

@MainActor final class MockRadioBackendTests: XCTestCase {
    func testSampleMatchesMockup() {
        let s = MockRadioBackend().snapshot
        XCTAssertEqual(s.main.frequencyHz, 7_128_500)
        XCTAssertEqual(s.main.mode, .lsb)
        XCTAssertFalse(s.sub.enabled)
        XCTAssertEqual(s.transmit.state, .idle)
        XCTAssertNil(s.telemetry.supplyV)
        XCTAssertEqual(s.display.spots.count, 7)
        XCTAssertEqual(s.band.selectedBand, "40")
    }

    func testMockIsMarkedSampleData() {
        let caps = MockRadioBackend().capabilities
        XCTAssertTrue(caps.isSampleData)
        for f in BackendFeature.allCases { XCTAssertEqual(caps.status(f), .mocked) }
    }

    func testBandPlanCoversSpanContiguously() {
        let d = RadioSnapshot.sample.display
        XCTAssertEqual(d.bandPlan.first?.lowHz, d.spanLowHz)
        XCTAssertEqual(d.bandPlan.last?.highHz, d.spanHighHz)
        for (a, b) in zip(d.bandPlan, d.bandPlan.dropFirst()) { XCTAssertEqual(a.highHz, b.lowHz) }
    }
}
