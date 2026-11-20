import XCTest
@testable import Observatory

final class GlowRingKnobTests: XCTestCase {
    func testKnobValueClampsToRange() {
        XCTAssertEqual(GlowRingKnob.clamp(150, to: 0...100), 100)
        XCTAssertEqual(GlowRingKnob.clamp(-5, to: 0...100), 0)
        XCTAssertEqual(GlowRingKnob.clamp(42, to: 0...100), 42)
    }

    func testKnobFraction() {
        XCTAssertEqual(GlowRingKnob.fraction(50, in: 0...100), 0.5, accuracy: 0.0001)
        XCTAssertEqual(GlowRingKnob.fraction(500, in: 0...100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(GlowRingKnob.fraction(5, in: 5...5), 0.0, accuracy: 0.0001)
    }

    func testFrequencyDisplayFormatting() {
        XCTAssertEqual(FrequencyDisplay.format(14_074_000), "14.074.000")
        XCTAssertEqual(FrequencyDisplay.format(7_100_000), "7.100.000")
        XCTAssertEqual(FrequencyDisplay.format(999), "999")
        XCTAssertEqual(FrequencyDisplay.format(1_000), "1.000")
        XCTAssertEqual(FrequencyDisplay.format(0), "0")
        XCTAssertEqual(FrequencyDisplay.format(UInt32.max), "4.294.967.295")
    }
}
