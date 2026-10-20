import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyCoordinationTests: XCTestCase {
    func testSessionTickPausesForBufferingAndResumesWhenReady() async throws {
        let ticks = Gate(), remote = Remote(), channel = Channel()
        var uptime: TimeInterval = 0
        let session = makeSession(remote, channel: channel, uptime: { uptime }, sleep: { nanos in
            if nanos == WatchPartyWaitingCoordinator.tickNanoseconds { try await ticks.wait() }
            else { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        })
        defer { session.stop(); ticks.cancelAll(); channel.onState = nil }
        let firstTick = expectation(description: "Coordinator waiting for first tick")
        ticks.onWait = { firstTick.fulfill() }
        try await session.start(snapshot: remote.snapshot)
        await fulfillment(of: [firstTick], timeout: 1)
        channel.receive?(.message(name: "status", payload: Data(#"{"member_id":"other","status":"buffering","media_key":"movie|tt1||"}"#.utf8)))
        let paused = expectation(description: "Waiting pause broadcast")
        let nextTick = expectation(description: "Next coordinator tick")
        ticks.onWait = { nextTick.fulfill() }
        channel.onState = { state in
            XCTAssertTrue(state.paused)
            XCTAssertTrue(state.waiting)
            XCTAssertEqual(state.positionMs, 1_500)
            paused.fulfill()
        }
        uptime = 0.5
        ticks.release()
        await fulfillment(of: [paused, nextTick], timeout: 1)
        ticks.onWait = nil
        channel.receive?(.message(name: "status", payload: Data(#"{"member_id":"other","status":"ready","media_key":"movie|tt1||"}"#.utf8)))
        let resumed = expectation(description: "Waiting resume broadcast")
        channel.onState = { state in
            XCTAssertFalse(state.paused)
            XCTAssertFalse(state.waiting)
            XCTAssertEqual(state.positionMs, 1_500)
            resumed.fulfill()
        }
        uptime = 1
        ticks.release()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(channel.states.map(\.seq), [2, 3])
    }

    func testGuestManualSourceRefreshUsesExistingAndroidStateRequestAndCooldown() async throws {
        let remote = Remote(), channel = Channel()
        remote.hostMemberID = "other"
        let session = makeSession(remote, channel: channel, uptime: { 0 },
                                  sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        defer { session.stop() }
        try await session.start(snapshot: remote.snapshot)
        XCTAssertEqual(channel.stateRequestMemberIDs, ["me"],
                       "Connection already requests state once for late join/reconnect")
        let first = try await session.requestHostStreamRefresh()
        XCTAssertTrue(first)
        XCTAssertEqual(channel.stateRequestMemberIDs, ["me", "me"])
        let duplicate = try await session.requestHostStreamRefresh()
        XCTAssertFalse(duplicate, "Rapid remote presses must not fan out token-bearing responses")
        XCTAssertEqual(channel.stateRequestMemberIDs.count, 2)
    }

    func testFailedManualSourceRefreshInvalidatesConnectionWithoutAutomaticReplay() async throws {
        let remote = Remote(), channel = Channel()
        remote.hostMemberID = "other"
        let session = makeSession(remote, channel: channel, uptime: { 0 },
                                  sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        defer { session.stop() }
        try await session.start(snapshot: remote.snapshot)
        XCTAssertEqual(channel.stateRequestMemberIDs.count, 1)
        channel.failStateRequest = true
        do {
            _ = try await session.requestHostStreamRefresh()
            XCTFail("Expected simulated transport failure")
        } catch {
            XCTAssertEqual(session.connection, .recovering)
        }
        XCTAssertEqual(channel.stateRequestMemberIDs.count, 1,
                       "A failed send must not be replayed or sent twice")
        XCTAssertNil(session.sharedStream)
    }

    func testHostCannotRequestGuestSourceRefresh() async throws {
        let remote = Remote(), channel = Channel()
        let session = makeSession(remote, channel: channel, uptime: { 0 },
                                  sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        defer { session.stop() }
        try await session.start(snapshot: remote.snapshot)
        do {
            _ = try await session.requestHostStreamRefresh()
            XCTFail("Host must not issue a guest-only request")
        } catch let error as WatchPartyStreamError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(channel.stateRequestMemberIDs, ["me"])
    }

    func testGuestAcceptsOnlyCurrentHostStreamAndRevocationInvalidatesSelection() async throws {
        let remote = Remote(), channel = Channel()
        remote.hostMemberID = "other"
        let session = makeSession(remote, channel: channel, uptime: { 0 },
                                  sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        defer { session.stop() }
        try await session.start(snapshot: remote.snapshot)
        let source = WatchPartyStream(
            mediaKey: "movie|tt1||", url: "https://example.test/video?token=private",
            headers: ["User-Agent": "NuvioTV"],
            responseHeaders: ["Content-Type": "video/mp4"]
        )
        func deliver(_ member: String, _ source: WatchPartyStream?) throws {
            let payload = try JSONEncoder().encode(WatchPartyStreamMessage(memberID: member, stream: source))
            channel.receive?(.message(name: "stream", payload: payload))
        }
        try deliver("not-the-host", source)
        XCTAssertNil(session.sharedStream, "An unrelated participant cannot inject a source")
        var wrong = source
        wrong.mediaKey = "movie|tt2||"
        try deliver("other", wrong)
        XCTAssertNil(session.sharedStream, "The exact room movie or episode must match")
        try deliver("other", source)
        XCTAssertEqual(session.sharedStream, source)
        let selected = try session.selectSharedStream(source)
        XCTAssertEqual(selected.candidate.responseHeaders["Content-Type"], "video/mp4")
        XCTAssertTrue(session.isCurrentSharedStreamSelection(selected))
        try deliver("other", nil)
        XCTAssertNil(session.sharedStream)
        XCTAssertFalse(session.isCurrentSharedStreamSelection(selected),
                       "A revoked source must not remain playable through an old selection")
        XCTAssertThrowsError(try session.selectSharedStream(source))
    }

    func testGuestSourceSelectionInvalidatedOnConnectionLoss() async throws {
        let remote = Remote(), channel = Channel()
        remote.hostMemberID = "other"
        let session = makeSession(remote, channel: channel, uptime: { 0 },
                                  sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        defer { session.stop() }
        try await session.start(snapshot: remote.snapshot)
        let source = WatchPartyStream(mediaKey: "movie|tt1||", url: "https://example.test/video")
        let payload = try JSONEncoder().encode(WatchPartyStreamMessage(memberID: "other", stream: source))
        channel.receive?(.message(name: "stream", payload: payload))
        let selected = try session.selectSharedStream(source)
        XCTAssertTrue(session.isCurrentSharedStreamSelection(selected))
        channel.receive?(.disconnected)
        XCTAssertNil(session.sharedStream)
        XCTAssertFalse(session.isCurrentSharedStreamSelection(selected))
    }

    func testFourClockSamplesKeepConnectionReadyWhenOneRefinementFails() async throws {
        let remote = Remote(), channel = Channel()
        let refined = expectation(description: "Four total clock RPC samples attempted")
        remote.onClock = { count in if count == 4 { refined.fulfill() } }
        remote.failClockCall = 2
        let session = makeSession(remote, channel: channel, uptime: { 0 }, sleep: { nanos in
            if nanos == 400_000_000 { return }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        defer { session.stop(); remote.onClock = nil }
        try await session.start(snapshot: remote.snapshot)
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(remote.clockCalls, 4)
        XCTAssertEqual(session.connection, .ready)
        XCTAssertTrue(channel.isConnected)
    }

    func testManualPauseCancelsActiveRemoteCorrectionAndPublishesOnce() async throws {
        let seekIssued = expectation(description: "Remote correction reached the checked seek bridge")
        let room = PlaybackRoom(hostOnly: false, memberID: "me", hostMemberID: "me",
                                playbackPositionMs: 5_000)
        let player = makePlaybackBinding(room: room, positionMs: 0,
                                         issueSeek: { _, _ in seekIssued.fulfill() })
        let binding = player.binding
        defer { binding.stop() }

        await fulfillment(of: [seekIssued], timeout: 1)
        XCTAssertTrue(player.bridge.awaitsSeekSample, "Correction must be suspended on its seek receipt")

        try await binding.perform(.pause)

        XCTAssertEqual(player.transports.values.filter { $0.paused == true }.count, 2,
                       "The remote seek's initial pause is followed by the manual pause")
        XCTAssertEqual(room.published.count, 1)
        XCTAssertTrue(room.published[0].paused)
        XCTAssertFalse(room.published[0].waiting)
    }

    func testPauseDoesNotRequireSeekReadyDurationOrSeekingState() async throws {
        let room = PlaybackRoom(hostOnly: false, memberID: "me", hostMemberID: "me",
                                playbackPositionMs: 0)
        let player = makePlaybackBinding(room: room, positionMs: 0, durationMs: 0,
                                         seeking: true, loading: true, coherent: false)
        defer { player.binding.stop() }

        try await player.binding.perform(.pause)

        XCTAssertEqual(player.transports.values.filter { $0.paused == true }.count, 1,
                       "A pause-only effect is applied locally through the checked bridge")
        XCTAssertEqual(room.published.count, 1)
        XCTAssertTrue(room.published[0].paused)
        XCTAssertFalse(room.published[0].waiting)
    }

    func testPauseRestoresTemporaryNudgeAndPublishesCanonicalRoomRate() async throws {
        let room = PlaybackRoom(hostOnly: false, memberID: "me", hostMemberID: "me",
                                playbackPositionMs: 0, playbackRate: 1)
        let player = makePlaybackBinding(room: room, positionMs: 0, sampleRate: 1.02)
        defer { player.binding.stop() }

        for _ in 0..<100 where player.binding.isSynchronizing { await Task.yield() }
        XCTAssertFalse(player.binding.isSynchronizing, "Initial room correction should finish before nudging")
        XCTAssertEqual(try player.bridge.setTemporaryRate(1.03), 1.03, accuracy: 0.001)
        XCTAssertTrue(player.bridge.isApplyingTemporaryRate)

        try await player.binding.perform(.pause)

        XCTAssertFalse(player.bridge.isApplyingTemporaryRate)
        XCTAssertEqual(room.published.count, 1)
        XCTAssertTrue(room.published[0].paused)
        XCTAssertFalse(room.published[0].waiting)
        XCTAssertEqual(room.published[0].rate, 1, accuracy: 0.001)
        let finalTransports = Array(player.transports.values.suffix(2))
        XCTAssertNil(finalTransports[0].paused)
        XCTAssertEqual(finalTransports[0].rate ?? -1, 1, accuracy: 0.001,
                       "Clearing the temporary nudge restores the canonical rate")
        XCTAssertEqual(finalTransports[1].paused, true)
        XCTAssertEqual(finalTransports[1].rate ?? -1, 1, accuracy: 0.001)
    }

    func testRemotePauseAppliesDuringLoadingWithoutEchoAndRejectsStaleContext() async throws {
        let room = PlaybackRoom(hostOnly: false, memberID: "me", hostMemberID: "me",
                                playbackPositionMs: 0)
        var contextCurrent = true
        let player = makePlaybackBinding(room: room, positionMs: 0,
                                        loading: true, coherent: false,
                                        isCurrent: { contextCurrent },
                                        issueSeek: { _, _ in })
        defer { player.binding.stop() }

        room.receiveRemotePlayback(paused: true, seq: 2, positionMs: 20_000)
        for _ in 0..<100 where player.transports.values.filter({ $0.paused == true }).isEmpty {
            await Task.yield()
        }
        for _ in 0..<100 where player.binding.isSynchronizing { await Task.yield() }

        XCTAssertEqual(player.transports.values.filter { $0.paused == true }.count, 1)
        XCTAssertTrue(room.published.isEmpty, "Remote state must not be republished as a local pause")

        let stamp = try XCTUnwrap(player.bridge.sample?.stamp)
        player.bridge.observe(WatchPartyPlayerSample(stamp: stamp, positionMs: 0, durationMs: 100_000,
                                                      rate: 1, paused: true, loading: false, coherent: true,
                                                      seeking: false))
        for _ in 0..<100 where !player.bridge.awaitsSeekSample { await Task.yield() }
        XCTAssertEqual(player.seekTargets.values, [20_000])
        XCTAssertTrue(player.bridge.awaitsSeekSample)
        XCTAssertTrue(room.published.isEmpty, "Ready-sample reconciliation must also avoid room echo")

        player.bridge.observe(WatchPartyPlayerSample(stamp: stamp, positionMs: 20_000, durationMs: 100_000,
                                                      rate: 1, paused: true, loading: false, coherent: true,
                                                      seeking: false))
        for _ in 0..<100 where player.binding.isSynchronizing { await Task.yield() }
        XCTAssertFalse(player.binding.isSynchronizing, "Confirmed paused-position seek should drain its worker")
        XCTAssertEqual(player.transports.values.filter { $0.paused == true }.count, 4)

        contextCurrent = false
        room.receiveRemotePlayback(paused: true, seq: 3, positionMs: 20_000)
        XCTAssertEqual(player.transports.values.filter { $0.paused == true }.count, 4,
                       "Stale context must not admit another transport pause or seek")
        XCTAssertTrue(room.published.isEmpty)
    }

    func testHostOnlyGuestPauseIsLocalAndMarksGuestBehind() async throws {
        let room = PlaybackRoom(hostOnly: true, memberID: "guest", hostMemberID: "host",
                                playbackPositionMs: 0)
        let player = makePlaybackBinding(room: room, positionMs: 0)
        defer { player.binding.stop() }

        try await player.binding.perform(.pause)

        XCTAssertEqual(player.transports.values.last?.paused, true)
        XCTAssertTrue(player.binding.isBehind)
        XCTAssertTrue(room.published.isEmpty, "A host-only guest must not publish a room pause")
    }

    func testPauseQueuedDuringExplicitControlIsCoalescedAndRetained() async throws {
        let stamp = WatchPartyPlayerStamp(generation: 1, engineID: ObjectIdentifier(NSObject()), mediaKey: "movie|tt1||")
        let firstControlStarted = expectation(description: "Prior explicit control started")
        let pauseCompleted = expectation(description: "Queued pause executed")
        let gate = Gate()
        var controls: [String] = []
        var completions = [0, 0]
        var applied = [0, 0]
        let router = WatchPartyControlRouter(isCurrent: { true }, currentStamp: { stamp },
            perform: { intent, onApplied in
                switch intent {
                case .speed:
                    controls.append("speed")
                    firstControlStarted.fulfill()
                    try await gate.wait()
                case .pause:
                    controls.append("pause")
                    onApplied?()
                default: XCTFail("Unexpected queued control")
                }
            }, onCompleted: { intent in
                if case .pause = intent { pauseCompleted.fulfill() }
            })
        defer { router.stop(); gate.cancelAll() }

        XCTAssertEqual(router.submit(.speed(1.5)), .accepted)
        await fulfillment(of: [firstControlStarted], timeout: 1)
        XCTAssertEqual(router.submit(.pause, completion: { completions[0] += 1 },
                                     onApplied: { applied[0] += 1 }), .accepted)
        XCTAssertEqual(router.submit(.pause, completion: { completions[1] += 1 },
                                     onApplied: { applied[1] += 1 }), .accepted)
        gate.release()
        await fulfillment(of: [pauseCompleted], timeout: 1)

        XCTAssertEqual(controls, ["speed", "pause"])
        XCTAssertEqual(completions, [1, 1])
        XCTAssertEqual(applied, [1, 1])
    }

    func testContextLossClearsQueuedPauseAndItsCompletion() async throws {
        var stamp = WatchPartyPlayerStamp(generation: 1, engineID: ObjectIdentifier(NSObject()), mediaKey: "movie|tt1||")
        let firstControlStarted = expectation(description: "Prior explicit control started")
        let gate = Gate()
        var pauseCount = 0
        var pauseCompletions = 0
        let router = WatchPartyControlRouter(isCurrent: { true }, currentStamp: { stamp },
            perform: { intent, _ in
                if case .speed = intent {
                    firstControlStarted.fulfill()
                    try await gate.wait()
                } else if case .pause = intent {
                    pauseCount += 1
                }
            })
        defer { router.stop(); gate.cancelAll() }

        XCTAssertEqual(router.submit(.speed(1.5)), .accepted)
        await fulfillment(of: [firstControlStarted], timeout: 1)
        XCTAssertEqual(router.submit(.pause, completion: { pauseCompletions += 1 }), .accepted)
        stamp = WatchPartyPlayerStamp(generation: 2, engineID: stamp.engineID, mediaKey: stamp.mediaKey)
        router.validateContext()
        XCTAssertEqual(pauseCompletions, 1)
        gate.release()
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(pauseCount, 0)
    }

    private func makePlaybackBinding(room: PlaybackRoom, positionMs: Int64,
                                     durationMs: Int64 = 100_000, seeking: Bool = false,
                                     sampleRate: Float = 1,
                                     loading: Bool = false, coherent: Bool = true,
                                     isCurrent: @escaping @MainActor () -> Bool = { true },
                                     issueSeek: @escaping @MainActor (Int64, WatchPartyPlayerStamp) async throws -> Void = { _, _ in }) -> PlaybackHarness {
        let engine = NSObject()
        let key = room.bindingState!.mediaKey
        let stamp = WatchPartyPlayerStamp(generation: 1, engineID: ObjectIdentifier(engine), mediaKey: key)
        let transports = TransportLog()
        let seekTargets = SeekTargetLog()
        let bridge = WatchPartyPlayerBridge(isCurrent: { _ = engine; return isCurrent() }, currentStamp: { stamp },
            issueSeek: { target, currentStamp in
                seekTargets.values.append(target)
                try await issueSeek(target, currentStamp)
            }, transport: { paused, rate, _ in
                transports.values.append((paused, rate))
                transports.onTransport?(paused, rate)
                return rate ?? 1
            })
        bridge.observe(WatchPartyPlayerSample(stamp: stamp, positionMs: positionMs, durationMs: durationMs,
                                              rate: sampleRate, paused: false, loading: loading, coherent: coherent,
                                              seeking: seeking))
        let binding = try! WatchPartyPlaybackBinding(room: room, bridge: bridge, isCurrent: isCurrent)
        return PlaybackHarness(binding: binding, bridge: bridge, transports: transports, seekTargets: seekTargets)
    }

    private struct PlaybackHarness {
        let binding: WatchPartyPlaybackBinding
        let bridge: WatchPartyPlayerBridge
        let transports: TransportLog
        let seekTargets: SeekTargetLog
    }

    @MainActor
    private final class TransportLog {
        var values: [(paused: Bool?, rate: Float?)] = []
        var onTransport: (@MainActor (Bool?, Float?) -> Void)?
    }

    @MainActor
    private final class SeekTargetLog {
        var values: [Int64] = []
    }

    @MainActor
    private final class PlaybackRoom: WatchPartyPlaybackRoom {
        struct Publication {
            let paused: Bool
            let positionMs: Int64
            let rate: Float
            let waiting: Bool
        }

        private var state: WatchPartyBindingRoomState
        var bindingState: WatchPartyBindingRoomState? { state }
        var published: [Publication] = []
        private var observers: [UUID: @MainActor () -> Void] = [:]

        init(hostOnly: Bool, memberID: String, hostMemberID: String?, playbackPositionMs: Int64,
             playbackRate: Float = 1) {
            let key = "movie|tt1||"
            let playback = WatchPartyPlayback(seq: 1, memberID: hostMemberID, paused: false,
                                              positionMs: playbackPositionMs, rate: playbackRate, at: 20_000,
                                              mediaKey: key, waiting: false)
            state = WatchPartyBindingRoomState(roomID: "room", memberID: memberID, mediaKey: key,
                                                hostMemberID: hostMemberID, hostOnly: hostOnly,
                                                connected: true, playback: playback)
        }

        func nowMs() -> Int64 { 20_000 }
        func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID {
            let id = UUID(); observers[id] = callback; return id
        }
        func removeChangeObserver(_ id: UUID) { observers[id] = nil }
        func publish(paused: Bool, positionMs: Int64, rate: Float, waiting: Bool) async throws {
            published.append(Publication(paused: paused, positionMs: positionMs, rate: rate, waiting: waiting))
        }
        func setPresence(status: WatchPartyMemberStatus, mediaKey: String?, behindMs: Int64?) async throws {}

        func receiveRemotePlayback(paused: Bool, seq: Int64, positionMs: Int64? = nil) {
            let previous = state
            let oldPlayback = previous.playback
            let playback = WatchPartyPlayback(seq: seq, memberID: oldPlayback?.memberID, paused: paused,
                                              positionMs: positionMs ?? oldPlayback?.positionMs ?? 0,
                                              rate: oldPlayback?.rate ?? 1, at: 20_000,
                                              mediaKey: previous.mediaKey, waiting: false)
            state = WatchPartyBindingRoomState(roomID: previous.roomID, memberID: previous.memberID,
                                                mediaKey: previous.mediaKey, hostMemberID: previous.hostMemberID,
                                                hostOnly: previous.hostOnly, connected: previous.connected,
                                                playback: playback)
            for callback in Array(observers.values) { callback() }
        }
    }

    private func makeSession(_ remote: Remote, channel: Channel, uptime: @escaping () -> TimeInterval,
                             sleep: @escaping WatchPartySession.Sleep) -> WatchPartySession {
        let context = WatchPartyRequestContext(backendIdentity: "https://party.example.test", userID: "user", profileID: "profile", epoch: UUID())
        return WatchPartySession(remote: remote, context: context, deviceID: "device", isCurrent: { _ in true },
                                 makeChannel: { channel }, clock: WatchPartyClock(uptime: uptime, wallTimeMs: { 20_000 }), sleep: sleep)
    }

    @MainActor
    private final class Gate {
        var onWait: (() -> Void)?
        private var continuation: CheckedContinuation<Void, Error>?
        func wait() async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertNil(self.continuation)
                self.continuation = continuation; onWait?()
            }
        }
        func release() { let current = continuation; continuation = nil; current?.resume() }
        func cancelAll() {
            let current = continuation; continuation = nil; onWait = nil
            current?.resume(throwing: CancellationError())
        }
    }

    @MainActor
    private final class Channel: WatchPartyChannel {
        var isConnected = false
        var receive: (@MainActor (WatchPartyChannelEvent) -> Void)?
        var onState: ((WatchPartyPlayback) -> Void)?
        var states: [WatchPartyPlayback] = []
        var stateRequestMemberIDs: [String] = []
        var failStateRequest = false
        func open(partyID: String, memberID: String, receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws {
            isConnected = true; self.receive = receive
        }
        func send(event: String, payload: Data) async throws {
            if event == "state_request" {
                if failStateRequest { throw WatchPartyChannelError.disconnected }
                let value = try JSONSerialization.jsonObject(with: payload) as? [String: String]
                stateRequestMemberIDs.append(value?["member_id"] ?? "")
            }
            if event == "state" {
                let state = try JSONDecoder().decode(WatchPartyPlayback.self, from: payload)
                states.append(state); onState?(state)
            }
        }
        func track(_ presence: WatchPartyPresence) async throws {}
        func refreshAuth() async throws {}
        func close() { isConnected = false }
    }

    @MainActor
    private final class Remote: WatchPartySessionRemote {
        var clockCalls = 0
        var failClockCall: Int?
        var onClock: ((Int) -> Void)?
        var hostMemberID = "me"
        var snapshot: WatchPartySnapshot {
            let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
            let state = WatchPartyPlayback(seq: 1, memberID: "me", paused: false, positionMs: 1_000, at: 20_000, mediaKey: media.key)
            return WatchPartySnapshot(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: hostMemberID, media: media, playback: state),
                                      members: [WatchPartyMember(id: "me", displayName: "Me"), WatchPartyMember(id: "other", displayName: "Other")], memberID: "me")
        }
        func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { snapshot }
        func clock() async throws -> Int64 {
            clockCalls += 1; onClock?(clockCalls)
            if clockCalls == failClockCall { throw WatchPartyAPIError.transport }
            return 20_000
        }
        func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot { WatchPartySnapshot(ok: true) }
        func update(partyID: String, deviceID: String, media: WatchPartyMedia?, playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot { snapshot }
    }
}
