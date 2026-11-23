import XCTest
@testable import Observatory

final class ConsoleAvailabilityTests: XCTestCase {
    func testControlFallsBackToFallback() {
        XCTAssertEqual(BackendCapabilities.allMocked.control(.band), .mocked)
    }

    func testControlOverride() {
        let caps = BackendCapabilities(statuses: [:], controls: [.memory: .unavailable("x")], fallback: .available)
        XCTAssertEqual(caps.control(.memory), .unavailable("x"))
        XCTAssertEqual(caps.control(.band), .available)
    }

    func testMockedFeaturesOrder() {
        let caps = BackendCapabilities(statuses: [.spectrum: .mocked, .connection: .available],
                                       fallback: .available)
        XCTAssertEqual(caps.mockedFeatures, [.spectrum])
    }

    func testFeatureNamesAreLowercaseAndDistinct() {
        let names = BackendFeature.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(BackendFeature.audioTerrain.displayName, "audio terrain")
        for n in names { XCTAssertEqual(n, n.lowercased()) }
    }

    func testDSPFunctionRawValues() {
        XCTAssertEqual(DSPFunction.allCases.map(\.rawValue),
                       ["NB", "BIN", "NR", "NNR", "ANF", "LMS", "SQ", "APF", "NF", "SNB"])
    }

    func testSampleBadge() {
        let all = StatusBarModel.sampleBadge(.allMocked)
        XCTAssertEqual(all?.text, "Sample data")
        XCTAssertEqual(all?.help, "Every reading is sample data")

        let some = BackendCapabilities(
            statuses: [.connection: .available, .spectrum: .mocked, .propagation: .mocked],
            fallback: .available)
        let partial = StatusBarModel.sampleBadge(some)
        XCTAssertEqual(partial?.text, "Partly sample")
        XCTAssertEqual(partial?.help, "Sample data: spectrum, propagation")

        XCTAssertNil(StatusBarModel.sampleBadge(BackendCapabilities(fallback: .available)))
    }

    func testFormatGuardsNaN() {
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: .nan), "S0")
        XCTAssertEqual(ConsoleFormat.offsetKHz(0), "+0.00 kHz")
        XCTAssertNil(ConsoleFormat.snr(nil))
        XCTAssertNil(ConsoleFormat.snr(.nan))
        XCTAssertEqual(ConsoleFormat.snr(24.2), "SNR 24 dB")
    }

    func testAGCHeaderIsNotFocusPrefixed() {
        XCTAssertEqual(ConsoleFormat.agcGainDetail(88), "Gain 88 dB")
    }

    func testQuickToggleIdsAreStable() {
        let ids = RadioSnapshot.sample.main.quickToggles.map(\.id)
        XCTAssertEqual(ids, ["ATT", "LNA", "AUTO", "NB", "NR", "ANF", "NOTCH", "SQ", "APF", "BIN"])
        XCTAssertEqual(RadioSnapshot.sample.main.quickToggles[1].label, "LNA +20")
        XCTAssertEqual(RadioSnapshot.sample.dsp.toggles.map(\.id),
                       ["NB", "BIN", "NR", "NNR", "ANF", "LMS", "SQ", "APF", "NF", "SNB"])
    }

    func testPropagationHeaderDetail() {
        let sample = BackendCapabilities(statuses: [.connection: .available, .propagation: .mocked],
                                         fallback: .available)
        XCTAssertEqual(BandModeColumnView.propagationDetail(sample), "Sample")
        XCTAssertEqual(BandModeColumnView.propagationDetail(.allMocked), "Follow off")
        XCTAssertEqual(BandModeColumnView.propagationDetail(BackendCapabilities(fallback: .available)),
                       "Follow off")
    }
}
