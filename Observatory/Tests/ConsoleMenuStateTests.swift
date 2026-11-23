import XCTest
import AppKit
@testable import Observatory

@MainActor final class ConsoleMenuStateTests: XCTestCase {
    func state(_ s: RadioSnapshot = .sample, expanded: Bool = true) -> ConsoleMenuState {
        ConsoleMenuState(snapshot: s, layout: .spectrumOnly, terrainExpanded: expanded, terrainView: .both)
    }
    func testFocusSubDisabledWhileSubOff() {
        XCTAssertFalse(state().isEnabled(.focus(.sub))); XCTAssertTrue(state().isEnabled(.focus(.main)))
        var s = RadioSnapshot.sample; s.sub.enabled = true
        XCTAssertTrue(state(s).isEnabled(.focus(.sub)))
    }
    func testChecks() {
        let m = state()
        XCTAssertTrue(m.isChecked(.focus(.main))); XCTAssertFalse(m.isChecked(.toggleSub))
        XCTAssertTrue(m.isChecked(.layout(.spectrumOnly))); XCTAssertFalse(m.isChecked(.layout(.waterfallOnly)))
        XCTAssertTrue(m.isChecked(.terrainView(.both)))
    }
    func testTerrainTitleFlips() {
        XCTAssertEqual(state(expanded: true).title(.toggleTerrain), "Hide Audio Terrain")
        XCTAssertEqual(state(expanded: false).title(.toggleTerrain), "Show Audio Terrain")
    }
    func testShortcutsAreUniqueAndAvoidSystemOnes() {
        let all: [ConsoleMenuAction] = [.focus(.main), .focus(.sub), .toggleSub, .toggleTerrain]
            + DisplayLayout.allCases.map { .layout($0) } + TerrainView.allCases.map { .terrainView($0) }
        let keys = all.compactMap { $0.keyEquivalent }.map { "\($0.modifiers.rawValue)-\($0.key)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        let cmd = NSEvent.ModifierFlags.command.rawValue
        for reserved in [",", "q", "m", "h", "w"] { XCTAssertFalse(keys.contains("\(cmd)-\(reserved)")) }
        XCTAssertEqual(ConsoleMenuAction.focus(.sub).keyEquivalent?.key, "2")
        XCTAssertEqual(ConsoleMenuAction.layout(.waterfallOnly).keyEquivalent?.modifiers, [.command, .option])
    }
    func testPerformSendsEngineStateAndSetsDisplayState() {
        let backend = MockRadioBackend()
        let suiteName = "lyra-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let display = DisplayStore(defaults: defaults)
        let shell = ConsoleShell(backend: backend, display: display)
        shell.perform(.toggleSub); XCTAssertTrue(backend.snapshot.sub.enabled)
        shell.perform(.focus(.sub)); XCTAssertEqual(backend.snapshot.session.focused, .sub)
        shell.perform(.toggleSub); XCTAssertFalse(backend.snapshot.sub.enabled)
        XCTAssertEqual(backend.snapshot.session.focused, .main)
        shell.perform(.layout(.waterfallOnly)); XCTAssertEqual(display.layout, .waterfallOnly)
        let expanded = display.terrainExpanded
        shell.perform(.toggleTerrain); XCTAssertEqual(display.terrainExpanded, !expanded)
        shell.perform(.terrainView(.waterfall)); XCTAssertEqual(display.terrainView, .waterfall)
    }
}
