import XCTest
@testable import Observatory

@MainActor final class DisplayStoreTests: XCTestCase {
    private var suiteNames: [String] = []
    private func suite() -> UserDefaults {
        let name = "lyra-test-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
    override func tearDown() {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }
    func testDefaults() {
        let s = DisplayStore(defaults: suite())
        XCTAssertEqual(s.layout, .spectrumAndWaterfall); XCTAssertTrue(s.terrainExpanded)
        XCTAssertEqual(s.terrainView, .threeD); XCTAssertEqual(s.terrainMix, 0.6, accuracy: 1e-9)
    }
    func testPersistsAcrossInstances() {
        let d = suite()
        let a = DisplayStore(defaults: d)
        a.layout = .waterfallOnly; a.terrainExpanded = false; a.terrainView = .both; a.terrainMix = 0.25
        let b = DisplayStore(defaults: d)
        XCTAssertEqual(b.layout, .waterfallOnly); XCTAssertFalse(b.terrainExpanded)
        XCTAssertEqual(b.terrainView, .both); XCTAssertEqual(b.terrainMix, 0.25, accuracy: 1e-9)
    }
    func testCorruptDefaultsFallBack() {
        let d = suite()
        d.set("sideways", forKey: "console.display.layout"); d.set("4D", forKey: "console.display.terrainView")
        d.set(7.0, forKey: "console.display.terrainMix")
        let s = DisplayStore(defaults: d)
        XCTAssertEqual(s.layout, .spectrumAndWaterfall); XCTAssertEqual(s.terrainView, .threeD); XCTAssertEqual(s.terrainMix, 1.0)
    }
    func testMixIsClampedOnSet() {
        let s = DisplayStore(defaults: suite())
        s.terrainMix = 3; XCTAssertEqual(s.terrainMix, 1.0)
        s.terrainMix = -1; XCTAssertEqual(s.terrainMix, 0.0)
    }
}
