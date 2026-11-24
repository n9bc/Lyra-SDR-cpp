import Foundation

/// Turns engine state into the console's `RadioSnapshot`. Pure: no engine access, no clock.
/// Nothing the engine has not reported is shown; unreported readings become nil. Readings (meters,
/// telemetry, TX levels) count as reported only while the connection is streaming: the engine
/// keeps its floors and last values before the first frame, after a disconnect and during a
/// stall. What the engine has no source for (propagation, keyer, tools) is copied from the sample
/// and gated elsewhere.
enum LiveSnapshotMapper {
    /// Below this the HL2 temperature is "not reported" (about -50 C right after open).
    private nonisolated static let minPlausibleTempC = -40.0
    /// `MeterModel`'s S-meter floor: at or below it the meter has no reading (WDSP not running).
    private nonisolated static let sMeterFloorDbm = -140.0

    nonisolated static func snapshot(from e: EngineState, phase: ConnectionPhase, vfoLocked: Bool,
                                     now: Date, timeZone: TimeZone,
                                     overlays: EngineOverlays = EngineOverlays()) -> RadioSnapshot {
        let sample = RadioSnapshot.sample
        let r = e.radio
        let subOn = r.subEnabled
        // The radio confirms a reading only while it streams to us.
        let live = phase == .streaming
        func reading(_ v: Double) -> Double? { live ? finite(v) : nil }
        let focused = focusedReceiver(r)
        let mainHz = Int64(r.rx1Hz) + Int64(r.markerOffsetHz)
        let subHz: Int64 = (r.splitEnabled || !subOn)
            ? Int64(r.vfoBHz) : Int64(r.rx2Hz) + Int64(r.markerOffsetHzRx2)
        let agc = agcMode(e.dsp.agcMode)
        let port = e.frontEnd.rxPort == 2 ? "Alt" : "RF1"

        let main = ReceiverSnapshot(
            id: .main, enabled: true, frequencyHz: mainHz, mode: radioMode(e.filter.mode),
            filterHz: e.filter.rxBandwidth, stepHz: e.filter.stepHz,
            bandName: bandName(forHz: UInt32(clamping: mainHz), in: e.bands),
            antenna: port, signalDbm: live ? sMeter(e.meters.sMeterDbm) : nil,
            snrDb: reading(e.meters.snrDb), agc: agc,
            ritEnabled: r.ritEnabled, ritOffsetHz: r.ritEnabled ? r.ritHz : 0,
            xitEnabled: r.xitEnabled, xitOffsetHz: r.xitEnabled ? r.xitHz : 0,
            splitTx: r.splitEnabled, isTxVFO: !r.splitEnabled,
            quickToggles: quickToggles(e, includeAutoAndBin: true))
        let sub = ReceiverSnapshot(
            id: .sub, enabled: subOn, frequencyHz: subHz, mode: radioMode(e.filter.modeRx2),
            filterHz: e.filter.rx2Bandwidth, stepHz: e.filter.stepHzRx2,
            bandName: bandName(forHz: UInt32(clamping: subHz), in: e.bands),
            antenna: port, signalDbm: live ? sMeter(e.meters.sMeterDbmRx2) : nil, snrDb: nil, agc: agc,
            ritEnabled: false, ritOffsetHz: 0, xitEnabled: false, xitOffsetHz: 0,
            splitTx: r.splitEnabled, isTxVFO: r.splitEnabled,
            quickToggles: quickToggles(e, includeAutoAndBin: false))

        let d = e.display
        let rx1 = Int64(r.rx1Hz), ctuneCentre = Int64(r.ctuneCenterHz)
        let mainCentre = SpectrumGeometry.mainCentreHz(
            rx1Hz: rx1, ritEnabled: r.ritEnabled, ritHz: Int64(r.ritHz),
            ctuneEnabled: r.ctuneEnabled, ctuneCentreHz: ctuneCentre)
        let dialOffset = SpectrumGeometry.ctunDialOffsetHz(
            rx1Hz: rx1, ctuneEnabled: r.ctuneEnabled, ctuneCentreHz: ctuneCentre)
        let mainSpan = Int64(d.spanHz)
        let spanLow = mainCentre - mainSpan / 2, spanHigh = mainCentre + mainSpan / 2
        let subCentre = Int64(r.rx2Hz)
        let subSpan = Int64(d.iqRateHz)
        // During TX the span is the TX analyzer's, not iqRate / zoom, so show the RX preference.
        let zoom = !d.txOwnsAnalyzer && d.spanHz > 0 && d.iqRateHz > 0
            ? Double(d.iqRateHz) / Double(d.spanHz) : d.zoom
        let mainCarrier = SpectrumGeometry.mainCarrierHz(
            centre: mainCentre, markerOffsetHz: Int64(r.markerOffsetHz), ctunDialOffsetHz: dialOffset)
        let subCarrier = SpectrumGeometry.subCarrierHz(
            rx2Hz: subCentre, markerOffsetHzRx2: Int64(r.markerOffsetHzRx2))
        // Passband edges are meaningful only with an analyzer running; without one the passband
        // collapses onto the carrier (an empty-equivalent range) and no Sub overlay is drawn.
        let analyzer = d.spanHz > 0
        let mainPassband = analyzer
            ? SpectrumGeometry.passband(
                centre: mainCentre, ctunDialOffsetHz: dialOffset,
                lowOffsetHz: wholeNumber(d.passbandLowHz).map(Int64.init) ?? 0,
                highOffsetHz: wholeNumber(d.passbandHighHz).map(Int64.init) ?? 0)
            : mainCarrier...mainCarrier
        let subPassband = analyzer
            ? SpectrumGeometry.passband(
                centre: subCentre, ctunDialOffsetHz: 0,
                lowOffsetHz: wholeNumber(d.passbandLowHzRx2).map(Int64.init) ?? 0,
                highOffsetHz: wholeNumber(d.passbandHighHzRx2).map(Int64.init) ?? 0)
            : subCarrier...subCarrier
        let subOverlay: SubOverlay? = subOn && !d.rx2SpectrumAvailable && analyzer
            ? SubOverlay(carrierHz: subCarrier, passband: subPassband,
                         offSpan: SpectrumGeometry.offSpanCue(hz: subCarrier, lowHz: spanLow,
                                                              highHz: spanHigh))
            : nil

        let visibleBands = e.bands.filter { e.link.isP2Rig || $0.name != "6m" }
        // A band click recalls into the focused receiver, so its carrier (what its panel title
        // shows) picks the highlighted chip.
        let selected = bandName(forHz: UInt32(clamping: focused == .sub ? subHz : mainHz),
                                in: visibleBands)

        let t = e.transmit
        let txState: TransmitState = (t.moxActive || t.txDisplayActive)
            ? .onAir : (t.txInhibit ? .blocked("TX inhibited") : .idle)

        return RadioSnapshot(
            connection: ConnectionSnapshot(
                phase: phase,
                radioName: [e.link.rigLabel, e.link.firmware].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " "),
                address: (e.link.running || e.link.p2Running) ? e.link.targetIp : e.link.savedIp,
                sampleRateHz: e.meters.sampleRateHz,
                protocolVersion: (e.link.p2Running || e.link.isP2Rig) ? 2 : 1),
            main: main, sub: sub,
            frontEnd: FrontEndSnapshot(
                lnaDb: e.frontEnd.lnaDb, lnaRange: e.link.isP2Rig ? 0...31 : -12...48,
                autoLna: e.frontEnd.autoLna, overload: live ? e.frontEnd.adcOverload : nil,
                inputs: ["RF1", "Alt"], selectedInput: port),
            audio: AudioSnapshot(
                afGainDb: e.audio.afGainDb, volume: e.audio.volume, muted: e.audio.muted,
                volume2: e.audio.volumeRx2, muted2: e.audio.mutedRx2, balance: e.audio.balance,
                outputDevice: e.audio.outputDevice, binaural: e.dsp.binEnabled,
                monitorTx: e.audio.monEnabled, monLevel: e.audio.monVolume,
                outputDevices: e.audio.outputDevices, outputDeviceIndex: e.audio.outputDeviceIndex),
            dsp: DSPSnapshot(
                toggles: DSPFunction.allCases.map { f in
                    QuickToggle(id: f.rawValue, label: dspLabel(f, e), isOn: dspOn(f, e.dsp))
                },
                nrMode: e.dsp.nrMode, anfLevel: sample.dsp.anfLevel,
                nbLevel: reported(e.dsp.nbStrength),
                agcThresholdDbfs: reported(e.dsp.agcThreshDb),
                agcGainDb: wholeNumber(e.dsp.agcMaxGainDb),
                notches: e.dsp.notches, squelchOn: e.dsp.squelchEnabled,
                lmsLevel: reported(e.dsp.lmsStrength), squelchLevel: reported(e.dsp.squelchThreshold),
                apfGainDb: reported(e.dsp.apfGainDb), binDepth: reported(e.dsp.binDepth),
                nnrMaskFloorDb: reported(e.dsp.nnrMaskFloorDb), nnrModel: e.dsp.nnrModel,
                autoAgc: e.dsp.autoAgcThresh, autoAgcMarginDb: reported(e.dsp.autoAgcMarginDb)),
            band: BandSnapshot(
                tabs: sample.band.tabs, selectedTab: sample.band.selectedTab,
                bands: visibleBands.map { bandLabel($0.name) }, selectedBand: selected),
            filter: FilterSnapshot(
                rxLowHz: e.filter.filterLowHz, txLowHz: e.filter.txFilterLowHz,
                bwLocked: e.filter.bwLocked,
                txBandwidthLabel: FilterPresets.label(e.filter.txBandwidthHz)),
            display: DisplaySnapshot(
                spanLowHz: spanLow, spanHighHz: spanHigh,
                subSpanLowHz: subCentre - subSpan / 2, subSpanHighHz: subCentre + subSpan / 2,
                zoom: zoom, wheelStepHz: d.scrollStepHz,
                peakHold: peakHold(d), bandPlanVisible: d.bandPlanSegments, bandPlan: bandPlan(overlays, d), spots: spots(overlays, d),
                mainCarrierHz: mainCarrier, mainPassband: mainPassband,
                subCarrierHz: subCarrier, subPassband: subPassband,
                subOverlay: subOverlay, subSpectrumAvailable: d.rx2SpectrumAvailable,
                dbRange: DbRange(floor: d.dbMin, ceiling: d.dbMax, auto: d.dbAuto),
                waterfallRange: DbRange(floor: d.waterfallDbMin, ceiling: d.waterfallDbMax,
                                        auto: d.waterfallDbAuto),
                waterfallRowsPerSecond: d.waterfallSpeed,
                waterfallColors: d.waterfallLut.isEmpty
                    ? .custom(baseRGB: d.waterfallBaseRGB) : .lut(d.waterfallLut),
                peakDecayDbps: d.peakDecayDbps, smoothing: d.smoothing, exactTuning: d.round100,
                stickyWheel: d.stickyWheel, spotsVisible: d.showSpots, txAxis: d.txOwnsAnalyzer),
            propagation: sample.propagation,
            transmit: TransmitSnapshot(
                state: txState, drivePct: Int((Double(t.driveRaw) * 100 / 255).rounded()),
                tunePct: t.tuneDrivePct, micGainDb: t.micGainDb, monitorLevel: e.audio.monVolume,
                voxEnabled: t.vox, attOnTx: t.attOnTx, swrProtectArmed: t.swrProtect,
                paCapture: false, psEnabled: t.psArmed,
                psFeedback: live && t.psArmed ? t.psFeedback : nil,
                fwdPowerW: reading(t.fwdPowerW), swr: t.swr >= 0 ? reading(t.swr) : nil,
                alcDb: reading(t.alcDb),
                micLevelDb: reading(t.micLevelDb)),
            keyer: sample.keyer,
            telemetry: TelemetrySnapshot(
                temperatureC: reading(e.telemetry.tempC).flatMap { $0 >= minPlausibleTempC ? $0 : nil },
                supplyV: reading(e.telemetry.supplyV), paCurrentA: reading(e.telemetry.paCurrentA),
                cpuPct: nil, tciClients: nil, utc: now, timeZone: timeZone, graphics: nil),
            session: SessionSnapshot(
                profileName: e.session.profileName, profileModified: e.session.profileModified,
                recordingElapsed: nil, lastSpot: nil, txDSPOn: [:], tools: sample.session.tools,
                statusMessage: e.session.statusMessage, ctunEnabled: r.ctuneEnabled,
                vfoLocked: vfoLocked, focused: focused))
    }

    /// The receiver the console treats as focused: Sub only while it is on. Focus 2 without Sub
    /// (VFO B under split) shows, and acts on, Main. The planner uses the same rule.
    nonisolated static func focusedReceiver(_ r: EngineState.Radio) -> ReceiverID {
        r.focusedRx == 2 && r.subEnabled ? .sub : .main
    }

    /// "40m" -> "40", "bc_49m" -> "49m", "" -> "".
    nonisolated static func bandLabel(_ engineName: String) -> String {
        if engineName.hasPrefix("bc_") { return String(engineName.dropFirst(3)) }
        if engineName.hasSuffix("m"), engineName.dropLast().allSatisfy(\.isNumber),
           engineName.count > 1 {
            return String(engineName.dropLast())
        }
        return engineName
    }

    // MARK: - Band plan, landmarks and spots

    /// The kind from the engine's segment label; the engine does not report the kind itself, and
    /// its colour is user-overridable, so it is not a classifier.
    nonisolated static func bandPlanKind(label: String, channel: Bool) -> BandPlanKind {
        if channel { return .channel }
        switch label {
        case "CW": return .cw
        case "DIG": return .digital
        case "CW/DIG": return .cwDigital
        case "SSB": return .phone
        case "FM": return .fm
        default: return .mixed
        }
    }

    private nonisolated static func bandPlan(_ o: EngineOverlays, _ d: EngineState.Display) -> [BandPlanSegment] {
        guard d.bandPlanSegments else { return [] }
        return o.segments.map {
            BandPlanSegment(lowHz: $0.lowHz, highHz: $0.highHz, label: $0.label,
                            kind: bandPlanKind(label: $0.label, channel: $0.channel),
                            channelQsyHz: $0.channel ? $0.qsyHz : nil)
        }
    }

    /// Landmarks first (in the engine's order), then spots; each group follows its own flags.
    private nonisolated static func spots(_ o: EngineOverlays, _ d: EngineState.Display) -> [Spot] {
        let marks = o.landmarks.filter { $0.beacon ? d.bandPlanBeacons : d.bandPlanLandmarks }.map {
            Spot(call: $0.label, frequencyHz: $0.hz, kind: $0.beacon ? .beacon : .watering,
                 label: $0.label, mode: $0.mode.isEmpty ? nil : $0.mode)
        }
        let live = d.showSpots ? o.spots.map {
            Spot(call: $0.call, frequencyHz: $0.hz, kind: $0.mine ? .own : .dx,
                 label: $0.call, mode: $0.mode.isEmpty ? nil : $0.mode)
        } : []
        return marks + live
    }

    // MARK: - Helpers

    /// Prefs' peak-hold encoding: seconds 0 off, -1 infinite hold, -2 live, above 0 hold then decay.
    private nonisolated static func peakHold(_ d: EngineState.Display) -> PeakHoldSetting {
        guard d.peakEnabled else { return .off }
        if d.peakHoldSecs == -1 { return .hold }
        if d.peakHoldSecs == -2 { return .live }
        return d.peakHoldSecs > 0 ? .seconds(d.peakHoldSecs) : .off
    }

    private nonisolated static func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }

    /// The S-meter reading, or nil at the meter's floor (the engine has no reading).
    private nonisolated static func sMeter(_ dbm: Double) -> Double? {
        finite(dbm).flatMap { $0 > sMeterFloorDbm ? $0 : nil }
    }

    /// Rounded to a whole number; nil for NaN or infinity, which `Int(_:)` would trap on.
    /// An engine level as reported: nil for NaN or infinity (the engine has not reported it).
    private nonisolated static func reported(_ v: Double) -> Double? {
        v.isFinite ? v : nil
    }

    private nonisolated static func wholeNumber(_ v: Double) -> Int? {
        guard v.isFinite, abs(v) < 1e9 else { return nil }
        return Int(v.rounded())
    }

    private nonisolated static func radioMode(_ s: String) -> RadioMode {
        RadioMode(rawValue: s.uppercased()) ?? .usb
    }

    private nonisolated static func agcMode(_ s: String) -> AGCMode {
        switch s.lowercased() {
        case "fast": .fast
        case "med": .med
        case "slow": .slow
        default: .off
        }
    }

    private nonisolated static func bandName(forHz hz: UInt32, in bands: [EngineBand]) -> String {
        bands.first { $0.lowHz <= hz && hz <= $0.highHz }.map { bandLabel($0.name) } ?? ""
    }

    private nonisolated static func dspOn(_ f: DSPFunction, _ d: EngineState.DSP) -> Bool {
        switch f {
        case .nb: d.nbEnabled
        case .bin: d.binEnabled
        case .nr: d.nrEnabled
        case .nnr: d.nnrEnabled
        case .anf: d.anfEnabled
        case .lms: d.lmsEnabled
        case .sq: d.squelchEnabled
        case .apf: d.apfEnabled
        case .nf: d.notchEnabled
        case .snb: false
        }
    }

    /// The DSP rack's labels: the notch carries its count; everything else is its name.
    private nonisolated static func dspLabel(_ f: DSPFunction, _ e: EngineState) -> String {
        f == .nf && e.dsp.notchCount > 0 ? "NF \(e.dsp.notchCount)" : f.rawValue
    }

    private nonisolated static func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }

    /// The receiver's quick toggles, in the sample's order. DSP is shared, so both receivers
    /// read the same state; Sub's list has no AUTO or BIN, as in the sample.
    private nonisolated static func quickToggles(_ e: EngineState, includeAutoAndBin: Bool) -> [QuickToggle] {
        let d = e.dsp
        var list = [
            QuickToggle(id: "ATT", label: "ATT", isOn: false),
            QuickToggle(id: "LNA", label: "LNA \(signed(e.frontEnd.lnaDb))", isOn: e.frontEnd.lnaDb != 0),
        ]
        if includeAutoAndBin { list.append(QuickToggle(id: "AUTO", label: "AUTO", isOn: e.frontEnd.autoLna)) }
        list += [
            QuickToggle(id: "NB", label: "NB", isOn: d.nbEnabled),
            QuickToggle(id: "NR", label: d.nrEnabled ? "NR \(d.nrMode)" : "NR", isOn: d.nrEnabled),
            QuickToggle(id: "ANF", label: "ANF", isOn: d.anfEnabled),
            QuickToggle(id: "NOTCH", label: d.notchCount > 0 ? "NOTCH \(d.notchCount)" : "NOTCH",
                        isOn: d.notchEnabled),
            QuickToggle(id: "SQ", label: "SQ", isOn: d.squelchEnabled),
            QuickToggle(id: "APF", label: "APF", isOn: d.apfEnabled),
        ]
        if includeAutoAndBin { list.append(QuickToggle(id: "BIN", label: "BIN", isOn: d.binEnabled)) }
        return list
    }
}
