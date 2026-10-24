import Foundation
import Combine

/// One program on a channel: a movie, or a specific episode of a show.
struct ChannelItem: Identifiable, Equatable, Codable {
    let id: String
    let channelID: String
    /// Metadata (for a series, only this program's episode).
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
///
/// Performance: pools come straight from Cinemeta's public catalogs (no TMDB,
/// nothing written to the shared metadata cache) and are saved with the
/// lineups for a day, so a later launch shows the guide at once. Each channel
/// fills as soon as its own catalogs arrive. Program lookups run three at a
/// time, wait while something plays (except the channel being watched), and
/// back off when the network is down.
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

    /// The tuning card and info banner, published on their own so the guide
    /// (still mounted under the player) doesn't redraw for them.
    final class Chrome: ObservableObject {
        @Published fileprivate(set) var overlay: Overlay?
        @Published fileprivate(set) var banner: Banner?
    }

    let chrome = Chrome()

    @Published private(set) var channels: [ChannelDefinition] = []
    /// Upcoming programs per channel (first = what tuning in starts with).
    @Published private(set) var lineups: [String: [ChannelItem]] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isLoadingLineup = false
    @Published private(set) var activeChannelID: String?
    @Published private(set) var nowPlaying: ChannelItem?

    var overlay: Overlay? {
        get { chrome.overlay }
        set { chrome.overlay = newValue }
    }

    var banner: Banner? {
        get { chrome.banner }
        set { chrome.banner = newValue }
    }

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
    private var saveTask: Task<Void, Never>?
    private var preparedStreams: [String: (stream: PreparedNextStream, at: Date)] = [:]
    private var resolving: [String: Task<PreparedNextStream?, Never>] = [:]
    private var loadedProfileKey: String?
    private var triedSaved = false
    /// Network trouble: lookups stop until this passes.
    private var offlineUntil: Date?
    private var networkFailures = 0
    private var backoff: TimeInterval = 30
    private var lookups = 0
    private let gate = ChannelRequestGate(limit: 3)

    nonisolated static let catalogSourceURL = "https://v3-cinemeta.strem.io/manifest.json"
    nonisolated static let catalogBaseURL = URL(string: "https://v3-cinemeta.strem.io")!
    /// How much programming the guide lays out per channel.
    static let guideWindowMinutes = 180
    private static let maxLineupItems = 8
    private static let poolLifetime: TimeInterval = 24 * 60 * 60
    private static let maxAttempts = 4
    private static let resolveTimeout: UInt64 = 25
    private static let preparedLifetime: TimeInterval = 90 * 60
    private static let minimumRatingWhenKnown = 6.0
    /// Catalog pages read per genre query.
    private static let catalogPages: [(catalog: String, skip: Int)] = [("top", 0), ("imdbRating", 0)]

    // MARK: - Guide

    func loadLineupIfNeeded() {
        let profileKey = ProfileSettings.activeProfileScope
        if loadedProfileKey != profileKey {
            if loadedProfileKey != nil { resetForProfileChange() }
            loadedProfileKey = profileKey
            triedSaved = false
        }
        let todays = ChannelLineup.available()
        channels = todays
        let ids = todays.map(\.id)
        _ = isOffline

        // Saved pools and lineups from an earlier launch: shown at once.
        if !triedSaved, pools.isEmpty {
            triedSaved = true
            guard lineupTask == nil else { return }
            isLoadingLineup = true
            lineupTask = Task { [weak self] in
                let saved = await Task.detached(priority: .userInitiated) { ChannelsSaved.read(profileKey: profileKey) }.value
                guard let self, self.loadedProfileKey == profileKey else { return }
                self.lineupTask = nil
                if let saved, Date().timeIntervalSince(saved.builtAt) < Self.poolLifetime, saved.channelIDs == ids {
                    self.pools = saved.pools
                    self.poolsBuiltAt = saved.builtAt
                    self.poolsBuiltForChannels = ids
                    self.unavailable = Set(ids.filter { (saved.pools[$0] ?? []).isEmpty })
                    self.recentByChannel = saved.recent
                    if self.lineups.isEmpty { self.lineups = saved.lineups.mapValues { Array($0.prefix(Self.maxLineupItems)) } }
                    self.isLoadingLineup = false
                    CrashRecorder.note("channels: saved lineup from \(Int(Date().timeIntervalSince(saved.builtAt) / 60)) min ago, "
                                       + "\(saved.pools.values.reduce(0) { $0 + $1.count }) titles, \(self.lineups.values.reduce(0) { $0 + $1.count }) programs")
                }
                self.loadLineupIfNeeded()
            }
            return
        }

        let hasAnyPool = pools.values.contains { !$0.isEmpty }
        let fresh = hasAnyPool && (poolsBuiltAt.map { Date().timeIntervalSince($0) < Self.poolLifetime } ?? false)
        if fresh, ids == poolsBuiltForChannels {
            isLoadingLineup = false
            ids.forEach(fillLineup)
            return
        }
        guard lineupTask == nil, !isOffline else {
            if lineupTask == nil { isLoadingLineup = false }
            return
        }
        isLoadingLineup = true
        lineupTask = Task { [weak self] in
            guard let self else { return }
            await self.buildPools(for: todays)
            guard self.loadedProfileKey == profileKey else { return }
            self.isLoadingLineup = false
            self.lineupTask = nil
            ids.forEach(self.fillLineup)
            self.scheduleSave()
        }
    }

    private func resetForProfileChange() {
        stop()
        lineupTask?.cancel()
        lineupTask = nil
        fillTasks.values.forEach { $0.cancel() }
        fillTasks = [:]
        saveTask?.cancel()
        preparedStreams = [:]
        resolving = [:]
        recentByChannel = [:]
        lineups = [:]
        pools = [:]
        poolsBuiltAt = nil
        poolsBuiltForChannels = []
        unavailable = []
        isLoadingLineup = false
        offlineUntil = nil
        networkFailures = 0
        backoff = 30
        CrashRecorder.note("channels: profile changed, lineups cleared")
    }

    /// Tops a channel's lineup up to about three hours of programs. The first
    /// program lands quickly; the rest fill in behind it.
    private func fillLineup(_ channelID: String) {
        guard fillTasks[channelID] == nil, !unavailable.contains(channelID), !isOffline,
              pools[channelID]?.isEmpty == false else { return }
        fillTasks[channelID] = Task { [weak self] in
            guard let self else { return }
            var misses = 0
            var added = 0
            while !Task.isCancelled, misses < 3, !self.isOffline {
                let current = self.lineups[channelID] ?? []
                let minutes = current.reduce(0) { $0 + $1.durationMinutes }
                guard minutes < Self.guideWindowMinutes, current.count < Self.maxLineupItems else { break }
                // Other channels wait while something plays.
                while OutsideGuidePause.shared.isPaused, self.activeChannelID != channelID, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                let avoid = Set(current.map(\.meta.id) + [self.nowPlaying?.meta.id].compactMap { $0 })
                let picked = await self.pick(channelID: channelID, avoidingShowIDs: avoid)
                guard !Task.isCancelled else { break }
                guard let item = picked else {
                    misses += 1
                    continue
                }
                var updated = self.lineups[channelID] ?? []
                guard !updated.contains(item) else { misses += 1; continue }
                updated.append(item)
                self.lineups[channelID] = updated
                added += 1
            }
            // A cancelled task's entry was already replaced (profile change).
            guard !Task.isCancelled else { return }
            self.fillTasks[channelID] = nil
            if added > 0 { self.scheduleSave() }
        }
    }

    /// Reads every channel's catalogs (a few at a time per query) and fills
    /// each channel as soon as its own queries are in.
    private func buildPools(for channels: [ChannelDefinition]) async {
        let started = Date()
        unavailable = []
        let queries = Array(Set(channels.flatMap(\.queries)))
        var candidates: [String: NuvioMeta] = [:]
        var finished = Set<ChannelSourceQuery>()
        var requests = 0
        var failures = 0
        let repository = self.repository
        let base = Self.catalogBaseURL
        let pages = Self.catalogPages
        await withTaskGroup(of: (ChannelSourceQuery, [NuvioMeta], Int, Int).self) { group in
            for query in queries {
                group.addTask {
                    var items: [NuvioMeta] = []
                    var failed = 0
                    for page in pages {
                        do {
                            let found = try await repository.plainCatalogPage(
                                baseURL: base, contentType: query.type, catalogId: page.catalog, skip: page.skip, genre: query.genre
                            )
                            items += found.map { meta in
                                meta.genres?.isEmpty == false ? meta : meta.withGenres([query.genre])
                            }
                        } catch {
                            failed += 1
                        }
                    }
                    return (query, items, pages.count, failed)
                }
            }
            for await (query, items, asked, failed) in group {
                // Profile changed meanwhile: leave everything alone.
                guard !Task.isCancelled else { continue }
                requests += asked
                failures += failed
                finished.insert(query)
                for meta in items where candidates[meta.id] == nil {
                    candidates[meta.id] = meta
                }
                // Channels whose own queries are all in can start filling.
                self.pools = Self.assign(candidates, to: channels)
                self.poolsBuiltForChannels = channels.map(\.id)
                for channel in channels where Set(channel.queries).isSubset(of: finished) {
                    if self.lineups[channel.id]?.isEmpty ?? true { self.fillLineup(channel.id) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        let ids = channels.map(\.id)
        unavailable = Set(ids.filter { (pools[$0] ?? []).isEmpty })
        if failures == requests, requests > 0 {
            // Nothing came back: try again later, not on every open.
            noteNetworkTrouble()
            poolsBuiltAt = nil
        } else {
            poolsBuiltAt = Date()
        }
        CrashRecorder.note("channels: pools built in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(requests) catalog requests"
                           + (failures > 0 ? " (\(failures) failed)" : "") + ", "
                           + ids.map { "\($0) \(pools[$0]?.count ?? 0)" }.joined(separator: ", "))
    }

    private static func assign(_ candidates: [String: NuvioMeta], to channels: [ChannelDefinition]) -> [String: [NuvioMeta]] {
        var pools: [String: [NuvioMeta]] = [:]
        for meta in candidates.values {
            if let rating = meta.rating, rating.isFinite, rating > 0, rating < minimumRatingWhenKnown { continue }
            guard let owner = ChannelLineup.owner(of: meta, among: channels) else { continue }
            pools[owner, default: []].append(meta)
        }
        return pools
    }

    // MARK: - Network trouble

    /// Lookups are paused; an expired pause is cleared.
    private var isOffline: Bool {
        guard let until = offlineUntil else { return false }
        if Date() >= until {
            offlineUntil = nil
            return false
        }
        return true
    }

    private func noteNetworkTrouble() {
        offlineUntil = Date().addingTimeInterval(backoff)
        CrashRecorder.note("channels: network trouble, pausing lookups for \(Int(backoff)) s")
        backoff = min(backoff * 2, 600)
    }

    private func noteLookup(failed: Bool) {
        lookups += 1
        if failed {
            networkFailures += 1
            if networkFailures >= 4, !isOffline { noteNetworkTrouble() }
        } else {
            networkFailures = 0
            backoff = 30
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed].contains(urlError.code)
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

        var networkMisses = 0
        for candidate in candidates.prefix(6) {
            guard !isOffline, networkMisses < 2, !Task.isCancelled else { return nil }
            let type = candidate.isSeries ? "series" : "movie"
            let full: NuvioMeta?
            do {
                let repository = self.repository
                let id = candidate.id
                full = try await gate.run { try await repository.getMetadata(id: id, type: type) }
                noteLookup(failed: false)
            } catch {
                let network = Self.isNetworkError(error)
                noteLookup(failed: network)
                if network { networkMisses += 1 }
                full = nil
            }
            if candidate.isSeries {
                guard let full else { continue }
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
                    // Only the chosen episode is kept: the rest of the guide
                    // stays in the shared cache, not pinned here.
                    meta: showMeta.keepingOnlyVideos([episode]),
                    episode: episode,
                    durationMinutes: ChannelItem.minutes(fromRuntime: full.runtime ?? candidate.runtime, isSeries: true)
                )
            } else {
                let movie = full ?? candidate
                return ChannelItem(
                    id: "\(channelID)|\(movie.id)",
                    channelID: channelID,
                    meta: movie.genres?.isEmpty == false ? movie : movie.withGenres(candidate.genres ?? []),
                    episode: nil,
                    durationMinutes: ChannelItem.minutes(fromRuntime: movie.runtime ?? candidate.runtime, isSeries: false)
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
        scheduleSave()
    }

    // MARK: - Saving

    /// Writes pools, lineups and recent titles a few seconds after the last
    /// change (off the main thread).
    private func scheduleSave() {
        guard let profileKey = loadedProfileKey, let builtAt = poolsBuiltAt else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.loadedProfileKey == profileKey else { return }
            let saved = ChannelsSaved(profileKey: profileKey, builtAt: builtAt, channelIDs: self.poolsBuiltForChannels,
                                      pools: self.pools, lineups: self.lineups, recent: self.recentByChannel)
            Task.detached(priority: .background) { saved.write() }
        }
    }

    // MARK: - Streams

    /// Finds (or reuses) a stream for a program, for tuning in.
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

    /// The stream search a program uses: the same id and type the app's
    /// stream resolution asks for.
    nonisolated static func streamTarget(for item: ChannelItem) -> (id: String, type: String) {
        if let episode = item.episode {
            return (item.meta.canonicalEpisodeStreamId(for: episode), "series")
        }
        return (item.meta.id, item.meta.type)
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
                // Tuning in is the one thing that doesn't wait out a backoff.
                offlineUntil = nil
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
                CrashRecorder.note("channels: nothing playable for a program on \(channelID), trying another")
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

    /// Looks up the next program's streams while the current one plays,
    /// without replacing the current program's search (the player's source
    /// list keeps showing what's on). The next tune-in uses the result.
    private func prefetchNext(channelID: String) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, self.activeChannelID == channelID,
                  let next = self.lineups[channelID]?.first else { return }
            let target = Self.streamTarget(for: next)
            _ = await StreamsRepository.shared.sideStreams(type: target.type, videoId: target.id,
                                                           reason: "channels next", withSubtitles: true,
                                                           keepFor: Self.preparedLifetime)
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

/// At most `limit` program lookups at once.
actor ChannelRequestGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Channels' pools, lineups and recent titles, saved for the next launch.
struct ChannelsSaved: Codable {
    var version = 1
    let profileKey: String
    let builtAt: Date
    let channelIDs: [String]
    let pools: [String: [NuvioMeta]]
    let lineups: [String: [ChannelItem]]
    let recent: [String: [String]]

    private static func url(profileKey: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safe = profileKey.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return base.appendingPathComponent("Channels-v1-\(safe).json")
    }

    static func read(profileKey: String) -> ChannelsSaved? {
        guard let url = url(profileKey: profileKey), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(ChannelsSaved.self, from: data),
              saved.profileKey == profileKey, saved.version == 1 else { return nil }
        return saved
    }

    func write() {
        guard let url = Self.url(profileKey: profileKey), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension NuvioMeta {
    /// Copy with only these episodes (a channel program keeps just its own).
    func keepingOnlyVideos(_ newVideos: [NuvioVideo]) -> NuvioMeta {
        NuvioMeta(
            id: id, name: name, description: description, posterUrl: posterUrl, backgroundUrl: backgroundUrl,
            logoUrl: logoUrl, imdbId: imdbId, tmdbId: tmdbId, type: type, year: year, genres: genres,
            rating: rating, releaseInfo: releaseInfo, runtime: runtime, cast: cast, director: director,
            writer: writer, certification: certification, country: country, language: language,
            released: released, status: status, videos: newVideos, trailerYtIds: trailerYtIds,
            externalRatings: externalRatings, posterShape: posterShape, isFromAddon: isFromAddon,
            landscapePosterUrl: landscapePosterUrl
        )
    }

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
