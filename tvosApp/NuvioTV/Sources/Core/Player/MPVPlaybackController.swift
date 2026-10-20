import Foundation
import UIKit
import AVFoundation
import AVKit
import MediaPlayer
import CoreGraphics
import Libmpv
import Metal
import QuartzCore
import Combine
import AetherEngine

struct MPVHTTPHeaderOptions: Equatable {
    let userAgent: String
    let referrer: String
    let headerFields: String

    init(headers: [String: String]) {
        userAgent = Self.value(for: "user-agent", in: headers) ?? "libmpv"
        referrer = Self.value(for: "referer", "referrer", in: headers) ?? ""

        headerFields = headers
            .filter { key, value in
                !key.isEmpty && !value.isEmpty && !Self.isReserved(key)
            }
            .sorted {
                let lhs = $0.key.lowercased()
                let rhs = $1.key.lowercased()
                return lhs == rhs ? $0.value < $1.value : lhs < rhs
            }
            .map { key, value in
                "\(key): \(value)"
                    .replacingOccurrences(of: ",", with: "\\,")
            }
            .joined(separator: ",")
    }

    private static func value(for names: String..., in headers: [String: String]) -> String? {
        for name in names {
            if let value = headers.first(where: {
                $0.key.caseInsensitiveCompare(name) == .orderedSame && !$0.value.isEmpty
            })?.value {
                return value
            }
        }
        return nil
    }

    private static func isReserved(_ key: String) -> Bool {
        ["user-agent", "referer", "referrer"].contains {
            key.caseInsensitiveCompare($0) == .orderedSame
        }
    }
}

/// MPV exposes an external subtitle filename for applicable tracks, but this
/// bridge does not expose a complete parsed cue list. `sub-text` is therefore
/// the only safe input here: translate one active cue at a time while the host
/// overlay keeps the original visible until the response arrives.
@MainActor
final class MPVSubtitleTranslationState: ObservableObject {
    typealias TranslationRequest = (
        String, AISubtitleTranslationSettings, AISubtitleRequestPacer
    ) async throws -> String

    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText: String?
    @Published private(set) var isTranslating = false

    var onFirstOutcome: ((Result<Void, Error>) -> Void)?

    private var tasks: [String: Task<Void, Never>] = [:]
    private var translatedTextBySource: [String: String] = [:]
    private var currentSource: String?
    private var currentSettings: AISubtitleTranslationSettings?
    private var sessionID = UUID()
    private var manualActivation = false
    private var didReportSuccess = false
    private var didReportFailure = false
    private var failedSourceTexts: Set<String> = []
    private var hasPermanentProviderFailure = false
    private var needsReevaluation = false
    private let maximumConcurrentRequests = 2
    let requestPacer: AISubtitleRequestPacer
    private let requestTranslation: TranslationRequest

    init(
        requestPacer: AISubtitleRequestPacer = .shared,
        requestTranslation: @escaping TranslationRequest = { source, settings, pacer in
            try await AISubtitleTranslator.translate(source, settings: settings, pacer: pacer)
        }
    ) {
        self.requestPacer = requestPacer
        self.requestTranslation = requestTranslation
    }

    var isActive: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled && !settings.apiKey.isEmpty && (settings.autoSelect || manualActivation)
    }

    var shouldDisplayOverlay: Bool {
        isActive && !sourceText.isEmpty
    }

    var displayText: String? {
        guard shouldDisplayOverlay else { return nil }
        return translatedText ?? sourceText
    }

    func setManualActivation(_ enabled: Bool) {
        manualActivation = enabled
        refreshForCurrentText()
    }

    func update(sourceText rawText: String) {
        update(sourceText: rawText, settings: AISubtitleTranslationSettings.current())
    }

    func update(sourceText rawText: String, settings: AISubtitleTranslationSettings) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Empty `sub-text` is normal between cues and for streams without
            // subtitles. Never validate credentials or show an AI toast for it.
            if !settings.isEnabled
                || settings.apiKey.isEmpty
                || !(settings.autoSelect || manualActivation)
                || currentSettings != settings {
                deactivate()
            } else {
                sourceText = ""
                currentSource = nil
                translatedText = nil
                isTranslating = false
            }
            return
        }
        guard settings.isEnabled else {
            deactivate()
            return
        }
        guard !settings.apiKey.isEmpty else {
            deactivate()
            report(.failure(AISubtitleTranslationError.missingAPIKey))
            return
        }
        guard settings.autoSelect || manualActivation else {
            deactivate()
            return
        }
        if currentSettings != settings {
            tasks.values.forEach { $0.cancel() }
            tasks = [:]
            translatedTextBySource = [:]
            failedSourceTexts = []
            hasPermanentProviderFailure = false
            sessionID = UUID()
            currentSettings = settings
            sourceText = ""
            currentSource = nil
            needsReevaluation = false
        }
        guard text != sourceText || needsReevaluation else { return }
        needsReevaluation = false
        sourceText = text
        translatedText = nil
        isTranslating = false
        currentSource = nil

        guard !text.isEmpty else { return }
        let source = AISubtitleTranslationState.cleaned(
            text,
            stripHearingImpaired: settings.stripHearingImpaired
        )
        currentSource = source
        guard !source.isEmpty else {
            translatedText = ""
            return
        }
        if let cached = translatedTextBySource[source] {
            translatedText = cached
            return
        }
        if tasks[source] != nil {
            isTranslating = true
            return
        }
        guard !hasPermanentProviderFailure else { return }
        guard !failedSourceTexts.contains(source) else { return }

        if tasks.count >= maximumConcurrentRequests,
           let staleSource = tasks.keys.first(where: { $0 != source }) {
            tasks[staleSource]?.cancel()
            tasks[staleSource] = nil
        }
        guard tasks.count < maximumConcurrentRequests else { return }
        translate(source: source, settings: settings)
    }

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        translatedTextBySource = [:]
        currentSource = nil
        currentSettings = nil
        sessionID = UUID()
        sourceText = ""
        translatedText = nil
        isTranslating = false
        manualActivation = false
        didReportSuccess = false
        didReportFailure = false
        failedSourceTexts = []
        hasPermanentProviderFailure = false
        needsReevaluation = false
    }

    /// Seeking invalidates in-flight results without dropping the visible
    /// source cue. The next `sub-text` refresh starts fresh work for it.
    func cancelPendingTranslations() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        sessionID = UUID()
        currentSource = nil
        translatedText = nil
        isTranslating = false
        needsReevaluation = true
    }

    private func translate(source: String, settings: AISubtitleTranslationSettings) {
        let activeSession = sessionID
        let profileScope = ProfileSettings.activeProfileScope
        let translationRequest = requestTranslation
        let pacer = requestPacer
        isTranslating = currentSource == source
        tasks[source] = Task { [weak self] in
            do {
                if let cached = await AISubtitleTranslationCache.shared.translation(
                    for: source,
                    targetLanguage: settings.targetLanguage,
                    model: settings.cacheModelIdentifier,
                    stripHearingImpaired: settings.stripHearingImpaired,
                    profileScope: profileScope
                ) {
                    guard !Task.isCancelled,
                          let self,
                          self.sessionID == activeSession else { return }
                    self.tasks[source] = nil
                    self.translatedTextBySource[source] = cached
                    self.refreshCurrentPresentation()
                    self.report(.success(()))
                    return
                }
                let translated = try await translationRequest(source, settings, pacer)
                let cleaned = AISubtitleTranslationState.cleaned(
                    translated,
                    stripHearingImpaired: settings.stripHearingImpaired
                )
                await AISubtitleTranslationCache.shared.store(
                    cleaned,
                    for: source,
                    targetLanguage: settings.targetLanguage,
                    model: settings.cacheModelIdentifier,
                    stripHearingImpaired: settings.stripHearingImpaired,
                    profileScope: profileScope
                )
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.tasks[source] = nil
                self.translatedTextBySource[source] = cleaned
                self.refreshCurrentPresentation()
                self.report(.success(()))
            } catch is CancellationError {
                guard let self, self.sessionID == activeSession else { return }
                self.tasks[source] = nil
                self.refreshCurrentPresentation()
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.tasks[source] = nil
                self.failedSourceTexts.insert(source)
                if (error as? AISubtitleTranslationError)?.isPermanentLimitError == true {
                    self.hasPermanentProviderFailure = true
                    self.tasks.values.forEach { $0.cancel() }
                    self.tasks = [:]
                }
                self.refreshCurrentPresentation()
                self.report(.failure(error))
            }
        }
    }

    private func refreshForCurrentText() {
        guard manualActivation || AISubtitleTranslationSettings.current().autoSelect else {
            deactivate()
            return
        }
        // Route through an empty sentinel so the unchanged active MPV text is
        // reconsidered immediately after the user enables it in the panel.
        let current = sourceText
        sourceText = ""
        currentSource = nil
        update(sourceText: current)
    }

    private func deactivate() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        translatedTextBySource = [:]
        currentSource = nil
        currentSettings = nil
        sessionID = UUID()
        sourceText = ""
        translatedText = nil
        isTranslating = false
        failedSourceTexts = []
        hasPermanentProviderFailure = false
        needsReevaluation = false
    }

    private func refreshCurrentPresentation() {
        guard let currentSource else {
            translatedText = nil
            isTranslating = false
            return
        }
        translatedText = translatedTextBySource[currentSource]
        isTranslating = tasks[currentSource] != nil
    }

    private func report(_ outcome: Result<Void, Error>) {
        switch outcome {
        case .success where !didReportSuccess:
            didReportSuccess = true
            onFirstOutcome?(outcome)
        case .failure where !didReportFailure:
            didReportFailure = true
            onFirstOutcome?(outcome)
        default:
            break
        }
    }
}

/// State that must be committed after MPV has opened the replacement file.
/// Keeping this as data also makes fallback restoration independently testable.
struct MPVLoadConfiguration: Equatable {
    let resumePositionMs: Int64?
    let externalSubtitles: [NuvioSubtitle]
    let playbackRate: Float
    let subtitleDelaySeconds: Double
    let audioDelaySeconds: Double
    let audioGainDB: Double
    let autoplay: Bool
    let preferredAudioLanguages: [String]

    init(request: PlaybackLoadRequest) {
        resumePositionMs = request.resumePositionSeconds.map { Int64(max(0, $0) * 1_000) }
        externalSubtitles = request.externalSubtitles
        playbackRate = request.playbackRate
        subtitleDelaySeconds = request.subtitleDelaySeconds
        audioDelaySeconds = request.audioDelaySeconds
        audioGainDB = request.audioGainDB
        autoplay = request.autoplay
        preferredAudioLanguages = request.preferredAudioLanguages
    }
}

struct PlaybackThumbnailSourceContext: Sendable, Equatable {
    let contextID = UUID()
    let generation: UInt64
    let playbackURL: URL?
    let headerSourceURL: URL?
    let requestHeaders: [String: String]
    let isLive: Bool
    let isKnownHLS: Bool
    let streamKey: String
}

/// Request-wide cancellation plus one replaceable bounded-probe cancellation. A timed-out cache
/// stage can finish and a fresh source stage can still run; superseded work cancels both.
final class PlaybackThumbnailRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let request = ProbeCancellation()
    private var stage: ProbeCancellation?

    var isCancelled: Bool { request.isCancelled }

    func beginStage() -> ProbeCancellation? {
        lock.lock()
        defer { lock.unlock() }
        guard !request.isCancelled else { return nil }
        let cancellation = ProbeCancellation()
        stage = cancellation
        return cancellation
    }

    func finishStage(_ cancellation: ProbeCancellation) {
        lock.lock()
        if stage === cancellation { stage = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        request.cancel()
        stage?.cancel()
        stage = nil
        lock.unlock()
    }
}

/// Shared bounded disk-cache and original-source fallback used by both playback backends.
/// Callers retain their own request/generation checks and image index.
enum PlaybackThumbnailSourceFallback {
    private static let cacheLimits = ProbeLimits(
        maxInputBytes: 32 * 1024 * 1024, maxPackets: 1_024,
        maxPacketBytes: 8 * 1024 * 1024, timeBudget: 1)
    private static let sourceLimits = ProbeLimits(
        maxInputBytes: 64 * 1024 * 1024, maxPackets: 2_048,
        maxPacketBytes: 8 * 1024 * 1024, timeBudget: 2)

    @MainActor
    static func boundedSnapshot(
        sourceContext: PlaybackThumbnailSourceContext,
        atSeconds seconds: Double,
        maxWidth: Int,
        cancellation: PlaybackThumbnailRequestCancellation,
        isCurrent: @MainActor () -> Bool
    ) async -> BoundedStillFrame? {
        guard seconds.isFinite, maxWidth > 0, !sourceContext.isLive, !sourceContext.isKnownHLS,
              isCurrent(), let playbackURL = sourceContext.playbackURL else { return nil }

        let descriptor = await PlaybackStreamCacheManager.shared.thumbnailSource(for: playbackURL)
        guard isCurrent(), !cancellation.isCancelled else { return nil }
        let originURL = descriptor?.remoteURL ?? sourceContext.headerSourceURL ?? playbackURL
        guard !isKnownHLSURL(originURL), supportsIndependentPreview(originURL) else { return nil }

        if let descriptor {
            let reader = PlaybackStreamCacheIOReader(source: descriptor)
            guard let stage = cancellation.beginStage() else {
                reader.close()
                return nil
            }
            let extractor = FrameExtractor(reader: reader)
            let still = await boundedSnapshot(
                extractor, seconds: seconds, maxWidth: maxWidth, limits: cacheLimits, cancellation: stage)
            cancellation.finishStage(stage)
            reader.close()
            guard isCurrent(), !cancellation.isCancelled else { return nil }
            if isAccurate(still, requestedSeconds: seconds) { return still }
        } else if isCacheProxyURL(playbackURL) {
            // A loopback cache URL is usable only while its exact active server descriptor exists.
            return nil
        }

        guard isCurrent(), !cancellation.isCancelled,
              let stage = cancellation.beginStage() else { return nil }
        let extractor = FrameExtractor(url: originURL, httpHeaders: descriptor?.originalHeaders ?? sourceContext.requestHeaders)
        let still = await boundedSnapshot(
            extractor, seconds: seconds, maxWidth: maxWidth, limits: sourceLimits, cancellation: stage)
        cancellation.finishStage(stage)
        guard isCurrent(), !cancellation.isCancelled,
              isAccurate(still, requestedSeconds: seconds) else { return nil }
        return still
    }

    @MainActor
    private static func boundedSnapshot(
        _ extractor: FrameExtractor,
        seconds: Double,
        maxWidth: Int,
        limits: ProbeLimits,
        cancellation: ProbeCancellation
    ) async -> BoundedStillFrame? {
        let width = CGFloat(maxWidth)
        let result = await extractor.boundedSnapshot(
            at: seconds,
            maxSize: CGSize(width: width, height: width),
            limits: limits,
            cancellation: cancellation,
            relativeToPresentationStart: true
        )
        await extractor.shutdown()
        return result
    }

    static func isAccurate(_ still: BoundedStillFrame?, requestedSeconds: Double) -> Bool {
        guard let actualSeconds = still?.actualSeconds, actualSeconds.isFinite,
              requestedSeconds.isFinite else { return false }
        return abs(actualSeconds - requestedSeconds) <= HybridSeekThumbnailPolicy.maximumPreviewTimeError
    }

    static func isKnownHLSURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
            || url.absoluteString.localizedCaseInsensitiveContains(".m3u8")
            || url.host?.localizedCaseInsensitiveContains("googlevideo.com") == true
    }

    static func isCacheProxyURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
        return url.path.hasPrefix("/stream/")
    }

    private static func supportsIndependentPreview(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme),
              !isCacheProxyURL(url), !isKnownHLSURL(url) else { return false }
        return !["iso", "img", "udf"].contains(url.pathExtension.lowercased())
    }
}

// MARK: - MPV Player View Controller (tvOS)
//
// Self-contained libmpv host. Ported from the iOS bridge, with the Kotlin/
// Compose plumbing and iOS-only UIViewController overrides (home indicator,
// status-bar, screen-edge gestures — none exist on tvOS) removed.

final class MPVPlayerViewController: UIViewController, PlaybackEngineControlling, ScrubThumbnailProviding {
    /// Synchronously revoke Party control admission before parking the engine.
    var onWillSuspendPlayback: (() -> Void)?
    /// Lifecycle reattachment has been requested; visual readiness still
    /// requires a fresh MPV playback restart and a coherent state sample.
    var onDidRestorePlayback: (() -> Void)?
    /// Called after a coherent position is captured but before tvOS suspends
    /// the player. PlayerViewModel uses it for a durable lifecycle save.
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?

    // MARK: - Trickplay & Seek Previews
    private let hybridThumbnailIndex = HybridSeekThumbnailIndex()
    private var externalTrickplayProvider: (any TrickplayProviding)?
    private var loadGeneration: UInt64 = 0
    private let firstFrameReadiness = MPVFirstFrameReadiness()
    // Accessed only on eventQueue; copy the ID before hopping to the UI queue.
    private var eventPlaylistEntryID: Int64?
    private var contentCanonicalKey: String?
    private var currentStreamKey: String = ""
    private var thumbnailSourceContext: PlaybackThumbnailSourceContext?
    private var thumbnailIndexResetTask: Task<Void, Never>?
    private var thumbnailRequestSequence: UInt64 = 0
    private var activeThumbnailCancellation: PlaybackThumbnailRequestCancellation?
    private var activeThumbnailTask: Task<CGImage?, Never>?
    private var activeThumbnailTaskRequestID: UInt64?
    private var externalProviderGeneration: UInt64 = 0

    var supportsScrubThumbnails: Bool { true }

    func setExternalTrickplayProvider(_ provider: (any TrickplayProviding)?) {
        cancelScrubThumbnailWork()
        externalProviderGeneration &+= 1
        let providerGeneration = externalProviderGeneration
        let generation = loadGeneration
        self.externalTrickplayProvider = provider
        let resetTask = thumbnailIndexResetTask
        Task { [weak self] in
            await resetTask?.value
            guard let self,
                  self.loadGeneration == generation,
                  self.externalProviderGeneration == providerGeneration else { return }
            await self.hybridThumbnailIndex.setExternalTrickplayProvider(provider)
        }
    }

    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage? {
        let generation = loadGeneration
        let requestID = beginScrubThumbnailRequest()
        let providerGeneration = externalProviderGeneration
        if let external = externalTrickplayProvider {
            let image = await external.thumbnail(at: seconds)
            guard isCurrentScrubThumbnailRequest(
                requestID, generation: generation, providerGeneration: providerGeneration) else { return nil }
            if let image {
                return image
            }
        }
        let image = await hybridThumbnailIndex.lookup(
            seconds: seconds,
            duration: duration,
            generation: generation
        )
        guard isCurrentScrubThumbnailRequest(
            requestID, generation: generation, providerGeneration: providerGeneration) else { return nil }
        return image
    }

    func scrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int = 360,
        precise: Bool = true
    ) async -> CGImage? {
        let generation = loadGeneration
        let sourceContext = thumbnailSourceContext
        let previousTask = activeThumbnailTask
        let requestID = beginScrubThumbnailRequest()
        let providerGeneration = externalProviderGeneration
        let cancellation = PlaybackThumbnailRequestCancellation()
        activeThumbnailCancellation = cancellation
        let duration = durationMs > 0 ? Double(durationMs) / 1000.0 : 3600.0
        let work: Task<CGImage?, Never> = Task { @MainActor [weak self, previousTask] in
            _ = await previousTask?.value
            guard let self,
                  self.isCurrentScrubThumbnailRequest(
                    requestID, generation: generation, providerGeneration: providerGeneration,
                    cancellation: cancellation) else { return nil }
            return await withTaskCancellationHandler {
                await self.generateScrubThumbnail(
                    atSeconds: seconds,
                    maxWidth: maxWidth,
                    duration: duration,
                    generation: generation,
                    requestID: requestID,
                    providerGeneration: providerGeneration,
                    sourceContext: sourceContext,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
        }
        activeThumbnailTask = work
        activeThumbnailTaskRequestID = requestID
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
        if activeThumbnailTaskRequestID == requestID {
            activeThumbnailTask = nil
            activeThumbnailTaskRequestID = nil
        }
        if thumbnailRequestSequence == requestID,
           activeThumbnailCancellation === cancellation {
            activeThumbnailCancellation = nil
        }
        return result
    }

    private func generateScrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int,
        duration: Double,
        generation: UInt64,
        requestID: UInt64,
        providerGeneration: UInt64,
        sourceContext: PlaybackThumbnailSourceContext?,
        cancellation: PlaybackThumbnailRequestCancellation
    ) async -> CGImage? {
        guard seconds.isFinite, maxWidth > 0,
              isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        if let external = externalTrickplayProvider {
            let image = await external.thumbnail(at: seconds)
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation) else { return nil }
            if let image {
                return image
            }
        }
        let cached = await hybridThumbnailIndex.lookup(
            seconds: seconds,
            duration: duration,
            generation: generation
        )
        guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        if let cached { return cached }
        guard let sourceContext,
              sourceContext.generation == generation else { return nil }
        let still = await PlaybackThumbnailSourceFallback.boundedSnapshot(
            sourceContext: sourceContext,
            atSeconds: seconds,
            maxWidth: maxWidth,
            cancellation: cancellation,
            isCurrent: {
                self.isCurrentScrubThumbnailRequest(
                    requestID, generation: generation, providerGeneration: providerGeneration,
                    cancellation: cancellation)
            })
        guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        return await storePreviewIfCurrent(
            still, requestedSeconds: seconds, generation: generation,
            requestID: requestID, providerGeneration: providerGeneration, cancellation: cancellation)
    }

    private func storePreviewIfCurrent(
        _ still: BoundedStillFrame?,
        requestedSeconds: Double,
        generation: UInt64,
        requestID: UInt64,
        providerGeneration: UInt64,
        cancellation: PlaybackThumbnailRequestCancellation
    ) async -> CGImage? {
        guard let still,
              let actualSeconds = still.actualSeconds,
              actualSeconds.isFinite,
              abs(actualSeconds - requestedSeconds) <= HybridSeekThumbnailPolicy.maximumPreviewTimeError,
              isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        await hybridThumbnailIndex.store(
            still.image, seconds: actualSeconds, kind: .fine, generation: generation)
        guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        return still.image
    }

    private func beginScrubThumbnailRequest() -> UInt64 {
        thumbnailRequestSequence &+= 1
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        activeThumbnailCancellation = nil
        return thumbnailRequestSequence
    }

    private func isCurrentScrubThumbnailRequest(
        _ requestID: UInt64,
        generation: UInt64,
        providerGeneration: UInt64,
        cancellation: PlaybackThumbnailRequestCancellation? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              thumbnailRequestSequence == requestID,
              loadGeneration == generation,
              externalProviderGeneration == providerGeneration else { return false }
        if let cancellation {
            guard !cancellation.isCancelled, activeThumbnailCancellation === cancellation else { return false }
        }
        if let thumbnailSourceContext {
            guard thumbnailSourceContext.generation == generation else { return false }
        }
        return true
    }

    private func cancelScrubThumbnailWork() {
        thumbnailRequestSequence &+= 1
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        activeThumbnailCancellation = nil
    }

    private func resetScrubThumbnailSource(
        playbackURL: URL?,
        headerSourceURL: URL? = nil,
        headers: [String: String],
        isLive: Bool,
        streamKey: String,
        canonicalMediaKey: String?,
        isKnownHLS: Bool = false
    ) {
        cancelScrubThumbnailWork()
        loadGeneration &+= 1
        externalProviderGeneration &+= 1
        externalTrickplayProvider = nil
        contentCanonicalKey = canonicalMediaKey
        currentStreamKey = streamKey
        let generation = loadGeneration
        thumbnailSourceContext = PlaybackThumbnailSourceContext(
            generation: generation,
            playbackURL: playbackURL,
            headerSourceURL: headerSourceURL,
            requestHeaders: headers,
            isLive: isLive,
            isKnownHLS: isLive || isKnownHLS
                || PlaybackThumbnailSourceFallback.isKnownHLSURL(playbackURL)
                || PlaybackThumbnailSourceFallback.isKnownHLSURL(headerSourceURL),
            streamKey: streamKey
        )
        let index = hybridThumbnailIndex
        let resetTask = Task { await index.reset(generation: generation, streamKey: streamKey) }
        thumbnailIndexResetTask = resetTask
    }

    func prepareScrubThumbnailExtractor() {
        // External storyboards/BIF are resolved asynchronously via TrickplayResolver
    }

    func suspendCoarseThumbnailWork() {
        // No heavy background decoding in MPV
    }

    func advanceCoarseThumbnailIfNeeded(duration: Double) {
        // Handled via HybridSeekThumbnailIndex disk and storyboard lookup
    }

    private static let defaultAudioOutput = "avfoundation"

    private let errorStateLock = NSLock()
    private var metalLayer = MPVMetalLayer()
    private(set) var currentAspectMode: PlayerAspectMode = .fit
    private var lastAppliedDrawableSize: CGSize = .zero
    private var pendingURL: String?
    private var pendingAudioURL: String?
    private var pendingHTTPHeaders: [String: String] = [:]
    private var pendingIsLiveStream = false
    private var pendingLoadConfiguration: MPVLoadConfiguration?
    private var currentMediaTitle: String?
    private var currentMediaArtist: String?
    #if os(tvOS) || os(iOS)
    private var currentMediaArtwork: MPMediaItemArtwork?
    private var artworkLoadTask: Task<Void, Never>?
    #endif
    private var didConfigureMPVRemoteCommands = false
    private let remoteCommandTargets = PlayerRemoteCommandTargets()
    private var watchPartyRemoteIntent: (@MainActor (PlayerRemoteIntent) -> Bool)?

    func setWatchPartyRemoteIntent(_ handler: (@MainActor (PlayerRemoteIntent) -> Bool)?) {
        let rebind = didConfigureMPVRemoteCommands
        if rebind { teardownMPVRemoteCommands() }
        watchPartyRemoteIntent = handler
        if rebind { setupMPVRemoteCommandsIfNeeded() }
    }

    func stopWatchPartyRemoteCommands() {
        watchPartyRemoteIntent = { _ in false }
        teardownMPVRemoteCommands()
    }
    /// Physical Apple TV can blank HDMI while matching frame rate / dynamic
    /// range. Keep the file paused until that switch finishes so playback time
    /// cannot advance behind the black screen.
    private var startupDisplayGateActive = false
    private var pendingAutoplayAfterDisplayGate = false
    private var mpv: OpaquePointer?
    private lazy var eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    private var recentPlaybackLogs: [String] = []
    private enum DesiredTrackSelection {
        case trackID(Int)
        case externalURL(String)
    }
    private struct PendingTrackCommand {
        let loadGeneration: UInt64
        let command: String
        let url: String
        let selectionGeneration: UInt64
        let selectsWhenReady: Bool
    }
    private let pendingTrackCommandsLock = NSLock()
    private var pendingTrackCommands: [UInt64: PendingTrackCommand] = [:]
    private var nextTrackCommandReplyID: UInt64 = 1
    private var subtitleSelectionGeneration: UInt64 = 0
    private var desiredSubtitleSelection: DesiredTrackSelection?
    private var audioSelectionGeneration: UInt64 = 0
    private var desiredAudioSelection: DesiredTrackSelection?
    let subtitleTranslationState = MPVSubtitleTranslationState()
    private var isMPVSubtitleRendererHiddenForTranslation = false

    // MARK: - Seek Watchdog Diagnostics
    private struct ActiveSeekWatchdog {
        let id: Int
        let targetMs: Int64
        let initialPositionMs: Int64
        let startTime: CFAbsoluteTime
        var seekingStartTime: CFAbsoluteTime?
        var seekingEndTime: CFAbsoluteTime?
        var cacheWaitStartTime: CFAbsoluteTime?
        var totalCacheWaitDuration: Double = 0
        var reported = false
    }
    private var activeSeekWatchdog: ActiveSeekWatchdog?
    private var seekWatchdogSequence: Int = 0
    private var isLocalOrDiskCacheStream: Bool = false
    private var pendingCacheProfile: PlaybackCacheProfile = .auto
    private var mpvPacketCacheDirectory: URL?
    private var mpvPacketDiskCacheAvailable = false
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    private let memoryWatchdog = MPVMemoryWatchdog()
    private var memoryDiagnosticSessionID = UUID().uuidString
    private var memoryDiagnosticCacheMode = "setup"
    private var lastMemoryEngineSampleTime: CFAbsoluteTime = 0
#endif

    var currentSubtitleText: String? {
        if let subText = getString("sub-text"), !subText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subText
        }
        if !subtitleTranslationState.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subtitleTranslationState.sourceText
        }
        return nil
    }

    // Cached track lists
    var audioTracks: [PlaybackTrackInfo] = []
    var subtitleTracks: [PlaybackTrackInfo] = []

    // State (polled from the view model every 250ms)
    var onFirstFrameReady: (() -> Void)?
    var isPlayerLoading: Bool = true
    var loadingStepMessage: String? {
        isPlayerLoading ? L10n.string("player_loading_buffering", fallback: "Buffering…") : nil
    }
    var isPlayerPlaying: Bool = false
    var isTransportPlaying: Bool { isPlayerPlaying }
    var isPlayerEnded: Bool = false
    private(set) var isAtEndOfFile: Bool = false
    private(set) var hasCoherentTimeSample: Bool = false
    var hasFirstFrameReadyForDisplay: Bool {
        firstFrameReadiness.isReady && !isPlayerLoading
    }
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1.0
    var currentErrorMessage: String {
        errorStateLock.lock(); defer { errorStateLock.unlock() }
        return _currentErrorMessage ?? ""
    }
    private var _currentErrorMessage: String?
    private var _didReachCleanEndOfFile = false
    private var didReachCleanEndOfFile: Bool {
        errorStateLock.lock(); defer { errorStateLock.unlock() }
        return _didReachCleanEndOfFile
    }

    // tvOS detaches video while another app is frontmost. Freeze the last
    // coherent time until MPV has reattached and sought back to it; otherwise
    // keep-open can briefly expose its last frame as time-pos == duration.
    private var isApplicationBackgrounded = false
    private var wasPlayingBeforeBackground = false
    private var lifecyclePositionMs: Int64?
    private var lifecycleDurationMs: Int64?
    /// Independent of the UI-facing position, which MPV can overwrite with the
    /// final frame just before tvOS delivers didEnterBackground.
    private var lastVerifiedPositionMs: Int64?
    private var lastVerifiedDurationMs: Int64?
    private var lastVerifiedWasPlaying = false
    private var foregroundRestoreTargetMs: Int64?
    private var foregroundRestoreDeadline: Date?
    private var lifecycleRestoreFailed = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        // `.resize` lets mpv own letterboxing/cropping via panscan/keepaspect.
        // `.resizeAspect` would re-letterbox after mpv already rendered.
        metalLayer.contentsGravity = .resize
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryDiagnosticCacheMode = "setup"
        memoryWatchdog.start(
            sessionID: memoryDiagnosticSessionID,
            cacheMode: memoryDiagnosticCacheMode,
            event: "mpv_setup_begin"
        )
#endif
        setupMpv()
        setupNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
        attemptStartPendingLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attemptStartPendingLoad()
    }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let scale = UIScreen.main.nativeScale
        let drawableSize = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        if drawableSize != lastAppliedDrawableSize {
            metalLayer.drawableSize = drawableSize
            lastAppliedDrawableSize = drawableSize
        }
        CATransaction.commit()
    }

    // MARK: - MPV Setup

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else {
            print("[MPV] Failed to create mpv instance")
            isPlayerLoading = false
            setPlaybackError("MPV could not create a playback instance.")
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
            memoryWatchdog.record(event: "mpv_create_failed")
#endif
            return
        }

        MPVStreamProtocolBridge.register(on: mpv)
        mpvPacketCacheDirectory = PlaybackCacheSettings.prepareMPVPacketCacheDirectory()

        checkError(mpv_request_log_messages(mpv, "warn"))

        var windowID = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &windowID))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "ao", Self.defaultAudioOutput))
        // AVSampleBufferAudioRenderer follows tvOS's active output route without
        // using the failing RemoteIO callback from MPV's AudioUnit backend.
        checkError(mpv_set_option_string(mpv, "audio-channels", "auto-safe"))
        // AVFoundation accepts interleaved PCM; packed float preserves decoded
        // precision while supporting route-selected stereo or multichannel audio.
        checkError(mpv_set_option_string(mpv, "audio-format", "float"))
        // Headroom for the Audio → Amplification control (+10 dB ≈ 316%).
        checkError(mpv_set_option_string(mpv, "volume-max", "400"))
        // Do not silently replace a failed audio renderer with `ao=null` and
        // continue as video-only playback.
        checkError(mpv_set_option_string(mpv, "audio-fallback-to-null", "no"))

        // Keep MPV's native RAM cache bounded; the network-cache profile sets
        // the remote disk-cache readahead window at each load.
        let cache = PlaybackCacheSettings(forwardBuffer: "32MiB", backBuffer: "16MiB")
        checkError(mpv_set_option_string(mpv, "cache", "yes"), context: "cache")
        var packetCacheOptionStatuses = [CInt]()
        if let packetCacheDirectory = mpvPacketCacheDirectory {
            packetCacheOptionStatuses.append(mpv_set_option_string(mpv, "demuxer-cache-dir", packetCacheDirectory.path))
            packetCacheOptionStatuses.append(mpv_set_option_string(mpv, "demuxer-cache-unlink-files", "immediate"))
            packetCacheOptionStatuses.append(mpv_set_option_string(mpv, "cache-on-disk", "yes"))
        } else {
            packetCacheOptionStatuses.append(mpv_set_option_string(mpv, "cache-on-disk", "no"))
        }
        for (index, status) in packetCacheOptionStatuses.enumerated() {
            let option = mpvPacketCacheDirectory == nil
                ? "cache-on-disk"
                : ["demuxer-cache-dir", "demuxer-cache-unlink-files", "cache-on-disk"][index]
            checkError(status, context: option)
        }
        mpvPacketDiskCacheAvailable = mpvPacketCacheDirectory != nil && packetCacheOptionStatuses.allSatisfy { $0 >= 0 }
        if !mpvPacketDiskCacheAvailable {
            let disableStatus = mpv_set_option_string(mpv, "cache-on-disk", "no")
            checkError(disableStatus, context: "cache-on-disk=no fallback")
            print("[MPVCache] Native packet cache unavailable during setup; using bounded RAM fallback when needed")
        }
        // ~2 minutes of readahead intent; demuxer-max-bytes still hard-caps RAM.
        checkError(mpv_set_option_string(mpv, "cache-secs", "120"), context: "cache-secs")
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "120"), context: "demuxer-readahead-secs")
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", cache.forwardBuffer), context: "demuxer-max-bytes")
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", cache.backBuffer), context: "demuxer-max-back-bytes")
        checkError(mpv_set_option_string(mpv, "vd-lavc-threads", "3"), context: "vd-lavc-threads")
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"), context: "video-rotate")
        checkError(mpv_set_option_string(mpv, "hr-seek", "no"), context: "hr-seek")
        checkError(mpv_set_option_string(mpv, "hr-seek-framedrop", "yes"), context: "hr-seek-framedrop")
        checkError(mpv_set_option_string(mpv, "demuxer-seekable-cache", "yes"), context: "demuxer-seekable-cache")
        checkError(mpv_set_option_string(mpv, "demuxer-mkv-subtitle-preroll", "yes"), context: "demuxer-mkv-subtitle-preroll")
        checkError(mpv_set_option_string(mpv, "demuxer-mkv-subtitle-preroll-secs", "2"), context: "demuxer-mkv-subtitle-preroll-secs")
        checkError(mpv_set_option_string(mpv, "sub-fix-timing", "no"), context: "sub-fix-timing")
        if let audioLanguage = SubtitleLanguagePreferences.preferredAudioLanguage(),
           let alang = SubtitleLanguagePreferences.mpvLanguageList(for: [audioLanguage]) {
            checkError(mpv_set_option_string(mpv, "alang", alang), context: "alang")
        }
        let preferredSubtitleLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        if let slang = SubtitleLanguagePreferences.mpvLanguageList(for: preferredSubtitleLanguages) {
            checkError(mpv_set_option_string(mpv, "slang", slang))
        }
        // ASS/SSA override: Off (default) preserves original authored styling and positioning;
        // Strip flattens styling into app subtitle style; Scale keeps layout with size adjust;
        // Force applies style more aggressively.
        let assMode = (ProfileSettings.current.string(forKey: SettingsKey.assOverrideMode) ?? "Off")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let assOverride: String
        switch assMode {
        case "scale": assOverride = "scale"
        case "force": assOverride = "force"
        case "strip": assOverride = "strip"
        case "off", "no", "disabled", "native", "authored", "none": assOverride = "no"
        default: assOverride = "no"
        }
        checkError(mpv_set_option_string(mpv, "sub-ass-override", assOverride))
        checkError(mpv_set_option_string(mpv, "sub-use-margins", "yes"))
        checkError(mpv_set_option_string(mpv, "sub-ass-force-margins", assOverride == "no" ? "no" : "yes"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes"))
        checkError(mpv_set_option_string(mpv, "tone-mapping", "auto"))
        #if targetEnvironment(simulator)
        checkError(mpv_set_option_string(mpv, "hdr-compute-peak", "no"))
        #else
        checkError(mpv_set_option_string(mpv, "hdr-compute-peak", "yes"))
        #endif
        checkError(mpv_set_option_string(mpv, "target-prim", "auto"))
        checkError(mpv_set_option_string(mpv, "target-trc", "auto"))

        let initializeStatus = mpv_initialize(mpv)
        guard initializeStatus >= 0 else {
            let message = String(cString: mpv_error_string(initializeStatus))
            print("[MPV] initialize failed: \(message)")
            let failedContext = mpv
            mpv = nil
            if let failedContext {
                // No observers or wakeup callback have been registered yet.
                eventQueue.async { mpv_destroy(failedContext) }
            }
            isPlayerLoading = false
            setPlaybackError("MPV could not start: \(message)")
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
            memoryWatchdog.record(event: "mpv_initialize_failed")
#endif
            return
        }
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryWatchdog.record(event: "mpv_initialized")
#endif
        applySubtitleStyle()

        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        // Selecting a different audio/subtitle track leaves the track *count*
        // unchanged, so those alone wouldn't refresh the cached track list and
        // the panel's checkmark would snap back to the old track. Observing the
        // active ids (they can be "no"/"auto", hence STRING) fires a refresh the
        // moment a selection actually changes. See `refreshTracks`.
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "sid", MPV_FORMAT_STRING)
        // Available for text tracks even when `sub-visibility` is off, which
        // lets the host overlay replace MPV's renderer without losing cues.
        mpv_observe_property(mpv, 0, "sub-text", MPV_FORMAT_STRING)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
#endif
    }

    private func suspendPlaybackForBackgroundOrInactive() {
        guard mpv != nil else { return }
        guard !isApplicationBackgrounded else { return }

        onWillSuspendPlayback?()
        // A callback may synchronously retire this player.
        guard mpv != nil, !isApplicationBackgrounded else { return }
        firstFrameReadiness.reset(keepingPlaylistEntry: true)

        let sampledDurationMs = milliseconds(from: readDoubleProperty("duration")) ?? durationMs
        let sampledPositionMs = milliseconds(from: readDoubleProperty("time-pos")) ?? positionMs
        let verifiedPositionMs = lastVerifiedPositionMs ?? positionMs
        let verifiedDurationMs = lastVerifiedDurationMs ?? durationMs
        let referenceDurationMs = max(sampledDurationMs, verifiedDurationMs)

        // The UI-facing position can already contain MPV's bogus final-frame
        // value by this point. Compare against the independent verified sample.
        let jumpedToEnd = referenceDurationMs >= 60_000
            && sampledPositionMs >= referenceDurationMs - 5_000
            && verifiedPositionMs < referenceDurationMs * 85 / 100
            && sampledPositionMs - verifiedPositionMs > 30_000
        let jumpedToZero = verifiedPositionMs > 5_000 && sampledPositionMs == 0
        let candidatePositionMs = (jumpedToEnd || jumpedToZero) ? verifiedPositionMs : sampledPositionMs
        let safePositionMs = max(0, candidatePositionMs)

        let mpvStillPlaying = !getFlag("pause") && !getFlag("eof-reached")
        wasPlayingBeforeBackground = (mpvStillPlaying || (jumpedToEnd && lastVerifiedWasPlaying)) && (lastVerifiedWasPlaying || isPlayerPlaying)
        lifecyclePositionMs = safePositionMs
        lifecycleDurationMs = max(referenceDurationMs, durationMs)
        foregroundRestoreTargetMs = nil
        foregroundRestoreDeadline = nil
        lifecycleRestoreFailed = false
        isApplicationBackgrounded = true
        screensaverDebugLog("[ScreensaverDebug][MPVController] suspendPlayback: sampledPos=\(sampledPositionMs)ms, safePos=\(safePositionMs)ms, wasPlaying=\(wasPlayingBeforeBackground)")
        clearCleanEndState()
        pausePlayback()
        setStringProperty("vid", "no")
        publishLifecycleSnapshot()
        onPlaybackSuspended?(safePositionMs, lifecycleDurationMs ?? 0)
    }

    private func restorePlaybackFromBackgroundOrInactive() {
        guard mpv != nil else { return }
        guard isApplicationBackgrounded else { return }

        let shouldResume = wasPlayingBeforeBackground
        wasPlayingBeforeBackground = false
        isApplicationBackgrounded = false
        screensaverDebugLog("[ScreensaverDebug][MPVController] restorePlayback: shouldResume=\(shouldResume), lifecyclePos=\(String(describing: lifecyclePositionMs))ms")
        if !isDisplaySwitchInFlight {
            setStringProperty("vid", "auto")
        }
        clearCleanEndState()

        if let target = lifecyclePositionMs {
            foregroundRestoreTargetMs = target
            foregroundRestoreDeadline = Date().addingTimeInterval(4)
            let rawPositionMs = milliseconds(from: readDoubleProperty("time-pos"))
            screensaverDebugLog("[ScreensaverDebug][MPVController] restorePlayback restoring pos: target=\(target)ms, rawPos=\(String(describing: rawPositionMs))ms")
            if watchPartyRemoteIntent != nil
                || rawPositionMs == nil
                || abs((rawPositionMs ?? target) - target) > 1_500
                || getFlag("eof-reached") {
                seekToMs(target)
            }
        }

        if shouldResume && watchPartyRemoteIntent == nil {
            screensaverDebugLog("[ScreensaverDebug][MPVController] restorePlayback resuming playback")
            playPlayback()
        } else {
            // Preserve an explicit user pause across app switching and screensaver.
            screensaverDebugLog("[ScreensaverDebug][MPVController] restorePlayback preserving pause")
            pausePlayback()
        }
        onDidRestorePlayback?()
    }

    @objc private func appWillResignActive() {
        screensaverDebugLog("[ScreensaverDebug][MPVController] appWillResignActive")
        suspendPlaybackForBackgroundOrInactive()
    }

    @objc private func enterBackground() {
        screensaverDebugLog("[ScreensaverDebug][MPVController] enterBackground")
        suspendPlaybackForBackgroundOrInactive()
    }

    @objc private func enterForeground() {
        screensaverDebugLog("[ScreensaverDebug][MPVController] enterForeground")
        restorePlaybackFromBackgroundOrInactive()
    }

    @objc private func appDidBecomeActive() {
        screensaverDebugLog("[ScreensaverDebug][MPVController] appDidBecomeActive")
        restorePlaybackFromBackgroundOrInactive()
    }

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    @objc private func handleMemoryWarning() {
        memoryWatchdog.record(event: "memory_warning")
    }
#endif

    private func publishLifecycleSnapshot() {
        if let duration = lifecycleDurationMs, duration > 0 {
            durationMs = duration
        }
        if let position = lifecyclePositionMs {
            positionMs = position
            bufferedMs = max(bufferedMs, position)
        }
        hasCoherentTimeSample = durationMs > 0 && positionMs >= 0 && positionMs < durationMs
        isAtEndOfFile = false
        isPlayerLoading = false
        isPlayerPlaying = false
        isPlayerEnded = false
    }

    // MARK: - Playback API

    func loadFile(_ urlString: String) {
        firstFrameReadiness.reset()
        if didConfigureMPVRemoteCommands { teardownMPVRemoteCommands(); setupMPVRemoteCommandsIfNeeded() }
        pendingLoadConfiguration = nil
        pendingHTTPHeaders = [:]
        pendingIsLiveStream = false
        pendingCacheProfile = .fromSettings(ProfileSettings.current.string(forKey: SettingsKey.networkCache))
        pendingURL = urlString
        resetScrubThumbnailSource(
            playbackURL: URL(string: urlString), headers: [:], isLive: false,
            streamKey: TrickplayDiskCache.streamKey(for: urlString), canonicalMediaKey: nil)
        if Thread.isMainThread {
            attemptStartPendingLoad()
        } else {
            DispatchQueue.main.async { [weak self] in self?.attemptStartPendingLoad() }
        }
    }

    func load(_ request: PlaybackLoadRequest) {
        firstFrameReadiness.reset()
        teardownMPVRemoteCommands()
        pendingLoadConfiguration = MPVLoadConfiguration(request: request)
        pendingAudioURL = request.audioURL?.absoluteString
        pendingHTTPHeaders = request.httpHeaders
        pendingIsLiveStream = request.isLiveStream
        pendingCacheProfile = request.cacheProfile
        pendingURL = request.videoURL.absoluteString
        currentMediaTitle = request.streamName
        currentMediaArtist = request.streamDescription
        currentAspectMode = request.aspectMode
        PlaybackAudioSession.activateMoviePlayback()

        let key = request.canonicalMediaKey ?? request.cacheFileIdentity?.cacheKey ?? TrickplayDiskCache.streamKey(for: request.videoURL.absoluteString)
        resetScrubThumbnailSource(
            playbackURL: request.videoURL,
            headers: request.httpHeaders,
            isLive: request.isLiveStream,
            streamKey: key,
            canonicalMediaKey: request.canonicalMediaKey,
            isKnownHLS: request.streamDescription == PlaybackMarkers.trailerSubtitle)

        #if os(tvOS) || os(iOS)
        currentMediaArtwork = nil
        artworkLoadTask?.cancel()
        if let artworkURL = request.artworkURL {
            artworkLoadTask = Task { [weak self] in
                guard let image = await BackdropImageCache.shared.image(for: artworkURL) else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.currentMediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.updateMPVNowPlayingInfo()
                }
            }
        }
        setupMPVRemoteCommandsIfNeeded()
        #endif
        if Thread.isMainThread {
            attemptStartPendingLoad()
        } else {
            DispatchQueue.main.async { [weak self] in self?.attemptStartPendingLoad() }
        }
    }

    private func attemptStartPendingLoad() {
        guard let url = pendingURL, mpv != nil else { return }
        // The active display wait will start the latest queued load once safe.
        guard !isDisplaySwitchInFlight else { return }
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1 else { return }
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryDiagnosticSessionID = UUID().uuidString
        memoryDiagnosticCacheMode = "pending"
        memoryWatchdog.updateContext(sessionID: memoryDiagnosticSessionID, cacheMode: memoryDiagnosticCacheMode)
        memoryWatchdog.record(event: "load_begin")
#endif
        pendingURL = nil
        applyHTTPHeaders(pendingHTTPHeaders, isLiveStream: pendingIsLiveStream)
        pendingHTTPHeaders = [:]
        subtitleTranslationState.reset()
        isMPVSubtitleRendererHiddenForTranslation = false
        setFlag("sub-visibility", true)
        lifecyclePositionMs = nil
        lifecycleDurationMs = nil
        lastVerifiedPositionMs = nil
        lastVerifiedDurationMs = nil
        lastVerifiedWasPlaying = false
        foregroundRestoreTargetMs = nil
        foregroundRestoreDeadline = nil
        lifecycleRestoreFailed = false
        hasCoherentTimeSample = false
        isAtEndOfFile = false
        startupDisplayGateActive = false
        pendingAutoplayAfterDisplayGate = false
        layoutMetalLayer()
        clearPlaybackError()
        resetDisplayCriteriaProbe()
        // Do not leave the prior title's HDR criteria active while this file
        // is loading. The new stream's own VIDEO_RECONFIG will apply fresh
        // criteria once its color parameters are known.
        clearDisplayCriteria()
        isPlayerLoading = true
        isPlayerEnded = false
        let sourceURL = URL(string: url) ?? URL(fileURLWithPath: url)
        let cachePolicy = MPVPlaybackCachePolicy.resolve(
            url: sourceURL,
            isLiveStream: pendingIsLiveStream,
            profile: pendingCacheProfile,
            nativeDiskAvailable: mpvPacketDiskCacheAvailable
        )
        // Keep MPV's RAM packet cache bounded for all sources; remote streams
        // can use libmpv's separate sandboxed disk packet cache.
        var nativeDiskFlag: CInt = cachePolicy.nativeDiskEnabled ? 1 : 0
        let nativeDiskStatus = mpv_set_property(mpv, "cache-on-disk", MPV_FORMAT_FLAG, &nativeDiskFlag)
        checkError(nativeDiskStatus, context: "cache-on-disk")
        var effectiveNativeDiskEnabled: Bool?
        if nativeDiskStatus >= 0 {
            effectiveNativeDiskEnabled = cachePolicy.nativeDiskEnabled
        } else {
            mpvPacketDiskCacheAvailable = false
            var disabledFlag: CInt = 0
            let disableStatus = mpv_set_property(mpv, "cache-on-disk", MPV_FORMAT_FLAG, &disabledFlag)
            checkError(disableStatus, context: "cache-on-disk=no fallback")
            if disableStatus >= 0 {
                effectiveNativeDiskEnabled = false
            } else {
                var currentFlag: CInt = 0
                let readStatus = mpv_get_property(mpv, "cache-on-disk", MPV_FORMAT_FLAG, &currentFlag)
                effectiveNativeDiskEnabled = readStatus >= 0 ? currentFlag != 0 : nil
            }
        }
        setStringProperty("demuxer-max-bytes", cachePolicy.forwardBuffer)
        setStringProperty("demuxer-max-back-bytes", cachePolicy.backBuffer)
        setStringProperty("cache-secs", String(cachePolicy.cacheSeconds))
        setStringProperty("demuxer-readahead-secs", String(cachePolicy.cacheSeconds))
        let nativeDiskLabel = effectiveNativeDiskEnabled.map { String($0) } ?? "unknown"
        print("[MPVCache] source=\(cachePolicy.source) nativeDisk=\(nativeDiskLabel) RAM=\(cachePolicy.forwardBuffer)/\(cachePolicy.backBuffer) cache-secs=\(cachePolicy.cacheSeconds)")
        let isLocalOrDiskCache = cachePolicy.source == .localOrLoopback
        self.isLocalOrDiskCacheStream = isLocalOrDiskCache
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        switch cachePolicy.source {
        case .localOrLoopback:
            memoryDiagnosticCacheMode = cachePolicy.diagnosticMode
        case .remote:
            memoryDiagnosticCacheMode = effectiveNativeDiskEnabled == true
                ? "network_disk"
                : (effectiveNativeDiskEnabled == false ? "network_ram_fallback" : "network_cache_state_unknown")
        case .liveRemote:
            memoryDiagnosticCacheMode = effectiveNativeDiskEnabled == true
                ? "live_network_disk"
                : (effectiveNativeDiskEnabled == false ? "live_network_ram_fallback" : "live_network_cache_state_unknown")
        }
        memoryWatchdog.updateContext(sessionID: memoryDiagnosticSessionID, cacheMode: memoryDiagnosticCacheMode)
        memoryWatchdog.record(event: "load_start")
#endif

        // Commit seek, tracks, controls and autoplay together at FILE_LOADED.
        if let langs = pendingLoadConfiguration?.preferredAudioLanguages,
           !langs.isEmpty,
           let alang = SubtitleLanguagePreferences.mpvLanguageList(for: langs) {
            setStringProperty("alang", alang)
        }
        setFlag("pause", true)
        command("loadfile", args: [url, "replace"])
        // loadfile replace creates its playlist entry synchronously. Unlike
        // path/duration, the entry ID distinguishes reloading the same URL.
        firstFrameReadiness.arm(playlistEntryID: readOptionalInt64Property("playlist/0/id"))
        setAspectMode(currentAspectMode)
    }

    func playPlayback() {
        cancelScrubThumbnailWork()
        guard mpv != nil else { return }
        screensaverDebugLog("[ScreensaverDebug][MPVController] playPlayback() called: pos=\(positionMs)ms")
        lastVerifiedWasPlaying = true
        setFlag("pause", false)
    }

    func pausePlayback() {
        guard mpv != nil else { return }
        screensaverDebugLog("[ScreensaverDebug][MPVController] pausePlayback() called: pos=\(positionMs)ms")
        lastVerifiedWasPlaying = false
        setFlag("pause", true)
    }

    func seekToMs(_ ms: Int64) {
        seekToMs(ms, exact: false)
    }

    /// Party completion is confirmed by a later coherent VM sample, not this command's return.
    func beginWatchPartySeek(_ ms: Int64) throws {
        guard mpv != nil else { throw WatchPartyPlayerBridgeError.notReady }
        seekToMs(ms, exact: true)
    }

    private(set) var isSeekingForWatchParty = false

    private func seekToMs(_ ms: Int64, exact: Bool) {
        guard mpv != nil else { return }
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryWatchdog.record(event: "seek")
#endif
        seekWatchdogSequence &+= 1
        let seekId = seekWatchdogSequence
        let now = CFAbsoluteTimeGetCurrent()
        activeSeekWatchdog = ActiveSeekWatchdog(
            id: seekId,
            targetMs: ms,
            initialPositionMs: positionMs,
            startTime: now
        )
        screensaverDebugLog("[ScreensaverDebug][MPVController] seekToMs(\(ms)) called: currentPos=\(positionMs)ms")
        print("[SeekWatchdog][#\(seekId)] ⏩ Seek started -> target: \(ms)ms (current: \(positionMs)ms, duration: \(durationMs)ms, isLocalCache: \(isLocalOrDiskCacheStream))")
        subtitleTranslationState.cancelPendingTranslations()
        rememberExplicitSeek(to: ms)
        command("seek", args: [String(format: "%.3f", Double(ms) / 1000.0), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func seekByMs(_ ms: Int64) {
        seekToMs(positionMs + ms)
    }

    private func rememberExplicitSeek(to requestedMs: Int64) {
        let upperBound = durationMs > 0 ? max(durationMs - 1, 0) : Int64.max
        lastVerifiedPositionMs = min(max(requestedMs, 0), upperBound)
        if durationMs > 0 {
            lastVerifiedDurationMs = durationMs
        }
    }

    func coherentSourceTimeSeconds() -> Double {
        let sampled = max(positionMs, 0)
        return Double(sampled) / 1000.0
    }

    #if os(tvOS) || os(iOS)
    private func updateMPVNowPlayingInfo() {
        guard durationMs > 0 else { return }
        var info = [String: Any]()
        if let title = currentMediaTitle, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist = currentMediaArtist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let artwork = currentMediaArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000.0
        info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlayerPlaying ? Double(currentSpeed) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupMPVRemoteCommandsIfNeeded() {
        guard !didConfigureMPVRemoteCommands else { return }
        didConfigureMPVRemoteCommands = true
        let center = MPRemoteCommandCenter.shared()
        installRemoteCommands(center)
    }

    private func installRemoteCommands(_ center: MPRemoteCommandCenter) {
        let action: @MainActor @Sendable (PlayerRemoteIntent) -> Void = { [weak self] intent in
            guard let self else { return }
            if let handler = self.watchPartyRemoteIntent { _ = handler(intent); return }
            guard let intent = intent.localIntent(positionMs: self.positionMs, isPlaying: self.isTransportPlaying) else { return }
            switch intent {
            case .play: self.playPlayback()
            case .pause: self.pausePlayback()
            case .seek(let position): self.seekToMs(position)
            default: break
            }
        }
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        remoteCommandTargets.add(center.playCommand, intent: .play, action: action)
        remoteCommandTargets.add(center.pauseCommand, intent: .pause, action: action)
        remoteCommandTargets.add(center.togglePlayPauseCommand, intent: .toggle, action: action)
        remoteCommandTargets.add(center.changePlaybackPositionCommand, resolve: { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return nil }
            return .position(event.positionTime)
        }, action: action)
        remoteCommandTargets.add(center.skipForwardCommand, intent: .skip(10), action: action)
        remoteCommandTargets.add(center.skipBackwardCommand, intent: .skip(-10), action: action)
    }

    private func teardownMPVRemoteCommands() {
        remoteCommandTargets.stop()
        didConfigureMPVRemoteCommands = false
    }
    #endif

    func setSpeed(_ speed: Float) {
        guard mpv != nil else { return }
        var s = Double(speed)
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &s)
        currentSpeed = speed
    }

    /// Decoded video dimensions (0 until the first frame reports params).
    var videoFrameSize: CGSize {
        let w = getInt("video-params/w")
        let h = getInt("video-params/h")
        guard w > 1, h > 1 else { return .zero }
        return CGSize(width: w, height: h)
    }

    var engineVersion: String? {
        guard let raw = getString("mpv-version"), !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("mpv ") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    var playbackDebugInfo: PlaybackDebugInfo {
        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        var fps = getDouble("container-fps")
        if !fps.isFinite || fps <= 0 { fps = getDouble("estimated-vf-fps") }

        let videoCodec = getString("current-tracks/video/codec") ?? ""
        let gamma = (getString("video-params/gamma") ?? "").lowercased()
        let dvProfile = getInt("current-tracks/video/dolby-vision-profile")
        let dynamicRange: String
        if dvProfile > 0 {
            dynamicRange = "Dolby Vision P\(dvProfile) → HDR10/PQ"
        } else if gamma.contains("hlg") || gamma.contains("b67") || gamma.contains("arib") {
            dynamicRange = "HLG"
        } else if gamma.contains("pq") || gamma.contains("2084") {
            dynamicRange = "HDR10/PQ"
        } else {
            dynamicRange = "SDR"
        }

        let hwdec = (getString("hwdec-current") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pipeline = hwdec.isEmpty || hwdec == "no"
            ? "gpu-next • software decode"
            : "gpu-next • \(hwdec)"

        let selectedAudio = audioTracks.first(where: \.selected) ?? audioTracks.first
        var audio = selectedAudio.map {
            $0.detail.isEmpty ? $0.title : $0.detail
        } ?? "Unknown"
        let audioDetailComponents = selectedAudio?.detail
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        let rawAudioCodec = getString("current-tracks/audio/codec")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audioSourceCodec = rawAudioCodec?.isEmpty == false ? rawAudioCodec : nil
        let audioSourceChannels = audioDetailComponents
            .first(where: { $0.localizedCaseInsensitiveContains("ch") })
            .flatMap { component in
                component.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
            }
        let audioCodecProfile = getString("current-tracks/audio/codec-profile")
        let profileEvidence = audioCodecProfile?.lowercased() ?? ""
        let audioSpatialFormat: String?
        if profileEvidence.contains("atmos") || profileEvidence.contains("joc") {
            audioSpatialFormat = "Atmos"
        } else if profileEvidence.contains("dts:x") {
            audioSpatialFormat = "DTS:X"
        } else {
            audioSpatialFormat = nil
        }
        let atmosEvidence = [
            audioCodecProfile,
            getString("current-tracks/audio/codec-desc"),
            getString("current-tracks/audio/title"),
            selectedAudio?.title,
            selectedAudio?.detail,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if (atmosEvidence.contains("atmos") || atmosEvidence.contains("joc")),
           !audio.localizedCaseInsensitiveContains("Atmos") {
            audio += " • Atmos"
        }

        let isDV = dvProfile > 0
        let fpsStr = fps.isFinite && fps > 0 ? String(format: "%.3f fps", fps) : "--"
        let videoCodecLabel = Self.videoCodecLabel(videoCodec)
        let videoStr = width > 0 && height > 0
            ? "\(width)×\(height) · \(fpsStr) · \(isDV ? "dolby-vision" : videoCodecLabel.lowercased())"
            : "\(fpsStr) · \(isDV ? "dolby-vision" : videoCodecLabel.lowercased())"

        let vBit = getDouble("video-bitrate")
        let vBitrateStr = vBit > 0
            ? String(format: "%.1f Mbit/s", vBit / 1_000_000.0)
            : "--"

        let dvStr = dvProfile > 0 ? "P\(dvProfile)" : "None"
        // No mastering metadata or enhancement-layer telemetry is collected here.
        let dvHdrStr = "--"

        let decoderStr = hwdec.isEmpty || hwdec == "no"
            ? "MPVKit.software (cpu)"
            : "MPVKit.gpu-next (\(hwdec))"

        let droppedCount = getInt("drop-frame-count")
        let droppedStr = "\(droppedCount) frames"

        // Source FPS and the screen maximum do not measure the active HDMI mode.
        let displayStr = "--"

        let aBit = getDouble("audio-bitrate")
        let aBitrateStr = aBit > 0
            ? String(format: "meas %.2f Mbit/s", aBit / 1_000_000.0)
            : "--"

        let routeStr = PlaybackSystemMonitor.audioRouteInfo()
            .replacingOccurrences(of: " · 0 changes", with: "")

        let cacheDur = getDouble("demuxer-cache-duration")
        let bufferSec = cacheDur > 0 ? cacheDur : 0.0
        let bufferStr = cacheDur > 0
            ? String(format: "%.1f s ahead", bufferSec)
            : "0.0 s ahead"

        let cacheSpeed = getDouble("cache-speed")
        let speedStr = cacheSpeed > 0
            ? String(format: "est %.1f Mbit/s", (cacheSpeed * 8) / 1_000_000.0)
            : "--"

        let cacheBytes = Int64(getInt("demuxer-cache-state/bytes"))
        let loadedStr = cacheBytes > 0
            ? ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
            : "--"

        let cpuPercent = PlaybackSystemMonitor.cpuUsage()
        let appCpuStr = cpuPercent > 0 ? String(format: "%.0f %%", cpuPercent) : "--"

        let mem = PlaybackSystemMonitor.memoryUsage()
        let resident = mem.residentMB > 0 ? String(format: "%.0f MB", mem.residentMB) : "--"
        let available = mem.availableMB > 0 ? String(format: "%.0f MB", mem.availableMB) : "--"
        let footprint = mem.virtualMB > 0 ? String(format: "%.0f MB", mem.virtualMB) : "--"
        let memStr = "resident \(resident) · available \(available) · footprint \(footprint)"

        let thermal = PlaybackSystemMonitor.thermalInfo()
        // The monitor estimates temperature from thermal state; it is not a sensor.
        let socTempStr = "--"
        let cpuClockStr = "--"

        return PlaybackDebugInfo(
            player: "MPVKit",
            pipeline: pipeline,
            videoCodec: videoCodecLabel,
            dynamicRange: dynamicRange,
            resolution: width > 0 && height > 0 ? "\(width)×\(height)" : "Unknown",
            frameRate: fpsStr,
            audio: audio,
            audioSourceCodec: audioSourceCodec,
            audioSourceChannels: audioSourceChannels,
            audioSpatialFormat: audioSpatialFormat,
            video: videoStr,
            hdr: dynamicRange,
            vBitrate: vBitrateStr,
            dv: dvStr,
            dvHdr: dvHdrStr,
            decoder: decoderStr,
            dropped: droppedStr,
            droppedCount: droppedCount,
            frameLead: "--",
            display: displayStr,
            aBitrate: aBitrateStr,
            underruns: "--",
            underrunsCount: 0,
            route: routeStr,
            aJitter: "--",
            buffer: bufferStr,
            bufferSeconds: bufferSec,
            speed: speedStr,
            ping: "--",
            loaded: loadedStr,
            stalls: "--",
            stallsCount: 0,
            appCpu: appCpuStr,
            appCpuPercent: cpuPercent,
            memory: memStr,
            socTemp: socTempStr,
            isThermalElevated: thermal.isElevated,
            cpuClock: cpuClockStr
        )
    }

    /// Actual profile parsed by FFmpeg from the selected HEVC track.
    var dolbyVisionProfile: Int {
        getInt("current-tracks/video/dolby-vision-profile")
    }

    private static func videoCodecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1", "av01": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        case "": return "Unknown"
        default: return codec.uppercased()
        }
    }

    /// The system Dolby Vision renderer owns the window's dynamic-range request
    /// while it presents the local playlist.
    func suspendDisplayCriteriaForNativePlayback() {
        clearDisplayCriteria()
    }

    func restoreDisplayCriteriaAfterNativePlayback() {
        resetDisplayCriteriaProbe()
        scheduleDisplayCriteriaProbe()
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        currentAspectMode = mode
        guard mpv != nil else { return }
        setDoubleProperty("video-zoom", 0)
        setDoubleProperty("video-pan-x", 0)
        setDoubleProperty("video-pan-y", 0)
        setStringProperty("video-unscaled", "no")
        metalLayer.contentsGravity = .resize
        switch mode {
        case .fit:
            setFlag("keepaspect", true)
            setDoubleProperty("panscan", 0.0)
        case .fill:
            setFlag("keepaspect", true)
            setDoubleProperty("panscan", 1.0)
        case .zoom:
            setFlag("keepaspect", true)
            setDoubleProperty("panscan", 0.5)
        case .stretch:
            setFlag("keepaspect", false)
            setDoubleProperty("panscan", 0.0)
        }
    }

    func setMuted(_ muted: Bool) {
        guard mpv != nil else { return }
        setFlag("mute", muted)
    }

    /// mpv `sub-delay`, in seconds; positive shows captions later.
    func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value)
    }

    /// mpv `audio-delay`, in seconds; positive delays the audio.
    func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "audio-delay", MPV_FORMAT_DOUBLE, &value)
    }

    /// PCM software amplification, expressed in dB. mpv's `volume` is a linear
    /// percentage (100 = unchanged), so convert: percent = 10^(dB/20) · 100.
    /// `volume-max` is raised at init so the full +10 dB (~316%) is allowed.
    func setAudioVolumeGain(dB: Double) {
        guard mpv != nil else { return }
        var value = pow(10.0, dB / 20.0) * 100.0
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &value)
    }

    func setAudioProcessing(dialogue: EnhanceDialogueMode, reduceLoud: Bool) {
        guard let mpv else { return }
        var filters: [String] = []
        switch dialogue {
        case .off:
            break
        case .enhance:
            filters.append("lavfi=[dynaudnorm=f=150:g=15:m=10.0]")
        case .boost:
            filters.append("lavfi=[dynaudnorm=f=100:g=21:m=20.0],equalizer=f=1500:width_type=o:width=1.5:g=8")
        }
        if reduceLoud {
            filters.append("lavfi=[acompressor=threshold=-20dB:ratio=4:attack=50:release=1000]")
        }
        let filterString = filters.joined(separator: ",")
        mpv_set_property_string(mpv, "af", filterString)
    }

    // MARK: - Track selection

    func selectAudio(_ trackId: Int) {
        guard mpv != nil else { return }
        audioSelectionGeneration &+= 1
        desiredAudioSelection = .trackID(trackId)
        applyAudioSelection(trackId)
    }

    private func applyAudioSelection(_ trackId: Int) {
        guard mpv != nil else { return }
        var id = Int64(trackId)
        mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &id)
    }

    func selectSubtitle(_ trackId: Int) {
        guard mpv != nil else { return }
        subtitleSelectionGeneration &+= 1
        desiredSubtitleSelection = .trackID(trackId)
        applySubtitleSelection(trackId)
    }

    private func applySubtitleSelection(_ trackId: Int) {
        guard mpv != nil else { return }
        if trackId < 0 {
            setStringProperty("sid", "no")
        } else {
            var id = Int64(trackId)
            mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &id)
        }
    }

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        guard mpv != nil else { return }
        if select {
            subtitleSelectionGeneration &+= 1
            desiredSubtitleSelection = .externalURL(subtitle.url)
        }
        commandAsyncTrack("sub-add", args: [
            subtitle.url,
            "auto",
            subtitle.label ?? "",
            subtitle.language
        ], url: subtitle.url, selectionGeneration: subtitleSelectionGeneration, selectsWhenReady: select)
    }

    func addAudioUrl(_ url: String) {
        pendingAudioURL = url
        guard mpv != nil, !isPlayerLoading else { return }
        attachPendingAudioIfNeeded()
    }

    private func attachPendingAudioIfNeeded() {
        guard let url = pendingAudioURL else { return }
        pendingAudioURL = nil
        audioSelectionGeneration &+= 1
        desiredAudioSelection = .externalURL(url)
        commandAsyncTrack(
            "audio-add", args: [url, "auto"], url: url,
            selectionGeneration: audioSelectionGeneration, selectsWhenReady: true
        )
    }

    private func applyPendingLoadConfiguration() {
        guard let configuration = pendingLoadConfiguration else { return }
        pendingLoadConfiguration = nil
        setSpeed(configuration.playbackRate)
        setSubtitleDelay(configuration.subtitleDelaySeconds)
        setAudioDelay(configuration.audioDelaySeconds)
        setAudioVolumeGain(dB: configuration.audioGainDB)
        configuration.externalSubtitles.forEach { addSubtitle($0, select: false) }
        if let resumeMs = configuration.resumePositionMs, resumeMs > 1_000 {
            seekToMs(resumeMs)
        }
        if !configuration.autoplay {
            pausePlayback()
            return
        }

        #if targetEnvironment(simulator)
        playPlayback()
        #else
        // VIDEO_RECONFIG supplies the stream's real color and frame-rate
        // metadata. The display probe below applies it, waits for HDMI to
        // settle, reattaches video, and then releases this autoplay gate.
        pendingAutoplayAfterDisplayGate = true
        startupDisplayGateActive = true
        pausePlayback()
        #endif
    }

    /// Pushes the user's saved subtitle appearance (Settings → Subtitle Style)
    /// into libmpv. Safe to call repeatedly — invoked once after init and again
    /// on every FILE_LOADED so the styling lands on each track that gets parsed.
    func applySubtitleStyle() {
        guard mpv != nil else { return }
        let style = SubtitleStyle.current
        setStringProperty("sub-scale", String(format: "%.3f", style.subScale))
        setStringProperty("sub-bold", style.bold ? "yes" : "no")
        setStringProperty("sub-outline-size", String(format: "%.3f", style.subOutlineSize))
        setStringProperty("sub-margin-y", String(style.subMarginY))
        setStringProperty("sub-margin-x", String(style.subMarginX))
        setStringProperty("sub-spacing", String(style.subSpacing))
        setStringProperty("sub-shadow-offset", style.backgroundEnabled ? "4" : "0")
        setStringProperty("sub-border-style", style.backgroundEnabled ? "background-box" : "outline-and-shadow")
        setStringProperty("sub-color", style.subColor)
        setStringProperty("sub-outline-color", style.subOutlineColor)
        setStringProperty("sub-back-color", style.subBackgroundColor)
    }

    func destroyPlayer() {
        firstFrameReadiness.reset()
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryWatchdog.stop(event: "destroy")
#endif
        cancelScrubThumbnailWork()
        loadGeneration &+= 1
        externalProviderGeneration &+= 1
        externalTrickplayProvider = nil
        thumbnailSourceContext = nil
        contentCanonicalKey = nil
        currentStreamKey = ""
        let generation = loadGeneration
        let index = hybridThumbnailIndex
        thumbnailIndexResetTask = Task { await index.reset(generation: generation) }
        NotificationCenter.default.removeObserver(self)
        pendingURL = nil
        subtitleTranslationState.reset()
        isMPVSubtitleRendererHiddenForTranslation = false
        pendingLoadConfiguration = nil
        startupDisplayGateActive = false
        pendingAutoplayAfterDisplayGate = false
        clearDisplayCriteria()
        clearPlaybackError()
        #if os(tvOS) || os(iOS)
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentMediaArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        teardownMPVRemoteCommands()
        #endif
        guard let ctx = mpv else { return }
        mpv = nil  // nil first so the event loop stops reading
        clearPendingTrackCommands()
        mpv_set_wakeup_callback(ctx, nil, nil)

        // libmpv's avfoundation audio output tears down AVAudioSession from
        // inside mpv_terminate_destroy(). That teardown can synchronously
        // reconfigure the audio route, so doing it on the main actor triggers
        // Xcode's "AVAudioSession Hang Risk" warning and can stall dismissal.
        // Use the existing serial event queue so teardown does not race the
        // event pump; the nil assignment above makes all later calls no-op.
        eventQueue.async {
            mpv_terminate_destroy(ctx)
        }
    }

    deinit {
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        memoryWatchdog.stop(event: "deinit")
#endif
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let ctx = mpv {
            mpv = nil
            mpv_set_wakeup_callback(ctx, nil, nil)
            eventQueue.async {
                mpv_terminate_destroy(ctx)
            }
        }
    }

    // MARK: - State Update

    /// Lightweight state refresh — called by the view model poll (every 250ms).
    func refreshPlaybackState() {
        guard mpv != nil else { return }
        if isApplicationBackgrounded || lifecycleRestoreFailed {
            publishLifecycleSnapshot()
            return
        }
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        refreshMemoryWatchdogEngineSnapshotIfDue()
#endif

        let duration = readDoubleProperty("duration")
        let position = readDoubleProperty("time-pos")
        let cached = readDoubleProperty("demuxer-cache-time") ?? 0
        let speed = getDouble("speed")
        let paused = getFlag("pause")
        let eofReached = getFlag("eof-reached")
        let idle = getFlag("core-idle")
        let seeking = getFlag("seeking")
        isSeekingForWatchParty = seeking
        let bufferingCache = getFlag("paused-for-cache")

        isAtEndOfFile = eofReached

        if let target = foregroundRestoreTargetMs {
            let sampledPositionMs = milliseconds(from: position)
            let restored = duration != nil
                && sampledPositionMs != nil
                && abs((sampledPositionMs ?? target) - target) <= 5_000
                && !eofReached

            if !restored {
                if let deadline = foregroundRestoreDeadline, Date() < deadline {
                    clearCleanEndState()
                    seekToMs(target)
                    publishLifecycleSnapshot()
                    return
                }

                // Never turn a failed lifecycle reattach into a completed
                // watch. Keep the verified snapshot and surface an error.
                setPlaybackError("Playback could not resume after returning to Nuvio.")
                lifecycleRestoreFailed = true
                publishLifecycleSnapshot()
                return
            }

            foregroundRestoreTargetMs = nil
            foregroundRestoreDeadline = nil
            lifecyclePositionMs = nil
            lifecycleDurationMs = nil
        }

        hasCoherentTimeSample = duration != nil && position != nil

        isPlayerLoading = startupDisplayGateActive
            || (idle && !paused && !eofReached)
            || seeking
            || bufferingCache
        isPlayerPlaying = !paused && !idle && !eofReached
        // Accept completion only after MPV's END_FILE event explicitly reports
        // EOF. The eof-reached property can race ahead of an END_FILE error.
        isPlayerEnded = eofReached
            && didReachCleanEndOfFile
            && currentErrorMessage.isEmpty
            && hasCoherentTimeSample

        if let durationMs = milliseconds(from: duration),
           let positionMs = milliseconds(from: position) {
            let cachedMs = milliseconds(from: cached) ?? 0
            let previousPositionMs = lastVerifiedPositionMs
            let referenceDurationMs = max(durationMs, lastVerifiedDurationMs ?? 0)
            let implausibleEndJump = referenceDurationMs >= 60_000
                && positionMs >= referenceDurationMs - 5_000
                && (previousPositionMs ?? positionMs) < referenceDurationMs * 85 / 100
                && positionMs - (previousPositionMs ?? positionMs) > 30_000

            if implausibleEndJump, let previousPositionMs {
                lifecyclePositionMs = previousPositionMs
                lifecycleDurationMs = referenceDurationMs
                foregroundRestoreTargetMs = previousPositionMs
                foregroundRestoreDeadline = Date().addingTimeInterval(4)
                clearCleanEndState()
                seekToMs(previousPositionMs)
                publishLifecycleSnapshot()
                return
            }

            if !eofReached,
               positionMs >= 0,
               positionMs < durationMs,
               !implausibleEndJump {
                lastVerifiedPositionMs = positionMs
                lastVerifiedDurationMs = durationMs
                lastVerifiedWasPlaying = !paused && !idle
            }
            self.durationMs = durationMs
            self.positionMs = max(positionMs, 0)
            self.bufferedMs = max(positionMs + cachedMs, 0)
        }
        currentSpeed = Float(speed > 0 ? speed : 1.0)

        // Update Seek Watchdog
        if var watchdog = activeSeekWatchdog {
            let now = CFAbsoluteTimeGetCurrent()
            if seeking, watchdog.seekingStartTime == nil {
                watchdog.seekingStartTime = now
                let elapsed = (now - watchdog.startTime) * 1000
                print("[SeekWatchdog][#\(watchdog.id)] 🔄 MPV seeking=true (+\(String(format: "%.1f", elapsed))ms from command)")
            }
            if !seeking, let start = watchdog.seekingStartTime, watchdog.seekingEndTime == nil {
                watchdog.seekingEndTime = now
                let seekDuration = (now - start) * 1000
                print("[SeekWatchdog][#\(watchdog.id)] ⏸️ MPV seeking=false (seeking state lasted \(String(format: "%.1f", seekDuration))ms)")
            }
            if bufferingCache {
                if watchdog.cacheWaitStartTime == nil {
                    watchdog.cacheWaitStartTime = now
                    let elapsed = (now - watchdog.startTime) * 1000
                    print("[SeekWatchdog][#\(watchdog.id)] ⏳ paused-for-cache=true (+\(String(format: "%.1f", elapsed))ms from seek start)")
                }
            } else if let cacheStart = watchdog.cacheWaitStartTime {
                let cacheDuration = now - cacheStart
                watchdog.totalCacheWaitDuration += cacheDuration
                watchdog.cacheWaitStartTime = nil
                print("[SeekWatchdog][#\(watchdog.id)] ⚡ paused-for-cache=false (waited for cache: \(String(format: "%.1f", cacheDuration * 1000))ms)")
            }
            if !watchdog.reported, !seeking, !bufferingCache, !idle, (positionMs > 0 || watchdog.targetMs == 0) {
                let posDiff = abs(positionMs - watchdog.targetMs)
                if posDiff <= 5000 || watchdog.seekingEndTime != nil {
                    watchdog.reported = true
                    let totalElapsed = (now - watchdog.startTime) * 1000
                    let cacheMs = (watchdog.totalCacheWaitDuration + (watchdog.cacheWaitStartTime.map { now - $0 } ?? 0)) * 1000
                    let seekStateMs = (watchdog.seekingEndTime.flatMap { end in watchdog.seekingStartTime.map { (end - $0) * 1000 } }) ?? 0
                    print("[SeekWatchdog][#\(watchdog.id)] ✅ Seek completed in \(String(format: "%.1f", totalElapsed))ms (seeking: \(String(format: "%.1f", seekStateMs))ms, cacheWait: \(String(format: "%.1f", cacheMs))ms) -> landed at \(positionMs)ms (target: \(watchdog.targetMs)ms, demuxerCached: \(cached)s)")
                    activeSeekWatchdog = nil
                } else {
                    activeSeekWatchdog = watchdog
                }
            } else {
                activeSeekWatchdog = watchdog
            }
        }

        #if os(tvOS) || os(iOS)
        updateMPVNowPlayingInfo()
        #endif
        refreshSubtitleTranslation()
    }

    private func refreshSubtitleTranslation() {
        guard mpv != nil else { return }
        subtitleTranslationState.update(sourceText: getString("sub-text") ?? "")
        let shouldHideRenderer = subtitleTranslationState.shouldDisplayOverlay
        guard shouldHideRenderer != isMPVSubtitleRendererHiddenForTranslation else { return }
        isMPVSubtitleRendererHiddenForTranslation = shouldHideRenderer
        // MPV continues decoding `sub-text` while invisible, so original text
        // is immediately available in the host overlay until Gemini responds.
        setFlag("sub-visibility", !shouldHideRenderer)
    }

    func updateState() {
        refreshPlaybackState()
        refreshTracks()
    }

    private func refreshTracks() {
        guard mpv != nil else { return }
        var audio = [PlaybackTrackInfo]()
        var subs = [PlaybackTrackInfo]()
        let count = getInt("track-list/count")
        var audioIdx = 0
        var subIdx = 0

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let title = getTrackString(i, "title")
            let lang = getTrackString(i, "lang")
            let codec = getTrackString(i, "codec")
            let channelCount = getInt("track-list/\(i)/demux-channel-count")
            let selected = getFlag("track-list/\(i)/selected")
            let externalFilename = getTrackString(i, "external-filename")

            if type == "audio" {
                let sampleRate = getInt("track-list/\(i)/demux-samplerate")
                let languageName = Self.localizedLanguageName(lang)
                let display = Self.audioTrackName(title: title, languageName: languageName,
                                                  codec: codec, channelCount: channelCount,
                                                  fallback: "Track \(audioIdx + 1)")
                let detail = Self.audioTrackDetail(codec: codec, channels: channelCount, sampleRate: sampleRate)
                audio.append(PlaybackTrackInfo(index: audioIdx, id: id, type: type, title: display, lang: lang,
                                       selected: selected, externalFilename: externalFilename,
                                       languageName: languageName, detail: detail))
                audioIdx += 1
            } else if type == "sub" {
                let display = trackTitle(title: title, lang: lang, codec: codec,
                                         channelCount: 0, fallback: "Subtitle \(subIdx + 1)")
                subs.append(PlaybackTrackInfo(index: subIdx, id: id, type: type, title: display, lang: lang,
                                      selected: selected, externalFilename: externalFilename))
                subIdx += 1
            }
        }
        audioTracks = audio
        subtitleTracks = subs
    }

    private func getTrackString(_ index: Int, _ field: String) -> String {
        (getString("track-list/\(index)/\(field)") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackTitle(title: String, lang: String, codec: String,
                            channelCount: Int, fallback: String) -> String {
        let base: String
        if !title.isEmpty {
            base = title
        } else if !lang.isEmpty {
            base = Locale.current.localizedString(forLanguageCode: lang) ?? lang
        } else {
            base = fallback
        }
        var details: [String] = []
        if channelCount == 2 { details.append("Stereo") }
        else if channelCount == 6 { details.append("5.1") }
        else if channelCount == 8 { details.append("7.1") }
        else if channelCount > 0 { details.append("\(channelCount)ch") }
        if !codec.isEmpty { details.append(codec.uppercased()) }
        let filtered = details.filter { !base.localizedCaseInsensitiveContains($0) }
        return filtered.isEmpty ? base : "\(base) (\(filtered.joined(separator: ", ")))"
    }

    /// Audio card title: the track's own name (or language) with a codec +
    /// channel-layout summary in parens — "LostFilm (AC-3 Stereo)".
    private static func audioTrackName(title: String, languageName: String,
                                       codec: String, channelCount: Int, fallback: String) -> String {
        let base: String
        if !title.isEmpty { base = title }
        else if !languageName.isEmpty { base = languageName }
        else { base = fallback }

        let summary = [prettyCodec(codec), channelLayout(channelCount)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return summary.isEmpty ? base : "\(base) (\(summary))"
    }

    /// Audio card detail line — "AC-3 | 6 ch | 48 kHz". Omits missing pieces.
    private static func audioTrackDetail(codec: String, channels: Int, sampleRate: Int) -> String {
        var parts: [String] = []
        let pretty = prettyCodec(codec)
        if !pretty.isEmpty { parts.append(pretty) }
        if channels > 0 { parts.append("\(channels) ch") }
        if sampleRate > 0 { parts.append("\(Int((Double(sampleRate) / 1000.0).rounded())) kHz") }
        return parts.joined(separator: " | ")
    }

    private static func localizedLanguageName(_ lang: String) -> String {
        let trimmed = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let name = Locale.current.localizedString(forLanguageCode: trimmed.lowercased()) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Human channel layout name; falls back to a raw count.
    private static func channelLayout(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let n where n > 0: return "\(n)ch"
        default: return ""
        }
    }

    /// Displays common audio codecs the way listeners recognize them.
    private static func prettyCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "dts": return "DTS"
        case "dts-hd", "dtshd": return "DTS-HD"
        case "truehd": return "TrueHD"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3": return "MP3"
        case "pcm", "pcm_s16le", "pcm_s24le": return "PCM"
        case "": return ""
        default: return codec.uppercased()
        }
    }

    // MARK: - Display mode matching (frame rate + HDR)
    //
    // tvOS never switches the HDMI output to HDR just because a Metal layer
    // renders PQ/HLG content — only AVFoundation players get that for free.
    // When "Match Content → Dynamic Range" is enabled on the Apple TV, apps
    // must request the switch through AVDisplayManager. tvOS 17 added a public
    // AVDisplayCriteria initializer, so build a format description carrying the
    // stream's color tags and hand it to the window. SDR streams must go through
    // the same path when Nuvio's Frame Rate Matching setting is enabled; gating
    // criteria on HDR alone leaves 23.976/24 fps SDR video juddering at 60 Hz.

    /// `-[UIWindow avDisplayManager]` is an ObjC *category* from AVKit: calling
    /// it creates no link-time symbol reference, so the linker drops AVKit from
    /// the binary and the selector doesn't exist at runtime (crashed on device
    /// with "unrecognized selector"). Referencing a real AVKit class forces the
    /// framework to be linked and loaded.
    private static let avKitLinkAnchor: AnyClass = AVDisplayManager.self

    /// The window we last set criteria on; doubles as the "criteria active" flag.
    private weak var displayCriteriaWindow: UIWindow?
    /// Criteria are applied at most once per loaded file (reset in
    /// `attemptStartPendingLoad`). Re-running on every VIDEO_RECONFIG would
    /// re-trigger HDMI mode switches — including the RECONFIG our own
    /// detach/reattach dance produces.
    private var didApplyDisplayCriteria = false
    /// True while the HDMI mode switch is settling and video is detached.
    private var isDisplaySwitchInFlight = false
    private var displaySwitchGeneration: UInt64 = 0
    /// `VIDEO_RECONFIG` may arrive before SwiftUI has attached this controller
    /// to a window, or before MPV has populated the stream dimensions. Keep a
    /// short, coalesced probe alive for those races so HDR does not silently
    /// stay in SDR on a physical Apple TV.
    private var displayCriteriaProbeGeneration = 0
    private var displayCriteriaProbeAttempts = 0
    private var isDisplayCriteriaProbeScheduled = false
    private static let maximumDisplayCriteriaProbeAttempts = 15

    private enum DisplayCriteriaUpdateResult {
        case appliedOrAlreadyActive
        case retry
        case finished
    }

    private func resetDisplayCriteriaProbe() {
        displayCriteriaProbeGeneration &+= 1
        displayCriteriaProbeAttempts = 0
        isDisplayCriteriaProbeScheduled = false
    }

    private func scheduleDisplayCriteriaProbe(after delay: TimeInterval = 0) {
        #if !targetEnvironment(simulator)
        guard mpv != nil,
              !didApplyDisplayCriteria,
              !isDisplaySwitchInFlight,
              !isDisplayCriteriaProbeScheduled else { return }

        let generation = displayCriteriaProbeGeneration
        isDisplayCriteriaProbeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.displayCriteriaProbeGeneration else { return }
            self.isDisplayCriteriaProbeScheduled = false
            self.probeDisplayCriteria(generation: generation)
        }
        #endif
    }

    private func probeDisplayCriteria(generation: Int) {
        #if !targetEnvironment(simulator)
        guard generation == displayCriteriaProbeGeneration else { return }

        switch updateDisplayCriteria() {
        case .retry:
            guard displayCriteriaProbeAttempts < Self.maximumDisplayCriteriaProbeAttempts else {
                print("[MPV] HDR display switch skipped: video parameters did not become ready")
                finishStartupDisplayGate()
                return
            }
            displayCriteriaProbeAttempts += 1
            scheduleDisplayCriteriaProbe(after: 0.2)
        case .appliedOrAlreadyActive:
            if !isDisplaySwitchInFlight {
                finishStartupDisplayGate()
            }
        case .finished:
            finishStartupDisplayGate()
        }
        #endif
    }

    private func finishStartupDisplayGate(after delay: TimeInterval = 0) {
        guard startupDisplayGateActive else { return }
        let generation = displayCriteriaProbeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.mpv != nil,
                  generation == self.displayCriteriaProbeGeneration,
                  self.startupDisplayGateActive else { return }
            self.startupDisplayGateActive = false
            let shouldPlay = self.pendingAutoplayAfterDisplayGate
            self.pendingAutoplayAfterDisplayGate = false
            if shouldPlay {
                self.playPlayback()
            }
            self.updateState()
        }
    }

    private func updateDisplayCriteria() -> DisplayCriteriaUpdateResult {
        // AVDisplayManager isn't in the simulator SDK (there's no HDMI output
        // to switch); this whole path is device-only.
        #if !targetEnvironment(simulator)
        guard #available(tvOS 17.0, *) else { return .finished }
        guard mpv != nil, !isDisplaySwitchInFlight else { return .finished }

        let gamma = (getString("video-params/gamma") ?? "").lowercased()
        let primaries = (getString("video-params/primaries") ?? "").lowercased()
        // Dolby Vision Profile 5 can initially present as BT.709 rather than
        // PQ in video-params. Read the selected track's container metadata
        // before the HDR gate so it is not incorrectly dismissed as SDR.
        let dolbyVisionProfile = getInt("current-tracks/video/dolby-vision-profile")
        let dolbyVisionLevel = getInt("current-tracks/video/dolby-vision-level")
        let isDolbyVision = dolbyVisionProfile > 0

        // No video attached (e.g. our own `vid=no`, or backgrounding): leave
        // whatever criteria are in place alone.
        guard !gamma.isEmpty || !primaries.isEmpty else { return .retry }
        guard !gamma.isEmpty || isDolbyVision else { return .retry }

        // MPV/FFmpeg have used both concise ("pq" / "hlg") and standards
        // names (ST 2084 / ARIB B-67) for the same transfer functions.
        let isHLG = gamma.contains("hlg") || gamma.contains("b67") || gamma.contains("arib")
        let isPQ = gamma.contains("pq") || gamma.contains("2084")
        // BT.2020 describes gamut, not HDR transfer. Require PQ, HLG or DV
        // evidence before requesting HDR output for wide-gamut SDR content.
        let isHDR = isDolbyVision || isPQ || isHLG
        let frameRateMode = ProfileSettings.current.string(forKey: SettingsKey.frameRateMatching) ?? "Always"
        let shouldMatchFrameRate = frameRateMode.caseInsensitiveCompare("Off") != .orderedSame
        guard isHDR || shouldMatchFrameRate else {
            clearDisplayCriteria()
            return .finished
        }
        guard !didApplyDisplayCriteria else { return .appliedOrAlreadyActive }
        guard let window = view.window else { return .retry }
        // Skip (SDR playback, no crash) rather than abort if the category is
        // ever missing again — e.g. a future tvOS removing it.
        _ = Self.avKitLinkAnchor
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            print("[MPV] AVDisplayManager unavailable; HDR display switch skipped")
            return .finished
        }

        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        guard width > 0, height > 0 else { return .retry }

        var fps = getDouble("container-fps")
        if !fps.isFinite || fps <= 0 { fps = getDouble("estimated-vf-fps") }
        // FPS may arrive after the first video parameters. Keep the criteria
        // unapplied so the existing probe can retry with a real cadence.
        guard fps.isFinite, fps > 0 else { return .retry }

        // `video-format` is the decoded pixel format, not the encoded stream
        // codec. Use the selected track so AV1 HDR is not described as HEVC.
        let videoCodec = (getString("current-tracks/video/codec") ?? "").lowercased()
        let codecType: CMVideoCodecType
        switch videoCodec {
        case "h264": codecType = kCMVideoCodecType_H264
        case "av1", "av01": codecType = kCMVideoCodecType_AV1
        case "hevc", "h265": codecType = kCMVideoCodecType_HEVC
        default:
            print("[MPV] Unknown video codec \(videoCodec); display switch skipped")
            return .finished
        }

        let extensions: [CFString: Any]
        if isHDR {
            let transfer: CFString = isHLG
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: transfer,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            print("[MPV] Failed to build HDR format description (\(status))")
            return .finished
        }

        // This is parsed from the stream itself, unlike a source title such as
        // "4K WEBRip". Dolby Vision needs its per-frame metadata delivered by
        // the decoder/output path; the MPV Metal renderer cannot manufacture
        // that metadata for AVDisplayManager, so its compatible HDR10/PQ base
        // layer is requested here instead. The log makes the exact profile
        // visible on-device without incorrectly claiming a Dolby Vision output.
        let sourceRange: String
        // Honest labeling: MPV cannot emit native Dolby Vision over HDMI —
        // this path is the Android-equivalent STRIP_TO_HDR10 / PQ fallback.
        if isDolbyVision {
            sourceRange = "Dolby Vision profile \(dolbyVisionProfile), level \(dolbyVisionLevel) → HDR10/PQ (not native DV)"
        } else if isHLG {
            sourceRange = "HLG"
        } else if isHDR {
            sourceRange = "HDR10/PQ"
        } else {
            sourceRange = "SDR"
        }
        if isHDR {
            let targetTRC = isHLG ? "hlg" : "pq"
            // Keep the renderer's output colorimetry identical to the format
            // description sent to tvOS. Leaving these on `auto` can adapt a wide
            // gamut source to BT.709 and then have the TV interpret it as BT.2020,
            // which exaggerates reds, oranges, and skin tones.
            setStringProperty("target-prim", "bt.2020")
            setStringProperty("target-trc", targetTRC)
        } else {
            setStringProperty("target-prim", "auto")
            setStringProperty("target-trc", "auto")
        }
        print("[MPV] Display request: \(sourceRange); frameRateMode=\(frameRateMode), codec=\(videoCodec.isEmpty ? "unknown" : videoCodec), gamma=\(gamma), primaries=\(primaries), \(width)x\(height) @ \(fps)fps")

        // The HDMI mode switch tears down and rebuilds the display pipeline.
        // Presenting Vulkan frames into the CAMetalLayer while that happens
        // crashes MoltenVK, so idle mpv's video chain first (the same
        // detach/reattach the background/foreground path already survives),
        // request the switch, and only reattach once the switch has settled.
        didApplyDisplayCriteria = true
        isDisplaySwitchInFlight = true
        displaySwitchGeneration &+= 1
        let switchGeneration = displaySwitchGeneration
        setStringProperty("vid", "no")

        let manager = window.avDisplayManager
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
        displayCriteriaWindow = window

        // Give the switch a beat to start before polling for completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reattachVideoWhenDisplaySettled(manager, attemptsLeft: 16, generation: switchGeneration)
        }
        return .appliedOrAlreadyActive
        #else
        return .finished
        #endif
    }

    #if !targetEnvironment(simulator)
    private func reattachVideoWhenDisplaySettled(_ manager: AVDisplayManager, attemptsLeft: Int, generation: UInt64) {
        guard generation == displaySwitchGeneration, isDisplaySwitchInFlight else { return }
        guard mpv != nil else {
            isDisplaySwitchInFlight = false
            return
        }
        if manager.isDisplayModeSwitchInProgress || isApplicationBackgrounded {
            // Exhausting the fast-poll budget must not be treated as HDMI readiness.
            let nextAttempts = max(0, attemptsLeft - 1)
            let retryDelay: TimeInterval = attemptsLeft > 0 ? 0.25 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.reattachVideoWhenDisplaySettled(manager, attemptsLeft: nextAttempts, generation: generation)
            }
            return
        }
        isDisplaySwitchInFlight = false
        setStringProperty("vid", "auto")
        if pendingURL != nil {
            attemptStartPendingLoad()
            return
        }
        // Let the reattached video output configure and present its paused
        // landing frame before transport starts. HDMI is already settled here.
        finishStartupDisplayGate(after: 0.2)
    }
    #endif

    private func clearDisplayCriteria() {
        #if !targetEnvironment(simulator)
        displaySwitchGeneration &+= 1
        isDisplaySwitchInFlight = false
        displayCriteriaWindow?.avDisplayManager.preferredDisplayCriteria = nil
        displayCriteriaWindow = nil
        didApplyDisplayCriteria = false
        if mpv != nil {
            setStringProperty("target-prim", "auto")
            setStringProperty("target-trc", "auto")
        }
        #endif
    }

    // MARK: - Error tracking

    private func clearPlaybackError() {
        errorStateLock.lock()
        recentPlaybackLogs.removeAll(keepingCapacity: true)
        _currentErrorMessage = nil
        _didReachCleanEndOfFile = false
        errorStateLock.unlock()
    }

    private func clearCleanEndState() {
        errorStateLock.lock()
        _didReachCleanEndOfFile = false
        errorStateLock.unlock()
    }

    private func setCleanEndState(_ reachedEOF: Bool) {
        errorStateLock.lock()
        _didReachCleanEndOfFile = reachedEOF
        errorStateLock.unlock()
    }

    private func appendPlaybackLog(prefix: String, level: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard level == "warn" || level == "error" || level == "fatal" else { return }
        PlaybackDiagnosticLogStore.shared.append(
            source: "MPV",
            message: "[\(level)] [\(prefix)] \(trimmed)"
        )
        errorStateLock.lock()
        recentPlaybackLogs.append("[\(prefix)] \(trimmed)")
        if recentPlaybackLogs.count > 4 {
            recentPlaybackLogs.removeFirst(recentPlaybackLogs.count - 4)
        }
        errorStateLock.unlock()
    }

    private func setPlaybackError(_ fallback: String) {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        errorStateLock.lock()
        _didReachCleanEndOfFile = false
        var parts = recentPlaybackLogs.suffix(3)
        if !trimmedFallback.isEmpty && !parts.contains(trimmedFallback) {
            parts.append(trimmedFallback)
        }
        _currentErrorMessage = parts.isEmpty ? "Unable to play this stream." : parts.joined(separator: "\n")
        errorStateLock.unlock()
    }

    // MARK: - Event Loop

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                let event = mpv_wait_event(mpv, 0)
                guard let eventPtr = event else { break }
                if eventPtr.pointee.event_id == MPV_EVENT_NONE { break }

                switch eventPtr.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    DispatchQueue.main.async { self.updateState() }
                case MPV_EVENT_START_FILE:
                    self.eventPlaylistEntryID = eventPtr.pointee.data.map {
                        UnsafePointer<mpv_event_start_file>(OpaquePointer($0)).pointee.playlist_entry_id
                    }
                    self.clearPlaybackError()
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                    self.memoryWatchdog.record(event: "start_file")
#endif
                case MPV_EVENT_FILE_LOADED:
                    let frameToken = self.firstFrameReadiness.token
                    let entryID = self.eventPlaylistEntryID
                    DispatchQueue.main.async {
                        guard self.mpv == mpv,
                              self.watchPartyRemoteIntent == nil
                                || self.firstFrameReadiness.matches(token: frameToken, playlistEntryID: entryID) else { return }
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                        self.memoryWatchdog.record(event: "file_loaded")
#endif
                        self.clearPlaybackError()
                        guard !self.rejectUnsupportedSimulatorCodecIfNeeded() else { return }
                        self.isPlayerLoading = false
                        self.attachPendingAudioIfNeeded()
                        self.applyPendingLoadConfiguration()
                        self.applySubtitleStyle()
                        self.setAspectMode(self.currentAspectMode)
                        self.updateState()
                        self.resetDisplayCriteriaProbe()
                        self.scheduleDisplayCriteriaProbe()
                    }
                case MPV_EVENT_PLAYBACK_RESTART:
                    // MPV completes a restart after queuing the initial video
                    // frame even when pause=yes. FILE_LOADED / VIDEO_RECONFIG
                    // alone only prove loading/configuration, not this stage.
                    let frameToken = self.firstFrameReadiness.token
                    let entryID = self.eventPlaylistEntryID
                    DispatchQueue.main.async {
                        guard self.mpv == mpv, !self.isApplicationBackgrounded,
                              self.firstFrameReadiness.matches(token: frameToken, playlistEntryID: entryID) else { return }
                        self.updateState()
                        let size = self.videoFrameSize
                        let videoPTS = self.readDoubleProperty("video-pts")
                        if self.firstFrameReadiness.receiveRestart(
                            token: frameToken, playlistEntryID: entryID,
                            hasVideoFrame: size.width > 0 && size.height > 0 && videoPTS?.isFinite == true
                        ) {
                            self.onFirstFrameReady?()
                        }
                    }
                case MPV_EVENT_VIDEO_RECONFIG:
                    // Fires once decode starts and whenever the video params
                    // change — the earliest point video-params/* is reliable.
                    // A short retry covers the race where it fires before the
                    // view is attached to a UIWindow on physical Apple TV.
                    DispatchQueue.main.async {
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                        self.memoryWatchdog.record(event: "video_reconfig")
#endif
                        self.scheduleDisplayCriteriaProbe()
                    }
                case MPV_EVENT_END_FILE:
                    DispatchQueue.main.async {
                        self.subtitleTranslationState.cancelPendingTranslations()
                    }
                    if let data = eventPtr.pointee.data {
                        let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if endFile.reason == MPV_END_FILE_REASON_EOF {
                            self.setCleanEndState(true)
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                            self.memoryWatchdog.record(event: "end_file_eof")
#endif
                        } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorText = String(cString: mpv_error_string(endFile.error))
                            self.setPlaybackError("[mpv] \(errorText)")
                            print("[MPV] End file error: \(errorText)")
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                            self.memoryWatchdog.record(event: "end_file_error")
#endif
                        } else {
                            self.setCleanEndState(false)
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
                            self.memoryWatchdog.record(event: "end_file_other")
#endif
                        }
                    }
                case MPV_EVENT_COMMAND_REPLY:
                    self.handleTrackCommandReply(eventPtr)
                case MPV_EVENT_SHUTDOWN:
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(eventPtr.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix!)
                        let level = String(cString: msg.pointee.level!)
                        let text = String(cString: msg.pointee.text!)
                        self.appendPlaybackLog(prefix: prefix, level: level, text: text)
                    }
                default:
                    break
                }
            }
        }
    }

    /// MoltenVK on the tvOS simulator can eventually trap while uploading an
    /// AV1 software-decoded frame through MTLSim shared memory. Stream labels
    /// are filtered before selection, but this verifies the actual container
    /// codec as a final safety net for unlabeled direct URLs.
    private func rejectUnsupportedSimulatorCodecIfNeeded() -> Bool {
        #if targetEnvironment(simulator)
        let codec = (getString("current-tracks/video/codec") ?? "").lowercased()
        guard codec == "av1" || codec == "av01" else { return false }

        setStringProperty("vid", "no")
        command("stop", checkForErrors: false)
        setPlaybackError("AV1 playback is unavailable in the Apple TV Simulator. Choose an H.264 or HEVC stream.")
        isPlayerLoading = false
        isPlayerPlaying = false
        isPlayerEnded = false
        return true
        #else
        return false
        #endif
    }

    // MARK: - MPV Helpers

    /// Adding a remote subtitle/audio track can wait for its URL to open. Queue it
    /// asynchronously so a slow server cannot block the main thread during FILE_LOADED.
    private func commandAsyncTrack(
        _ command: String,
        args: [String?],
        url: String,
        selectionGeneration: UInt64,
        selectsWhenReady: Bool
    ) {
        guard let mpv else { return }

        pendingTrackCommandsLock.lock()
        let replyID = nextTrackCommandReplyID
        nextTrackCommandReplyID &+= 1
        pendingTrackCommands[replyID] = PendingTrackCommand(
            loadGeneration: loadGeneration,
            command: command,
            url: url,
            selectionGeneration: selectionGeneration,
            selectsWhenReady: selectsWhenReady
        )
        pendingTrackCommandsLock.unlock()

        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        let status = mpv_command_async(mpv, replyID, &cargs)
        if status < 0 {
            pendingTrackCommandsLock.lock()
            pendingTrackCommands.removeValue(forKey: replyID)
            pendingTrackCommandsLock.unlock()
            checkError(status, context: command)
        }
    }

    private func handleTrackCommandReply(_ event: UnsafeMutablePointer<mpv_event>) {
        let replyID = event.pointee.reply_userdata
        pendingTrackCommandsLock.lock()
        let pending = pendingTrackCommands.removeValue(forKey: replyID)
        pendingTrackCommandsLock.unlock()
        guard let pending else { return }
        let status = event.pointee.error
        let message = status < 0 ? String(cString: mpv_error_string(status)) : nil
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.mpv != nil,
                  self.loadGeneration == pending.loadGeneration else { return }
            if let message {
                self.appendPlaybackLog(prefix: pending.command, level: "error", text: message)
            } else {
                self.completeTrackCommand(pending)
            }
        }
    }

    private func completeTrackCommand(_ pending: PendingTrackCommand) {
        switch pending.command {
        case "sub-add":
            guard subtitleSelectionGeneration == pending.selectionGeneration else {
                reapplyDesiredSubtitleSelection()
                return
            }
            guard pending.selectsWhenReady else {
                reapplyDesiredSubtitleSelection()
                return
            }
            refreshTracks()
            guard let track = subtitleTracks.last(where: { $0.externalFilename == pending.url }) else {
                appendPlaybackLog(prefix: pending.command, level: "error", text: "Loaded subtitle track was not found")
                return
            }
            desiredSubtitleSelection = .trackID(track.id)
            applySubtitleSelection(track.id)
            subtitleSelectionGeneration &+= 1
        case "audio-add":
            guard audioSelectionGeneration == pending.selectionGeneration else {
                reapplyDesiredAudioSelection()
                return
            }
            guard pending.selectsWhenReady else {
                reapplyDesiredAudioSelection()
                return
            }
            refreshTracks()
            guard let track = audioTracks.last(where: { $0.externalFilename == pending.url }) else {
                appendPlaybackLog(prefix: pending.command, level: "error", text: "Loaded audio track was not found")
                return
            }
            desiredAudioSelection = .trackID(track.id)
            applyAudioSelection(track.id)
            audioSelectionGeneration &+= 1
        default:
            break
        }
    }

    private func reapplyDesiredSubtitleSelection() {
        guard let desiredSubtitleSelection,
              case .trackID(let trackID) = desiredSubtitleSelection else { return }
        applySubtitleSelection(trackID)
    }

    private func reapplyDesiredAudioSelection() {
        guard let desiredAudioSelection,
              case .trackID(let trackID) = desiredAudioSelection else { return }
        applyAudioSelection(trackID)
    }

    private func clearPendingTrackCommands() {
        pendingTrackCommandsLock.lock()
        pendingTrackCommands.removeAll()
        pendingTrackCommandsLock.unlock()
    }

    private func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) {
        guard mpv != nil else { return }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        let ret = mpv_command(mpv, &cargs)
        if checkForErrors { checkError(ret) }
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    private func readDoubleProperty(_ name: String) -> Double? {
        guard mpv != nil else { return nil }
        var data = Double()
        let result = mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        guard result >= 0, data.isFinite else { return nil }
        return data
    }

    private func readOptionalInt64Property(_ name: String) -> Int64? {
        guard mpv != nil else { return nil }
        var value = Int64()
        guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    private func refreshMemoryWatchdogEngineSnapshotIfDue() {
        guard Thread.isMainThread, mpv != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMemoryEngineSampleTime >= 1 else { return }
        lastMemoryEngineSampleTime = now

        memoryWatchdog.updateEngineSnapshot(MPVMemoryEngineSnapshot(
            sampledAt: Date(),
            cacheTotalBytes: readOptionalInt64Property("demuxer-cache-state/total-bytes"),
            cacheForwardBytes: readOptionalInt64Property("demuxer-cache-state/fw-bytes"),
            cacheDurationSeconds: readDoubleProperty("demuxer-cache-duration"),
            inputBytesPerSecond: readDoubleProperty("cache-speed"),
            timePositionSeconds: readDoubleProperty("time-pos"),
            coreIdle: readOptionalFlagProperty("core-idle"),
            eofReached: readOptionalFlagProperty("eof-reached"),
            cacheReaderIdle: readOptionalFlagProperty("demuxer-cache-state/idle"),
            cacheReaderEOF: readOptionalFlagProperty("demuxer-cache-state/eof"),
            cacheUnderrun: readOptionalFlagProperty("demuxer-cache-state/underrun"),
            paused: readOptionalFlagProperty("pause"),
            seeking: readOptionalFlagProperty("seeking"),
            pausedForCache: readOptionalFlagProperty("paused-for-cache"),
            width: readOptionalInt64Property("video-params/w").flatMap { Int(exactly: $0) },
            height: readOptionalInt64Property("video-params/h").flatMap { Int(exactly: $0) },
            codec: readOptionalStringProperty("video-codec"),
            hardwareDecoder: readOptionalStringProperty("hwdec-current"),
            demuxerMaxBytes: readOptionalStringProperty("demuxer-max-bytes"),
            demuxerMaxBackBytes: readOptionalStringProperty("demuxer-max-back-bytes"),
            localOrDiskCache: isLocalOrDiskCacheStream
        ))
    }

    private func readOptionalFlagProperty(_ name: String) -> Bool? {
        guard mpv != nil else { return nil }
        var value = Int64()
        guard mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value > 0
    }

    private func readOptionalStringProperty(_ name: String) -> String? {
        guard mpv != nil, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        let result = String(cString: value)
        return result.isEmpty ? nil : result
    }
#endif

    private func getDouble(_ name: String) -> Double {
        readDoubleProperty(name) ?? 0
    }

    private func milliseconds(from seconds: Double?) -> Int64? {
        guard let seconds,
              seconds.isFinite,
              seconds >= 0,
              seconds <= Double(Int64.max) / 1000 else { return nil }
        return Int64(seconds * 1000)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func setStringProperty(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        checkError(mpv_set_property_string(mpv, name, value))
    }

    private func applyHTTPHeaders(_ headers: [String: String], isLiveStream: Bool = false) {
        MPVStreamProtocolBridge.shared.setHTTPHeaders(headers, isLiveStream: isLiveStream)
        let options = MPVHTTPHeaderOptions(headers: headers)
        setStringProperty("user-agent", options.userAgent)
        // This MPV instance is reused. Empty values clear the prior source's
        // referrer and headers before the next load.
        setStringProperty("referrer", options.referrer)
        setStringProperty("http-header-fields", options.headerFields)
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        checkError(mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data))
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func checkError(_ status: CInt, context: String? = nil) {
        if status < 0 {
            if let context {
                print("[MPV] API error for \(context): \(String(cString: mpv_error_string(status)))")
            } else {
                print("[MPV] API error: \(String(cString: mpv_error_string(status)))")
            }
        }
    }
}

// MARK: - Metal Layer

final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
