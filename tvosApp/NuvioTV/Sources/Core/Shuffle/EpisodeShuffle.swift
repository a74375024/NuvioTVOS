import Foundation

/// Which episodes a shuffle draws from.
struct EpisodeShuffleOptions: Equatable, Sendable {
    /// Restrict to one season; nil means the whole show.
    var season: Int? = nil
    /// Prefer episodes not watched yet (falls back to all once none are left).
    var unwatchedOnly = false
    /// Prefer highly rated episodes when ratings are available.
    var topRatedOnly = false

    static let wholeShow = EpisodeShuffleOptions()
}

/// Pure episode picking for shuffle. No UI or storage.
enum EpisodeShuffler {
    /// Ratings at or above this count as "top rated".
    static let topRatedThreshold = 8.0

    /// Regular, already-released episodes the options allow. Never empty
    /// because of `unwatchedOnly` / `topRatedOnly` alone: those relax when they
    /// would leave nothing to pick.
    static func pool(
        from episodes: [NuvioVideo],
        options: EpisodeShuffleOptions,
        isWatched: (NuvioVideo) -> Bool
    ) -> [NuvioVideo] {
        var base = episodes.filter { episode in
            episode.season > 0 && episode.episode > 0
                && (EpisodeReleasePolicy.hasAired(episode.released) || EpisodeReleasePolicy.isAiringToday(episode.released))
        }
        if let season = options.season {
            let inSeason = base.filter { $0.season == season }
            if !inSeason.isEmpty { base = inSeason }
        }
        if options.topRatedOnly {
            let rated = base.compactMap { episode in rating(of: episode).map { (episode, $0) } }
            if !rated.isEmpty {
                let strong = rated.filter { $0.1 >= topRatedThreshold }.map(\.0)
                if strong.count >= 3 {
                    base = strong
                } else {
                    // Few episodes clear the bar: take the best quarter instead.
                    let sorted = rated.sorted { $0.1 > $1.1 }.map(\.0)
                    base = Array(sorted.prefix(max(3, sorted.count / 4)))
                }
            }
        }
        if options.unwatchedOnly {
            let unwatched = base.filter { !isWatched($0) }
            if !unwatched.isEmpty { base = unwatched }
        }
        return base
    }

    /// A random episode from the pool, avoiding the current one and recent
    /// picks while there is anything else to choose.
    static func pick(
        from episodes: [NuvioVideo],
        options: EpisodeShuffleOptions,
        excluding recentIDs: [String],
        currentID: String?,
        isWatched: (NuvioVideo) -> Bool
    ) -> NuvioVideo? {
        let candidates = pool(from: episodes, options: options, isWatched: isWatched)
        guard !candidates.isEmpty else { return nil }
        // Remember about half the pool (up to 20) so short seasons still vary.
        let memory = Set(recentIDs.suffix(min(20, max(1, candidates.count / 2))))
        let fresh = candidates.filter { $0.id != currentID && !memory.contains($0.id) }
        if let choice = fresh.randomElement() { return choice }
        let notCurrent = candidates.filter { $0.id != currentID }
        return notCurrent.randomElement() ?? candidates.randomElement()
    }

    static func hasRatings(_ episodes: [NuvioVideo]) -> Bool {
        episodes.contains { rating(of: $0) != nil }
    }

    static func rating(of episode: NuvioVideo) -> Double? {
        guard let raw = episode.rating?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let number = raw.split(separator: "/").first.map(String.init) ?? raw
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// Hands a shuffle start from the show page to the player, and remembers
/// recent picks per show so the next shuffle avoids repeats.
@MainActor
final class ShuffleLaunchStore {
    static let shared = ShuffleLaunchStore()

    struct Launch: Equatable {
        let showID: String
        let episodeID: String
        let options: EpisodeShuffleOptions
        let armedAt: Date
    }

    private var pending: Launch?
    private var recentByShow: [String: [String]] = [:]

    /// Called right before the show page starts a shuffled episode.
    func arm(showID: String, episodeID: String, options: EpisodeShuffleOptions) {
        pending = Launch(showID: showID, episodeID: episodeID, options: options, armedAt: Date())
        remember(showID: showID, episodeID: episodeID)
    }

    /// Any non-shuffle play from the show page clears a stale launch.
    func disarm() {
        pending = nil
    }

    /// The player takes the launch only when it is starting exactly the
    /// episode that was shuffled, so a cancelled source picker followed by a
    /// normal play never starts in shuffle mode.
    func consume(showID: String, episodeID: String?) -> Launch? {
        guard let launch = pending else { return nil }
        pending = nil
        guard launch.showID == showID,
              launch.episodeID == episodeID,
              Date().timeIntervalSince(launch.armedAt) < 10 * 60 else { return nil }
        return launch
    }

    func recentPicks(showID: String) -> [String] {
        recentByShow[showID] ?? []
    }

    func remember(showID: String, episodeID: String) {
        var list = recentByShow[showID] ?? []
        list.removeAll { $0 == episodeID }
        list.append(episodeID)
        if list.count > 40 { list.removeFirst(list.count - 40) }
        recentByShow[showID] = list
    }
}

/// Watched marks made while shuffling. Continue Watching ignores these when
/// working out where you are in a show, so a shuffle night never moves your
/// place (the episodes still show as watched everywhere else).
enum ShuffleWatchLog {
    private static let key = "nuvio.tv.shuffle.watchLog"
    private static let maxEntries = 500
    private static let maxAge: TimeInterval = 365 * 24 * 60 * 60
    /// How close a watched mark's time must be to the logged time to match.
    private static let matchWindow: TimeInterval = 10 * 60

    private struct Entry: Codable, Equatable {
        let metaID: String
        let imdbID: String?
        let season: Int
        let episode: Int
        let at: Date
    }

    private static let lock = NSLock()
    private static var cache: (profile: String, entries: [Entry])?

    static func record(meta: NuvioMeta, season: Int, episode: Int, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries.removeAll { $0.at < cutoff }
        entries.append(Entry(
            metaID: meta.id.lowercased(),
            imdbID: meta.imdbId?.lowercased(),
            season: season,
            episode: episode,
            at: date
        ))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        saveLocked(entries)
    }

    /// True when this watched mark was made by a shuffle session.
    static func contains(_ item: WatchedStoreItem) -> Bool {
        guard let season = item.season, let episode = item.episode else { return false }
        lock.lock()
        defer { lock.unlock() }
        let entries = loadLocked()
        guard !entries.isEmpty else { return false }
        let metaID = item.meta.id.lowercased()
        let imdbID = item.meta.imdbId?.lowercased()
        return entries.contains { entry in
            guard entry.season == season, entry.episode == episode else { return false }
            let sameShow = entry.metaID == metaID
                || (imdbID != nil && (entry.imdbID == imdbID || entry.metaID == imdbID))
            return sameShow && abs(entry.at.timeIntervalSince(item.watchedAt)) <= matchWindow
        }
    }

    private static func loadLocked() -> [Entry] {
        let profile = ProfileSettings.activeProfileScope
        if let cache, cache.profile == profile { return cache.entries }
        let entries: [Entry]
        if let data = ProfileSettings.current.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        cache = (profile, entries)
        return entries
    }

    private static func saveLocked(_ entries: [Entry]) {
        cache = (ProfileSettings.activeProfileScope, entries)
        if let data = try? JSONEncoder().encode(entries) {
            ProfileSettings.current.set(data, forKey: key)
        }
    }
}
