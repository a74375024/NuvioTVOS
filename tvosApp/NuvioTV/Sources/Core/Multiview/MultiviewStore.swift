import Foundation
import Combine
import SwiftUI
import UIKit
import AetherEngine

/// One live stream the user added to Multiview. Captured from the running
/// player so a tile can reopen exactly what was on screen (same URL and
/// request headers) without re-resolving through the add-ons.
struct MultiviewChannel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let url: URL
    let httpHeaders: [String: String]
    let artworkURL: URL?
}

/// How the grid arranges its tiles. Spotlight gives one game most of the
/// screen with the rest stacked beside it.
enum MultiviewLayout: Equatable {
    case grid
    case spotlight
}

/// Session-scoped list of Multiview channels plus the presentation flag the
/// root view binds its full-screen cover to. Nothing is persisted: live links
/// usually expire, so a stale grid after relaunch would only show errors.
@MainActor
final class MultiviewStore: ObservableObject {
    static let shared = MultiviewStore()

    /// AetherEngine is validated with up to four live tiles on Apple TV
    /// (Sodalite#175, AE#687). More would split the disk budget too thin.
    static let maxTiles = 4

    @Published private(set) var channels: [MultiviewChannel] = []
    @Published var isPresented = false
    /// Remembered across visits so adding a channel keeps the chosen layout.
    @Published var layout: MultiviewLayout = .grid
    /// The channel in the large spotlight tile; nil means the first tile.
    @Published var spotlightID: String?

    private var presentTask: Task<Void, Never>?

    var isFull: Bool { channels.count >= Self.maxTiles }

    func contains(url: URL) -> Bool {
        channels.contains { $0.url == url }
    }

    /// Adds the channel unless the same stream is already in the grid. When the
    /// grid is full the oldest tile makes room, so the newest pick always shows.
    func add(_ channel: MultiviewChannel) {
        guard !contains(url: channel.url) else { return }
        if channels.count >= Self.maxTiles {
            channels.removeFirst()
        }
        channels.append(channel)
    }

    func remove(id: String) {
        channels.removeAll { $0.id == id }
        if spotlightID == id { spotlightID = nil }
        if channels.isEmpty {
            isPresented = false
        }
    }

    func clear() {
        channels.removeAll()
        spotlightID = nil
        isPresented = false
    }

    /// Opens the grid once the full-screen player has torn down its engine, so
    /// the tiles never compete with it for the audio session or the panel.
    func presentAfterPlayerTeardown(delay: TimeInterval = 0.45) {
        presentTask?.cancel()
        presentTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.channels.isEmpty else { return }
            self.isPresented = true
        }
    }

    func dismiss() {
        presentTask?.cancel()
        isPresented = false
    }
}

/// One playing tile. Owns its own `AetherEngine`; the engine coordinates the
/// shared audio session, Now Playing and display criteria with the others
/// (see Vendor/AetherEngine/docs/api.md, "Running several engines at once").
@MainActor
final class MultiviewTile: ObservableObject, Identifiable {
    enum Status: Equatable {
        case loading
        case playing
        case failed(String)
    }

    let channel: MultiviewChannel
    let engine: AetherEngine?
    nonisolated var id: String { channel.id }

    /// Explicit rather than inferred from the tag: the grid can promote a
    /// secondary tile when the primary one is removed (applies on next load).
    var role: SharedOutputRole = .secondary

    @Published private(set) var status: Status = .loading
    @Published private(set) var isAudible = false

    private var loadTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isStopped = false
    private var fullReloadAttempts = 0

    init(channel: MultiviewChannel) {
        self.channel = channel
        self.engine = try? AetherEngine()
        if engine == nil {
            status = .failed(L10n.string("multiview_engine_unavailable", fallback: "Player unavailable"))
        }
    }

    func start(tag: String, role: SharedOutputRole) {
        guard let engine else { return }
        isStopped = false
        self.role = role
        engine.logTag = tag
        // Every tile starts silent; the grid makes the focused one audible.
        engine.volume = isAudible ? 1 : 0
        observe(engine)
        load(engine: engine)
    }

    func setAudible(_ audible: Bool) {
        isAudible = audible
        engine?.volume = audible ? 1 : 0
    }

    func retry() {
        guard let engine, !isStopped else { return }
        status = .loading
        fullReloadAttempts = 0
        load(engine: engine)
    }

    /// Every engine must be stopped before release, or the shared audio
    /// session is never handed back (api.md, "Stop every engine").
    func stop() {
        isStopped = true
        loadTask?.cancel()
        recoveryTask?.cancel()
        cancellables.removeAll()
        engine?.stop()
    }

    private func load(engine: AetherEngine) {
        let role = self.role
        loadTask?.cancel()
        let url = channel.url
        let lowered = url.absoluteString.lowercased()
        let isHLS = url.pathExtension.lowercased() == "m3u8" || lowered.contains(".m3u8")
        let panelInHDR = UIScreen.main.currentEDRHeadroom > 1.001
        let options = LoadOptions(
            // Tiles never switch the TV's picture mode: a frame-rate or HDR
            // handshake per tile would blank the whole panel each time.
            suppressDisplayCriteria: true,
            httpHeaders: channel.httpHeaders,
            matchContentEnabled: false,
            panelIsInHDRMode: panelInHDR,
            nativeRemoteHLS: isHLS,
            autoplay: true,
            sharedOutputRole: role
        )
        loadTask = Task { @MainActor [weak self] in
            do {
                _ = try await engine.load(url: url, options: options)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isStopped else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func observe(_ engine: AetherEngine) {
        cancellables.removeAll()

        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self, ready, !self.isStopped else { return }
                self.status = .playing
                self.fullReloadAttempts = 0
            }
            .store(in: &cancellables)

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, !self.isStopped else { return }
                switch state {
                case .error(let message):
                    // Live origins drop often; rejoin a few times before
                    // showing the error and handing retry to the viewer.
                    if self.fullReloadAttempts < 3, self.status == .playing {
                        self.scheduleRecovery()
                    } else {
                        self.status = .failed(message)
                    }
                case .ended:
                    // A live feed that "ends" has usually dropped; try to rejoin.
                    self.scheduleRecovery()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Live retune contract (api.md, "Live: the retune request"): back off,
        // try the in-engine recovery, and fall back to a bounded full reload.
        engine.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRecovery()
            }
            .store(in: &cancellables)
    }

    private func scheduleRecovery() {
        guard recoveryTask == nil, let engine else { return }
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.recoveryTask = nil
            guard !Task.isCancelled, !self.isStopped else { return }
            if engine.retryLiveSourceRecovery() { return }
            guard self.fullReloadAttempts < 3 else {
                self.status = .failed(L10n.string("multiview_stream_lost", fallback: "Stream lost"))
                return
            }
            self.fullReloadAttempts += 1
            self.status = .loading
            self.load(engine: engine)
        }
    }
}
