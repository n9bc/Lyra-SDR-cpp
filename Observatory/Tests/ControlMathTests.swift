import XCTest
@testable import Observatory

final class ControlMathTests: XCTestCase {
    func testClampAndFraction() {
        XCTAssertEqual(ControlMath.clamp(150, to: 0...100), 100)
        XCTAssertEqual(ControlMath.fraction(25, in: 0...100), 0.25)
        XCTAssertEqual(ControlMath.fraction(5, in: 5...5), 0)
    }
    func testValueAtFractionSnapsFromLowerBound() {
        XCTAssertEqual(ControlMath.value(atFraction: 0.33, in: -10...10, step: 5), -5)
        XCTAssertEqual(ControlMath.value(atFraction: 1.7, in: 0...1, step: nil), 1)
    }
    func testKeyboardSteps() {
        XCTAssertEqual(ControlMath.keyboardStep(in: 0...200, step: nil, coarse: false), 2)
        XCTAssertEqual(ControlMath.keyboardStep(in: 0...200, step: nil, coarse: true), 20)
        XCTAssertEqual(ControlMath.keyboardStep(in: 0...200, step: 5, coarse: false), 5)
        XCTAssertEqual(ControlMath.keyboardStep(in: 0...200, step: 50, coarse: true), 50)
    }
    func testDragSensitivity() {
        XCTAssertEqual(ControlMath.dragAdjusted(0, deltaPoints: 100, in: 0...100, step: nil, fine: false), 50)
        XCTAssertEqual(ControlMath.dragAdjusted(0, deltaPoints: 100, in: 0...100, step: nil, fine: true), 5)
        XCTAssertEqual(ControlMath.dragAdjusted(90, deltaPoints: 400, in: 0...100, step: nil, fine: false), 100)
    }
    func testDialAngleSweep() {
        XCTAssertEqual(LyraRotaryDial.angle(for: 0, in: 0...10), -135)
        XCTAssertEqual(LyraRotaryDial.angle(for: 5, in: 0...10), 0)
        XCTAssertEqual(LyraRotaryDial.angle(for: 99, in: 0...10), 135)
    }
}

extension ControlMathTests {
    func testSmallScrollDeltasAccumulateOnSteppedRange() {
        var v = -60.0
        var rem = 0.0
        for _ in 0..<10 {
            v = ControlMath.scrollAdjusted(v, remainder: &rem, deltaPoints: 1, in: -60...0, step: 1, fine: false)
        }
        XCTAssertGreaterThanOrEqual(v - (-60), 2)
        XCTAssertEqual(v, -57)
    }
    func testScrollRemainderResetsAtEdges() {
        var rem = 0.5
        let v = ControlMath.scrollAdjusted(100, remainder: &rem, deltaPoints: 50, in: 0...100, step: 1, fine: false)
        XCTAssertEqual(v, 100)
        XCTAssertEqual(rem, 0)
    }
    func testNudged() {
        XCTAssertEqual(ControlMath.nudged(50, in: 0...100, step: nil, up: true, coarse: false), 51)
        XCTAssertEqual(ControlMath.nudged(5, in: 0...100, step: nil, up: false, coarse: true), 0)
    }
}

extension ControlMathTests {
    func testSegmentedIndexClampsWithoutWrap() {
        typealias S = LyraSegmentedControl<String>
        XCTAssertEqual(S.index(from: 0, delta: -1, count: 4), 0)
        XCTAssertEqual(S.index(from: 3, delta: 1, count: 4), 3)
        XCTAssertEqual(S.index(from: 1, delta: 1, count: 4), 2)
        XCTAssertEqual(S.index(from: 0, delta: 1, count: 0), 0)
    }
}
