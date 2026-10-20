import Foundation

/// Explicit UI intents only. Never feed engine observations or synchronization effects into this.
/// Admission failure is terminal for the gesture: no raw-player fallback and no offline queue.
@MainActor
final class WatchPartyControlRouter {
    enum Submission: Equatable { case accepted, busy, unavailable }
    private let perform: @MainActor (WatchPartyLocalIntent, (@MainActor () -> Void)?) async throws -> Void
    private let isCurrent: @MainActor () -> Bool
    private let currentStamp: @MainActor () -> WatchPartyPlayerStamp?
    private let readCanonicalRate: @MainActor () -> Float?
    var canonicalRate: Float? { readCanonicalRate() }
    private let suspend: @MainActor (Bool) -> Void
    private let onError: @MainActor (Error) -> Void
    private let onCompleted: @MainActor (WatchPartyLocalIntent) -> Void
    private var task: Task<Void, Never>?
    private var stopped = false
    private var suspended = false
    private var revision = UUID()
    private struct RunningControl {
        let id: UUID
        let stamp: WatchPartyPlayerStamp
        let completions: [PlayerControlCompletion]
    }
    private struct QueuedPause {
        let stamp: WatchPartyPlayerStamp
        var completions: [PlayerControlCompletion]
        var onApplied: [@MainActor () -> Void]
        var wantsReceipt: Bool
    }
    private var running: RunningControl?
    private var queuedPause: QueuedPause?

    init(isCurrent: @escaping @MainActor () -> Bool,
         currentStamp: @escaping @MainActor () -> WatchPartyPlayerStamp?,
         canonicalRate: @escaping @MainActor () -> Float? = { nil },
         perform: @escaping @MainActor (WatchPartyLocalIntent, (@MainActor () -> Void)?) async throws -> Void,
         suspend: @escaping @MainActor (Bool) -> Void = { _ in },
         onError: @escaping @MainActor (Error) -> Void = { _ in },
         onCompleted: @escaping @MainActor (WatchPartyLocalIntent) -> Void = { _ in }) {
        self.isCurrent = isCurrent; self.currentStamp = currentStamp
        self.readCanonicalRate = canonicalRate
        self.perform = perform; self.suspend = suspend
        self.onError = onError; self.onCompleted = onCompleted
    }

    @discardableResult
    func submit(_ intent: WatchPartyLocalIntent, completion: (@MainActor () -> Void)? = nil,
                onApplied: (@MainActor () -> Void)? = nil) -> Submission {
        let finished = PlayerControlCompletion(completion)
        guard !stopped, !suspended else {
            onError(WatchPartyPlaybackBindingError.notReady)
            finished.finish()
            return .unavailable
        }
        guard isCurrent(), let stamp = currentStamp() else {
            validateContext()
            onError(WatchPartyPlaybackBindingError.notReady)
            finished.finish()
            return .unavailable
        }
        validateContext()
        guard task == nil else {
            if case .pause = intent, running?.stamp == stamp {
                if var queued = queuedPause, queued.stamp == stamp {
                    queued.completions.append(finished)
                    if let onApplied { queued.onApplied.append(onApplied) }
                    queued.wantsReceipt = queued.wantsReceipt || completion != nil || onApplied != nil
                    queuedPause = queued
                } else {
                    clearQueuedPause()
                    queuedPause = QueuedPause(stamp: stamp, completions: [finished],
                                              onApplied: onApplied.map { [$0] } ?? [],
                                              wantsReceipt: completion != nil || onApplied != nil)
                }
                return .accepted
            }
            onError(WatchPartyPlaybackBindingError.busy)
            finished.finish()
            return .busy
        }
        start(intent, stamp: stamp, completions: [finished],
              onApplied: onApplied.map { [$0] } ?? [], wantsReceipt: completion != nil || onApplied != nil)
        return .accepted // Enqueued, NOT confirmation that engine or network succeeded.
    }

    private func start(_ intent: WatchPartyLocalIntent, stamp: WatchPartyPlayerStamp,
                       completions: [PlayerControlCompletion], onApplied: [@MainActor () -> Void],
                       wantsReceipt: Bool) {
        let mark = revision
        let id = UUID()
        running = RunningControl(id: id, stamp: stamp, completions: completions)
        task = Task { [weak self] in
            guard let self else { completions.forEach { $0.finish() }; return }
            defer {
                self.task = nil
                if self.running?.id == id { self.running = nil }
                completions.forEach { $0.finish() }
                self.startQueuedPauseIfPossible()
            }
            do {
                try Task.checkCancellation()
                guard self.permitted(mark, stamp: stamp) else { throw WatchPartyPlaybackBindingError.staleOperation }
                let applied: (@MainActor () -> Void)?
                if wantsReceipt {
                    applied = { [weak self, completions] in
                        guard let self, self.running?.id == id, self.permitted(mark, stamp: stamp) else { return }
                        for callback in onApplied { callback() }
                        // Engine receipt, not eventual room RPC confirmation.
                        completions.forEach { $0.finish() }
                    }
                } else {
                    applied = nil
                }
                try await self.perform(intent, applied)
                try Task.checkCancellation()
                guard self.permitted(mark, stamp: stamp) else { return }
                self.onCompleted(intent)
            } catch {
                if self.permitted(mark, stamp: stamp), !(error is CancellationError) { self.onError(error) }
            }
        }
    }

    private func permitted(_ mark: UUID, stamp: WatchPartyPlayerStamp) -> Bool {
        !stopped && !suspended && revision == mark && isCurrent() && currentStamp() == stamp
    }

    /// Reuse the VM tick; no additional timer. Context/source loss releases native waiters.
    func validateContext() {
        let runningIsStale = running.map { !isCurrent() || currentStamp() != $0.stamp } ?? false
        let queuedIsStale = queuedPause.map { !isCurrent() || currentStamp() != $0.stamp } ?? false
        guard runningIsStale || queuedIsStale else { return }
        revision = UUID()
        task?.cancel()
        finishRunning()
        clearQueuedPause()
    }

    private func finishRunning() {
        let completions = running?.completions ?? []
        running = nil
        completions.forEach { $0.finish() }
    }

    private func clearQueuedPause() {
        let completions = queuedPause?.completions ?? []
        queuedPause = nil
        completions.forEach { $0.finish() }
    }

    private func startQueuedPauseIfPossible() {
        guard task == nil, !stopped, !suspended, let queued = queuedPause else { return }
        queuedPause = nil
        guard isCurrent(), currentStamp() == queued.stamp else {
            queued.completions.forEach { $0.finish() }
            return
        }
        start(.pause, stamp: queued.stamp, completions: queued.completions,
              onApplied: queued.onApplied, wantsReceipt: queued.wantsReceipt)
    }

    /// Revoke effects before the lifecycle caller parks the engine. Never publishes a user pause.
    func setSuspended(_ value: Bool) {
        guard !stopped, suspended != value else { return }
        suspended = value
        revision = UUID()
        task?.cancel() // Keep its slot until the cancelled async operation actually returns.
        suspend(value)
        finishRunning()
        clearQueuedPause()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision = UUID()
        task?.cancel()
        finishRunning()
        clearQueuedPause()
    }
}
