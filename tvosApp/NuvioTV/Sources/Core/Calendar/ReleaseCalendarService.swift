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
    /// Episode synopsis (the show's description for a season drop).
    var overview: String? = nil
    /// The release value as the source gave it (for starting playback).
    var released: String? = nil

    var isSeriesPremiere: Bool { season == 1 && episode == 1 }
    var isSeasonPremiere: Bool { season > 1 && episode == 1 }
}

/// One show's release dates, kept between launches so each show is looked up
/// on its own schedule instead of every show on every refresh. Compact: only
/// the episodes that can still reach the calendar are kept.
struct CalendarShowRecord: Codable, Sendable {
    let id: String
    var name: String
    var type: String
    var poster: String?
    var background: String?
    var logo: String?
    var overview: String?
    var status: String?
    var videos: [CalendarShowVideo]
    /// Last good lookup; nil = never looked up yet.
    var fetchedAt: Date?
    var failures: Int = 0
    var lastAttempt: Date?
}

struct CalendarShowVideo: Codable, Sendable, Hashable {
    let season: Int
    let episode: Int
    let title: String
    let released: String?
    let thumbnail: String?
    let overview: String?
}

/// The calendar's window, readable off the main thread.
enum CalendarWindow {
    static let pastDays = 30
    static let futureDays = 30
}

/// Builds and caches the release calendar for the active profile from the
/// shows in the Library plus the shows being watched.
///
/// Each show has a record with its upcoming and recent episodes, saved to
/// disk. A refresh only looks up the shows that are due: every 6 h when an
/// episode is within two days, 12 h within a week, daily when one is dated
/// further out, every 3 days for a returning show with no date and monthly
/// for an ended one. The calendar itself is rebuilt from the records, off
/// the main thread, without any requests.
@MainActor
final class ReleaseCalendarStore: ObservableObject {
    static let shared = ReleaseCalendarStore()

    /// How far back "New for You" reaches, and how far ahead we look.
    static let pastDays = CalendarWindow.pastDays
    static let futureDays = CalendarWindow.futureDays
    /// Shows watched within this window count as "watching".
    static let watchingWindowDays = 120
    /// Upper bound on shows followed.
    static let maxShows = 150
    /// Lookups per refresh once the calendar exists (the first build does all).
    static let maxLookupsPerRefresh = 40

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var showCount = 0
    /// Shows being looked up in the current refresh (for the header).
    @Published private(set) var lookupCount = 0
    @Published private(set) var lastUpdated: Date?
    /// Whether the focused card's episode can be played: the add-ons' stream
    /// lists are read for that one card (keyed by `availabilityKey`).
    @Published private(set) var availability: [String: Availability] = [:]

    enum Availability: Equatable {
        case checking
        case ready(Int)
        case notYet
        case unknown
    }

    private var records: [String: CalendarShowRecord] = [:]
    private var recordsLoaded = false
    private var availabilityCheckedAt: [String: Date] = [:]
    private var probeGeneration = 0
    private static let positiveLifetime: TimeInterval = 2 * 60 * 60
    private static let negativeLifetime: TimeInterval = 30 * 60

    private var refreshTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadedKey: String?
    private var lastShowSignature: String?
    private var pendingExtra: [(id: String, name: String)] = []

    struct Show: Hashable, Sendable {
        let id: String
        let name: String
        var sources: Set<CalendarEvent.Source>
    }

    private struct CacheFile: Codable {
        var version = 3
        let key: String
        let savedAt: Date
        let showSignature: String
        let records: [CalendarShowRecord]
    }

    /// Profile plus metadata language: records hold localized names.
    private static var currentKey: String {
        ProfileSettings.activeProfileScope + "|" + CinemetaCatalogRepository.metadataCacheContext
    }

    // MARK: - Public

    /// Shows the saved calendar immediately, then looks up whichever shows
    /// are due. `force` looks every show up again.
    func refreshIfNeeded(extraLibrary: [(id: String, name: String)] = [], force: Bool = false, reason: String = "open") {
        let key = Self.currentKey
        if loadedKey != key {
            // A different profile (or language): start over.
            if loadedKey != nil { CrashRecorder.note("calendar: profile or language changed, starting over") }
            refreshTask?.cancel()
            refreshTask = nil
            loadTask?.cancel()
            loadTask = nil
            loadedKey = key
            records = [:]
            recordsLoaded = false
            events = []
            lastUpdated = nil
            lastShowSignature = nil
            availability = [:]
            availabilityCheckedAt = [:]
            isRefreshing = false
        }
        pendingExtra = extraLibrary
        guard recordsLoaded else {
            guard loadTask == nil else { return }
            loadTask = Task { [weak self] in
                let file = await Task.detached(priority: .userInitiated) { Self.readCache(key: key) }.value
                guard let self, !Task.isCancelled, self.loadedKey == key else { return }
                self.loadTask = nil
                self.recordsLoaded = true
                if let file {
                    for record in file.records { self.records[record.id] = record }
                    self.lastShowSignature = file.showSignature
                    self.lastUpdated = file.savedAt
                }
                self.refreshIfNeeded(extraLibrary: self.pendingExtra, force: force, reason: reason)
            }
            return
        }

        let shows = collectShows(extraLibrary: extraLibrary)
        let signature = Self.signature(for: shows)
        showCount = shows.count
        let now = Date()
        var due = shows.filter { show in
            guard let record = records[show.id] else { return true }
            return force || Self.nextCheck(for: record, now: now) <= now
        }
        let showsChanged = signature != lastShowSignature
        guard !due.isEmpty || showsChanged || events.isEmpty else { return }
        guard refreshTask == nil else { return }

        // Most overdue first; once the calendar exists, a refresh is capped.
        if !records.isEmpty, due.count > Self.maxLookupsPerRefresh {
            due.sort { (records[$0.id].map { Self.nextCheck(for: $0, now: now) } ?? .distantPast)
                < (records[$1.id].map { Self.nextCheck(for: $0, now: now) } ?? .distantPast) }
            due = Array(due.prefix(Self.maxLookupsPerRefresh))
        }
        let snapshot = records
        let dueShows = due
        let started = Date()
        isRefreshing = !due.isEmpty
        lookupCount = due.count
        refreshTask = Task { [weak self] in
            // Calendar from what's saved first, so it's on screen at once.
            if self?.events.isEmpty == true, !snapshot.isEmpty {
                let early = await Task.detached(priority: .userInitiated) { Self.buildEvents(shows: shows, records: snapshot, now: now) }.value
                guard let self, !Task.isCancelled, self.loadedKey == key else { return }
                self.events = early
            }
            let looked = await Self.lookUp(dueShows, previous: snapshot)
            guard let self, !Task.isCancelled, self.loadedKey == key else { return }
            for record in looked.records { self.records[record.id] = record }
            // Shows no longer followed are forgotten.
            let followed = Set(shows.map(\.id))
            self.records = self.records.filter { followed.contains($0.key) }
            let current = self.records
            let built = await Task.detached(priority: .userInitiated) { Self.buildEvents(shows: shows, records: current, now: Date()) }.value
            guard !Task.isCancelled, self.loadedKey == key else { return }
            self.events = built
            self.lastUpdated = Date()
            self.lastShowSignature = signature
            self.isRefreshing = false
            self.lookupCount = 0
            self.refreshTask = nil
            let counts = CinemetaCatalogRepository.metadataCacheCounts()
            CrashRecorder.note("calendar (\(reason)): \(shows.count) shows, \(dueShows.count) looked up (\(looked.failed) failed)"
                               + (showsChanged ? ", show list changed" : "") + ", \(built.count) events in "
                               + "\(Int(Date().timeIntervalSince(started) * 1000)) ms; metadata cache \(counts.all) entries, \(counts.full) full")
            let file = CacheFile(key: key, savedAt: Date(), showSignature: signature, records: Array(current.values))
            Task.detached(priority: .background) { Self.writeCache(file) }
            // Anything still due (over the cap) goes next time.
        }
    }

    // MARK: - Show metadata

    /// A show's full metadata, for playback and watched marking from the
    /// calendar (the shared cache usually has it).
    func meta(for showID: String, type: String = "series") async -> NuvioMeta? {
        try? await CinemetaCatalogRepository().getMetadata(id: showID, type: type)
    }

    // MARK: - Ready to watch (the focused card only)

    nonisolated static func availabilityKey(showID: String, season: Int, episode: Int) -> String {
        "\(showID):\(season):\(episode)"
    }

    /// Reads the add-ons' stream lists for one episode (the card you're
    /// resting on) without taking over any search, and counts the sources
    /// playback could use. Never resolves a link. Kept 2 h when sources were
    /// found, 30 min when not; an unanswered check isn't kept. Stops when the
    /// caller is cancelled (focus moved on). Doesn't run during playback.
    func probeAvailability(showID: String, season: Int, episode: Int) async {
        let key = Self.availabilityKey(showID: showID, season: season, episode: episode)
        if let checked = availabilityCheckedAt[key] {
            let lifetime: TimeInterval
            if case .ready? = availability[key] { lifetime = Self.positiveLifetime } else { lifetime = Self.negativeLifetime }
            if Date().timeIntervalSince(checked) < lifetime { return }
        }
        guard !OutsideGuidePause.shared.isPaused else { return }
        probeGeneration &+= 1
        let generation = probeGeneration
        let previous = availability[key] == .checking ? nil : availability[key]
        availability[key] = .checking
        let streams = await StreamsRepository.shared.sideStreams(
            type: "series", videoId: key, reason: "calendar", withSubtitles: false, cancellable: true
        )
        // A newer probe owns the badge now.
        guard generation == probeGeneration else { return }
        if Task.isCancelled {
            availability[key] = previous
            return
        }
        guard let streams else {
            availability[key] = .unknown
            availabilityCheckedAt[key] = nil
            return
        }
        let count = Self.playableCount(streams)
        availability[key] = count > 0 ? .ready(count) : .notYet
        availabilityCheckedAt[key] = Date()
    }

    /// The streams playback would consider, with the same settings.
    private static func playableCount(_ streams: [NuvioStream]) -> Int {
        let store = ProfileSettings.current
        let includeDebrid = DebridResolver(store: store).isEnabled || TorrentSettings.isEnabled(store: store)
        let cachedOnlyPreference = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let cachedOnly = SmartPlaybackSelector.effectiveCachedOnly(cachedOnlyPreference, contentType: "series")
        let preserve = (store.object(forKey: SettingsKey.preserveAddonStreamOrder) as? Bool) ?? false
        return SmartPlaybackSelector.playableStreams(
            from: streams, includeDebrid: includeDebrid, cachedOnly: cachedOnly, preserveAddonStreams: preserve
        ).filter { !$0.isNotPlayable }.count
    }

    // MARK: - Schedule

    /// When a show should be looked up again.
    nonisolated static func nextCheck(for record: CalendarShowRecord, now: Date) -> Date {
        if record.failures > 0, let attempt = record.lastAttempt {
            // 15 min, 30 min, 1 h … up to 6 h after a failed lookup.
            let wait = min(6 * 3600, 900 * pow(2, Double(min(record.failures - 1, 5))))
            return attempt.addingTimeInterval(wait)
        }
        guard let fetched = record.fetchedAt else { return .distantPast }
        return fetched.addingTimeInterval(refreshInterval(for: record, now: now))
    }

    nonisolated static func refreshInterval(for record: CalendarShowRecord, now: Date) -> TimeInterval {
        let hour: TimeInterval = 3600
        let days = record.videos.compactMap { airMoment($0.released).map { $0.time ?? $0.day } }
        let nearest = days.map { abs($0.timeIntervalSince(now)) }.min() ?? .infinity
        if nearest <= 48 * hour { return 6 * hour }
        if nearest <= 7 * 24 * hour { return 12 * hour }
        if days.contains(where: { $0 > now }) { return 24 * hour }
        let status = (record.status ?? "").lowercased()
        if status.contains("ended") || status.contains("cancel") { return 30 * 24 * hour }
        return 3 * 24 * hour
    }

    // MARK: - Looking shows up

    private struct Looked: Sendable {
        var records: [CalendarShowRecord] = []
        var failed = 0
    }

    /// Looks the shows up four at a time. A show looked up before is fetched
    /// fresh (its time came); a new one may come from the shared cache.
    private nonisolated static func lookUp(_ shows: [Show], previous: [String: CalendarShowRecord]) async -> Looked {
        let repository = CinemetaCatalogRepository()
        var result = Looked()
        var start = 0
        while start < shows.count, !Task.isCancelled {
            let batch = Array(shows[start..<min(start + 4, shows.count)])
            start += 4
            let found = await withTaskGroup(of: (Show, NuvioMeta?).self, returning: [(Show, NuvioMeta?)].self) { group in
                for show in batch {
                    let known = previous[show.id]?.fetchedAt != nil
                    group.addTask {
                        let meta: NuvioMeta?
                        if known {
                            meta = try? await repository.refreshMetadata(id: show.id, type: "series")
                        } else {
                            meta = try? await repository.getMetadata(id: show.id, type: "series")
                        }
                        return (show, meta)
                    }
                }
                var collected: [(Show, NuvioMeta?)] = []
                for await item in group { collected.append(item) }
                return collected
            }
            let now = Date()
            for (show, meta) in found {
                if let meta {
                    result.records.append(record(from: meta, show: show, now: now))
                } else {
                    var failedRecord = previous[show.id] ?? CalendarShowRecord(id: show.id, name: show.name, type: "series", videos: [])
                    failedRecord.failures += 1
                    failedRecord.lastAttempt = now
                    result.records.append(failedRecord)
                    result.failed += 1
                }
            }
        }
        return result
    }

    private nonisolated static func record(from meta: NuvioMeta, show: Show, now: Date) -> CalendarShowRecord {
        // Episodes from two months back on: enough for 30 days of "new" even
        // when the record is a month old.
        let floor = Calendar.current.date(byAdding: .day, value: -(CalendarWindow.pastDays + 31), to: Calendar.current.startOfDay(for: now)) ?? now
        let videos = (meta.videos ?? []).filter { $0.season > 0 }.compactMap { video -> CalendarShowVideo? in
            guard let moment = airMoment(video.released), moment.day >= floor else { return nil }
            return CalendarShowVideo(season: video.season, episode: video.episode, title: video.title,
                                     released: video.released, thumbnail: video.thumbnail, overview: video.overview)
        }
        return CalendarShowRecord(
            id: show.id, name: meta.name.isEmpty ? show.name : meta.name, type: meta.canonicalType,
            poster: meta.posterUrl, background: meta.backgroundUrl, logo: meta.logoUrl,
            overview: meta.description, status: meta.status, videos: videos,
            fetchedAt: now, failures: 0, lastAttempt: now
        )
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

    nonisolated static func buildEvents(shows: [Show], records: [String: CalendarShowRecord], now: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -CalendarWindow.pastDays, to: today),
              let windowEnd = calendar.date(byAdding: .day, value: CalendarWindow.futureDays + 1, to: today) else { return [] }
        var collected: [CalendarEvent] = []
        for show in shows {
            guard let record = records[show.id] else { continue }
            collected.append(contentsOf: Self.events(from: record, show: show, windowStart: windowStart, windowEnd: windowEnd))
        }
        return collected.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            let lt = lhs.airTime ?? lhs.day, rt = rhs.airTime ?? rhs.day
            if lt != rt { return lt < rt }
            return lhs.showName.localizedCaseInsensitiveCompare(rhs.showName) == .orderedAscending
        }
    }

    private nonisolated static func events(
        from record: CalendarShowRecord,
        show: Show,
        windowStart: Date,
        windowEnd: Date
    ) -> [CalendarEvent] {
        struct Dated {
            let video: CalendarShowVideo
            let day: Date
            let time: Date?
        }
        let dated: [Dated] = record.videos.compactMap { video in
            guard let moment = airMoment(video.released),
                  moment.day >= windowStart, moment.day < windowEnd else { return nil }
            return Dated(video: video, day: moment.day, time: moment.time)
        }
        guard !dated.isEmpty else { return [] }

        let showName = record.name.isEmpty ? show.name : record.name
        // Several episodes of one season on one day read as a single drop.
        let grouped = Dictionary(grouping: dated) { "\($0.video.season)|\($0.day.timeIntervalSince1970)" }
        var result: [CalendarEvent] = []
        for (_, group) in grouped {
            let sortedGroup = group.sorted { $0.video.episode < $1.video.episode }
            guard let first = sortedGroup.first else { continue }
            if sortedGroup.count >= 3 {
                result.append(CalendarEvent(
                    id: "\(record.id):s\(first.video.season):drop:\(Int(first.day.timeIntervalSince1970))",
                    kind: .seasonDrop,
                    showID: record.id,
                    showType: record.type,
                    showName: showName,
                    season: first.video.season,
                    episode: first.video.episode,
                    episodeCount: sortedGroup.count,
                    episodeTitle: "",
                    day: first.day,
                    airTime: first.time,
                    imageURL: record.background ?? first.video.thumbnail ?? record.poster,
                    logoURL: record.logo,
                    sources: show.sources,
                    overview: record.overview,
                    released: first.video.released
                ))
            } else {
                for entry in sortedGroup {
                    result.append(CalendarEvent(
                        id: "\(record.id):s\(entry.video.season)e\(entry.video.episode)",
                        kind: .episode,
                        showID: record.id,
                        showType: record.type,
                        showName: showName,
                        season: entry.video.season,
                        episode: entry.video.episode,
                        episodeCount: 1,
                        episodeTitle: entry.video.title,
                        day: entry.day,
                        airTime: entry.time,
                        imageURL: entry.video.thumbnail ?? record.background ?? record.poster,
                        logoURL: record.logo,
                        sources: show.sources,
                        overview: entry.video.overview?.isEmpty == false ? entry.video.overview : record.overview,
                        released: entry.video.released
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

    private nonisolated static func cacheURL(key: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        // A short stable hash of profile + language, safe for a file name.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return base.appendingPathComponent("ReleaseCalendar-v3-\(String(hash, radix: 16)).json")
    }

    private nonisolated static func readCache(key: String) -> CacheFile? {
        guard let url = cacheURL(key: key),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.key == key, cache.version == 3 else { return nil }
        return cache
    }

    private nonisolated static func writeCache(_ cache: CacheFile) {
        guard let url = cacheURL(key: cache.key),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
