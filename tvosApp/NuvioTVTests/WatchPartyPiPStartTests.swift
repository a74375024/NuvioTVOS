import XCTest
@testable import NuvioTV

final class WatchPartyPiPStartTests: XCTestCase {
    func testFailedStartNeverTransfersFullscreenOwnershipAndAllowsRetry() {
        var state = PlayerPiPStartState()
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.isStarting)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.fail())
        XCTAssertFalse(state.isInProgress)
        XCTAssertFalse(state.stop())
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.confirm())
        XCTAssertTrue(state.isActive)
    }

    func testRepeatedStartDoesNotRequestAnotherTransition() {
        var state = PlayerPiPStartState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.confirm())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.isActive)
    }

    func testCancelBeforeConfirmationKeepsFullscreenSession() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.begin())
    }

    func testLateFailureCannotRevokeConfirmedWindow() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertTrue(state.confirm())
        XCTAssertFalse(state.fail())
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.stop())
    }

    func testStopAfterFailureDoesNotReportAClosedFloatingWindow() {
        var state = PlayerPiPStartState()
        state.begin()
        XCTAssertTrue(state.fail())
        XCTAssertFalse(state.stop())
        XCTAssertFalse(state.fail())
        XCTAssertFalse(state.confirm())
        XCTAssertFalse(state.isInProgress)
    }
}
