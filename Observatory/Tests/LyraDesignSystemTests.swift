import AppKit
import SwiftUI
import XCTest
@testable import Observatory

final class LyraDesignSystemTests: XCTestCase {
    private func components(_ color: Color) -> (red: Double, green: Double, blue: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    func testSpectrumStopsAreOrderedAndBounded() {
        let s = LyraDS.Palette.spectrumStops
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.first?.position, 0.0)
        XCTAssertEqual(s.last?.position, 1.0)
        XCTAssertEqual(s.map(\.position), s.map(\.position).sorted())
    }

    func testSampleHitsStopsAndClamps() {
        let s = LyraDS.Palette.spectrumStops
        XCTAssertEqual(LyraDS.Palette.sample(s, at: 0.3), s[1].rgba)
        XCTAssertEqual(LyraDS.Palette.sample(s, at: -2), s[0].rgba)
        XCTAssertEqual(LyraDS.Palette.sample(s, at: 9), s[4].rgba)
    }

    func testSampleInterpolatesMidpoint() {
        let s = LyraDS.Palette.spectrumStops
        let mid = LyraDS.Palette.sample(s, at: 0.15)
        let expect = (s[0].rgba + s[1].rgba) / 2
        for i in 0..<4 { XCTAssertEqual(mid[i], expect[i], accuracy: 1e-5) }
    }

    func testCyanTokenMatchesHex() {
        let c = components(LyraDS.Palette.cyan)
        XCTAssertEqual(c.red, 0, accuracy: 0.01)
        XCTAssertEqual(c.green, 229.0 / 255, accuracy: 0.01)
        XCTAssertEqual(c.blue, 1, accuracy: 0.01)
    }
}
