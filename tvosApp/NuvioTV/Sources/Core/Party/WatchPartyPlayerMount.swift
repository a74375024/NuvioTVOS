import Foundation

/// A checked pairing of owner and model. Construct at a launch/restore transition outside body.
/// SwiftUI must use a stable identity for this runtime, and a new identity for a new runtime.
@MainActor
struct WatchPartyPlayerMount {
    private let runtime: WatchPartyPlayerRuntime
    private let lease: WatchPartyPlayerRuntime.Lease
    private let onDetached: (@MainActor () -> Void)?

    var viewModel: PlayerViewModel { lease.resource }
    var isCurrent: Bool { runtime.isCurrent(lease) }

    init(runtime: WatchPartyPlayerRuntime, lease: WatchPartyPlayerRuntime.Lease,
         onDetached: (@MainActor () -> Void)? = nil) throws {
        guard runtime.isCurrent(lease) else { throw WatchPartyPlaybackRuntimeError.staleLease }
        self.runtime = runtime
        self.lease = lease
        self.onDetached = onDetached
    }

    func attach() throws -> (surface: WatchPartyPlayerRuntime.Surface, startsLoad: Bool) {
        let surface = try runtime.attachFullscreen(lease)
        return (surface, try runtime.claimInitialLoad(surface))
    }

    @discardableResult
    func detach(_ surface: WatchPartyPlayerRuntime.Surface) -> Bool {
        let pip = PictureInPictureManager.shared
        let keepsPlayback = pip.activeCoordinator === viewModel.sessionCoordinator
            && (pip.isPictureInPictureActive || pip.isRestoringUIInProgress)
        let detached = runtime.detachFullscreen(surface, keepingPictureInPicture: keepsPlayback)
        if detached && !runtime.isCurrent(lease) { onDetached?() }
        return detached
    }

    func finish() {
        if runtime.finish(lease) { onDetached?() }
    }
}

extension WatchPartyPlaybackRuntime where Resource == PlayerViewModel {
    /// The app root must retain this owner and invalidate it before account/profile/backend changes.
    static func player(isCurrent: @escaping @MainActor (WatchPartyPlaybackContext) -> Bool) -> WatchPartyPlayerRuntime {
        WatchPartyPlayerRuntime(isCurrent: isCurrent, stopResource: { $0.shutdownForWatchParty() })
    }

    /// A fresh launch explicitly creates its own coordinator, bypassing ambient PiP adoption.
    func beginPlayer(context: WatchPartyPlaybackContext) throws -> Lease {
        try begin(context: context) {
            PlayerViewModel(sessionCoordinator: PlaybackSessionCoordinator(), adoptsPictureInPictureSession: false)
        }
    }

    /// Compose the accepted room with the same runtime/model. The runtime retains binding cleanup.
    /// Root still must install onNeedsMedia and complete system/PiP controls before activation.
    func bindPlayback(_ lease: Lease, room: WatchPartySession) throws -> WatchPartyPlaybackBinding {
        let ownerIsCurrent = try makeValidator(for: lease)
        let context = lease.context
        guard room.playbackContext == context else {
            throw WatchPartyPlaybackBindingError.staleOperation
        }
        let valid: @MainActor () -> Bool = { [weak room] in
            guard ownerIsCurrent(), let current = room?.playbackContext else { return false }
            return current.request == context.request && current.membershipID == context.membershipID
                && current.roomID == context.roomID && current.memberID == context.memberID
        }
        let model = lease.resource
        let bridge = try model.attachWatchPartyPlayerBridge(media: room.party?.media, isCurrent: valid)
        do {
            let binding = try WatchPartyPlaybackBinding(room: room, bridge: bridge, isCurrent: valid)
            do {
                try model.attachWatchPartyControls(binding: binding, isCurrent: valid)
                try ownBinding(lease) { [weak model] in
                    binding.stop()
                    model?.detachWatchPartyPlayerBridge()
                }
            } catch { binding.stop(); throw error }
            return binding
        } catch { model.detachWatchPartyPlayerBridge(); throw error }
    }
}
