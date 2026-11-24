import XCTest
@testable import Observatory

/// Final review finding 5: a throttled slider changed without a mouse drag (VoiceOver increment,
/// Full Keyboard Access) gets no editing-ended callback, yet its final value must reach the engine
/// and its local override must clear.
final class ThrottledSliderStateTests: XCTestCase {
    func testStepsWithoutEditingCallbacksFlushAndClear() throws {
        var s = ThrottledSliderState()
        let first = s.set(10, now: 0)
        XCTAssertEqual(first.send, 10)
        let second = s.set(11, now: 0.01)
        XCTAssertNil(second.send, "held: within 33 ms")
        XCTAssertEqual(s.shown(engine: 10), 11, "follows the step until the flush")
        let g = try XCTUnwrap(second.trailing)
        // An older scheduled flush does nothing once a newer step has scheduled its own.
        XCTAssertNil(s.trailingFlush(generation: try XCTUnwrap(first.trailing), now: 0.05))
        XCTAssertEqual(s.trailingFlush(generation: g, now: 0.05), 11, "the final value goes out")
        XCTAssertEqual(s.shown(engine: 7), 7, "the engine's value again, whatever it says")
        XCTAssertNil(s.set(12, now: 0.06).send, "the flush counts as a write: 33 ms from it")
    }

    func testAStepThatWasSentStillClearsTheOverride() throws {
        var s = ThrottledSliderState()
        let r = s.set(3, now: 0)
        XCTAssertEqual(r.send, 3)
        XCTAssertNil(s.trailingFlush(generation: try XCTUnwrap(r.trailing), now: 0.05), "nothing held")
        XCTAssertEqual(s.shown(engine: 5), 5)
    }

    /// A mouse drag is unchanged: the thumb follows the pointer until release, the release sends
    /// what was held and clears the override, and no trailing flush is scheduled while tracking.
    func testMouseDragBehaviourIsUnchanged() {
        var s = ThrottledSliderState()
        XCTAssertNil(s.editingChanged(true, now: 0), "begin sends nothing")
        let a = s.set(1, now: 0)
        XCTAssertEqual(a.send, 1)
        XCTAssertNil(a.trailing)
        let b = s.set(2, now: 0.01)
        XCTAssertNil(b.send)
        XCTAssertNil(b.trailing)
        XCTAssertEqual(s.shown(engine: 0), 2)
        XCTAssertEqual(s.editingChanged(false, now: 0.02), 2)
        XCTAssertEqual(s.shown(engine: 0), 0)
    }

    /// A trailing flush scheduled before a drag began does not clear the drag's override.
    func testTrailingFlushIgnoredWhileTracking() throws {
        var s = ThrottledSliderState()
        let r = s.set(1, now: 0)
        XCTAssertNil(s.editingChanged(true, now: 0.001))
        _ = s.set(2, now: 0.002)
        XCTAssertNil(s.trailingFlush(generation: try XCTUnwrap(r.trailing), now: 0.05))
        XCTAssertEqual(s.shown(engine: 0), 2)
    }
}
