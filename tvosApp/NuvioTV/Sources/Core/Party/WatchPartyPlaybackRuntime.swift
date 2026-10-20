import Foundation

/// Capture a new membershipID after each accepted create/join, even for the same room/member.
/// A source reload keeps this identity; an episode/media change requires explicit teardown.
struct WatchPartyPlaybackContext: Equatable, Sendable {
    let request: WatchPartyRequestContext
    let membershipID: UUID
    let roomID: String
    let memberID: String
    let mediaKey: String
}

enum WatchPartyPlaybackRuntimeError: Error, Equatable {
    case alreadyActive, staleContext, staleLease, bindingAlreadyOwned
}

/// Resource is PlayerViewModel in production (which itself owns the engine coordinator).
/// The generic resource allows lifecycle tests without creating a player or opening a source.
/// The app root must retain one instance and call invalidate BEFORE profile/backend transitions.
/// This owner does not join/leave rooms, resolve sources, start timers or send playback commands.
@MainActor
final class WatchPartyPlaybackRuntime<Resource: AnyObject> {
    struct Lease {
        fileprivate let ownerID: UUID
        fileprivate let id: UUID
        let context: WatchPartyPlaybackContext
        let resource: Resource
    }

    struct Surface {
        fileprivate let ownerID: UUID
        fileprivate let runtimeID: UUID
        fileprivate let id: UUID
        /// Informational only; claimInitialLoad is the gate before starting a load.
        let isFirstAttachment: Bool
    }

    enum Phase: Equatable { case idle, prepared, fullscreen, pictureInPicture }
    private(set) var phase: Phase = .idle
    /// Root uses identity only to close a resource when its accepted room/media disappears.
    var currentContext: WatchPartyPlaybackContext? { active?.context }
    private let ownerID = UUID()
    private var revision = UUID()
    private var creating = false
    private var invalidating = false
    private var active: Lease?
    private var surfaceID: UUID?
    private var hasAttached = false
    private var initialLoadClaimed = false
    private var stopBinding: (@MainActor () -> Void)?
    private let contextIsCurrent: @MainActor (WatchPartyPlaybackContext) -> Bool
    private let stopResource: @MainActor (Resource) -> Void

    init(isCurrent: @escaping @MainActor (WatchPartyPlaybackContext) -> Bool,
         stopResource: @escaping @MainActor (Resource) -> Void) {
        self.contextIsCurrent = isCurrent
        self.stopResource = stopResource
    }

    /// Call at an explicit launch transition, never from a SwiftUI body.
    /// Factory runs once and cannot silently replace a still-owned player.
    func begin(context: WatchPartyPlaybackContext,
               makeResource: @MainActor () -> Resource) throws -> Lease {
        guard active == nil, !creating, !invalidating else { throw WatchPartyPlaybackRuntimeError.alreadyActive }
        guard contextIsCurrent(context) else { throw WatchPartyPlaybackRuntimeError.staleContext }
        let mark = revision
        creating = true
        defer { creating = false }
        let resource = makeResource()
        // A synchronous factory can re-enter the root and invalidate its context.
        guard revision == mark, contextIsCurrent(context) else {
            stopResource(resource)
            throw WatchPartyPlaybackRuntimeError.staleContext
        }
        let lease = Lease(ownerID: ownerID, id: UUID(), context: context, resource: resource)
        active = lease
        phase = .prepared
        return lease
    }

    /// Restore by exact identity, not URL. Rejoining the same room cannot adopt an old player.
    func restore(context: WatchPartyPlaybackContext) throws -> Lease {
        guard contextIsCurrent(context) else { throw WatchPartyPlaybackRuntimeError.staleContext }
        guard let active, active.context == context else { throw WatchPartyPlaybackRuntimeError.staleLease }
        return active
    }

    /// Check again after every resolver/engine await before applying a completion.
    func isCurrent(_ lease: Lease) -> Bool {
        lease.ownerID == ownerID && active?.id == lease.id
            && contextIsCurrent(lease.context)
    }

    /// Capture identity without retaining lease.resource inside a callback owned by that resource.
    func makeValidator(for lease: Lease) throws -> (@MainActor () -> Bool) {
        try validate(lease)
        let id = lease.id, owner = lease.ownerID, context = lease.context
        return { [weak self] in
            guard let self else { return false }
            return self.ownerID == owner && self.active?.id == id && self.contextIsCurrent(context)
        }
    }

    /// A new surface supersedes the old surface token. Its late onDisappear becomes inert.
    /// This does not perform the PiP manager's actual surface-rebind handshake.
    func attachFullscreen(_ lease: Lease) throws -> Surface {
        try validate(lease)
        let id = UUID()
        let result = Surface(ownerID: ownerID, runtimeID: lease.id, id: id,
                             isFirstAttachment: !hasAttached)
        surfaceID = id
        hasAttached = true
        phase = .fullscreen
        return result
    }

    /// Claim immediately before invoking the synchronous VM load entry point.
    /// If a surface disappears before claiming, its replacement can still start the load.
    /// Retries/source changes after this claim belong to the same model, not a second launch.
    func claimInitialLoad(_ surface: Surface) throws -> Bool {
        guard surface.ownerID == ownerID, let active, active.id == surface.runtimeID,
              surfaceID == surface.id, isCurrent(active) else {
            throw WatchPartyPlaybackRuntimeError.staleLease
        }
        guard !initialLoadClaimed else { return false }
        initialLoadClaimed = true
        return true
    }

    /// Adopt an already-running player without letting its first Watch Party surface call load().
    func markInitialLoadClaimed(_ lease: Lease) throws {
        try validate(lease)
        initialLoadClaimed = true
    }

    @discardableResult
    func detachFullscreen(_ surface: Surface, keepingPictureInPicture: Bool) -> Bool {
        guard surface.ownerID == ownerID, active?.id == surface.runtimeID,
              surfaceID == surface.id, let active else { return false }
        // Teardown must still work after external context invalidation.
        if !contextIsCurrent(active.context) {
            invalidate()
        } else if keepingPictureInPicture {
            surfaceID = nil
            phase = .pictureInPicture
        } else {
            invalidate()
        }
        return true
    }

    /// Bind exactly once per runtime. The cleanup must cancel tasks/observers before shutdown.
    /// Never capture the runtime strongly in a cleanup owned by the runtime itself.
    func ownBinding(_ lease: Lease, stop: @escaping @MainActor () -> Void) throws {
        try validate(lease)
        guard stopBinding == nil else { throw WatchPartyPlaybackRuntimeError.bindingAlreadyOwned }
        stopBinding = stop
    }

    @discardableResult
    func finish(_ lease: Lease) -> Bool {
        guard lease.ownerID == ownerID, active?.id == lease.id else { return false }
        invalidate()
        return true
    }

    /// Roll back an incomplete adoption while preserving a resource that was already playing
    /// outside the runtime. Once a presentation is published, normal invalidation owns shutdown.
    func abandon(_ lease: Lease) {
        guard lease.ownerID == ownerID, active?.id == lease.id else { return }
        invalidate(stopResource: false)
    }

    /// Clear identity before invoking callbacks so old completions cannot stop a successor.
    /// Explicit owner teardown is required; no asynchronous deinit cleanup.
    func invalidate() { invalidate(stopResource: true) }

    private func invalidate(stopResource shouldStopResource: Bool) {
        guard !invalidating else { return }
        invalidating = true
        defer { invalidating = false }
        revision = UUID()
        let resource = active?.resource
        let cleanup = stopBinding
        active = nil
        stopBinding = nil
        surfaceID = nil
        hasAttached = false
        initialLoadClaimed = false
        phase = .idle
        cleanup?()
        if shouldStopResource, let resource { stopResource(resource) }
    }

    private func validate(_ lease: Lease) throws {
        guard isCurrent(lease) else { throw WatchPartyPlaybackRuntimeError.staleLease }
    }
}

/// Create the model with an explicitly supplied PlaybackSessionCoordinator so an unrelated
/// PictureInPictureManager.activeCoordinator cannot be adopted at a fresh Party launch.
/// The opt-in PlayerView mount can consume this owner; app root and party binding are still pending.
typealias WatchPartyPlayerRuntime = WatchPartyPlaybackRuntime<PlayerViewModel>
