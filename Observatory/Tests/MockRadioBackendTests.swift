import XCTest
import Observation
@testable import Observatory

/// `onChange` is `@Sendable`, so the test records the notification in a locked box.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

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

    func testFocusSubRefusedWhileSubOff() {
        XCTAssertEqual(MockRadioBackend.applying(.focus(.sub), to: .sample).session.focused, .main)
    }
    func testSubOnThenFocusSub() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.focus(.sub), to: s)
        XCTAssertTrue(s.sub.enabled); XCTAssertEqual(s.session.focused, .sub); XCTAssertEqual(s.focusedReceiver.id, .sub)
    }
    func testSubOffReturnsFocusToMain() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.focus(.sub), to: s)
        s = MockRadioBackend.applying(.setSubEnabled(false), to: s)
        XCTAssertFalse(s.sub.enabled); XCTAssertEqual(s.session.focused, .main)
    }
    func testTuneMovesOnlyThatReceiver() {
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: 1_000), to: .sample)
        XCTAssertEqual(s.main.frequencyHz, 7_129_500); XCTAssertEqual(s.sub.frequencyHz, 14_195_000)
        XCTAssertEqual(s.display.spanLowHz, 7_060_000); XCTAssertEqual(s.display.spanHighHz, 7_200_000)
    }
    func testTuneDisabledReceiverIgnored() {
        XCTAssertEqual(MockRadioBackend.applying(.tune(.sub, deltaHz: 1_000), to: .sample), .sample)
    }
    func testTuneOutsideSpanRecentres() {
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: 100_000), to: .sample)
        XCTAssertEqual(s.main.frequencyHz, 7_228_500)
        XCTAssertEqual(s.display.spanLowHz, 7_158_500); XCTAssertEqual(s.display.spanHighHz, 7_298_500)
    }
    func testTuneNeverNegative() {
        var start = RadioSnapshot.sample; start.main.frequencyHz = 500
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: -1_000), to: start)
        XCTAssertEqual(s.main.frequencyHz, 0); XCTAssertEqual(s.display.spanLowHz, 0); XCTAssertEqual(s.display.spanHighHz, 140_000)
    }
    func testSubTuneMovesSubSpan() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.tune(.sub, deltaHz: 200_000), to: s)
        XCTAssertEqual(s.sub.frequencyHz, 14_395_000)
        XCTAssertEqual(s.display.subSpanLowHz, 14_325_000); XCTAssertEqual(s.display.spanLowHz, 7_060_000)
    }
    func testSubViewHasSubSpanAndNoFortyMetreOverlays() {
        let v = RadioSnapshot.sample.display.view(for: .sub)
        XCTAssertEqual(v.spanLowHz, 14_125_000); XCTAssertEqual(v.spanHighHz, 14_265_000)
        XCTAssertTrue(v.bandPlan.isEmpty); XCTAssertTrue(v.spots.isEmpty)
        XCTAssertEqual(RadioSnapshot.sample.display.view(for: .main), RadioSnapshot.sample.display)
    }
    func testSendNotifiesObservers() {
        let backend = MockRadioBackend()
        let fired = Flag()
        withObservationTracking { _ = backend.snapshot } onChange: { fired.set() }
        backend.send(.setSubEnabled(true))
        XCTAssertTrue(fired.isSet); XCTAssertTrue(backend.snapshot.sub.enabled)
    }
}
