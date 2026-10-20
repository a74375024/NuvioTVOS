/// AVKit start admission, separate from confirmed ownership of the floating window.
/// A failed or cancelled start must leave the fullscreen session mounted.
struct PlayerPiPStartState {
    private enum Phase { case idle, starting, active }
    private var phase: Phase = .idle

    var isStarting: Bool { phase == .starting }
    var isActive: Bool { phase == .active }
    var isInProgress: Bool { phase != .idle }

    @discardableResult
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    mutating func confirm() -> Bool {
        guard phase == .starting else { return false }
        phase = .active
        return true
    }

    mutating func fail() -> Bool {
        guard phase == .starting else { return false }
        phase = .idle
        return true
    }

    /// Returns whether a confirmed floating window actually owned playback.
    mutating func stop() -> Bool {
        let wasActive = isActive
        phase = .idle
        return wasActive
    }
}
