import Foundation

/// Correlates MPV's completed playback restart with the requested playlist
/// entry. Reading an event on MPV's serial queue does not make its later UI
/// callback current after a replacement load or lifecycle suspension.
final class MPVFirstFrameReadiness {
    private let lock = NSLock()
    private var generation = UUID()
    private var playlistEntryID: Int64?
    private var ready = false

    var token: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    func reset(keepingPlaylistEntry: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        ready = false
        if !keepingPlaylistEntry { playlistEntryID = nil }
    }

    func arm(playlistEntryID: Int64?) {
        lock.lock(); defer { lock.unlock() }
        self.playlistEntryID = playlistEntryID
    }

    func matches(token: UUID, playlistEntryID: Int64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation && playlistEntryID != nil && playlistEntryID == self.playlistEntryID
    }

    /// A restart is meaningful for video readiness only with a configured
    /// video frame. Transport pause and container duration are not evidence.
    func receiveRestart(token: UUID, playlistEntryID: Int64?, hasVideoFrame: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == generation,
              let playlistEntryID, playlistEntryID == self.playlistEntryID,
              hasVideoFrame, !ready else { return false }
        ready = true
        return true
    }
}
