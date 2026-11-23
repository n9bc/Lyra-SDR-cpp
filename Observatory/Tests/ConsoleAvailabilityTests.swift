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

final class ConsoleAvailabilityDecisionTests: XCTestCase {
    func testOnlyUnavailableDisables() {
        XCTAssertTrue(ConsoleAvailability.isDisabled(.unavailable("no")))
        XCTAssertFalse(ConsoleAvailability.isDisabled(.mocked))
        XCTAssertFalse(ConsoleAvailability.isDisabled(.available))
    }

    func testHelpIsReasonWhenUnavailableElseNormal() {
        XCTAssertEqual(ConsoleAvailability.help(.unavailable("Not wired yet"), normal: "Tune carrier"), "Not wired yet")
        XCTAssertEqual(ConsoleAvailability.help(.mocked, normal: "Tune carrier"), "Tune carrier")
        XCTAssertEqual(ConsoleAvailability.help(.available, normal: "Tune carrier"), "Tune carrier")
    }

    func testChipDefaultsToAvailable() {
        XCTAssertEqual(ConsoleChip(title: "A", help: "h").status, .available)
    }

    func testMeterReadingNilAndNotLive() {
        let nilValue = TransmitMeters.reading(fraction: 0.5, readout: nil, live: true)
        XCTAssertEqual(nilValue.fill, 0)
        XCTAssertEqual(nilValue.text, "\u{2014}")
        let idle = TransmitMeters.reading(fraction: 0.5, readout: "5.0 W", live: false)
        XCTAssertEqual(idle.fill, 0)
        XCTAssertEqual(idle.text, "\u{2014}")
        let live = TransmitMeters.reading(fraction: 2, readout: "5.0 W", live: true)
        XCTAssertEqual(live.fill, 1)
        XCTAssertEqual(live.text, "5.0 W")
    }

    @MainActor func testStatusBarOmitsUnmeasuredBadges() {
        var s = RadioSnapshot.sample
        s.telemetry.tciClients = nil
        s.telemetry.cpuPct = nil
        s.telemetry.graphics = nil
        let m = StatusBarModel(snapshot: s, capabilities: BackendCapabilities(fallback: .available))
        XCTAssertEqual(m.items.map(\.kind), [.telemetry])
        let full = StatusBarModel(snapshot: .sample, capabilities: BackendCapabilities(fallback: .available))
        XCTAssertEqual(full.items.count, 4)
    }
}
