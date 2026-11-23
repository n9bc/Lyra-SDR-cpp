import Observation
import XCTest
@testable import Observatory

/// Stands in for the engine. `perform` mimics the executor contract: a batch stops at a
/// `requireJumpAllowed` while `blockJumps` is set, and nothing after the guard is applied.
@MainActor
final class FakeEngineFacade: EngineFacade {
    var state = EngineState.idle
    var blockJumps = false
    private(set) var performed: [[EngineCall]] = []
    private(set) var applied: [EngineCall] = []
    private(set) var onChange: (@MainActor (EngineChange) -> Void)?
    /// Runs inside `perform`, before it returns, as the engine's synchronous signals do.
    var onPerform: ((FakeEngineFacade, [EngineCall]) -> Void)?

    func readState() -> EngineState { state }
    func observe(_ onChange: @escaping @MainActor (EngineChange) -> Void) { self.onChange = onChange }
    func quitApplication() {}

    func perform(_ calls: [EngineCall]) {
        performed.append(calls)
        onPerform?(self, calls)
        for call in calls {
            if case .requireJumpAllowed = call, blockJumps { return }
            applied.append(call)
        }
    }

    func fire(_ change: EngineChange) { onChange?(change) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@MainActor
final class LiveRadioBackendTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var facade = FakeEngineFacade()

    override func setUp() {
        clock = t0
        facade = FakeEngineFacade()
    }

    private func make() -> LiveRadioBackend {
        LiveRadioBackend(facade: facade, now: { [unowned self] in clock }, startTimer: false)
    }

    private func advance(_ s: TimeInterval) { clock = clock.addingTimeInterval(s) }

    func testInitialSnapshotFromState() {
        facade.state.radio.rx1Hz = 7_074_000
        facade.state.link.rigLabel = "Hermes-Lite 2"
        let backend = make()
        XCTAssertEqual(backend.snapshot.main.frequencyHz, 7_074_000)
        XCTAssertEqual(backend.snapshot.connection.radioName, "Hermes-Lite 2")
        XCTAssertEqual(backend.snapshot.connection.phase, .disconnected)
    }

    func testSendPerformsPlannedCalls() {
        facade.state.radio.rx1Hz = 7_000_000
        let backend = make()
        backend.send(.tune(.main, deltaHz: 1000))
        XCTAssertEqual(facade.performed, [[.setRx1Hz(7_001_000)]])
    }

    func testRefusedCommandPerformsNothing() {
        let backend = make()
        backend.send(.focus(.sub))   // Sub is off
        XCTAssertTrue(facade.performed.isEmpty)
    }

    func testVfoLockIsLocal() {
        facade.state.radio.rx1Hz = 7_000_000
        let backend = make()
        backend.send(.setVFOLock(true))
        XCTAssertTrue(backend.snapshot.session.vfoLocked)
        XCTAssertTrue(facade.performed.isEmpty)
        backend.send(.tune(.main, deltaHz: 1000))
        XCTAssertTrue(facade.performed.isEmpty)
        backend.send(.setVFOLock(false))
        XCTAssertFalse(backend.snapshot.session.vfoLocked)
    }

    func testEngineChangeUpdatesSnapshot() {
        let backend = make()
        facade.state.radio.rx1Hz = 14_200_000
        facade.fire(.radio)
        XCTAssertEqual(backend.snapshot.main.frequencyHz, 14_200_000)
    }

    func testUnchangedStateDoesNotReassign() {
        let backend = make()
        let fired = Flag()
        withObservationTracking { _ = backend.snapshot } onChange: { fired.set() }
        facade.fire(.radio)
        XCTAssertFalse(fired.value)
        facade.state.radio.rx1Hz = 1
        facade.fire(.radio)
        XCTAssertTrue(fired.value)
    }

    func testIdenticalStateWithinOneSecondDoesNotReassign() {
        clock = Date(timeIntervalSince1970: 1_000_000.1)
        let backend = make()
        let fired = Flag()
        withObservationTracking { _ = backend.snapshot } onChange: { fired.set() }
        advance(0.5)
        facade.fire(.radio)
        backend.tick()
        XCTAssertFalse(fired.value)
    }

    func testTickAcrossSecondReassignsOnlyTheClock() {
        clock = Date(timeIntervalSince1970: 1_000_000.1)
        let backend = make()
        let before = backend.snapshot
        let fired = Flag()
        withObservationTracking { _ = backend.snapshot } onChange: { fired.set() }
        advance(0.5)
        backend.tick()
        XCTAssertFalse(fired.value)
        advance(0.5)
        backend.tick()
        XCTAssertTrue(fired.value)
        var expected = before
        expected.telemetry.utc = Date(timeIntervalSince1970: 1_000_001)
        XCTAssertEqual(backend.snapshot, expected)
    }

    func testConnectWithoutSavedAddressStillPerformsAndTimesOutWithoutSuffix() {
        facade.state.link.savedIp = "  "
        let backend = make()
        backend.send(.connect)
        XCTAssertEqual(facade.performed, [[.connect]])
        advance(8)
        backend.tick()
        XCTAssertEqual(backend.snapshot.connection.phase, .error("No radio answered"))
    }

    func testMeterUpdatesAreCoalesced() {
        let backend = make()
        facade.state.meters.sMeterDbm = -90
        facade.fire(.meters)
        XCTAssertEqual(backend.snapshot.main.signalDbm, -90)

        advance(0.03)
        facade.state.meters.sMeterDbm = -80
        facade.fire(.meters)
        XCTAssertEqual(backend.snapshot.main.signalDbm, -90)

        advance(0.07)
        backend.tick()
        XCTAssertEqual(backend.snapshot.main.signalDbm, -80)

        // A non-meter change applies at once, whatever the meters did.
        advance(0.01)
        facade.state.radio.rx1Hz = 3_700_000
        facade.fire(.radio)
        XCTAssertEqual(backend.snapshot.main.frequencyHz, 3_700_000)
    }

    func testConnectDrivesTracker() {
        facade.state.link.savedIp = "169.254.19.221"
        let backend = make()
        backend.send(.connect)
        XCTAssertEqual(facade.performed, [[.connect]])
        XCTAssertEqual(backend.snapshot.connection.phase, .connecting)

        advance(0.5)
        facade.state.link.running = true
        facade.state.link.datagramsPerSec = 380
        facade.fire(.stats)
        XCTAssertEqual(backend.snapshot.connection.phase, .streaming)
    }

    func testConnectTimesOutOnTick() {
        facade.state.link.savedIp = "169.254.19.221"
        let backend = make()
        backend.send(.connect)
        advance(8)
        backend.tick()
        XCTAssertEqual(backend.snapshot.connection.phase,
                       .error("No radio answered at 169.254.19.221"))
    }

    /// Retrying after a timeout: the facade closes the dead socket inside `perform`, and that
    /// drop must land on the old attempt, not on the new connect request.
    func testRetryAfterTimeoutStaysConnectingThroughTheSynchronousClose() {
        facade.state.link.savedIp = "169.254.19.221"
        let backend = make()
        backend.send(.connect)
        facade.state.link.running = true   // socket open, no datagrams
        facade.fire(.stats)
        advance(8)
        backend.tick()
        XCTAssertEqual(backend.snapshot.connection.phase,
                       .error("No radio answered at 169.254.19.221"))

        facade.onPerform = { fake, calls in
            guard calls.contains(.connect) else { return }
            fake.state.link.running = false
            fake.fire(.stats)
        }
        backend.send(.connect)
        XCTAssertEqual(backend.snapshot.connection.phase, .connecting)
        advance(3)
        backend.tick()
        XCTAssertEqual(backend.snapshot.connection.phase, .connecting)

        // The new request keeps its own timeout.
        advance(5)
        backend.tick()
        XCTAssertEqual(backend.snapshot.connection.phase,
                       .error("No radio answered at 169.254.19.221"))
    }

    func testRetryAfterTimeoutStreamsWhenDataArrives() {
        facade.state.link.savedIp = "169.254.19.221"
        let backend = make()
        backend.send(.connect)
        facade.state.link.running = true
        facade.fire(.stats)
        advance(8)
        backend.tick()

        facade.onPerform = { fake, calls in
            guard calls.contains(.connect) else { return }
            fake.state.link.running = false
            fake.fire(.stats)
        }
        backend.send(.connect)
        advance(2)
        facade.state.link.running = true
        facade.fire(.stats)
        XCTAssertEqual(backend.snapshot.connection.phase, .socketOpen)
        advance(0.5)
        facade.state.link.datagramsPerSec = 380
        facade.fire(.stats)
        XCTAssertEqual(backend.snapshot.connection.phase, .streaming)
    }

    func testDisconnectRequestsTrackerFirst() {
        facade.state.link.savedIp = "10.0.0.2"
        facade.state.link.running = true
        facade.state.link.datagramsPerSec = 380
        let backend = make()
        XCTAssertEqual(backend.snapshot.connection.phase, .streaming)
        backend.send(.disconnect)
        XCTAssertEqual(facade.performed, [[.disconnect]])
        facade.state.link.running = false
        facade.fire(.stats)
        XCTAssertEqual(backend.snapshot.connection.phase, .disconnected)
    }

    func testConnectOnLaunch() {
        facade.state.link.autoConnectOnLaunch = true
        facade.state.link.savedIp = "10.0.0.2"
        make().connectOnLaunchIfEnabled()
        XCTAssertEqual(facade.performed, [[.connect]])

        facade = FakeEngineFacade()
        facade.state.link.autoConnectOnLaunch = false
        facade.state.link.savedIp = "10.0.0.2"
        make().connectOnLaunchIfEnabled()
        XCTAssertTrue(facade.performed.isEmpty)

        facade = FakeEngineFacade()
        facade.state.link.autoConnectOnLaunch = true
        make().connectOnLaunchIfEnabled()
        XCTAssertTrue(facade.performed.isEmpty)
    }

    func testBlockedBatchStopsAtGuard() {
        facade.state.radio.splitEnabled = true
        facade.state.radio.rx1Hz = 14_200_000
        facade.state.radio.vfoBHz = 7_100_000
        facade.blockJumps = true
        let backend = make()
        backend.send(.copyAToB)
        // The backend hands the whole batch, guard first, over in one perform; it never
        // splits it or evaluates the guard itself.
        XCTAssertEqual(facade.performed.count, 1)
        XCTAssertEqual(facade.performed[0], [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 14_200_000),
            .setRptActive(false), .setVfoBHz(14_200_000),
        ])
        // The executor contract: nothing after the guard ran.
        XCTAssertTrue(facade.applied.isEmpty)
    }

    func testCapabilitiesChangeOnlyWhenInputsChange() {
        let backend = make()
        XCTAssertEqual(backend.capabilities.control(.dsp(.nnr)),
                       .unavailable("NNR model files are not installed"))
        let fired = Flag()
        withObservationTracking { _ = backend.capabilities } onChange: { fired.set() }
        facade.fire(.dsp)
        XCTAssertFalse(fired.value)
        facade.state.dsp.nnrAvailable = true
        facade.fire(.dsp)
        XCTAssertTrue(fired.value)
        XCTAssertEqual(backend.capabilities.control(.dsp(.nnr)), .available)
    }

    func testLiveCapabilities() {
        let hl2 = BackendCapabilities.live(nnrAvailable: false, isP2: false)
        XCTAssertEqual(hl2.status(.spectrum), .mocked)
        XCTAssertEqual(hl2.status(.spots), .unavailable("Spots arrive in Milestone 4"))
        XCTAssertEqual(hl2.status(.recorder), .unavailable("Recorder arrives in a later milestone"))
        XCTAssertEqual(hl2.status(.meters), .available)
        XCTAssertEqual(hl2.control(.band), .available)
        XCTAssertEqual(hl2.control(.dsp(.nr)), .available)
        XCTAssertEqual(hl2.control(.dsp(.snb)), .unavailable("The engine has no SNB"))
        XCTAssertEqual(hl2.control(.dsp(.nnr)), .unavailable("NNR model files are not installed"))
        XCTAssertEqual(hl2.control(.attenuator),
                       .unavailable("Hermes-Lite 2 has no attenuator; use LNA"))
        XCTAssertEqual(hl2.control(.zeroBeat),
                       .unavailable("Zero beat needs the live spectrum (Milestone 4)"))
        XCTAssertEqual(hl2.control(.transmit), .unavailable("Transmit arrives in Milestone 5"))
        XCTAssertEqual(hl2.control(.bandTabs), .unavailable("Only Ham bands in this version"))

        let p2 = BackendCapabilities.live(nnrAvailable: true, isP2: true)
        XCTAssertEqual(p2.control(.dsp(.nnr)), .available)
        XCTAssertEqual(p2.control(.attenuator), .unavailable("Arrives in Milestone 5"))
    }
}
