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

    func testAGCHeaderWithoutAReportedGain() {
        XCTAssertEqual(ConsoleFormat.agcGainDetail(nil), "Gain \u{2014}")
    }

    /// R2: the console has no Sub-column DSP control, so every shared level says in its help
    /// text that it acts on both receivers (map H13).
    func testSharedLevelsHelpNamesBothReceivers() {
        for base in ["Noise blanker level", "AGC threshold", "LMS strength"] {
            let help = ConsoleFormat.sharedHelp(base)
            XCTAssertTrue(help.hasPrefix(base))
            XCTAssertTrue(help.contains("both receivers"), help)
        }
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

    // MARK: - Controls with no engine path (final review, Important 4, T1-7, T2-1)

    /// Every control the live console has no engine path for, with the reason it shows.
    private let noEnginePath: [ConsoleControl: String] = [
        .frontEnd: "Arrives in Milestone 5",
        .noiseCapture: "Arrives in a later milestone",
        .rxEqualizer: "The receive equaliser arrives in Milestone 5",
        .tools: "Arrives in a later milestone",
        .txDSP: "Transmit arrives in Milestone 5",
        .transmit: "Transmit arrives in Milestone 5",
        .profile: "Arrives in a later milestone",
        .vfoBandwidth: "Use the filter chips to change the bandwidth",
    ]

    func testLiveCapabilitiesDisableControlsWithoutAnEnginePath() {
        for isP2 in [false, true] {
            let caps = BackendCapabilities.live(nnrAvailable: true, isP2: isP2)
            for (control, reason) in noEnginePath {
                let status = caps.control(control)
                XCTAssertEqual(status, .unavailable(reason), "\(control)")
                XCTAssertTrue(ConsoleAvailability.isDisabled(status), "\(control)")
                // The one tooltip a disabled control shows is its reason, never its normal help.
                XCTAssertEqual(ConsoleAvailability.help(status, normal: "Normal help"), reason,
                               "\(control)")
            }
        }
    }

    /// Milestone 5a Task 1 wired the audio controls to the engine.
    func testLiveAudioControlsAreAvailable() {
        for isP2 in [false, true] {
            XCTAssertEqual(BackendCapabilities.live(nnrAvailable: true, isP2: isP2).control(.audio), .available)
        }
    }

    /// Milestone 5a Task 2 wired the DSP and AGC levels to the engine.
    func testLiveLevelControlsAreAvailable() {
        for isP2 in [false, true] {
            let caps = BackendCapabilities.live(nnrAvailable: true, isP2: isP2)
            XCTAssertEqual(caps.control(.agcLevels), .available)
            XCTAssertEqual(caps.control(.dspLevels), .available)
        }
    }

    /// Sample mode keeps these controls usable; the Sample badge marks the data instead.
    func testSampleModeKeepsThoseControlsEnabled() {
        for control in noEnginePath.keys {
            let status = BackendCapabilities.allMocked.control(control)
            XCTAssertFalse(ConsoleAvailability.isDisabled(status), "\(control)")
            XCTAssertEqual(ConsoleAvailability.help(status, normal: "Normal help"), "Normal help")
        }
    }

    /// The live engine serves the spectrum display: its settings, the tuning step, spectrum
    /// tuning and spots are enabled with their normal help.
    func testLiveSpectrumControlsAreAvailable() {
        let caps = BackendCapabilities.live(nnrAvailable: false, isP2: false)
        XCTAssertFalse(ConsoleAvailability.isDisabled(caps.status(.spots)))
        XCTAssertEqual(ConsoleAvailability.help(caps.status(.spots), normal: "Show spots"),
                       "Show spots")
        for control in [ConsoleControl.displaySettings, .tuningStep, .spectrumTuning, .notches] {
            XCTAssertEqual(caps.control(control), .available, "\(control)")
        }
    }

    func testMOXKeyIsDisabledWithTheMilestoneFiveReasonOnLive() {
        let live = BackendCapabilities.live(nnrAvailable: false, isP2: false).control(.transmit)
        XCTAssertTrue(ConsoleAvailability.isDisabled(live))
        XCTAssertEqual(MOXButton.help(live), "Transmit arrives in Milestone 5")
        XCTAssertFalse(MOXButton.help(live).contains("Transmit (Space)"))
        XCTAssertEqual(MOXButton.help(.mocked), MOXButton.normalHelp)
        XCTAssertTrue(MOXButton.normalHelp.hasPrefix("Transmit (Space)"))
    }

    func testSettingsGearNeedsAnAction() {
        XCTAssertEqual(TopBarView.settingsStatus(hasAction: true), .available)
        let none = TopBarView.settingsStatus(hasAction: false)
        XCTAssertTrue(ConsoleAvailability.isDisabled(none))
        XCTAssertEqual(ConsoleAvailability.help(none, normal: "Settings"),
                       "Settings need the radio engine")
    }
}
