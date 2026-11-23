import Foundation

/// Turns a console `RadioCommand` into the ordered engine calls that carry it out. Pure: it reads
/// the engine state it is given and decides nothing else. The A/B copy, swap, split and band rules
/// are ported from `TuningPanel.qml` (`assignTx`, `abBlocked`, `bFromHz`, `copyAtoB`, `copyBtoA`,
/// `swapAB`) and `BandPanel.qml` (`goBand`). An empty list means refused or nothing to do.
enum LiveCommandPlanner {
    nonisolated static func calls(for command: RadioCommand, state e: EngineState,
                                  vfoLocked: Bool) -> [EngineCall] {
        let r = e.radio
        switch command {
        case .connect: return [.connect]
        case .disconnect: return [.disconnect]
        case .setVFOLock: return []   // console-only; the backend keeps the flag

        case .focus(let id):
            switch id {
            case .main: return [.setFocusedRx(1)]
            case .sub: return r.subEnabled ? [.setFocusedRx(2)] : []
            }
        case .setSubEnabled(let on): return [.setSubEnabled(on)]

        case .tune(let id, let delta):
            if vfoLocked { return [] }
            switch id {
            case .main: return [.setRx1Hz(moved(r.rx1Hz, by: delta))]
            case .sub:
                if r.splitEnabled { return [.setVfoBHz(moved(r.vfoBHz, by: delta))] }
                if r.subEnabled { return [.setRx2Hz(moved(r.rx2Hz, by: delta))] }
                return []
            }

        case .setSplit(let on):
            if on {
                var plan: [EngineCall] = []
                if r.vfoBHz == 0 {
                    let carrier = Int64(r.rx1Hz) + Int64(r.markerOffsetHz) + Int64(r.splitShiftHz)
                    plan.append(.setVfoBHz(clamp(carrier)))
                }
                return plan + [.setSplitEnabled(true)]
            }
            // QML assignTx(false) always refocuses RX1; only needed when focus would be stranded
            // on a receiver that no longer exists.
            return [.setSplitEnabled(false)]
                + (r.focusedRx == 2 && !r.subEnabled ? [.setFocusedRx(1)] : [])

        case .copyAToB: return vfoLocked ? [] : copyAToB(e)
        case .copyBToA: return vfoLocked ? [] : copyBToA(e)
        case .swapAB: return vfoLocked ? [] : swapAB(e)

        case .setRIT(let on): return [.setRitEnabled(on)]
        case .setXIT(let on): return [.setXitEnabled(on)]
        case .setCTUN(let on): return [.setCtuneEnabled(on)]

        case .setMode(let id, let mode):
            return [id == .main ? .setMode(mode.rawValue) : .setModeRx2(mode.rawValue)]
        case .setFilter(let id, let hz):
            return [id == .main ? .setRxBandwidth(hz) : .setRx2Bandwidth(hz)]
        case .setBandwidthLock(let on): return [.setBwLocked(on)]

        case .selectBand(let label): return vfoLocked ? [] : selectBand(label, e)

        case .setAGC(let mode): return [.setAgcMode(mode.rawValue.lowercased())]
        case .setDSP(let function, let on):
            if function == .snb { return [] }                      // no engine path
            if function == .nnr && !e.dsp.nnrAvailable { return [] }
            return [.setDsp(function, on)]
        }
    }

    // MARK: - A/B rules

    /// VFO B's dial frequency (QML `bFromHz`): RX2 under Sub without split, else VFO B. The jump
    /// guards compare dial frequencies; the CW marker offset is display-only.
    private nonisolated static func bDial(_ r: EngineState.Radio) -> UInt32 {
        r.subEnabled && !r.splitEnabled ? r.rx2Hz : r.vfoBHz
    }

    /// B only counts as live (and so can be blocked) in split or with Sub on.
    private nonisolated static func bIsLive(_ r: EngineState.Radio) -> Bool {
        r.splitEnabled || r.subEnabled
    }

    private nonisolated static func copyAToB(_ e: EngineState) -> [EngineCall] {
        let r = e.radio
        var plan: [EngineCall] = []
        if bIsLive(r) { plan.append(.requireJumpAllowed(fromHz: bDial(r), toHz: r.rx1Hz)) }
        if r.splitEnabled { plan.append(.setRptActive(false)) }
        plan.append(r.subEnabled && !r.splitEnabled ? .setRx2Hz(r.rx1Hz) : .setVfoBHz(r.rx1Hz))
        if r.subEnabled {
            plan += [.setModeRx2(e.filter.mode), .setRx2Bandwidth(e.filter.rxBandwidth)]
        }
        return plan
    }

    private nonisolated static func copyBToA(_ e: EngineState) -> [EngineCall] {
        let r = e.radio
        let b = bDial(r)
        var plan: [EngineCall] = [.requireJumpAllowed(fromHz: r.rx1Hz, toHz: b)]
        if r.splitEnabled { plan.append(.setRptActive(false)) }
        plan.append(.setRx1Hz(b))
        if r.subEnabled {
            plan += [.setMode(e.filter.modeRx2), .setRxBandwidth(e.filter.rx2Bandwidth)]
        }
        return plan
    }

    private nonisolated static func swapAB(_ e: EngineState) -> [EngineCall] {
        let r = e.radio
        let a = r.rx1Hz, b = bDial(r)
        var plan: [EngineCall] = [.requireJumpAllowed(fromHz: a, toHz: b)]
        if bIsLive(r) { plan.append(.requireJumpAllowed(fromHz: bDial(r), toHz: a)) }
        if r.splitEnabled { plan.append(.setRptActive(false)) }
        plan.append(r.subEnabled && !r.splitEnabled ? .setRx2Hz(a) : .setVfoBHz(a))
        plan.append(.setRx1Hz(b))
        if r.subEnabled {
            plan += [.setMode(e.filter.modeRx2), .setModeRx2(e.filter.mode),
                     .setRxBandwidth(e.filter.rx2Bandwidth), .setRx2Bandwidth(e.filter.rxBandwidth)]
        }
        return plan
    }

    // MARK: - Band memory

    private nonisolated static func selectBand(_ label: String, _ e: EngineState) -> [EngineCall] {
        // A band change retunes filters and PA band, never under power: un-key and stop.
        if e.transmit.txDisplayActive { return [.stopTxForBlockedJump] }
        guard let band = e.bands.first(where: { LiveSnapshotMapper.bandLabel($0.name) == label })
        else { return [] }
        let r = e.radio
        if r.focusedRx == 2 && r.subEnabled {
            return [.recallBand(name: band.name, defaultHz: band.defaultHz, rx2: true)]
        }
        // Focus on VFO B under split without Sub has no recall path in the engine call set
        // (QML recalls into VFO B); refuse rather than retune RX1 by mistake.
        if r.focusedRx == 2 && r.splitEnabled { return [] }
        return [.recallBand(name: band.name, defaultHz: band.defaultHz, rx2: false)]
    }

    // MARK: - Arithmetic

    private nonisolated static func moved(_ hz: UInt32, by delta: Int64) -> UInt32 {
        clamp(Int64(hz) &+ delta)
    }

    private nonisolated static func clamp(_ v: Int64) -> UInt32 {
        UInt32(max(0, min(v, Int64(UInt32.max))))
    }
}
