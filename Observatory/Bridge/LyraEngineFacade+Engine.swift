#if LYRA_BRIDGE
// Compiled only in the CMake build, where the bridging header exposes LyraEngineFacade.
// The Console category (src/bridge/LyraEngineFacadeConsole.mm) reads the engine live and
// carries out each call; this file only translates between it and the Swift types.
import Foundation

extension LyraEngineFacade: EngineFacade {
    func readState() -> EngineState {
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
            notchEnabled: d.notchEnabled, notchCount: d.notchCount)

        let fe = consoleFrontEnd()
        e.frontEnd = EngineState.FrontEnd(
            lnaDb: fe.lnaDb, autoLna: fe.autoLna, adcOverload: fe.adcOverload, rxPort: fe.rxPort)

        let a = consoleAudio()
        e.audio = EngineState.Audio(
            afGainDb: a.afGainDb, volume: a.volume, muted: a.muted, volumeRx2: a.volumeRx2,
            mutedRx2: a.mutedRx2, balance: a.balance, monEnabled: a.monEnabled,
            monVolume: a.monVolume, outputDevice: a.outputDevice)

        let m = consoleMeters()
        e.meters = EngineState.Meters(
            sMeterDbm: m.sMeterDbm, sMeterDbmRx2: m.sMeterDbmRx2, snrDb: m.snrDb,
            sampleRateHz: m.sampleRateHz)
        // The rest of Display is read live in M4 Task 7; the span and IQ rate move here as is.
        e.display.spanHz = m.spanHz
        e.display.iqRateHz = m.iqRateHz

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
            }
        }
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
