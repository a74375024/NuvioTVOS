import Foundation
import Combine

/// One program on a channel: a movie, or a specific episode of a show.
struct ChannelItem: Identifiable, Equatable {
    let id: String
    let channelID: String
    /// Full metadata (series include their episode guide).
    let meta: NuvioMeta
    let episode: NuvioVideo?

    var title: String { meta.name }

    /// "S3 · E14 · Title" for episodes; used by the player to know the episode.
    var subtitleLine: String {
        guard let episode else { return "" }
        return "S\(episode.season) · E\(episode.episode) · \(episode.title)"
    }

    var detailLine: String {
        if let episode {
            let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = "S\(episode.season) · E\(episode.episode)"
            return title.isEmpty || title.lowercased().hasPrefix("episode ") ? code : "\(code) · \(title)"
        }
        var parts = [L10n.string("channel_movie", fallback: "Movie")]
        if let year = meta.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    var artworkURL: String? {
        episode?.thumbnail ?? meta.backgroundUrl ?? meta.posterUrl
    }

    static func == (lhs: ChannelItem, rhs: ChannelItem) -> Bool { lhs.id == rhs.id }
}

/// Runs the Channels feature: builds each channel's pool from Cinemeta,
/// picks programs, finds streams ahead of time, and moves from one program to
/// the next. Always starts fresh when tuning in.
@MainActor
final class ChannelSessionStore: ObservableObject {
    static let shared = ChannelSessionStore()

    enum Overlay: Equatable {
        case tuning(channelID: String, item: ChannelItem?)
        case upNext(channelID: String, item: ChannelItem?)
        case failed(channelID: String, message: String)
    }

    @Published private(set) var channels: [ChannelDefinition] = []
    /// What each channel will start with when tuned to.
    @Published private(set) var previews: [String: ChannelItem] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isLoadingLineup = false
    @Published private(set) var activeChannelID: String?
    @Published private(set) var overlay: Overlay?

    var isActive: Bool { activeChannelID != nil }

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
    private var sessionTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetched: (item: ChannelItem, stream: PreparedNextStream, at: Date)?
    private var currentItem: ChannelItem?

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
        let fresh = poolsBuiltAt.map { Date().timeIntervalSince($0) < Self.poolLifetime } ?? false
        if fresh, ids == poolsBuiltForChannels {
            fillMissingPreviews()
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
            self.previews = [:]
            self.isLoadingLineup = false
            self.lineupTask = nil
            self.fillMissingPreviews()
        }
    }

    private func fillMissingPreviews() {
        for channel in channels where previews[channel.id] == nil && !unavailable.contains(channel.id) {
            Task { [weak self] in
                guard let self, let item = await self.pick(channelID: channel.id) else { return }
                if self.previews[channel.id] == nil {
                    self.previews[channel.id] = item
                }
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
                        let page = try? await repository.browseCatalog(
                            addonId: nil,
                            contentType: query.type,
                            catalogId: catalog,
                            skip: skip,
                            genre: query.genre
                        )
                        // A catalog that ignores genres gets its genre from the query.
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

    /// A random program from the channel, avoiding titles shown recently.
    private func pick(channelID: String, excludingItemID: String? = nil) async -> ChannelItem? {
        guard let pool = pools[channelID], !pool.isEmpty else { return nil }
        let recent = Set(recentByChannel[channelID] ?? [])
        let memory = min(recent.count, max(0, pool.count - 3))
        let avoid = Set((recentByChannel[channelID] ?? []).suffix(memory))
        var candidates = pool.filter { !avoid.contains($0.id) }.shuffled()
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
                let item = ChannelItem(
                    id: "\(channelID)|\(full.id)|\(episode.id)",
                    channelID: channelID,
                    meta: showMeta,
                    episode: episode
                )
                if item.id != excludingItemID { return item }
            } else {
                let full = (try? await repository.getMetadata(id: candidate.id, type: "movie")) ?? candidate
                let item = ChannelItem(
                    id: "\(channelID)|\(full.id)",
                    channelID: channelID,
                    meta: full.genres?.isEmpty == false ? full : full.withGenres(candidate.genres ?? []),
                    episode: nil
                )
                if item.id != excludingItemID { return item }
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

    // MARK: - Session

    /// Starts the channel from a fresh program.
    func tune(_ channelID: String) {
        stopTasks()
        activeChannelID = channelID
        prefetched = nil
        let preview = previews[channelID]
        overlay = .tuning(channelID: channelID, item: preview)
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.startProgram(channelID: channelID, first: preview, minimumOverlay: 1.2, isTuning: true)
        }
    }

    /// Called by the player when a program ends.
    func itemFinished() {
        guard let channelID = activeChannelID else { return }
        leavePlayer?()
        let upcoming = prefetched?.item
        overlay = .upNext(channelID: channelID, item: upcoming)
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.startProgram(channelID: channelID, first: upcoming, minimumOverlay: 4, isTuning: false)
        }
    }

    /// Leaves the channel (Menu from the player or the tuning card).
    func stop() {
        stopTasks()
        activeChannelID = nil
        overlay = nil
        prefetched = nil
        currentItem = nil
    }

    private func stopTasks() {
        sessionTask?.cancel()
        prefetchTask?.cancel()
        sessionTask = nil
        prefetchTask = nil
    }

    private func startProgram(channelID: String, first: ChannelItem?, minimumOverlay: TimeInterval, isTuning: Bool) async {
        let started = Date()
        var candidate = first
        var attempts = 0
        while attempts < Self.maxAttempts, !Task.isCancelled, activeChannelID == channelID {
            attempts += 1
            if candidate == nil {
                candidate = await pick(channelID: channelID, excludingItemID: currentItem?.id)
            }
            guard let item = candidate else { break }
            setOverlayItem(item, channelID: channelID, isTuning: isTuning)

            let stream: PreparedNextStream?
            if let prefetched, prefetched.item.id == item.id,
               Date().timeIntervalSince(prefetched.at) < Self.preparedLifetime {
                stream = prefetched.stream
            } else {
                stream = await resolveWithTimeout(item)
            }
            self.prefetched = nil
            guard !Task.isCancelled, activeChannelID == channelID else { return }

            guard let stream else {
                // Nothing playable from the user's add-ons: quietly try another pick.
                remember(item)
                candidate = nil
                continue
            }

            let elapsed = Date().timeIntervalSince(started)
            if elapsed < minimumOverlay {
                try? await Task.sleep(nanoseconds: UInt64((minimumOverlay - elapsed) * 1_000_000_000))
            }
            guard !Task.isCancelled, activeChannelID == channelID else { return }

            remember(item)
            currentItem = item
            overlay = nil
            presentItem?(item, stream)
            refreshPreview(channelID: channelID)
            prefetchNext(channelID: channelID, after: item)
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

    private func setOverlayItem(_ item: ChannelItem, channelID: String, isTuning: Bool) {
        overlay = isTuning
            ? .tuning(channelID: channelID, item: item)
            : .upNext(channelID: channelID, item: item)
    }

    /// Finds the next program and its stream while the current one plays.
    private func prefetchNext(channelID: String, after item: ChannelItem) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            for _ in 0..<Self.maxAttempts {
                guard !Task.isCancelled, self.activeChannelID == channelID else { return }
                guard let next = await self.pick(channelID: channelID, excludingItemID: item.id) else { return }
                if let stream = await self.resolveWithTimeout(next) {
                    guard !Task.isCancelled, self.activeChannelID == channelID else { return }
                    self.prefetched = (next, stream, Date())
                    return
                }
                self.remember(next)
            }
        }
    }

    /// Gives the guide a new "starts with" pick after a program begins.
    private func refreshPreview(channelID: String) {
        previews[channelID] = nil
        Task { [weak self] in
            guard let self, let item = await self.pick(channelID: channelID, excludingItemID: self.currentItem?.id) else { return }
            if self.previews[channelID] == nil { self.previews[channelID] = item }
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
