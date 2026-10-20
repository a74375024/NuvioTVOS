import Foundation
import Combine

/// One thing on the release calendar. Kept generic (a "show" with a dated
/// event) so other sources, such as sports schedules, can add their own kinds
/// later without changing the screen.
struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A single TV episode.
        case episode
        /// Several episodes of one season released the same day (a binge drop).
        case seasonDrop
    }

    enum Source: String, Codable, Sendable {
        case library
        case watching
    }

    let id: String
    let kind: Kind
    let showID: String
    let showType: String
    let showName: String
    let season: Int
    let episode: Int
    let episodeCount: Int
    let episodeTitle: String
    /// Local start of the day it airs.
    let day: Date
    /// Exact air time when the source gives one; nil for date-only listings.
    let airTime: Date?
    let imageURL: String?
    let logoURL: String?
    var sources: Set<Source>

    var isSeriesPremiere: Bool { season == 1 && episode == 1 }
    var isSeasonPremiere: Bool { season > 1 && episode == 1 }
}

/// Builds and caches the release calendar for the active profile from the
/// shows in the Library plus the shows being watched.
@MainActor
final class ReleaseCalendarStore: ObservableObject {
    static let shared = ReleaseCalendarStore()

    /// How far back "Recently aired" reaches, and how far ahead we look.
    static let pastDays = 7
    static let futureDays = 30
    /// Shows watched within this window count as "watching".
    static let watchingWindowDays = 120
    /// Upper bound on shows looked up per refresh, to keep the first load quick.
    static let maxShows = 150
    /// A cached calendar younger than this is shown without refetching.
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var showCount = 0
    @Published private(set) var lastUpdated: Date?

    private var refreshTask: Task<Void, Never>?
    private var loadedProfileKey: String?
    private var lastShowSignature: String?

    private struct Show: Hashable, Sendable {
        let id: String
        let name: String
        var sources: Set<CalendarEvent.Source>
    }

    private struct CacheFile: Codable {
        let profileKey: String
        let builtAt: Date
        let showSignature: String
        let showCount: Int
        let events: [CalendarEvent]
    }

    // MARK: - Public

    /// Shows the cached calendar immediately, then refreshes when it is stale,
    /// the set of shows changed, or `force` is set.
    func refreshIfNeeded(extraLibrary: [(id: String, name: String)] = [], force: Bool = false) {
        let profileKey = ProfileSettings.activeProfileScope
        if loadedProfileKey != profileKey {
            loadedProfileKey = profileKey
            events = []
            lastUpdated = nil
            lastShowSignature = nil
            if let cache = Self.readCache(profileKey: profileKey) {
                events = cache.events
                lastUpdated = cache.builtAt
                lastShowSignature = cache.showSignature
                showCount = cache.showCount
            }
        }

        let shows = collectShows(extraLibrary: extraLibrary)
        let signature = Self.signature(for: shows)
        let isStale = lastUpdated.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        guard force || isStale || signature != lastShowSignature else { return }
        guard refreshTask == nil else { return }

        showCount = shows.count
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let built = await Self.buildEvents(for: shows)
            guard let self, !Task.isCancelled else { return }
            guard ProfileSettings.activeProfileScope == profileKey else {
                self.refreshTask = nil
                self.isRefreshing = false
                return
            }
            let now = Date()
            self.events = built
            self.lastUpdated = now
            self.lastShowSignature = signature
            self.isRefreshing = false
            self.refreshTask = nil
            Self.writeCache(CacheFile(
                profileKey: profileKey,
                builtAt: now,
                showSignature: signature,
                showCount: shows.count,
                events: built
            ))
        }
    }

    // MARK: - Collecting shows

    private func collectShows(extraLibrary: [(id: String, name: String)]) -> [Show] {
        var byID: [String: Show] = [:]
        var order: [String] = []

        func add(id rawID: String, name: String, source: CalendarEvent.Source) {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            if var existing = byID[id] {
                existing.sources.insert(source)
                byID[id] = existing
            } else {
                byID[id] = Show(id: id, name: name, sources: [source])
                order.append(id)
            }
        }

        for item in LibraryStore.items() where item.meta.isSeries {
            add(id: item.meta.id, name: item.meta.name, source: .library)
        }
        for item in extraLibrary {
            add(id: item.id, name: item.name, source: .library)
        }

        for item in ContinueWatchingStore.items() where item.meta.isSeries {
            add(id: item.meta.id, name: item.meta.name, source: .watching)
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.watchingWindowDays, to: Date()) ?? .distantPast
        let recentEpisodes = WatchedStore.visibleItems()
            .filter { $0.season != nil && $0.watchedAt >= cutoff && $0.meta.isSeries }
            .sorted { $0.watchedAt > $1.watchedAt }
        for item in recentEpisodes {
            add(id: item.meta.id, name: item.meta.name, source: .watching)
        }

        return order.prefix(Self.maxShows).compactMap { byID[$0] }
    }

    private static func signature(for shows: [Show]) -> String {
        shows.map { "\($0.id)#\($0.sources.map(\.rawValue).sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Building events

    private static func buildEvents(for shows: [Show]) async -> [CalendarEvent] {
        let repository = CinemetaCatalogRepository()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .day, value: -pastDays, to: today),
              let windowEnd = calendar.date(byAdding: .day, value: futureDays + 1, to: today) else { return [] }

        // Look shows up a few at a time so a big library doesn't flood the
        // metadata source.
        var collected: [CalendarEvent] = []
        let maxConcurrent = 4
        var start = 0
        while start < shows.count, !Task.isCancelled {
            let batch = Array(shows[start..<min(start + maxConcurrent, shows.count)])
            start += maxConcurrent
            let results = await withTaskGroup(of: [CalendarEvent].self, returning: [CalendarEvent].self) { group in
                for show in batch {
                    group.addTask {
                        guard let meta = try? await repository.getMetadata(id: show.id, type: "series") else {
                            return []
                        }
                        return Self.events(from: meta, show: show, windowStart: windowStart, windowEnd: windowEnd)
                    }
                }
                var merged: [CalendarEvent] = []
                for await events in group {
                    merged.append(contentsOf: events)
                }
                return merged
            }
            collected.append(contentsOf: results)
        }

        return collected.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            let lt = lhs.airTime ?? lhs.day, rt = rhs.airTime ?? rhs.day
            if lt != rt { return lt < rt }
            return lhs.showName.localizedCaseInsensitiveCompare(rhs.showName) == .orderedAscending
        }
    }

    private nonisolated static func events(
        from meta: NuvioMeta,
        show: Show,
        windowStart: Date,
        windowEnd: Date
    ) -> [CalendarEvent] {
        let videos = (meta.videos ?? []).filter { $0.season > 0 }
        guard !videos.isEmpty else { return [] }

        struct Dated {
            let video: NuvioVideo
            let day: Date
            let time: Date?
        }
        let dated: [Dated] = videos.compactMap { video in
            guard let moment = airMoment(video.released),
                  moment.day >= windowStart, moment.day < windowEnd else { return nil }
            return Dated(video: video, day: moment.day, time: moment.time)
        }
        guard !dated.isEmpty else { return [] }

        let showName = meta.name.isEmpty ? show.name : meta.name
        let showType = meta.canonicalType
        // Several episodes of one season on one day read as a single drop.
        let grouped = Dictionary(grouping: dated) { "\($0.video.season)|\($0.day.timeIntervalSince1970)" }
        var result: [CalendarEvent] = []
        for (_, group) in grouped {
            let sortedGroup = group.sorted { $0.video.episode < $1.video.episode }
            guard let first = sortedGroup.first else { continue }
            if sortedGroup.count >= 3 {
                result.append(CalendarEvent(
                    id: "\(meta.id):s\(first.video.season):drop:\(Int(first.day.timeIntervalSince1970))",
                    kind: .seasonDrop,
                    showID: meta.id,
                    showType: showType,
                    showName: showName,
                    season: first.video.season,
                    episode: first.video.episode,
                    episodeCount: sortedGroup.count,
                    episodeTitle: "",
                    day: first.day,
                    airTime: first.time,
                    imageURL: meta.backgroundUrl ?? first.video.thumbnail ?? meta.posterUrl,
                    logoURL: meta.logoUrl,
                    sources: show.sources
                ))
            } else {
                for entry in sortedGroup {
                    result.append(CalendarEvent(
                        id: "\(meta.id):s\(entry.video.season)e\(entry.video.episode)",
                        kind: .episode,
                        showID: meta.id,
                        showType: showType,
                        showName: showName,
                        season: entry.video.season,
                        episode: entry.video.episode,
                        episodeCount: 1,
                        episodeTitle: entry.video.title,
                        day: entry.day,
                        airTime: entry.time,
                        imageURL: entry.video.thumbnail ?? meta.backgroundUrl ?? meta.posterUrl,
                        logoURL: meta.logoUrl,
                        sources: show.sources
                    ))
                }
            }
        }
        return result
    }

    /// Parses a release value into the local calendar day and, when the
    /// source gives a real time, the exact moment. A timestamp at exactly
    /// midnight UTC is how date-only listings are stored, so it keeps its
    /// calendar date instead of shifting a day earlier in US time zones.
    nonisolated static func airMoment(_ raw: String?) -> (day: Date, time: Date?)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let calendar = Calendar.current

        func localDay(fromPrefix value: String) -> Date? {
            let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var components = DateComponents()
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            return calendar.date(from: components)
        }

        guard raw.contains("T") else {
            return localDay(fromPrefix: raw).map { ($0, nil) }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
            return localDay(fromPrefix: raw).map { ($0, nil) }
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = utc.dateComponents([.hour, .minute, .second], from: date)
        if parts.hour == 0, parts.minute == 0, parts.second == 0 {
            return localDay(fromPrefix: raw).map { ($0, nil) }
        }
        return (calendar.startOfDay(for: date), date)
    }

    // MARK: - Disk cache

    private nonisolated static func cacheURL(profileKey: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safe = profileKey.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return base.appendingPathComponent("ReleaseCalendar-\(safe).json")
    }

    private nonisolated static func readCache(profileKey: String) -> CacheFile? {
        guard let url = cacheURL(profileKey: profileKey),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.profileKey == profileKey else { return nil }
        return cache
    }

    private nonisolated static func writeCache(_ cache: CacheFile) {
        guard let url = cacheURL(profileKey: cache.profileKey),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
