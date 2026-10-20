import Foundation

// Waiting semantics adapted from PartyRepository.kt, NuvioMedia/NuvioTV (GPL-3.0), f7e2a78.
enum WatchPartyWaitingDecision: Equatable {
    case pause(positionMs: Int64)
    case resume(positionMs: Int64)
}

/// Pure state owned by the session's single coordinator task. No timer or player is created here.
struct WatchPartyWaitingCoordinator {
    static let tickNanoseconds: UInt64 = 500_000_000
    static let resumeGrace: TimeInterval = 3
    static let waitLimit: TimeInterval = 15
    private(set) var ignoredMemberIDs: Set<String> = []
    private var waitingSince: TimeInterval?
    private var resumedAt: TimeInterval?

    mutating func reset() { self = WatchPartyWaitingCoordinator() }
    mutating func disconnected() { waitingSince = nil }
    mutating func memberReady(_ id: String) { ignoredMemberIDs.remove(id) }
    mutating func retainMembers(_ ids: Set<String>) { ignoredMemberIDs.formIntersection(ids) }

    mutating func accepted(previous: WatchPartyPlayback?, next: WatchPartyPlayback,
                           mediaKey: String, presence: [String: WatchPartyPresence], uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        if let previous, previous.paused, !next.paused {
            resumedAt = uptime
            if previous.waiting {
                ignoredMemberIDs.formUnion(WatchPartyPolicy.waitingMemberIDs(mediaKey: mediaKey, presence: presence, ignored: []))
            }
        }
        if !next.waiting { waitingSince = nil }
        else if previous?.waiting != true { waitingSince = uptime }
    }

    mutating func decision(party: WatchPartyInfo, memberID: String, members: [WatchPartyMember],
                           presence: [String: WatchPartyPresence], playback: WatchPartyPlayback,
                           connected: Bool, uptime: TimeInterval, serverNowMs: Int64) -> WatchPartyWaitingDecision? {
        guard connected, uptime.isFinite,
              playback.mediaKey == nil || playback.mediaKey == party.media.key,
              WatchPartyPolicy.coordinatorID(memberID: memberID, hostMemberID: party.hostMemberID,
                                              hostOnly: party.hostOnly, members: members,
                                              onlineMemberIDs: Set(presence.keys)) == memberID else {
            waitingSince = nil
            return nil
        }
        let waiting = WatchPartyPolicy.waitingMemberIDs(mediaKey: party.media.key, presence: presence, ignored: ignoredMemberIDs)
        if !playback.paused {
            let graceOver = resumedAt.map { uptime >= $0 && uptime - $0 > Self.resumeGrace } ?? true
            guard !waiting.isEmpty, graceOver else { return nil }
            return .pause(positionMs: WatchPartyPolicy.expectedPosition(playback, nowMs: serverNowMs))
        }
        guard playback.waiting else { waitingSince = nil; return nil }
        if waitingSince == nil || uptime < (waitingSince ?? uptime) { waitingSince = uptime }
        let timedOut = uptime - (waitingSince ?? uptime) > Self.waitLimit
        return waiting.isEmpty || timedOut ? .resume(positionMs: playback.positionMs) : nil
    }
}
