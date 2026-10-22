import Foundation
import Combine

/// Live TV from the Emby / Jellyfin servers signed in under Settings →
/// Jellyfin: channel list, a few hours of real guide data, and tuning (with
/// cable-style channel up / down from the player).
@MainActor
final class LiveTVStore: ObservableObject {
    static let shared = LiveTVStore()

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// No server configured, or none of them has Live TV for this account.
        case empty(String)
        case failed(String)
    }

    enum Overlay: Equatable {
        case tuning(LiveTVChannel)
        case failed(LiveTVChannel, String)
    }

    struct Banner: Equatable {
        let channel: LiveTVChannel
        let now: LiveTVProgram?
        let next: LiveTVProgram?
        let token = UUID()
    }

    @Published private(set) var channels: [LiveTVChannel] = []
    @Published private(set) var programs: [String: [LiveTVProgram]] = [:]
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingGuide = false
    @Published private(set) var watching: LiveTVChannel?
    @Published private(set) var overlay: Overlay?
    @Published private(set) var banner: Banner?
    /// Short confirmation shown in the guide ("Added to Multiview").
    @Published var toast: String?

    var isWatching: Bool { watching != nil }

    /// Wired by the app root, which owns the player.
    var present: ((LiveTVChannel, URL, NuvioMeta, String) -> Void)?
    var leavePlayer: (() -> Void)?

    static let guideHours = 3.0
    private static let guideLifetime: TimeInterval = 20 * 60
    private static let channelLifetime: TimeInterval = 6 * 60 * 60
    private static let programBatch = 60

    private var loadedSignature: String?
    private var channelsLoadedAt: Date?
    private var guideLoadedAt: Date?
    private var guideWindowStart: Date?
    private var loadTask: Task<Void, Never>?
    private var guideTask: Task<Void, Never>?
    private var tuneTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var openStreams: [String: (stream: LiveTVStream, serverID: String)] = [:]

    // MARK: Servers

    private struct Server {
        let config: JellyfinServerConfig
        let client: LiveTVClient
    }

    private func servers() -> [Server] {
        JellyfinServerStore.shared.servers.compactMap { config in
            guard let base = config.baseURL else { return nil }
            let token = JellyfinCredentialStore.token(forServerID: config.id)
            guard !token.isEmpty else { return nil }
            return Server(config: config, client: LiveTVClient(serverID: config.id, baseURL: base, token: token, userID: config.userId))
        }
    }

    private func client(for serverID: String) -> LiveTVClient? {
        servers().first { $0.config.id == serverID }?.client
    }

    var hasServers: Bool { !JellyfinServerStore.shared.servers.isEmpty }

    // MARK: Loading

    func loadIfNeeded(force: Bool = false) {
        let signature = ProfileSettings.activeProfileScope + "|" + JellyfinServerStore.shared.servers.map(\.id).joined(separator: ",")
        if signature != loadedSignature {
            channels = []
            programs = [:]
            channelsLoadedAt = nil
            guideLoadedAt = nil
            state = .idle
        }
        let channelsFresh = channelsLoadedAt.map { Date().timeIntervalSince($0) < Self.channelLifetime } ?? false
        if !force, channelsFresh, signature == loadedSignature, !channels.isEmpty {
            refreshGuideIfNeeded()
            return
        }
        guard loadTask == nil else { return }
        loadedSignature = signature
        let configured = servers()
        guard !configured.isEmpty else {
            state = .empty(hasServers
                ? "Sign in to your server again in Settings → Jellyfin."
                : "Add your Emby or Jellyfin server in Settings → Jellyfin (server address, username and password) to see its live channels here.")
            return
        }
        if channels.isEmpty { state = .loading }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            var all: [LiveTVChannel] = []
            var problems: [String] = []
            for server in configured {
                var client = server.client
                do {
                    if client.userID.isEmpty, let base = server.config.baseURL {
                        let resolved = try await JellyfinClient.currentUserId(
                            baseURL: base, apiKey: client.token, username: server.config.username
                        )
                        var updated = server.config
                        updated.userId = resolved
                        JellyfinServerStore.shared.upsert(updated)
                        client = LiveTVClient(serverID: client.serverID, baseURL: client.baseURL, token: client.token, userID: resolved)
                    }
                    all += try await client.channels()
                } catch {
                    problems.append("\(server.config.displayName): \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            self.channels = Self.ordered(all)
            self.channelsLoadedAt = Date()
            if all.isEmpty {
                self.state = problems.isEmpty
                    ? .empty("Your server didn't list any live channels for this account.")
                    : .failed(problems.joined(separator: "\n"))
            } else {
                self.state = .loaded
                self.guideLoadedAt = nil
                self.refreshGuideIfNeeded()
            }
        }
    }

    /// Favorites first, then by channel number (numeric where possible), then name.
    private static func ordered(_ channels: [LiveTVChannel]) -> [LiveTVChannel] {
        channels.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            switch (a.number.flatMap(Double.init), b.number.flatMap(Double.init)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The guide grid starts at the last half hour.
    static func windowStart(for date: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return calendar.date(from: components) ?? date
    }

    func refreshGuideIfNeeded() {
        let start = Self.windowStart()
        let fresh = guideLoadedAt.map { Date().timeIntervalSince($0) < Self.guideLifetime } ?? false
        guard !(fresh && guideWindowStart == start), guideTask == nil, !channels.isEmpty else { return }
        let end = start.addingTimeInterval(Self.guideHours * 3600 + 1800)
        let byServer = Dictionary(grouping: channels, by: \.serverID)
        let clients = Dictionary(uniqueKeysWithValues: servers().map { ($0.config.id, $0.client) })
        isLoadingGuide = true
        guideTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.guideTask = nil
                self.isLoadingGuide = false
            }
            var collected: [String: [LiveTVProgram]] = [:]
            for (serverID, serverChannels) in byServer {
                guard let client = clients[serverID] else { continue }
                // Channels in view first, so the top of the guide fills in quickly.
                let ids = serverChannels.map(\.itemID)
                for batchStart in stride(from: 0, to: ids.count, by: Self.programBatch) {
                    guard !Task.isCancelled else { return }
                    let batch = Array(ids[batchStart..<min(ids.count, batchStart + Self.programBatch)])
                    guard let list = try? await client.programs(channelItemIDs: batch, from: start, to: end) else { continue }
                    for program in list { collected[program.channelID, default: []].append(program) }
                    var merged = self.programs
                    for id in batch.map({ "\(serverID)|\($0)" }) {
                        merged[id] = (collected[id] ?? []).sorted { $0.start < $1.start }
                    }
                    self.programs = merged
                }
            }
            self.guideLoadedAt = Date()
            self.guideWindowStart = start
        }
    }

    // MARK: Guide helpers

    func current(on channelID: String, at date: Date = Date()) -> LiveTVProgram? {
        programs[channelID]?.first { $0.isOn(at: date) }
    }

    func next(on channelID: String, at date: Date = Date()) -> LiveTVProgram? {
        programs[channelID]?.first { $0.start >= date }
    }

    func number(of channel: LiveTVChannel) -> String {
        if let number = channel.number { return number }
        return String((channels.firstIndex(of: channel) ?? 0) + 1)
    }

    // MARK: Watching

    func watch(_ channel: LiveTVChannel) {
        tuneTask?.cancel()
        bannerTask?.cancel()
        banner = nil
        let previous = watching
        watching = channel
        overlay = .tuning(channel)
        tuneTask = Task { [weak self] in
            guard let self else { return }
            if let previous, previous.id != channel.id { await self.close(previous) }
            guard let client = self.client(for: channel.serverID) else {
                self.overlay = .failed(channel, "Sign in to this server again in Settings → Jellyfin.")
                return
            }
            let started = Date()
            do {
                let stream = try await client.openStream(channelItemID: channel.itemID)
                guard !Task.isCancelled, self.watching?.id == channel.id else {
                    await client.closeStream(stream)
                    return
                }
                self.openStreams[channel.id] = (stream, channel.serverID)
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 0.6 { try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000)) }
                guard !Task.isCancelled, self.watching?.id == channel.id else { return }
                let now = self.current(on: channel.id)
                self.overlay = nil
                self.present?(channel, stream.url, self.meta(for: channel, now: now), now?.title ?? "")
                self.showBanner(for: channel)
            } catch {
                guard !Task.isCancelled, self.watching?.id == channel.id else { return }
                self.overlay = .failed(channel, error.localizedDescription)
            }
        }
    }

    /// Channel up / down from the player.
    func flip(by step: Int) {
        guard let current = watching, let index = channels.firstIndex(of: current), channels.count > 1 else { return }
        let target = channels[(index + step + channels.count) % channels.count]
        leavePlayer?()
        watch(target)
    }

    /// Leaving the player or the tuning card.
    func stopWatching() {
        tuneTask?.cancel()
        bannerTask?.cancel()
        let channel = watching
        watching = nil
        overlay = nil
        banner = nil
        if let channel {
            Task { [weak self] in await self?.close(channel) }
        }
    }

    /// Frees the server-side stream unless Multiview is still showing it.
    private func close(_ channel: LiveTVChannel) async {
        guard let open = openStreams[channel.id] else { return }
        if MultiviewStore.shared.contains(url: open.stream.url) { return }
        openStreams[channel.id] = nil
        await client(for: open.serverID)?.closeStream(open.stream)
    }

    func meta(for channel: LiveTVChannel, now: LiveTVProgram?) -> NuvioMeta {
        let description = [now?.title, now?.episodeTitle, now?.overview].compactMap { $0 }.joined(separator: "\n")
        return NuvioMeta(
            id: "live:jf:\(channel.serverID):\(channel.itemID)",
            name: channel.name,
            description: description.isEmpty ? nil : description,
            posterUrl: channel.imageURL?.absoluteString,
            backgroundUrl: now?.imageURL?.absoluteString,
            logoUrl: channel.imageURL?.absoluteString,
            type: "livetv"
        )
    }

    private func showBanner(for channel: LiveTVChannel) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.watching?.id == channel.id else { return }
            self.banner = Banner(channel: channel, now: self.current(on: channel.id), next: self.next(on: channel.id))
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    // MARK: Multiview & favorites

    func addToMultiview(_ channel: LiveTVChannel) {
        Task { [weak self] in
            guard let self, let client = self.client(for: channel.serverID) else { return }
            self.flash("Opening \(channel.name)…")
            do {
                let stream = try await client.openStream(channelItemID: channel.itemID)
                let store = MultiviewStore.shared
                store.add(MultiviewChannel(
                    id: stream.url.absoluteString,
                    title: channel.name,
                    subtitle: self.current(on: channel.id)?.title,
                    url: stream.url,
                    httpHeaders: [:],
                    artworkURL: channel.imageURL
                ))
                self.flash("Added \(channel.name) to Multiview · \(store.channels.count) of \(MultiviewStore.maxTiles)")
            } catch {
                self.flash(error.localizedDescription)
            }
        }
    }

    func toggleFavorite(_ channel: LiveTVChannel) {
        guard let index = channels.firstIndex(of: channel) else { return }
        let favorite = !channel.isFavorite
        var updated = channels
        updated[index].isFavorite = favorite
        channels = Self.ordered(updated)
        Task { [weak self] in
            do {
                try await self?.client(for: channel.serverID)?.setFavorite(favorite, itemID: channel.itemID)
            } catch {
                self?.flash(error.localizedDescription)
            }
        }
    }

    private func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Screenshot tour

    /// Sample guide for the CI screenshot tour (`-NuvioScreenTour live-demo`),
    /// so the layout can be checked without a real server.
    func loadDemo() {
        let names = ["News 24", "Sports Central", "Movie Classics", "Kids Zone", "Nature HD", "Comedy Hits", "Local 7", "Music Live"]
        let shows: [[(String, Int, String)]] = [
            [("Evening News", 60, "news"), ("World Tonight", 30, "news"), ("Late Edition", 60, "news"), ("Overnight", 60, "news")],
            [("NFL Football: Seattle at Denver", 190, "sports"), ("Postgame", 30, "sports")],
            [("Casablanca", 105, "movie"), ("The Third Man", 95, "movie")],
            [("Cartoon Block", 30, "kids"), ("Science Kids", 30, "kids"), ("Puzzle Time", 30, "kids"), ("Story Hour", 60, "kids"), ("Bedtime Tales", 60, "kids")],
            [("Planet Oceans", 60, ""), ("Wild Mountains", 60, ""), ("Desert Life", 60, ""), ("Night Sky", 60, "")],
            [("Stand-Up Tonight", 45, ""), ("Sketch Hour", 60, ""), ("Late Laughs", 60, ""), ("Reruns", 60, "")],
            [("Local Weather", 15, "news"), ("City Council Live", 75, "news"), ("Community Spotlight", 30, ""), ("Late News", 30, "news"), ("Overnight", 60, "")],
            [("Concert Series", 120, ""), ("Top 20 Countdown", 90, "")]
        ]
        let start = Self.windowStart().addingTimeInterval(-20 * 60)
        var demoChannels: [LiveTVChannel] = []
        var demoPrograms: [String: [LiveTVProgram]] = [:]
        for (index, name) in names.enumerated() {
            let channel = LiveTVChannel(id: "demo|\(index)", serverID: "demo", itemID: "\(index)", name: name, number: String(index + 2), imageURL: nil, isFavorite: index == 1)
            demoChannels.append(channel)
            var cursor = start
            demoPrograms[channel.id] = shows[index].enumerated().map { offset, show in
                let end = cursor.addingTimeInterval(TimeInterval(show.1 * 60))
                defer { cursor = end }
                return LiveTVProgram(
                    id: "demo|\(index)|\(offset)", channelID: channel.id, title: show.0,
                    episodeTitle: offset == 1 ? "Episode \(offset + 3)" : nil,
                    overview: "Sample listing used for the automated screenshot tour.",
                    start: cursor, end: end,
                    isMovie: show.2 == "movie", isSports: show.2 == "sports", isNews: show.2 == "news", isKids: show.2 == "kids",
                    isLive: show.2 == "sports", isPremiere: offset == 0 && index % 3 == 0, imageURL: nil
                )
            }
        }
        loadedSignature = ProfileSettings.activeProfileScope + "|" + JellyfinServerStore.shared.servers.map(\.id).joined(separator: ",")
        channelsLoadedAt = Date()
        guideLoadedAt = Date()
        guideWindowStart = Self.windowStart()
        channels = Self.ordered(demoChannels)
        programs = demoPrograms
        state = .loaded
    }
}
