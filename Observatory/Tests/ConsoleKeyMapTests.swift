import XCTest
import AppKit
@testable import Observatory

@MainActor final class ConsoleKeyMapTests: XCTestCase {
    let s = RadioSnapshot.sample
    func testKeyCodes() {
        XCTAssertEqual(ConsoleKey(keyCode: 123), .left); XCTAssertEqual(ConsoleKey(keyCode: 126), .up); XCTAssertNil(ConsoleKey(keyCode: 49))
    }
    func testSteps() {
        XCTAssertEqual(ConsoleKeyMap.command(for: .left, modifiers: [], snapshot: s, textInputActive: false), .tune(.main, deltaHz: -1_000))
        XCTAssertEqual(ConsoleKeyMap.command(for: .right, modifiers: [], snapshot: s, textInputActive: false), .tune(.main, deltaHz: 1_000))
        XCTAssertEqual(ConsoleKeyMap.command(for: .down, modifiers: [], snapshot: s, textInputActive: false), .tune(.main, deltaHz: -10))
        XCTAssertEqual(ConsoleKeyMap.command(for: .up, modifiers: [], snapshot: s, textInputActive: false), .tune(.main, deltaHz: 10))
    }
    func testArrowFlagsStillTune() {
        XCTAssertEqual(ConsoleKeyMap.command(for: .up, modifiers: [.function, .numericPad], snapshot: s, textInputActive: false), .tune(.main, deltaHz: 10))
    }
    func testTunesFocusedSub() {
        var t = s; t.sub.enabled = true; t.session.focused = .sub
        XCTAssertEqual(ConsoleKeyMap.command(for: .right, modifiers: [], snapshot: t, textInputActive: false), .tune(.sub, deltaHz: 1_000))
    }
    func testPassesThrough() {
        XCTAssertNil(ConsoleKeyMap.command(for: .left, modifiers: [], snapshot: s, textInputActive: true))
        for m: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertNil(ConsoleKeyMap.command(for: .left, modifiers: m, snapshot: s, textInputActive: false))
        }
        var locked = s; locked.session.vfoLocked = true
        XCTAssertNil(ConsoleKeyMap.command(for: .left, modifiers: [], snapshot: locked, textInputActive: false))
    }
}
