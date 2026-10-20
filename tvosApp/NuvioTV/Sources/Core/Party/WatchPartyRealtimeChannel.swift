import Foundation
import Realtime

/// Dedicated SDK client per attempt; no second Auth client or app-lifecycle observer.
@MainActor
final class WatchPartyRealtimeChannel: WatchPartyChannel {
    private var client: RealtimeClientV2?
    private var channel: RealtimeChannelV2?
    private var observers: [Task<Void, Never>] = []
    private var generation = UUID()
    private var used = false
    private let configuration: ServerConfiguration
    private let context: WatchPartyRequestContext
    private let sessionProvider: WatchPartyAPI.SessionProvider
    private let isCurrent: WatchPartyAPI.ContextValidator

    init(configuration: ServerConfiguration, context: WatchPartyRequestContext,
         sessionProvider: @escaping WatchPartyAPI.SessionProvider,
         isCurrent: @escaping WatchPartyAPI.ContextValidator) {
        self.configuration = configuration
        self.context = context
        self.sessionProvider = sessionProvider
        self.isCurrent = isCurrent
    }

    var isConnected: Bool {
        isCurrent(context) && client?.status == .connected && channel?.status == .subscribed
    }

    func open(partyID: String, memberID: String,
              receive: @escaping @MainActor (WatchPartyChannelEvent) -> Void) async throws {
        guard !used, isCurrent(context), configuration.backendIdentity == context.backendIdentity,
              !partyID.isEmpty, !memberID.isEmpty else { throw WatchPartyAPIError.staleContext }
        used = true
        let url = try WatchPartyChannelContract.realtimeURL(configuration: configuration)
        let attempt = generation
        let context = self.context
        let provider = sessionProvider
        let validator = isCurrent
        let options = RealtimeClientOptions(
            headers: ["apikey": configuration.publishableKey],
            // SDK counts the first subscribe as an attempt: 1 means one try, no join retry loop.
            maxRetryAttempts: 1,
            vsn: .v1,
            // Watch Party must never fall back to HTTP for a gesture racing disconnect.
            fetch: { _ in throw WatchPartyChannelError.disconnected },
            accessToken: {
                try Task.checkCancellation()
                guard await validator(context) else { throw WatchPartyAPIError.staleContext }
                let session = await provider()
                try Task.checkCancellation()
                guard await validator(context) else { throw WatchPartyAPIError.staleContext }
                guard let session, session.userId == context.userID, !session.accessToken.isEmpty,
                      session.backendIdentity == context.backendIdentity
                        || (session.backendIdentity == nil && context.backendIdentity == ServerDiscoveryPolicy.officialBackend)
                else { throw WatchPartyAPIError.signInRequired }
                return session.accessToken
            },
            handleAppLifecycle: false
        )
        let client = RealtimeClientV2(url: url, options: options)
        let created = client.channel("watch-party:\(partyID)") {
            $0.isPrivate = true
            $0.broadcast.receiveOwnBroadcasts = false
            $0.broadcast.acknowledgeBroadcasts = false
            $0.presence.key = memberID
        }
        self.client = client
        channel = created
        // Register every stream synchronously before subscribing.
        for event in WatchPartyChannelContract.events {
            let stream = created.broadcastStream(event: event)
            observers.append(Task { [weak self] in
                for await object in stream {
                    guard let self, self.generation == attempt, self.isCurrent(context), !Task.isCancelled else { return }
                    guard let payload = try? JSONEncoder().encode(object) else { continue }
                    receive(.message(name: event, payload: payload))
                }
            })
        }
        let presence = created.presenceChange()
        observers.append(Task { [weak self] in
            for await action in presence {
                guard let self, self.generation == attempt, self.isCurrent(context), !Task.isCancelled else { return }
                let joins = action.joins.mapValues { value in
                    (try? value.decodeState(as: WatchPartyPresence.self)) ?? WatchPartyPresence(memberID: "")
                }
                receive(.presence(joins: joins, leaves: Set(action.leaves.keys)))
            }
        })
        let statuses = client.statusChange
        observers.append(Task { [weak self] in
            var connectedOnce = false
            for await status in statuses {
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                if status == .connected { connectedOnce = true }
                else if connectedOnce {
                    // Clear buffer and discard this client before the session retries.
                    self.close()
                    receive(.disconnected)
                    return
                }
            }
        })
        let channelStatuses = created.statusChange
        observers.append(Task { [weak self] in
            var subscribedOnce = false
            for await status in channelStatuses {
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                if status == .subscribed { subscribedOnce = true }
                else if subscribedOnce {
                    self.close()
                    receive(.disconnected)
                    return
                }
            }
        })
        do {
            try await created.subscribeWithError()
            try Task.checkCancellation()
            guard generation == attempt, isConnected else { throw WatchPartyChannelError.disconnected }
        } catch {
            if generation == attempt { close() }
            if error is CancellationError { throw error }
            throw WatchPartyChannelError.disconnected
        }
    }

    func send(event: String, payload: Data) async throws {
        guard WatchPartyChannelContract.events.contains(event),
              let object = try? JSONDecoder().decode(JSONObject.self, from: payload) else {
            throw WatchPartyChannelError.invalidPayload
        }
        // Use raw JSONObject overload: no asynchronous encoding between guard and SDK admission.
        guard let channel, isConnected, !Task.isCancelled else { throw WatchPartyChannelError.disconnected }
        let attempt = generation
        await channel.broadcast(event: event, message: object)
        guard generation == attempt, isConnected, !Task.isCancelled else { throw WatchPartyChannelError.disconnected }
    }

    func track(_ presence: WatchPartyPresence) async throws {
        let object = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(presence))
        guard let channel, isConnected, !Task.isCancelled else { throw WatchPartyChannelError.disconnected }
        let attempt = generation
        await channel.track(state: object)
        guard generation == attempt, isConnected, !Task.isCancelled else { throw WatchPartyChannelError.disconnected }
    }

    func refreshAuth() async throws {
        let attempt = generation
        guard isConnected, let client else { throw WatchPartyChannelError.disconnected }
        let session = await sessionProvider()
        try Task.checkCancellation()
        guard generation == attempt, isCurrent(context), isConnected else { throw WatchPartyAPIError.staleContext }
        guard let session, session.userId == context.userID, !session.accessToken.isEmpty,
              session.backendIdentity == context.backendIdentity
                || (session.backendIdentity == nil && context.backendIdentity == ServerDiscoveryPolicy.officialBackend)
        else { throw WatchPartyAPIError.signInRequired }
        await client.setAuth(session.accessToken)
        guard generation == attempt, isConnected else { throw WatchPartyChannelError.disconnected }
    }

    func close() {
        generation = UUID()
        observers.forEach { $0.cancel() }
        observers.removeAll()
        client?.disconnect()
        channel = nil
        client = nil
    }
}
