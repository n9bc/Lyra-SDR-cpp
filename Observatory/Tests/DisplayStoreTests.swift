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
    }
    func testPersistsAcrossInstances() {
        let d = suite()
        let a = DisplayStore(defaults: d)
        a.layout = .waterfallOnly; a.terrainExpanded = false
        let b = DisplayStore(defaults: d)
        XCTAssertEqual(b.layout, .waterfallOnly); XCTAssertFalse(b.terrainExpanded)
    }
    func testCorruptDefaultsFallBack() {
        let d = suite()
        d.set("sideways", forKey: "console.display.layout")
        let s = DisplayStore(defaults: d)
        XCTAssertEqual(s.layout, .spectrumAndWaterfall)
    }
    func testTerrainSmoothingDefaultsPersistsAndFallsBack() {
        let d = suite()
        let a = DisplayStore(defaults: d)
        XCTAssertEqual(a.terrainSmoothing, 0.5)
        a.terrainSmoothing = 0.8
        XCTAssertEqual(DisplayStore(defaults: d).terrainSmoothing, 0.8, accuracy: 1e-9)
        for bad: Any in ["smooth", 1.5, -0.1, Double.nan] {
            d.set(bad, forKey: "console.display.terrainSmoothing")
            XCTAssertEqual(DisplayStore(defaults: d).terrainSmoothing, 0.5, "\(bad)")
        }
    }
    func testRetiredTerrainKeysAreLeftAlone() {
        // The terrain view and mix are gone; values a user already stored are neither read nor deleted.
        let d = suite()
        d.set("Both", forKey: "console.display.terrainView"); d.set(0.25, forKey: "console.display.terrainMix")
        let s = DisplayStore(defaults: d)
        s.layout = .spectrumOnly; s.terrainExpanded = false
        XCTAssertEqual(d.string(forKey: "console.display.terrainView"), "Both")
        XCTAssertEqual(d.double(forKey: "console.display.terrainMix"), 0.25, accuracy: 1e-9)
    }
}
