import XCTest
@testable import Observatory

/// S-meter scale labels sit where the nonlinear meter puts their S-value, not evenly spaced.
final class VFOSMeterScaleTests: XCTestCase {
    private func fraction(_ label: String) -> Double? {
        VFOPanelView.sScale.first { $0.label == label }?.fraction
    }

    func testLabelsInOrder() {
        XCTAssertEqual(VFOPanelView.sScale.map(\.label), ["S", "1", "3", "5", "7", "9", "+20", "+40", "+60"])
    }

    func testEachLabelSitsAtItsMeterFraction() {
        let dbm: [String: Double] = ["S": -127, "1": -121, "3": -109, "5": -97, "7": -85, "9": -73,
                                     "+20": -53, "+40": -33, "+60": -13]
        for (label, value) in dbm {
            XCTAssertEqual(fraction(label)!, ConsoleFormat.meterFraction(dbm: value), accuracy: 1e-9, label)
        }
    }

    func testS9AtSixTenthsAndEndsAtTheEdges() {
        XCTAssertEqual(fraction("S")!, 0, accuracy: 1e-9)
        XCTAssertEqual(fraction("9")!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(fraction("+60")!, 1, accuracy: 1e-9)
    }

    func testNotEvenlySpaced() {
        let f = VFOPanelView.sScale.map(\.fraction)
        for i in 1..<f.count { XCTAssertGreaterThan(f[i], f[i - 1]) }
        // Evenly spaced would put "9" at 5/8; the meter puts S9 at 0.6.
        XCTAssertNotEqual(f[5], 5.0 / 8.0, accuracy: 1e-3)
    }
}
