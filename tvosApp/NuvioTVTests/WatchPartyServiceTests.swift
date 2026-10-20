import XCTest
import Combine
@testable import NuvioTV

@MainActor
final class WatchPartyServiceTests: XCTestCase {
    private func environment() -> WatchPartyEnvironment {
        WatchPartyEnvironment(configuration: ServerConfiguration(backendURL: "https://party.example.test", publishableKey: "public",
                                                                  capabilities: ServerCapabilities(), discoveryURL: nil),
                              userID: "user", profileID: "profile", identity: WatchPartyIdentity(deviceID: "stable-device", displayName: "Viewer"))
    }

    private func service(_ remote: Remote, channel: Channel? = nil,
                         sleep: @escaping WatchPartySession.Sleep = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) },
                         environment: @escaping WatchPartyService.EnvironmentProvider) -> WatchPartyService {
        let channel = channel ?? Channel()
        return WatchPartyService(environment: environment, makeRemote: { _, _, _ in remote }, makeSession: { remote, env, context, validator in
            WatchPartySession(remote: remote, context: context, deviceID: env.identity.deviceID,
                              isCurrent: validator, makeChannel: { channel },
                              connectionTasksEnabled: false,
                              sleep: sleep)
        })
    }

    func testAvatarCatalogChangesDoNotInvalidateRoomIdentity() {
        let configuration = ServerConfiguration(backendURL: "https://party.example.test", publishableKey: "public",
                                                 capabilities: ServerCapabilities(), discoveryURL: nil)
        let left = WatchPartyEnvironment(configuration: configuration, userID: "user", profileID: "profile",
                                         identity: WatchPartyIdentity(deviceID: "device", displayName: "Viewer"))
        let right = WatchPartyEnvironment(configuration: configuration, userID: "user", profileID: "profile",
                                          identity: WatchPartyIdentity(deviceID: "device", displayName: "Viewer",
                                                                       avatarURL: "https://party.example.test/avatar.png",
                                                                       avatarColor: "#123456"))
        XCTAssertEqual(left, right)
    }

    func testCreateChecksAvailabilityAndOwnsAcceptedMembership() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        defer { service.invalidateContext() }
        try await service.create(media: remote.media)
        XCTAssertEqual(Array(remote.calls.prefix(2)), ["enabled", "create"])
        XCTAssertEqual(remote.identities.first?.deviceID, "stable-device")
        XCTAssertEqual(service.session?.connection, .ready)
        XCTAssertFalse(service.busy)
        do { try await service.create(media: remote.media); XCTFail("Expected existing membership guard") }
        catch { XCTAssertEqual(error as? WatchPartyServiceError, .alreadyInRoom) }
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
    }

    func testRealtimeFailureKeepsMembershipWithoutRepeatingCreate() async throws {
        let env = environment(), remote = Remote(), channel = Channel()
        channel.openFails = true
        let service = service(remote, channel: channel, environment: { env })
        defer { service.invalidateContext() }
        try await service.create(media: remote.media)
        XCTAssertEqual(service.session?.party?.id, "room")
        XCTAssertEqual(service.session?.connection, .recovering)
        XCTAssertFalse(service.membershipOutcomeUncertain)
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
    }

    func testAmbiguousCreateIsNotRepeatedWithoutExplicitAcknowledgement() async throws {
        let env = environment(), remote = Remote()
        remote.createError = WatchPartyAPIError.transport
        let service = service(remote, environment: { env })
        defer { service.invalidateContext() }
        do { try await service.create(media: remote.media); XCTFail("Expected transport error") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .transport) }
        XCTAssertTrue(service.membershipOutcomeUncertain)
        do { try await service.create(media: remote.media); XCTFail("Expected uncertain-outcome guard") }
        catch { XCTAssertEqual(error as? WatchPartyServiceError, .membershipOutcomeUncertain) }
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
        service.acknowledgeUncertainMembershipOutcome()
        remote.createError = nil
        try await service.create(media: remote.media)
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 2)
    }

    func testContextInvalidationRejectsLateCreateEvenWhenIdentityReturnsToSameValue() async {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        remote.onCreate = { service.invalidateContext() }
        defer { remote.onCreate = nil; service.invalidateContext() }
        do { try await service.create(media: remote.media); XCTFail("Expected obsolete operation") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
        XCTAssertNil(service.session)
        XCTAssertFalse(service.busy)
        XCTAssertFalse(service.membershipOutcomeUncertain)
    }

    func testDisabledBackendDoesNotAttemptMembershipMutation() async {
        let env = environment(), remote = Remote()
        remote.isEnabled = false
        let service = service(remote, environment: { env })
        do { try await service.create(media: remote.media); XCTFail("Expected disabled backend") }
        catch { XCTAssertEqual(error as? WatchPartyServiceError, .unavailable) }
        XCTAssertEqual(remote.calls, ["enabled"])
        XCTAssertEqual(service.available, false)
        XCTAssertFalse(service.membershipOutcomeUncertain)
    }

    func testBusinessRejectionDoesNotBecomeAmbiguousNetworkOutcome() async {
        let env = environment(), remote = Remote()
        remote.createResult = WatchPartySnapshot(error: "party_full")
        let service = service(remote, environment: { env })
        do { try await service.create(media: remote.media); XCTFail("Expected room-full rejection") }
        catch { XCTAssertEqual(error as? WatchPartyServiceError, .rejected(.full)) }
        XCTAssertEqual(service.failure, .full)
        XCTAssertFalse(service.membershipOutcomeUncertain)
    }

    func testBusyOperationRejectsConcurrentEntry() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        defer { remote.onCreate = nil; service.invalidateContext() }
        remote.onCreate = {
            do { try await service.join(code: "ABC234"); XCTFail("Expected busy guard") }
            catch { XCTAssertEqual(error as? WatchPartyServiceError, .busy) }
        }
        try await service.create(media: remote.media)
        XCTAssertFalse(remote.calls.contains("join"))
        XCTAssertFalse(service.busy)
    }

    func testJoinNormalizesCodeAndPreviewPreservesExistingSession() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        defer { service.invalidateContext() }
        try await service.join(code: "abc-234")
        XCTAssertEqual(remote.joinedCode, "ABC234")
        let current = service.session
        _ = try await service.preview(code: "ABC234")
        XCTAssertTrue(service.session === current)
        XCTAssertEqual(service.session?.connection, .ready)
    }

    func testHostOnlyMutationAppliesSnapshotAfterControlBroadcastInvalidatesChannel() async throws {
        let env = environment(), remote = Remote(), channel = Channel()
        let service = service(remote, channel: channel, environment: { env })
        defer { remote.onSetHostOnly = nil; service.invalidateContext() }
        try await service.create(media: remote.media)
        let before = remote.snapshot
        remote.hostOnlyResult = WatchPartySnapshot(
            party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: "me", hostOnly: true, media: remote.media),
            members: before.members,
            memberID: "me"
        )
        remote.onSetHostOnly = {
            channel.receive?(.message(name: "control", payload: Data()))
        }

        try await service.setHostOnly(enabled: false)

        XCTAssertEqual(remote.hostOnlyEnabled, false)
        XCTAssertTrue(service.session?.party?.hostOnly == true)
        XCTAssertEqual(service.session?.connection, .recovering)
        XCTAssertFalse(service.busy)
    }

    func testNewerRecoverySnapshotWinsOverLateHostOnlyResponse() async throws {
        let env = environment(), remote = Remote(), channel = Channel()
        let service = service(remote, channel: channel, sleep: { _ in }, environment: { env })
        defer { remote.onSetHostOnly = nil; service.invalidateContext() }
        try await service.create(media: remote.media)
        remote.hostOnlyResult = WatchPartySnapshot(
            party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: "me", hostOnly: true, media: remote.media),
            members: remote.snapshot.members,
            memberID: "me"
        )
        remote.onSetHostOnly = {
            channel.receive?(.message(name: "control", payload: Data()))
            for _ in 0..<100 where service.session?.connection != .ready { await Task.yield() }
        }

        try await service.setHostOnly(enabled: true)

        XCTAssertEqual(service.session?.connection, .ready)
        XCTAssertFalse(service.session?.party?.hostOnly ?? true)
        XCTAssertFalse(service.busy)
    }

    func testChangedProfileStopsOldRoomBeforeStartingAnotherRequest() async throws {
        var env: WatchPartyEnvironment? = environment()
        let remote = Remote(), channel = Channel()
        let service = service(remote, channel: channel, environment: { env })
        defer { service.invalidateContext() }
        try await service.create(media: remote.media)
        let old = service.session
        let previous = try XCTUnwrap(env)
        env = WatchPartyEnvironment(configuration: previous.configuration, userID: previous.userID, profileID: "other",
                                    identity: previous.identity)
        _ = try await service.checkAvailability()
        XCTAssertNil(service.session)
        XCTAssertEqual(old?.connection, .stopped)
        XCTAssertFalse(channel.isConnected)
    }

    func testCallerCancellationAfterAcceptancePreservesKnownMembership() async throws {
        let env = environment(), remote = Remote(), channel = Channel()
        let service = service(remote, channel: channel, environment: { env })
        defer { channel.onOpen = nil; service.invalidateContext() }
        var operation: Task<Void, Error>?
        channel.onOpen = { operation?.cancel() }
        let task = Task { try await service.create(media: remote.media) }
        operation = task
        do { try await task.value; XCTFail("Expected caller cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(service.session?.party?.id, "room")
        XCTAssertEqual(service.session?.connection, .ready)
        XCTAssertFalse(service.membershipOutcomeUncertain)
        XCTAssertFalse(service.busy)
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
        operation = nil
    }

    func testResumeAfterRemovalRequiresExplicitNewJoin() async throws {
        let env = environment(), remote = Remote(), channel = Channel()
        let service = service(remote, channel: channel, environment: { env })
        defer { service.invalidateContext() }
        try await service.create(media: remote.media)
        channel.receive?(.message(name: "member_left", payload: Data(#"{"member_id":"me","reason":"removed"}"#.utf8)))
        do { try await service.resume(); XCTFail("Expected explicit new-join requirement") }
        catch { XCTAssertEqual(error as? WatchPartyServiceError, .newJoinRequired) }
        XCTAssertEqual(service.session?.membershipExit, .removed)
        XCTAssertFalse(remote.calls.contains("join"))
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
    }

    func testInvalidationRevokesEpochBeforeConsumerCleanupAndStopsRoomAfterward() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        try await service.create(media: remote.media)
        let room = try XCTUnwrap(service.session)
        let context = try XCTUnwrap(room.playbackContext)
        var callbacks = 0
        let observer = service.contextDidInvalidate.sink { _ in
            callbacks += 1
            XCTAssertFalse(service.isCurrent(context.request))
            XCTAssertTrue(service.session === room)
            XCTAssertEqual(room.connection, .ready)
            service.invalidateContext() // Reentrant teardown must not recursively notify.
        }
        service.invalidateContext()
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(room.connection, .stopped)
        XCTAssertNil(service.session)
        observer.cancel()
    }

    func testRootAttachmentIsInertAndBoundaryStopsRoomWithoutImplicitLeaveOrJoin() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        let boundary = PassthroughSubject<Void, Never>()
        let owner = WatchPartyAppOwner(service: service, contextChanges: boundary.eraseToAnyPublisher())
        defer { owner.stop() }
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertEqual(owner.runtime?.phase, .idle)
        try await service.create(media: remote.media)
        let room = try XCTUnwrap(service.session)
        boundary.send(())
        XCTAssertEqual(room.connection, .stopped)
        XCTAssertNil(service.session)
        XCTAssertFalse(remote.calls.contains("leave"))
        XCTAssertFalse(remote.calls.contains("join"))
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
    }

    func testRootBoundaryRejectsLateCreateEvenWhenEnvironmentReturnsToSameValue() async {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        let boundary = PassthroughSubject<Void, Never>()
        let owner = WatchPartyAppOwner(service: service, contextChanges: boundary.eraseToAnyPublisher())
        defer { remote.onCreate = nil; owner.stop() }
        remote.onCreate = { boundary.send(()); boundary.send(()) }
        do { try await service.create(media: remote.media); XCTFail("Expected revoked root epoch") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
        XCTAssertNil(service.session)
        XCTAssertEqual(remote.calls.filter { $0 == "create" }.count, 1)
    }

    func testRootStopRemovesBoundarySubscriptionAndDoesNotAffectSuccessor() async throws {
        let env = environment(), remote = Remote()
        let service = service(remote, environment: { env })
        let boundary = PassthroughSubject<Void, Never>()
        let owner = WatchPartyAppOwner(service: service, contextChanges: boundary.eraseToAnyPublisher())
        owner.stop()
        owner.stop()
        XCTAssertNil(owner.service)
        XCTAssertNil(owner.runtime)
        _ = try await service.checkAvailability()
        boundary.send(())
        XCTAssertEqual(service.available, true)
        service.invalidateContext()
    }

    @MainActor
    private final class Remote: WatchPartyServiceRemote {
        let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
        var calls: [String] = []
        var identities: [WatchPartyIdentity] = []
        var isEnabled = true
        var createError: Error?
        var createResult: WatchPartySnapshot?
        var hostOnlyEnabled: Bool?
        var hostOnlyResult: WatchPartySnapshot?
        var onSetHostOnly: (@MainActor () async -> Void)?
        var onCreate: (@MainActor () async -> Void)?
        var joinedCode: String?
        var snapshot: WatchPartySnapshot {
            WatchPartySnapshot(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: "me", media: media),
                               members: [WatchPartyMember(id: "me", displayName: "Viewer")], memberID: "me", serverTimeMs: 100)
        }
        func enabled() async throws -> Bool { calls.append("enabled"); return isEnabled }
        func create(identity: WatchPartyIdentity, media: WatchPartyMedia, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot {
            calls.append("create"); identities.append(identity); await onCreate?()
            if let createError { throw createError }
            return createResult ?? snapshot
        }
        func join(code: String, identity: WatchPartyIdentity) async throws -> WatchPartySnapshot {
            calls.append("join"); joinedCode = code; return snapshot
        }
        func preview(code: String) async throws -> WatchPartyPreview { calls.append("preview"); return WatchPartyPreview(media: media) }
        func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { calls.append("heartbeat"); return snapshot }
        func clock() async throws -> Int64 { calls.append("clock"); return 100 }
        func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { calls.append("leave"); return WatchPartySnapshot(ok: true) }
        func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { calls.append("end"); return WatchPartySnapshot(ok: true) }
        func setHostOnly(partyID: String, deviceID: String, enabled: Bool) async throws -> WatchPartySnapshot {
            calls.append("setHostOnly")
            hostOnlyEnabled = enabled
            await onSetHostOnly?()
            return hostOnlyResult ?? snapshot
        }
        func update(partyID: String, deviceID: String, media: WatchPartyMedia?, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot { calls.append("update"); return snapshot }
    }

    @MainActor
    private final class Channel: WatchPartyChannel {
        var isConnected = false
        var openFails = false
        var onOpen: (() -> Void)?
        var receive: (@MainActor (WatchPartyChannelEvent) -> Void)?
        func open(partyID: String, memberID: String, receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws {
            if openFails { throw WatchPartyChannelError.disconnected }
            isConnected = true
            self.receive = receive
            onOpen?()
        }
        func send(event: String, payload: Data) async throws {}
        func track(_ presence: WatchPartyPresence) async throws {}
        func refreshAuth() async throws {}
        func close() { isConnected = false }
    }
}
