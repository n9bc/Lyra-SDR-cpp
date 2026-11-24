#if LYRA_BRIDGE
// Compiled only in the CMake build, where the bridging header exposes LyraEngineFacade.
// The Console category (src/bridge/LyraEngineFacadeConsole.mm) reads the engine live and
// carries out each call; this file only translates between it and the Swift types.
import Foundation

extension LyraEngineFacade: EngineFacade {
    func readState(includingDisplay: Bool) -> EngineState {
        var e = EngineState()

        let r = consoleRadio()
        e.radio = EngineState.Radio(
            rx1Hz: r.rx1Hz, markerOffsetHz: r.markerOffsetHz, rx2Hz: r.rx2Hz,
            markerOffsetHzRx2: r.markerOffsetHzRx2, vfoBHz: r.vfoBHz,
            subEnabled: r.subEnabled, splitEnabled: r.splitEnabled, focusedRx: r.focusedRx,
            ritEnabled: r.ritEnabled, ritHz: r.ritHz, xitEnabled: r.xitEnabled, xitHz: r.xitHz,
            ctuneEnabled: r.ctuneEnabled, ctuneCenterHz: r.ctuneCenterHz,
            splitShiftHz: r.splitShiftHz)

        let f = consoleFilter()
        e.filter = EngineState.Filter(
            mode: f.mode, modeRx2: f.modeRx2, rxBandwidth: f.rxBandwidth,
            rx2Bandwidth: f.rx2Bandwidth, stepHz: f.stepHz, stepHzRx2: f.stepHzRx2,
            filterLowHz: f.filterLowHz, txFilterLowHz: f.txFilterLowHz,
            txBandwidthHz: f.txBandwidthHz, bwLocked: f.bwLocked)

        let d = consoleDsp()
        // Passed through as reported: agcMaxGainDb is NaN whenever the engine is not running,
        // and the mapper turns NaN into "not reported" itself.
        e.dsp = EngineState.DSP(
            agcMode: d.agcMode, agcThreshDb: d.agcThreshDb, agcMaxGainDb: d.agcMaxGainDb,
            nbEnabled: d.nbEnabled, nbStrength: d.nbStrength,
            binEnabled: d.binEnabled,
            nrEnabled: d.nrEnabled, nrMode: d.nrMode, nnrEnabled: d.nnrEnabled,
            nnrAvailable: d.nnrAvailable, anfEnabled: d.anfEnabled, lmsEnabled: d.lmsEnabled,
            squelchEnabled: d.squelchEnabled, apfEnabled: d.apfEnabled,
            notchEnabled: d.notchEnabled, notchCount: d.notchCount,
            lmsStrength: d.lmsStrength, squelchThreshold: d.squelchThreshold, apfGainDb: d.apfGainDb,
            binDepth: d.binDepth, nnrMaskFloorDb: d.nnrMaskFloorDb, autoAgcMarginDb: d.autoAgcMarginDb,
            nnrModel: d.nnrModel, autoAgcThresh: d.autoAgcThresh)

        let fe = consoleFrontEnd()
        e.frontEnd = EngineState.FrontEnd(
            lnaDb: fe.lnaDb, autoLna: fe.autoLna, adcOverload: fe.adcOverload, rxPort: fe.rxPort)

        let a = consoleAudio()
        e.audio = EngineState.Audio(
            afGainDb: a.afGainDb, volume: a.volume, muted: a.muted, volumeRx2: a.volumeRx2,
            mutedRx2: a.mutedRx2, balance: a.balance, monEnabled: a.monEnabled,
            monVolume: a.monVolume, outputDevice: a.outputDevice, outputDevices: a.outputDevices,
            outputDeviceIndex: a.outputDeviceIndex)

        let m = consoleMeters()
        e.meters = EngineState.Meters(
            sMeterDbm: m.sMeterDbm, sMeterDbmRx2: m.sMeterDbmRx2, snrDb: m.snrDb,
            sampleRateHz: m.sampleRateHz)
        if includingDisplay { e.display = Self.display(from: consoleDisplay()) }

        e.bands = amateurBands().compactMap(Self.band(from:))

        let t = consoleTelemetry()
        e.telemetry = EngineState.Telemetry(tempC: t.tempC, supplyV: t.supplyV,
                                            paCurrentA: t.paCurrentA)

        let x = consoleTransmit()
        e.transmit = EngineState.Transmit(
            moxActive: x.moxActive, txDisplayActive: x.txDisplayActive, txInhibit: x.txInhibit,
            driveRaw: x.driveRaw, tuneDrivePct: x.tuneDrivePct, micGainDb: x.micGainDb,
            vox: x.vox, attOnTx: x.attOnTx, swrProtect: x.swrProtect, psArmed: x.psArmed,
            psFeedback: x.psFeedback, fwdPowerW: x.fwdPowerW, swr: x.swr, alcDb: x.alcDb,
            micLevelDb: x.micLevelDb)

        let s = consoleSession()
        e.session = EngineState.Session(profileName: s.profileName,
                                        profileModified: s.profileModified,
                                        statusMessage: s.statusMessage)

        let l = consoleLink()
        e.link = EngineState.Link(
            running: l.running, p2Running: l.p2Running, isP2Rig: l.isP2Rig,
            datagramsPerSec: l.datagramsPerSec, targetIp: l.targetIp, savedIp: l.savedIp,
            rigLabel: l.rigLabel, firmware: l.firmware,
            autoConnectOnLaunch: l.autoConnectOnLaunch)
        return e
    }

    func observe(_ onChange: @escaping @MainActor (EngineChange) -> Void) {
        // The facade invokes this block on the main thread (Qt signals).
        setConsoleChangeCallback { change in
            MainActor.assumeIsolated { onChange(EngineChange(rawValue: change.rawValue)) }
        }
    }

    /// Runs the batch in order and stops at the first jump guard that reports blocked.
    func perform(_ calls: [EngineCall]) {
        for call in calls {
            switch call {
            case .connect: connectRadio()
            case .disconnect: disconnectRadio()
            case .requireJumpAllowed(let from, let to):
                if !requireJumpAllowed(fromHz: from, toHz: to) { return }
            case .stopTxForBlockedJump: stopTxForBlockedJump()
            case .setRx1Hz(let hz): setRx1FreqHz(hz)
            case .setRx2Hz(let hz): setRx2FreqHz(hz)
            case .setVfoBHz(let hz): setVfoBHz(hz)
            case .setSubEnabled(let on): setSubEnabled(on)
            case .setFocusedRx(let rx): setFocusedRx(rx)
            case .setSplitEnabled(let on): setSplitEnabled(on)
            case .setRptActive(let on): setRptActive(on)
            case .setRitEnabled(let on): setRitEnabled(on)
            case .setXitEnabled(let on): setXitEnabled(on)
            case .setCtuneEnabled(let on): setCtuneEnabled(on)
            case .setMode(let mode): setReceiverMode(mode)
            case .setModeRx2(let mode): setReceiverModeRx2(mode)
            case .setRxBandwidth(let hz): setRxBandwidth(hz)
            case .setRx2Bandwidth(let hz): setRx2Bandwidth(hz)
            case .setBwLocked(let on): setBwLocked(on)
            case .recallBand(let name, let defaultHz, let rx2):
                recallBand(name, defaultHz: defaultHz, rx2: rx2)
            case .setAgcMode(let mode): setAgcMode(mode)
            case .setDsp(let function, let on): setDspFunction(function.rawValue, enabled: on)
            case .setCtuneCenterHz(let hz): setCtuneCenter(hz)
            case .setZoomPref(let zoom): setZoomPreference(zoom)
            case .setScrollStepPref(let hz): setScrollStepPreference(hz)
            case .setRound100Pref(let on): setRound100Preference(on)
            case .setPeakPref(let enabled, let secs): setPeakPreference(enabled: enabled, secs: secs)
            case .setSmoothingPref(let value): setSmoothingPreference(value)
            case .setBandPlanSegmentsPref(let on): setBandPlanSegmentsPreference(on)
            case .setShowSpotsPref(let on): setShowSpotsPreference(on)
            case .setStepPref(let id, let hz): setStepPreference(id, hz: hz)
            case .activateSpot(let call): activateSpot(call)
            case .setAfGainDb(let db): setAfGainDb(db)
            case .setVolume(let v): setVolume(v)
            case .setVolumeRx2(let v): setVolumeRx2(v)
            case .setMuted(let on): setMuted(on)
            case .setMutedRx2(let on): setMutedRx2(on)
            case .setBalance(let v): setBalance(v)
            case .setMonEnabled(let on): setMonEnabled(on)
            case .setMonVolume(let v): setMonVolume(v)
            case .setAudioOutputDevice(let index): setAudioOutputDevice(index)
            case .setNbStrength(let v): setNbStrength(v)
            case .setLmsStrength(let v): setLmsStrength(v)
            case .setSquelchThreshold(let v): setSquelchThreshold(v)
            case .setApfGainDb(let v): setApfGainDb(v)
            case .setBinDepth(let v): setBinDepth(v)
            case .setNnrMaskFloorDb(let v): setNnrMaskFloorDb(v)
            case .setNrMode(let v): setNrMode(v)
            case .setNnrModel(let v): setNnrModel(v)
            case .setAgcThreshDb(let v): setAgcThreshDb(v)
            case .setAutoAgcThresh(let on): setAutoAgcThresh(on)
            case .setAutoAgcMarginDb(let v): setAutoAgcMarginDb(v)
            }
        }
    }

    func setCtuneCenter(_ hz: UInt32) { setCtuneCenterHz(hz) }
    /// `Prefs::setZoom`; the engine follows it through the binding `attachHostWindow` makes.
    func setZoomPreference(_ zoom: Double) { writeZoomPref(zoom) }
    func setScrollStepPreference(_ hz: Int) { writeScrollStepPref(hz) }
    func setRound100Preference(_ on: Bool) { writeRound100Pref(on) }
    func setPeakPreference(enabled: Bool, secs: Double) {
        writePeakPrefEnabled(enabled, holdSecs: secs)
    }
    func setSmoothingPreference(_ value: Int) { writeSmoothingPref(value) }
    func setBandPlanSegmentsPreference(_ on: Bool) { writeBandPlanSegmentsPref(on) }
    func setShowSpotsPreference(_ on: Bool) { writeShowSpotsPref(on) }
    /// `Prefs::setVfoStepHz(mode, hz)` / `setVfoStepHzRx2(modeRx2, hz)`, the keys `consoleFilter`
    /// reads.
    func setStepPreference(_ receiver: ReceiverID, hz: Int) {
        writeStepPref(hz, rx2: receiver == .sub)
    }
    func activateSpot(_ call: String) { activateSpotCall(call) }

    /// `BandPlan::segments` / `landmarks` and `SpotStore::spotsInSpan` for the window.
    func readOverlays(centreHz: Int64, spanHz: Int64) -> EngineOverlays {
        let o = consoleOverlays(centreHz: Double(centreHz), spanHz: Double(spanHz))
        return EngineOverlays(
            segments: o.segments.map {
                EngineSegment(lowHz: Self.hz($0.lowHz), highHz: Self.hz($0.highHz), label: $0.label,
                              channel: $0.channel,
                              qsyHz: $0.qsyHz.isFinite ? Self.hz($0.qsyHz) : nil)
            },
            landmarks: o.landmarks.map {
                EngineLandmark(hz: Self.hz($0.hz), label: $0.label, mode: $0.mode, beacon: $0.beacon)
            },
            spots: o.spots.map {
                EngineSpot(call: $0.call, hz: Self.hz($0.hz), mine: $0.mine, mode: $0.mode)
            })
    }

    private nonisolated static func display(from d: LyraDisplayReading) -> EngineState.Display {
        EngineState.Display(
            spanHz: d.spanHz, iqRateHz: d.iqRateHz, zoom: d.zoom, txOwnsAnalyzer: d.txOwnsAnalyzer,
            passbandLowHz: d.passbandLowHz, passbandHighHz: d.passbandHighHz,
            passbandLowHzRx2: d.passbandLowHzRx2, passbandHighHzRx2: d.passbandHighHzRx2,
            rx2SpectrumAvailable: d.rx2SpectrumAvailable,
            dbMin: d.dbMin, dbMax: d.dbMax, dbAuto: d.dbAuto,
            waterfallDbMin: d.waterfallDbMin, waterfallDbMax: d.waterfallDbMax,
            waterfallDbAuto: d.waterfallDbAuto, waterfallSpeed: d.waterfallSpeed,
            waterfallPalette: d.waterfallPalette, waterfallLut: [UInt8](d.waterfallLut),
            waterfallBaseRGB: d.waterfallBaseRGB,
            peakEnabled: d.peakEnabled, peakHoldSecs: d.peakHoldSecs,
            peakDecayDbps: d.peakDecayDbps, smoothing: d.smoothing,
            scrollStepHz: d.scrollStepHz, round100: d.round100, stickyWheel: d.stickyWheel,
            bandPlanSegments: d.bandPlanSegments, bandPlanLandmarks: d.bandPlanLandmarks,
            bandPlanBeacons: d.bandPlanBeacons, showSpots: d.showSpots)
    }

    /// A frequency in whole Hz; 0 for NaN or infinity, which `Int64(_:)` would trap on.
    private nonisolated static func hz(_ v: Double) -> Int64 {
        v.isFinite ? Int64(v.rounded()) : 0
    }

    /// One `-amateurBands` entry, or nil if a key is missing.
    private nonisolated static func band(from d: [String: Any]) -> EngineBand? {
        guard let name = d["name"] as? String,
              let low = (d["low"] as? NSNumber)?.uint32Value,
              let high = (d["high"] as? NSNumber)?.uint32Value,
              let def = (d["defaultHz"] as? NSNumber)?.uint32Value else { return nil }
        return EngineBand(name: name, lowHz: low, highHz: high, defaultHz: def)
    }
}
#endif
