import SwiftUI
import XCTest
@testable import Observatory

final class LyraThemeTests: XCTestCase {
    func testHexColorParsing() {
        let rgb = Color(hex: "#00e5ff").rgbComponents()
        XCTAssertEqual(rgb.r, 0.0, accuracy: 0.01)
        XCTAssertEqual(rgb.g, 229.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(rgb.b, 1.0, accuracy: 0.01)
    }

    func testHexWithoutHashAndInvalidFallback() {
        let amber = Color(hex: "ff9f43").rgbComponents()
        XCTAssertEqual(amber.r, 1.0, accuracy: 0.01)
        let bad = Color(hex: "nonsense").rgbComponents()
        XCTAssertEqual(bad.r, 0.0, accuracy: 0.01)
        XCTAssertEqual(bad.g, 0.0, accuracy: 0.01)
        XCTAssertEqual(bad.b, 0.0, accuracy: 0.01)
    }

    func testThemeColorsExist() {
        let all: [Color] = [
            LyraTheme.background, LyraTheme.surface, LyraTheme.border,
            LyraTheme.cyan, LyraTheme.amber, LyraTheme.violet,
            LyraTheme.textPrimary, LyraTheme.textMuted, LyraTheme.textDim,
        ]
        XCTAssertEqual(all.count, 9)
        let bg = LyraTheme.background.rgbComponents()
        XCTAssertEqual(bg.r, 12.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.g, 14.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.b, 20.0 / 255.0, accuracy: 0.01)
    }
}

private extension Color {
    func rgbComponents() -> (r: Double, g: Double, b: Double) {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}
