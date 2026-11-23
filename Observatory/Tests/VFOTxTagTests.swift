import XCTest
@testable import Observatory

/// Spec §5.2: TX tags light only in `.onAir`; otherwise the TX VFO is marked outline-only.
final class VFOTxTagTests: XCTestCase {
    private let allStates: [TransmitState] = [.idle, .requested, .onAir, .releasing, .blocked("TX inhibit")]

    func testReceiveOnlyVFOIsPlainInEveryState() {
        for state in allStates {
            XCTAssertEqual(VFOChipStyle.txTag(isTxVFO: false, state: state), .plain, "\(state)")
        }
    }

    func testTxVFOIsFilledOnlyOnAir() {
        for state in allStates {
            let expected: VFOChipStyle = state == .onAir ? .tx : .txDesignated
            XCTAssertEqual(VFOChipStyle.txTag(isTxVFO: true, state: state), expected, "\(state)")
        }
    }

    func testOnlyOnAirYieldsTheFilledStyle() {
        for state in allStates {
            for isTx in [false, true] {
                let filled = VFOChipStyle.txTag(isTxVFO: isTx, state: state) == .tx
                XCTAssertEqual(filled, isTx && state == .onAir, "\(state) isTx=\(isTx)")
            }
        }
    }
}
