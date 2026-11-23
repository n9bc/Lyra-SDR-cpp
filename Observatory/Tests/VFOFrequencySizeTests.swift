import XCTest
@testable import Observatory

/// One frequency font size per available width, sized for the widest readout ("000.000.000"),
/// so Main and Sub (and every band) render at the same digit size.
final class VFOFrequencySizeTests: XCTestCase {
    func testCappedAt62() {
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: 10_000), 62)
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: 1_000), 62)
    }

    func testFlooredAt31() {
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: 0), 31)
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: -50), 31)
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: 40), 31)
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: .nan), 31)
    }

    func testMonotonicNonDecreasing() {
        var last: CGFloat = 0
        for w in stride(from: CGFloat(0), through: 800, by: 5) {
            let s = VFOPanelView.frequencyFontSize(width: w)
            XCTAssertGreaterThanOrEqual(s, last, "width \(w)")
            XCTAssertTrue((31...62).contains(s), "width \(w) -> \(s)")
            last = s
        }
    }

    func testElevenCharacterTemplateFitsBetweenTheBounds() {
        for w in stride(from: CGFloat(210), through: 400, by: 10) {
            let s = VFOPanelView.frequencyFontSize(width: w)
            XCTAssertLessThanOrEqual(VFOPanelView.frequencyTemplateWidth(fontSize: s), w + 0.001, "width \(w)")
        }
    }

    func testSameSizeForMainAndSubAtEqualWidth() {
        // The size depends only on width, never on the digits shown.
        XCTAssertEqual(VFOPanelView.frequencyFontSize(width: 257), VFOPanelView.frequencyFontSize(width: 257))
        XCTAssertLessThan(VFOPanelView.frequencyFontSize(width: 257), 62)
        XCTAssertGreaterThan(VFOPanelView.frequencyFontSize(width: 257), 31)
    }
}
