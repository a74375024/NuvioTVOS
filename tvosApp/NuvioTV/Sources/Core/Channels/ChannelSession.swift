import Foundation
import Combine

/// One program on a channel: a movie, or a specific episode of a show.
struct ChannelItem: Identifiable, Equatable {
    let id: String
    let channelID: String
    /// Full metadata (series include their episode guide).
    let meta: NuvioMeta
    let episode: NuvioVideo?
    /// Estimated running time, for laying the program out in the guide.
    let durationMinutes: Int

    var title: String { meta.name }

    /// "S3 · E14 · Title" for episodes; used by the player to know the episode.
    var subtitleLine: String {
        guard let episode else { return "" }
        return "S\(episode.season) · E\(episode.episode) · \(episode.title)"
    }

    var episodeTitle: String? {
        guard let title = episode?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, !title.lowercased().hasPrefix("episode ") else { return nil }
        return title
    }

    var detailLine: String {
        if let episode {
            let code = "S\(episode.season) · E\(episode.episode)"
            return episodeTitle.map { "\(code) · \($0)" } ?? code
        }
        var parts = [L10n.string("channel_movie", fallback: "Movie")]
        if let year = meta.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    var overview: String? {
        let text = (episode?.overview ?? meta.description)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? meta.description : text
    }

    var artworkURL: String? {
        episode?.thumbnail ?? meta.backgroundUrl ?? meta.posterUrl
    }

    var backdropURL: String? {
        meta.backgroundUrl ?? episode?.thumbnail ?? meta.posterUrl
    }

    static func == (lhs: ChannelItem, rhs: ChannelItem) -> Bool { lhs.id == rhs.id }

    /// Parses Cinemeta runtimes like "22 min", "1h 52min", "112 min" or "2h".
    static func minutes(fromRuntime runtime: String?, isSeries: Bool) -> Int {
        let fallback = isSeries ? 30 : 105
        guard let raw = runtime?.lowercased(), !raw.isEmpty else { return fallback }
        func number(before unit: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*\(unit)") else { return nil }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range),
                  let numberRange = Range(match.range(at: 1), in: raw) else { return nil }
            return Int(raw[numberRange])
        }
        let hours = number(before: "h") ?? 0
        let mins = number(before: "m") ?? 0
        var total = hours * 60 + mins
        if total == 0, let bare = Int(raw.filter(\.isNumber)) { total = bare }
        return (5...300).contains(total) ? total : fallback
    }
}

/// Runs the Channels feature: builds each channel's pool from Cinemeta, keeps
/// a few hours of upcoming programs per channel for the guide, finds streams
/// ahead of time, and moves from one program to the next. Tuning in always
/// starts the program from the beginning.
@MainActor
final class ChannelSessionStore: ObservableObject {
    static let shared = ChannelSessionStore()

    enum Overlay: Equatable {
        case tuning(channelID: String, item: ChannelItem?)
        case upNext(channelID: String, item: ChannelItem?)
        case failed(channelID: String, message: String)
    }

    /// Cable-style info bar shown over playback when a program starts.
    struct Banner: Equatable {
        let channelID: String
        let item: ChannelItem
        let next: ChannelItem?
        let token = UUID()
    }

    @Published private(set) var channels: [ChannelDefinition] = []
    /// Upcoming programs per channel (first = what tuning in starts with).
    @Published private(set) var lineups: [String: [ChannelItem]] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isLoadingLineup = false
    @Published private(set) var activeChannelID: String?
    @Published private(set) var nowPlaying: ChannelItem?
    @Published private(set) var overlay: Overlay?
    @Published private(set) var banner: Banner?

    var isActive: Bool { activeChannelID != nil }

    /// What each channel will start with when tuned to.
    var previews: [String: ChannelItem] {
        lineups.compactMapValues(\.first)
    }

    func number(of channelID: String) -> Int {
        (channels.firstIndex { $0.id == channelID } ?? 0) + 101
    }

    // Wired by the app root, which owns stream resolution and the player.
    var resolveStream: ((ChannelItem) async -> PreparedNextStream?)?
    var presentItem: ((ChannelItem, PreparedNextStream) -> Void)?
    var leavePlayer: (() -> Void)?

    private let repository = CinemetaCatalogRepository()
    private var pools: [String: [NuvioMeta]] = [:]
    private var poolsBuiltAt: Date?
    private var poolsBuiltForChannels: [String] = []
    private var recentByChannel: [String: [String]] = [:]
    private var lineupTask: Task<Void, Never>?
    private var fillTasks: [String: Task<Void, Never>] = [:]
    private var sessionTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var preparedStreams: [String: (stream: PreparedNextStream, at: Date)] = [:]
    private var resolving: [String: Task<PreparedNextStream?, Never>] = [:]

    nonisolated static let catalogSourceURL = "https://v3-cinemeta.strem.io/manifest.json"
    /// How much programming the guide lays out per channel.
    static let guideWindowMinutes = 180
    private static let maxLineupItems = 8
    private static let poolLifetime: TimeInterval = 12 * 60 * 60
    private static let maxAttempts = 4
    private static let resolveTimeout: UInt64 = 25
    private static let preparedLifetime: TimeInterval = 90 * 60
    private static let minimumRatingWhenKnown = 6.0

    // MARK: - Guide

    func loadLineupIfNeeded() {
        let todays = ChannelLineup.available()
        channels = todays
        let ids = todays.map(\.id)
        let hasAnyPool = pools.values.contains { !$0.isEmpty }
        let fresh = hasAnyPool && (poolsBuiltAt.map { Date().timeIntervalSince($0) < Self.poolLifetime } ?? false)
        if fresh, ids == poolsBuiltForChannels {
            ids.forEach(fillLineup)
            return
        }
        guard lineupTask == nil else { return }
        isLoadingLineup = true
        lineupTask = Task { [weak self] in
            guard let self else { return }
            let built = await self.buildPools(for: todays)
            self.pools = built
            self.poolsBuiltAt = Date()
            self.poolsBuiltForChannels = ids
            self.unavailable = Set(ids.filter { (built[$0] ?? []).isEmpty })
            self.lineups = [:]
            self.isLoadingLineup = false
            self.lineupTask = nil
            ids.forEach(self.fillLineup)
        }
    }

    /// Tops a channel's lineup up to about three hours of programs. The first
    /// program lands quickly; the rest fill in behind it.
    private func fillLineup(_ channelID: String) {
        guard fillTasks[channelID] == nil, !unavailable.contains(channelID) else { return }
        fillTasks[channelID] = Task { [weak self] in
            guard let self else { return }
            defer { self.fillTasks[channelID] = nil }
            var misses = 0
            while !Task.isCancelled, misses < 3 {
                let current = self.lineups[channelID] ?? []
                let minutes = current.reduce(0) { $0 + $1.durationMinutes }
                guard minutes < Self.guideWindowMinutes, current.count < Self.maxLineupItems else { return }
                let avoid = Set(current.map(\.meta.id) + [self.nowPlaying?.meta.id].compactMap { $0 })
                guard let item = await self.pick(channelID: channelID, avoidingShowIDs: avoid) else {
                    misses += 1
                    continue
                }
                var updated = self.lineups[channelID] ?? []
                guard !updated.contains(item) else { misses += 1; continue }
                updated.append(item)
                self.lineups[channelID] = updated
            }
        }
    }

    private func buildPools(for channels: [ChannelDefinition]) async -> [String: [NuvioMeta]] {
        let queries = Array(Set(channels.flatMap(\.queries)))
        var candidates: [String: NuvioMeta] = [:]
        await withTaskGroup(of: [NuvioMeta].self) { group in
            for query in queries {
                group.addTask { [repository] in
                    var items: [NuvioMeta] = []
                    for (catalog, skip) in [("top", 0), ("top", 100), ("imdbRating", 0)] {
                        // Cinemeta's public catalogs are read directly as a title
                        // source, even when Cinemeta is turned off in Settings.
                        let page = try? await repository.browseCatalog(
                            addonId: ChannelSessionStore.catalogSourceURL,
                            contentType: query.type,
                            catalogId: catalog,
                            skip: skip,
                            genre: query.genre
                        )
                        items += (page?.items ?? []).map { meta in
                            meta.genres?.isEmpty == false ? meta : meta.withGenres([query.genre])
                        }
                    }
                    return items
                }
            }
            for await items in group {
                for meta in items where candidates[meta.id] == nil {
                    candidates[meta.id] = meta
                }
            }
        }

        var pools: [String: [NuvioMeta]] = [:]
        for meta in candidates.values {
            if let rating = meta.rating, rating.isFinite, rating > 0, rating < Self.minimumRatingWhenKnown { continue }
            guard let owner = ChannelLineup.owner(of: meta, among: channels) else { continue }
            pools[owner, default: []].append(meta)
        }
        return pools
    }

    // MARK: - Picking

    /// A random program from the channel, avoiding shows already in its lineup
    /// and titles shown recently.
    private func pick(channelID: String, avoidingShowIDs: Set<String> = []) async -> ChannelItem? {
        guard let pool = pools[channelID], !pool.isEmpty else { return nil }
        let recentList = recentByChannel[channelID] ?? []
        let memory = min(recentList.count, max(0, pool.count - avoidingShowIDs.count - 3))
        let avoid = Set(recentList.suffix(memory)).union(avoidingShowIDs)
        var candidates = pool.filter { !avoid.contains($0.id) }.shuffled()
        if candidates.isEmpty { candidates = pool.filter { !avoidingShowIDs.contains($0.id) }.shuffled() }
        if candidates.isEmpty { candidates = pool.shuffled() }

        for candidate in candidates.prefix(6) {
            if candidate.isSeries {
                guard let full = try? await repository.getMetadata(id: candidate.id, type: "series") else { continue }
                let showMeta = full.genres?.isEmpty == false ? full : full.withGenres(candidate.genres ?? [])
                guard let episode = EpisodeShuffler.pick(
                    from: full.videos ?? [],
                    options: .wholeShow,
                    excluding: [],
                    currentID: nil,
                    isWatched: { _ in false }
                ) else { continue }
                return ChannelItem(
                    id: "\(channelID)|\(full.id)|\(episode.id)",
                    channelID: channelID,
                    meta: showMeta,
                    episode: episode,
                    durationMinutes: ChannelItem.minutes(fromRuntime: full.runtime ?? candidate.runtime, isSeries: true)
                )
            } else {
                let full = (try? await repository.getMetadata(id: candidate.id, type: "movie")) ?? candidate
                return ChannelItem(
                    id: "\(channelID)|\(full.id)",
                    channelID: channelID,
                    meta: full.genres?.isEmpty == false ? full : full.withGenres(candidate.genres ?? []),
                    episode: nil,
                    durationMinutes: ChannelItem.minutes(fromRuntime: full.runtime ?? candidate.runtime, isSeries: false)
                )
            }
        }
        return nil
    }

    private func remember(_ item: ChannelItem) {
        var list = recentByChannel[item.channelID] ?? []
        list.removeAll { $0 == item.meta.id }
        list.append(item.meta.id)
        if list.count > 30 { list.removeFirst(list.count - 30) }
        recentByChannel[item.channelID] = list
    }

    // MARK: - Streams

    /// Finds (or reuses) a stream for a program. Shared by the guide preview,
    /// tuning and prefetching so one lookup serves all three.
    func preparedStream(for item: ChannelItem) async -> PreparedNextStream? {
        if let cached = preparedStreams[item.id], Date().timeIntervalSince(cached.at) < Self.preparedLifetime {
            return cached.stream
        }
        if let inFlight = resolving[item.id] {
            return await inFlight.value
        }
        let task = Task { [weak self] () -> PreparedNextStream? in
            guard let self else { return nil }
            return await self.resolveWithTimeout(item)
        }
        resolving[item.id] = task
        let stream = await task.value
        resolving[item.id] = nil
        if let stream {
            preparedStreams[item.id] = (stream, Date())
            if preparedStreams.count > 24 {
                let oldest = preparedStreams.sorted { $0.value.at < $1.value.at }.prefix(preparedStreams.count - 24)
                oldest.forEach { preparedStreams.removeValue(forKey: $0.key) }
            }
        }
        return stream
    }

    func cachedStream(for item: ChannelItem) -> PreparedNextStream? {
        guard let cached = preparedStreams[item.id], Date().timeIntervalSince(cached.at) < Self.preparedLifetime else { return nil }
        return cached.stream
    }

    // MARK: - Session

    /// Tunes to a channel, starting from the beginning of the chosen program
    /// (its first upcoming one unless a later one was picked in the guide).
    func tune(_ channelID: String, startingAt itemID: String? = nil) {
        stopTasks()
        if let itemID, var lineup = lineups[channelID], let index = lineup.firstIndex(where: { $0.id == itemID }) {
            lineup.removeFirst(index)
            lineups[channelID] = lineup
        }
        activeChannelID = channelID
        overlay = .tuning(channelID: channelID, item: lineups[channelID]?.first)
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.startNextProgram(channelID: channelID, minimumOverlay: 0.8, isTuning: true)
        }
    }

    /// Channel up / down while watching.
    func flip(by step: Int) {
        guard let current = activeChannelID,
              let index = channels.firstIndex(where: { $0.id == current }) else { return }
        let playable = channels.filter { !unavailable.contains($0.id) }
        guard playable.count > 1 else { return }
        var nextIndex = index
        repeat {
            nextIndex = (nextIndex + step + channels.count) % channels.count
        } while unavailable.contains(channels[nextIndex].id) && nextIndex != index
        let target = channels[nextIndex].id
        leavePlayer?()
        tune(target)
    }

    /// Called by the player when a program ends.
    func itemFinished() {
        guard let channelID = activeChannelID else { return }
        leavePlayer?()
        overlay = .upNext(channelID: channelID, item: lineups[channelID]?.first)
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.startNextProgram(channelID: channelID, minimumOverlay: 4, isTuning: false)
        }
    }

    /// Leaves the channel (Menu from the player or the tuning card).
    func stop() {
        stopTasks()
        activeChannelID = nil
        overlay = nil
        nowPlaying = nil
        banner = nil
    }

    private func stopTasks() {
        sessionTask?.cancel()
        prefetchTask?.cancel()
        bannerTask?.cancel()
        sessionTask = nil
        prefetchTask = nil
    }

    private func startNextProgram(channelID: String, minimumOverlay: TimeInterval, isTuning: Bool) async {
        let started = Date()
        var attempts = 0
        while attempts < Self.maxAttempts, !Task.isCancelled, activeChannelID == channelID {
            attempts += 1
            var item = lineups[channelID]?.first
            if item == nil {
                item = await pick(channelID: channelID, avoidingShowIDs: Set([nowPlaying?.meta.id].compactMap { $0 }))
                if let item { lineups[channelID] = [item] }
            }
            guard let item else { break }
            overlay = isTuning
                ? .tuning(channelID: channelID, item: item)
                : .upNext(channelID: channelID, item: item)

            let stream = await preparedStream(for: item)
            guard !Task.isCancelled, activeChannelID == channelID else { return }

            // The program leaves the lineup either way: it's playing or unplayable.
            lineups[channelID] = (lineups[channelID] ?? []).filter { $0.id != item.id }
            remember(item)
            guard let stream else {
                // Nothing playable from the user's add-ons: quietly try another.
                fillLineup(channelID)
                continue
            }
            preparedStreams[item.id] = nil

            let elapsed = Date().timeIntervalSince(started)
            if elapsed < minimumOverlay {
                try? await Task.sleep(nanoseconds: UInt64((minimumOverlay - elapsed) * 1_000_000_000))
            }
            guard !Task.isCancelled, activeChannelID == channelID else { return }

            nowPlaying = item
            overlay = nil
            presentItem?(item, stream)
            fillLineup(channelID)
            showBanner(channelID: channelID, item: item)
            prefetchNext(channelID: channelID)
            return
        }
        guard !Task.isCancelled, activeChannelID == channelID else { return }
        overlay = .failed(
            channelID: channelID,
            message: L10n.string(
                "channel_nothing_playable",
                fallback: "Couldn't find anything playable on this channel right now. Your add-ons may not have streams for these titles."
            )
        )
    }

    private func showBanner(channelID: String, item: ChannelItem) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            // Let the picture appear first, then show the info bar for a few seconds.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.activeChannelID == channelID else { return }
            self.banner = Banner(channelID: channelID, item: item, next: self.lineups[channelID]?.first)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    /// Finds the next program's stream while the current one plays.
    private func prefetchNext(channelID: String) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, self.activeChannelID == channelID,
                  let next = self.lineups[channelID]?.first else { return }
            _ = await self.preparedStream(for: next)
        }
    }

    private func resolveWithTimeout(_ item: ChannelItem) async -> PreparedNextStream? {
        guard let resolveStream else { return nil }
        let timeout = Self.resolveTimeout
        return await withTaskGroup(of: PreparedNextStream?.self) { group in
            group.addTask { await resolveStream(item) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension NuvioMeta {
    /// Copy with a genre list, for catalog rows that arrive without one.
    func withGenres(_ newGenres: [String]) -> NuvioMeta {
        guard !newGenres.isEmpty else { return self }
        return NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: newGenres,
            rating: rating,
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: cast,
            director: director,
            writer: writer,
            certification: certification,
            country: country,
            language: language,
            released: released,
            status: status,
            videos: videos,
            trailerYtIds: trailerYtIds,
            externalRatings: externalRatings,
            posterShape: posterShape,
            isFromAddon: isFromAddon,
            landscapePosterUrl: landscapePosterUrl
        )
    }
}
