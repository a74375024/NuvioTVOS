import Foundation

struct WatchPartyPlayerStamp: Equatable {
    let generation: UInt64
    let engineID: ObjectIdentifier
    let mediaKey: String
}

struct WatchPartyPlayerSample: Equatable {
    let stamp: WatchPartyPlayerStamp
    let positionMs: Int64
    let durationMs: Int64
    let rate: Float
    let paused: Bool
    let loading: Bool
    let coherent: Bool
    let seeking: Bool
    var rendered: Bool = true
    var failed: Bool = false
}

enum WatchPartyEffectOrigin: Equatable { case localUser, remoteRoom, drift, waiting, lifecycle }
enum WatchPartyPlayerBridgeError: Error, Equatable {
    case notReady, busy, staleOperation, timedOut, invalidRate, unsupportedRate, alreadyAttached
}

struct WatchPartyPlayerEffect {
    let paused: Bool
    let rate: Float
    var seekToMs: Int64? = nil
}

struct WatchPartyPlayerReceipt {
    let origin: WatchPartyEffectOrigin
    let stamp: WatchPartyPlayerStamp
    let confirmedSeekPositionMs: Int64?
    let appliedRate: Float
}

/// An execution boundary, not room policy. The future binding admits local intents / publishes
/// receipts; remote/drift/waiting effects must never be republished merely because a sample changes.
/// No transport to a room, timer polling, progress import or preference writes live here.
@MainActor
final class WatchPartyPlayerBridge {
    typealias Sleep = @MainActor (UInt64) async throws -> Void
    typealias Transport = @MainActor (_ paused: Bool?, _ rate: Float?, _ stamp: WatchPartyPlayerStamp) throws -> Float

    private struct PendingSeek {
        let id: UUID
        let stamp: WatchPartyPlayerStamp
        let target: Int64
        var issuedSampleID: UUID
        let continuation: CheckedContinuation<WatchPartyPlayerSample, Error>
        let isAdmitted: @MainActor () -> Bool
        var engineReturned = false
    }

    var onSample: (@MainActor (WatchPartyPlayerSample) -> Void)?
    private(set) var sample: WatchPartyPlayerSample?
    private(set) var isApplyingTemporaryRate = false
    private var baseRate: (stamp: WatchPartyPlayerStamp, rate: Float)?
    private var sampleID = UUID()
    private var stopped = false
    private var effectID: UUID?
    private var pending: PendingSeek?
    private var issueTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let contextIsCurrent: @MainActor () -> Bool
    private let currentStamp: @MainActor () -> WatchPartyPlayerStamp?
    private let issueSeek: @MainActor (Int64, WatchPartyPlayerStamp) async throws -> Void
    private let transport: Transport
    private let sleep: Sleep
    private let rateLimit: @MainActor () -> Float

    var isSeeking: Bool { pending != nil }
    var awaitsSeekSample: Bool { pending?.engineReturned == true }

    init(isCurrent: @escaping @MainActor () -> Bool,
         currentStamp: @escaping @MainActor () -> WatchPartyPlayerStamp?,
         issueSeek: @escaping @MainActor (Int64, WatchPartyPlayerStamp) async throws -> Void,
         transport: @escaping Transport,
         maximumRate: @escaping @MainActor () -> Float = { 4 },
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        self.contextIsCurrent = isCurrent
        self.currentStamp = currentStamp
        self.issueSeek = issueSeek
        self.transport = transport
        self.rateLimit = maximumRate
        self.sleep = sleep
    }

    /// Feed the already-refreshed, generation-checked VM sample. Never refresh the engine here.
    func observe(_ value: WatchPartyPlayerSample) {
        guard !stopped else { return }
        guard contextIsCurrent(), currentStamp() == value.stamp else {
            finishSeek(.failure(WatchPartyPlayerBridgeError.staleOperation))
            sample = nil
            return
        }
        if sample?.stamp != value.stamp {
            finishSeek(.failure(WatchPartyPlayerBridgeError.staleOperation))
            baseRate = nil
            isApplyingTemporaryRate = false
        }
        if let pending, !pending.isAdmitted() {
            finishSeek(.failure(WatchPartyPlayerBridgeError.staleOperation))
        }
        sampleID = UUID()
        sample = value
        confirmSeekIfPossible()
        onSample?(value)
    }

    /// Serial compound operation: pause → seek confirmation → rate and final play/pause.
    /// The origin is preserved for admission/publication by the future binding, not inferred from UI state.
    func apply(_ effect: WatchPartyPlayerEffect, origin: WatchPartyEffectOrigin,
               isPauseOnly: Bool = false,
               isAdmitted: @escaping @MainActor () -> Bool = { true }) async throws -> WatchPartyPlayerReceipt {
        try Task.checkCancellation()
        guard effect.rate.isFinite, (0.25...4).contains(effect.rate) else { throw WatchPartyPlayerBridgeError.invalidRate }
        guard effectID == nil else { throw WatchPartyPlayerBridgeError.busy }
        guard let initial = sample else { throw WatchPartyPlayerBridgeError.notReady }
        let pauseOnly = isPauseOnly && effect.paused && effect.seekToMs == nil
        guard pauseOnly ? !initial.failed : (initial.coherent && !initial.loading) else {
            throw WatchPartyPlayerBridgeError.notReady
        }
        try validate(initial.stamp)
        let maximum = rateLimit()
        guard maximum.isFinite, effect.rate <= maximum + 0.001 else { throw WatchPartyPlayerBridgeError.unsupportedRate }
        guard isAdmitted() else { throw WatchPartyPlayerBridgeError.staleOperation }
        let id = UUID()
        effectID = id
        defer { if effectID == id { effectID = nil } }
        clearTemporaryRate()
        var confirmed: Int64?
        if let target = effect.seekToMs {
            guard initial.durationMs > 0 else { throw WatchPartyPlayerBridgeError.notReady }
            _ = try transport(true, nil, initial.stamp)
            let bounded = min(max(0, target), max(0, initial.durationMs - 1))
            confirmed = try await seek(to: bounded, stamp: initial.stamp, isAdmitted: isAdmitted).positionMs
        }
        try Task.checkCancellation()
        try validate(initial.stamp)
        guard isAdmitted() else { throw WatchPartyPlayerBridgeError.staleOperation }
        let applied = try transport(effect.paused, effect.rate, initial.stamp)
        try validate(initial.stamp)
        guard isAdmitted(), applied.isFinite, applied > 0 else { throw WatchPartyPlayerBridgeError.staleOperation }
        baseRate = (initial.stamp, applied)
        isApplyingTemporaryRate = false
        return WatchPartyPlayerReceipt(origin: origin, stamp: initial.stamp,
                                       confirmedSeekPositionMs: confirmed, appliedRate: applied)
    }

    /// Temporary drift correction never becomes a user preference or the canonical room rate.
    @discardableResult
    func setTemporaryRate(_ rate: Float) throws -> Float {
        guard rate.isFinite, (0.25...4).contains(rate) else { throw WatchPartyPlayerBridgeError.invalidRate }
        guard effectID == nil, let sample, sample.coherent, !sample.loading,
              sample.rate.isFinite, sample.rate > 0 else { throw WatchPartyPlayerBridgeError.notReady }
        try validate(sample.stamp)
        if baseRate?.stamp != sample.stamp { baseRate = (sample.stamp, sample.rate) }
        let maximum = rateLimit()
        guard maximum.isFinite, maximum >= 0.25 else { throw WatchPartyPlayerBridgeError.unsupportedRate }
        let bounded = min(rate, maximum)
        if abs(sample.rate - bounded) <= 0.001 { return sample.rate }
        let applied = try transport(nil, bounded, sample.stamp)
        isApplyingTemporaryRate = true
        return applied
    }

    func clearTemporaryRate() {
        guard isApplyingTemporaryRate else { return }
        isApplyingTemporaryRate = false
        if let baseRate, !stopped, contextIsCurrent(), currentStamp() == baseRate.stamp {
            _ = try? transport(nil, baseRate.rate, baseRate.stamp)
        }
    }

    /// Called before resource shutdown, source teardown, or replacing the binding.
    func stop() {
        guard !stopped else { return }
        clearTemporaryRate()
        stopped = true
        onSample = nil
        sample = nil
        finishSeek(.failure(WatchPartyPlayerBridgeError.staleOperation))
    }

    private func validate(_ stamp: WatchPartyPlayerStamp) throws {
        guard !stopped, contextIsCurrent(), currentStamp() == stamp else {
            throw WatchPartyPlayerBridgeError.staleOperation
        }
    }

    private func seek(to target: Int64, stamp: WatchPartyPlayerStamp,
                      isAdmitted: @escaping @MainActor () -> Bool) async throws -> WatchPartyPlayerSample {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = PendingSeek(id: id, stamp: stamp, target: target,
                                      issuedSampleID: sampleID, continuation: continuation, isAdmitted: isAdmitted)
                timeoutTask = Task { [weak self, sleep] in
                    do { try await sleep(10_000_000_000) } catch { return }
                    guard !Task.isCancelled, let self, self.pending?.id == id else { return }
                    self.finishSeek(.failure(WatchPartyPlayerBridgeError.timedOut))
                }
                issueTask = Task { [weak self, issueSeek] in
                    do {
                        guard self?.pending?.id == id, isAdmitted() else {
                            throw WatchPartyPlayerBridgeError.staleOperation
                        }
                        try self?.validate(stamp)
                        try Task.checkCancellation()
                        try await issueSeek(target, stamp)
                        guard !Task.isCancelled, let self, self.pending?.id == id else { return }
                        try self.validate(stamp)
                        self.pending?.engineReturned = true
                        // Require a sample taken AFTER the engine call returned, never a cached
                        // observation that happened while the command was still being issued.
                        self.pending?.issuedSampleID = self.sampleID
                        self.confirmSeekIfPossible()
                    } catch {
                        guard let self, self.pending?.id == id else { return }
                        self.finishSeek(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                self.finishSeek(.failure(CancellationError()))
            }
        }
    }

    private func confirmSeekIfPossible() {
        guard let pending, pending.engineReturned, let sample,
              pending.isAdmitted(),
              sampleID != pending.issuedSampleID, sample.stamp == pending.stamp,
              sample.coherent, !sample.loading, !sample.seeking,
              WatchPartyTimeMath.distance(sample.positionMs, pending.target) <= 500 else { return }
        finishSeek(.success(sample))
    }

    private func finishSeek(_ result: Result<WatchPartyPlayerSample, Error>) {
        guard let pending else { return }
        self.pending = nil
        timeoutTask?.cancel(); timeoutTask = nil
        issueTask?.cancel(); issueTask = nil
        pending.continuation.resume(with: result)
    }
}
