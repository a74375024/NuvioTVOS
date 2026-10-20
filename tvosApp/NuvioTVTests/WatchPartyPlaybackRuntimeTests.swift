import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyPlaybackRuntimeTests: XCTestCase {
    private final class Resource {}
    private typealias Runtime = WatchPartyPlaybackRuntime<Resource>

    private func context(epoch: UUID = UUID(), membershipID: UUID = UUID(),
                         mediaKey: String = "movie|test||") -> WatchPartyPlaybackContext {
        WatchPartyPlaybackContext(request: WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                                                   userID: "user", profileID: "profile", epoch: epoch),
                                  membershipID: membershipID, roomID: "room", memberID: "member", mediaKey: mediaKey)
    }

    func testPiPRestoreRetainsExactResourceAndOnlyFirstSurfaceStartsLoad() throws {
        let context = context()
        var creations = 0, stops = 0
        let runtime = Runtime(isCurrent: { $0 == context }, stopResource: { _ in stops += 1 })
        let lease = try runtime.begin(context: context) { creations += 1; return Resource() }
        let first = try runtime.attachFullscreen(lease)
        XCTAssertTrue(first.isFirstAttachment)
        XCTAssertTrue(try runtime.claimInitialLoad(first))
        XCTAssertTrue(runtime.detachFullscreen(first, keepingPictureInPicture: true))
        XCTAssertEqual(runtime.phase, .pictureInPicture)
        let restored = try runtime.restore(context: context)
        XCTAssertTrue(restored.resource === lease.resource)
        let second = try runtime.attachFullscreen(restored)
        XCTAssertFalse(second.isFirstAttachment)
        XCTAssertFalse(try runtime.claimInitialLoad(second))
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(runtime.detachFullscreen(second, keepingPictureInPicture: false))
        XCTAssertEqual(stops, 1)
    }

    func testLateDisappearOfSupersededSurfaceCannotDestroyRestoredPlayer() throws {
        var stops = 0
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in stops += 1 })
        let lease = try runtime.begin(context: context()) { Resource() }
        let outgoing = try runtime.attachFullscreen(lease)
        _ = try runtime.attachFullscreen(lease)
        XCTAssertFalse(runtime.detachFullscreen(outgoing, keepingPictureInPicture: false))
        XCTAssertTrue(runtime.isCurrent(lease))
        XCTAssertEqual(runtime.phase, .fullscreen)
        XCTAssertEqual(stops, 0)
        runtime.invalidate()
        XCTAssertEqual(stops, 1)
    }

    func testConcurrentLaunchDoesNotConstructAnotherResource() throws {
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        defer { runtime.invalidate() }
        _ = try runtime.begin(context: context()) { Resource() }
        XCTAssertThrowsError(try runtime.begin(context: context()) {
            XCTFail("Second resource must never be constructed")
            return Resource()
        }) { XCTAssertEqual($0 as? WatchPartyPlaybackRuntimeError, .alreadyActive) }
    }

    func testSupersededMountBeforeInitialLoadDoesNotLoseOrDuplicateTheLaunch() throws {
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        defer { runtime.invalidate() }
        let lease = try runtime.begin(context: context()) { Resource() }
        let abandoned = try runtime.attachFullscreen(lease)
        let replacement = try runtime.attachFullscreen(lease)
        XCTAssertThrowsError(try runtime.claimInitialLoad(abandoned))
        XCTAssertTrue(try runtime.claimInitialLoad(replacement))
        XCTAssertFalse(try runtime.claimInitialLoad(replacement))
    }

    func testSameRoomAndMemberAfterRejoinCannotRestorePriorMembership() throws {
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        defer { runtime.invalidate() }
        let first = context()
        _ = try runtime.begin(context: first) { Resource() }
        let rejoined = context(epoch: first.request.epoch)
        XCTAssertThrowsError(try runtime.restore(context: rejoined)) {
            XCTAssertEqual($0 as? WatchPartyPlaybackRuntimeError, .staleLease)
        }
    }

    func testContextReturningAToBToACannotReviveOldLease() throws {
        var current = context()
        var stops = 0
        let runtime = Runtime(isCurrent: { $0 == current }, stopResource: { _ in stops += 1 })
        let original = current
        let old = try runtime.begin(context: original) { Resource() }
        runtime.invalidate()
        current = context()
        runtime.invalidate()
        current = original
        let next = try runtime.begin(context: original) { Resource() }
        XCTAssertFalse(runtime.isCurrent(old))
        XCTAssertFalse(runtime.finish(old))
        XCTAssertTrue(runtime.isCurrent(next))
        XCTAssertEqual(stops, 1)
        runtime.invalidate()
        XCTAssertEqual(stops, 2)
    }

    func testBindingStopsBeforeResourceAndInvalidatesCallbacksExactlyOnce() throws {
        var events: [String] = []
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in events.append("player") })
        let lease = try runtime.begin(context: context()) { Resource() }
        try runtime.ownBinding(lease) {
            XCTAssertFalse(runtime.isCurrent(lease))
            events.append("binding")
            runtime.invalidate() // Reentrant cleanup cannot run twice.
        }
        XCTAssertTrue(runtime.finish(lease))
        XCTAssertFalse(runtime.finish(lease))
        runtime.invalidate()
        XCTAssertEqual(events, ["binding", "player"])
        XCTAssertEqual(runtime.phase, .idle)
    }

    func testSecondBindingIsRejectedWithoutReplacingFirstCleanup() throws {
        var cleanups = 0
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        let lease = try runtime.begin(context: context()) { Resource() }
        try runtime.ownBinding(lease) { cleanups += 1 }
        XCTAssertThrowsError(try runtime.ownBinding(lease) { XCTFail("Second cleanup was retained") }) {
            XCTAssertEqual($0 as? WatchPartyPlaybackRuntimeError, .bindingAlreadyOwned)
        }
        runtime.invalidate()
        XCTAssertEqual(cleanups, 1)
    }

    func testInvalidationDuringFactoryDisposesResourceAndRejectsAcceptance() {
        var stops = 0
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in stops += 1 })
        XCTAssertThrowsError(try runtime.begin(context: context()) {
            runtime.invalidate()
            return Resource()
        }) { XCTAssertEqual($0 as? WatchPartyPlaybackRuntimeError, .staleContext) }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(runtime.phase, .idle)
    }

    func testReentrantLaunchDuringFactoryAndCleanupCannotStealOwnership() throws {
        let context = context()
        var runtime: Runtime!
        runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in
            do {
                _ = try runtime.begin(context: context) { Resource() }
                XCTFail("Expected alreadyActive error")
            } catch {
                XCTAssertEqual(error as? WatchPartyPlaybackRuntimeError, .alreadyActive)
            }
        })
        let lease = try runtime.begin(context: context) {
            do {
                _ = try runtime.begin(context: context) { Resource() }
                XCTFail("Expected alreadyActive error")
            } catch {
                XCTAssertEqual(error as? WatchPartyPlaybackRuntimeError, .alreadyActive)
            }
            return Resource()
        }
        runtime.finish(lease)
        runtime = nil
    }

    func testForeignOwnerCannotAttachOrFinishAnotherOwnersLease() throws {
        let a = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        let b = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        defer { a.invalidate(); b.invalidate() }
        let context = context()
        let lease = try a.begin(context: context) { Resource() }
        _ = try b.begin(context: context) { Resource() }
        XCTAssertThrowsError(try b.attachFullscreen(lease))
        XCTAssertFalse(b.finish(lease))
        XCTAssertTrue(a.isCurrent(lease))
    }

    func testOldAsyncCompletionCannotStopSuccessor() async throws {
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        let old = try runtime.begin(context: context()) { Resource() }
        let completion = Task { @MainActor in
            await Task.yield()
            return runtime.finish(old)
        }
        runtime.invalidate()
        let next = try runtime.begin(context: context()) { Resource() }
        let accepted = await completion.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(runtime.isCurrent(next))
        runtime.invalidate()
    }

    func testExternalContextLossRejectsRestoreAndStillAllowsTeardown() throws {
        var valid = true
        var stops = 0
        let context = context()
        let runtime = Runtime(isCurrent: { _ in valid }, stopResource: { _ in stops += 1 })
        let lease = try runtime.begin(context: context) { Resource() }
        let surface = try runtime.attachFullscreen(lease)
        valid = false
        XCTAssertFalse(runtime.isCurrent(lease))
        XCTAssertThrowsError(try runtime.restore(context: context))
        XCTAssertTrue(runtime.detachFullscreen(surface, keepingPictureInPicture: true))
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(runtime.phase, .idle)
    }

    func testValidatorDoesNotRetainResourceAndCannotReviveAcrossReplacement() throws {
        let runtime = Runtime(isCurrent: { _ in true }, stopResource: { _ in })
        var lease: Runtime.Lease? = try runtime.begin(context: context()) { Resource() }
        weak var resource = lease?.resource
        let valid = try runtime.makeValidator(for: XCTUnwrap(lease))
        XCTAssertTrue(valid())
        runtime.invalidate()
        lease = nil
        XCTAssertNil(resource)
        XCTAssertFalse(valid())
        _ = try runtime.begin(context: context()) { Resource() }
        XCTAssertFalse(valid())
        runtime.invalidate()
    }
}
