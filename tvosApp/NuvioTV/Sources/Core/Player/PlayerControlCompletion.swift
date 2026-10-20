import Foundation

/// Take the callback before invoking it: AVKit can synchronously re-enter during completion.
@MainActor
final class PlayerControlCompletion {
    private var callback: (@MainActor () -> Void)?
    init(_ callback: (@MainActor () -> Void)?) { self.callback = callback }
    func finish() { let callback = callback; self.callback = nil; callback?() }
}

/// Keeps AVKit skip callbacks releasable even if an engine/network operation returns late.
@MainActor
final class PlayerPiPRequests {
    private struct Request {
        let completion: PlayerControlCompletion
        let check: @MainActor () -> Bool?
        var appliedAt: TimeInterval?
    }
    private var pending: [UUID: Request] = [:]
    private let uptime: @MainActor () -> TimeInterval
    var count: Int { pending.count }

    init(uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }

    /// nil check = lost context; false = timebase settling. No timer: the owner's existing tick
    /// drives a maximum 2 s settling window after the engine receipt, never during native seek.
    func begin(_ callback: @escaping @MainActor () -> Void, check: @escaping @MainActor () -> Bool?)
        -> (applied: @MainActor () -> Void, finished: @MainActor () -> Void) {
        let id = UUID()
        let completion = PlayerControlCompletion(callback)
        pending[id] = Request(completion: completion, check: check)
        return (applied: { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            if self.pending[id]?.appliedAt == nil { self.pending[id]?.appliedAt = self.uptime() }
            self.evaluate(id)
        }, finished: { [weak self, completion] in
            guard let self, let request = self.pending[id] else { completion.finish(); return }
            if request.appliedAt == nil { self.finish(id) } else { self.evaluate(id) }
        })
    }

    func tick() { for id in Array(pending.keys) { evaluate(id) } }

    private func evaluate(_ id: UUID) {
        guard let request = pending[id] else { return }
        guard let coherent = request.check() else { finish(id); return }
        guard let appliedAt = request.appliedAt else { return }
        let now = uptime()
        if coherent || !now.isFinite || !appliedAt.isFinite || now < appliedAt || now - appliedAt >= 2 { finish(id) }
    }

    private func finish(_ id: UUID) { let request = pending.removeValue(forKey: id); request?.completion.finish() }

    func cancelAll() {
        let callbacks = pending.values.map { $0.completion }
        pending.removeAll()
        for callback in callbacks { callback.finish() }
    }
}
