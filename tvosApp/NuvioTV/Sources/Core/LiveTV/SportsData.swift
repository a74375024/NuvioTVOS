import Foundation

// MARK: - Game schedule
//
// The week ahead for the major leagues (teams, logos, start times, venue,
// week, TV network), from ESPN's public scoreboard. No scores are used.
//
// Kept to a minimum: one request per league for the next week, only when
// Live Events is opened and the saved schedule is from an earlier day (or
// on Refresh). Leagues none of your channels showed last time are skipped
// and looked at again after a week. Nothing about the viewer is sent.

struct SportsTeam: Codable, Hashable {
    let id: String
    let name: String
    var short: String?
    var alternates: [String] = []
    var badge: String?
    /// "Utah", "Los Angeles": only used to match college teams.
    var location: String? = nil

    /// "LAR", or initials when there's no abbreviation.
    var abbreviation: String {
        if let short, !short.isEmpty, short.count <= 4 { return short.uppercased() }
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        if words.count >= 2 { return words.prefix(3).compactMap { $0.first.map(String.init) }.joined().uppercased() }
        return String(name.prefix(3)).uppercased()
    }
}

struct SportsGame: Codable, Hashable, Identifiable {
    let id: String
    /// Row group: "NFL", "College Football", "Soccer"…
    let league: String
    /// Chip text: "NFL", "EPL", "UCL"…
    let leagueShort: String
    let isSoccer: Bool
    /// "Week 8", or nil.
    let weekLabel: String?
    let home: SportsTeam
    let away: SportsTeam
    let start: Date
    /// TV networks, national first ("FOX", "ESPN", "NBA League Pass").
    var networks: [String] = []
    let venue: String?
    var postponed = false
    /// Already over when the schedule was fetched.
    var completed = false

    var title: String {
        isSoccer ? "\(home.name) vs \(away.name)" : "\(away.name) at \(home.name)"
    }
}

@MainActor
final class SportsData: ObservableObject {
    static let shared = SportsData()

    struct League {
        let path: String
        let group: String
        let short: String
        let soccer: Bool
        var extra = ""
    }

    static let leagues: [League] = [
        League(path: "football/nfl", group: "NFL", short: "NFL", soccer: false),
        League(path: "football/college-football", group: "College Football", short: "NCAAF", soccer: false, extra: "&groups=80"),
        League(path: "basketball/nba", group: "NBA", short: "NBA", soccer: false),
        League(path: "baseball/mlb", group: "MLB", short: "MLB", soccer: false),
        League(path: "hockey/nhl", group: "NHL", short: "NHL", soccer: false),
        League(path: "soccer/usa.1", group: "MLS", short: "MLS", soccer: true),
        League(path: "soccer/eng.1", group: "Soccer", short: "EPL", soccer: true),
        League(path: "soccer/uefa.champions", group: "Soccer", short: "UCL", soccer: true),
        League(path: "soccer/esp.1", group: "Soccer", short: "LIGA", soccer: true)
    ]

    static let enabledKey = "nuvio.tv.livetv.gameSchedule"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let showUnwatchableKey = "nuvio.tv.livetv.showUnwatchable"
    static var showsUnwatchable: Bool {
        get { UserDefaults.standard.object(forKey: showUnwatchableKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showUnwatchableKey) }
    }

    @Published private(set) var games: [SportsGame] = []
    @Published private(set) var revision = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var refreshing = false

    private struct Saved: Codable {
        var games: [SportsGame] = []
        var fetchedAt: Date?
        /// League (chip text) → when it was last fetched.
        var leagueFetched: [String: Date] = [:]
        /// League → last time one of its games was on your channels.
        var leagueWatchable: [String: Date] = [:]
        /// Last attempt that got nothing, so a failing source isn't asked
        /// again every time Live Events opens.
        var failedAt: Date?
        /// Failed days in a row (backoff 1 h → 6 h → 24 h; after 3, only Refresh).
        var failures: Int?
        /// League → "limit" or "plain": the request form that works.
        var leagueForm: [String: String]?
        /// Requests made today, for the log.
        var requestDay: String?
        var requestCount: Int?
    }

    private var saved = Saved()
    private var task: Task<Void, Never>?
    private var loadedFromDisk = false
    private let file: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("game-schedule.json")
        // The old TheSportsDB cache isn't used any more.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("sportsdb.json"))
    }

    private var loading: Task<Void, Never>?

    /// The saved schedule, read in the background, without any request.
    func loadCached() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        let file = self.file
        loading = Task { [weak self] in
            let value = await Task.detached(priority: .utility) { () -> Saved? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(Saved.self, from: data)
            }.value
            guard let self else { return }
            if let value { self.saved = value }
            self.publish()
        }
    }

    /// Called when Live Events opens: fetches only if the saved schedule is
    /// from an earlier day, and not while backing off after failures.
    func refreshIfNeeded() {
        loadCached()
        Task { [weak self] in
            await self?.loading?.value
            guard let self, Self.isEnabled, self.task == nil else { return }
            if let fetched = self.saved.fetchedAt, Calendar.current.isDateInToday(fetched),
               Date().timeIntervalSince(fetched) < 20 * 3600 { return }
            let failures = self.saved.failures ?? 0
            if failures > 0, let failed = self.saved.failedAt {
                guard failures <= 3 else { return }   // only Refresh from here
                let wait: [TimeInterval] = [3600, 6 * 3600, 24 * 3600]
                if Date().timeIntervalSince(failed) < wait[min(failures - 1, 2)] { return }
            }
            self.start(force: false)
        }
    }

    /// Options → Refresh schedule: every league, now.
    func refreshNow() {
        loadCached()
        Task { [weak self] in
            await self?.loading?.value
            guard let self, Self.isEnabled, self.task == nil else { return }
            self.start(force: true)
        }
    }

    /// Turned off or on in Options.
    func enabledChanged() {
        loadCached()
        publish()
        if Self.isEnabled { refreshIfNeeded() }
    }

    /// After matching: which leagues had a game on your channels.
    func noteWatchable(_ leagues: Set<String>) {
        guard !leagues.isEmpty else { return }
        let now = Date()
        var changed = false
        for league in leagues {
            if let last = saved.leagueWatchable[league], now.timeIntervalSince(last) < 6 * 3600 { continue }
            saved.leagueWatchable[league] = now
            changed = true
        }
        if changed { save() }
    }

    private func start(force: Bool) {
        refreshing = true
        task = Task { [weak self] in
            await self?.fetch(force: force)
            self?.task = nil
            self?.refreshing = false
        }
    }

    private func publish() {
        if Self.isEnabled {
            let cutoff = Date().addingTimeInterval(-12 * 3600)
            games = saved.games.filter { $0.start > cutoff }.sorted { $0.start < $1.start }
            updatedAt = saved.fetchedAt
        } else {
            games = []
        }
        revision &+= 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    private func fetch(force: Bool) async {
        let now = Date()
        let calendar = Calendar.current
        // Date ranges stopped working (HTTP 400) in Sept 2026; a whole month
        // still does. The week ahead is one month, or two near month's end.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMM"
        let from = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let to = calendar.date(byAdding: .day, value: 8, to: now) ?? now
        var months = [formatter.string(from: from)]
        if formatter.string(from: to) != months[0] { months.append(formatter.string(from: to)) }
        var byLeague = Dictionary(grouping: saved.games, by: \.leagueShort)
        var fetchedAny = false
        var requests = 0
        for league in Self.leagues {
            if !force, skip(league.short, now: now) { continue }
            if requests > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            requests += 1
            var list: [SportsGame] = []
            var ok = false
            for (index, month) in months.enumerated() {
                if index > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                if let part = await fetchLeague(league, month: month, from: from, to: to) {
                    list += part
                    ok = true
                }
            }
            guard ok else { continue }
            byLeague[league.short] = list
            saved.leagueFetched[league.short] = now
            fetchedAny = true
        }
        CrashRecorder.note("schedule: \(requests) leagues, ok=\(fetchedAny), \(saved.requestCount ?? 0) requests today")
        guard fetchedAny || requests == 0 else {
            saved.failedAt = now
            saved.failures = (saved.failures ?? 0) + 1
            save()
            return
        }
        saved.failedAt = nil
        saved.failures = 0
        let cutoff = now.addingTimeInterval(-2 * 86_400)
        saved.games = byLeague.values.flatMap { $0 }.filter { $0.start > cutoff }
        saved.fetchedAt = now
        save()
        publish()
    }

    /// A league none of your channels showed in the last week is looked at
    /// once a week instead of daily.
    private func skip(_ league: String, now: Date) -> Bool {
        guard let fetched = saved.leagueFetched[league] else { return false }
        let week: TimeInterval = 7 * 86_400
        if let watchable = saved.leagueWatchable[league], now.timeIntervalSince(watchable) < week { return false }
        return now.timeIntervalSince(fetched) < week
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func get(_ address: String) async -> (status: Int, data: Data)? {
        let today = Self.dayKey.string(from: Date())
        if saved.requestDay != today { saved.requestDay = today; saved.requestCount = 0 }
        saved.requestCount = (saved.requestCount ?? 0) + 1
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let result = try await URLSession.shared.data(for: request)
            return ((result.1 as? HTTPURLResponse)?.statusCode ?? 0, result.0)
        } catch {
            CrashRecorder.note("schedule: request failed (\((error as NSError).code))")
            return nil
        }
    }

    private func fetchLeague(_ league: League, month: String, from: Date, to: Date) async -> [SportsGame]? {
        let base = "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard?dates=\(month)\(league.extra)"
        // Remember which form works, so a league is asked once, not twice.
        let plainForm = saved.leagueForm?[league.short] == "plain"
        guard var result = await get(plainForm ? base : base + "&limit=1000") else { return nil }
        if result.status == 200, !plainForm {
            saved.leagueForm = (saved.leagueForm ?? [:]).merging([league.short: "limit"]) { _, new in new }
        }
        if result.status == 400, !plainForm {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let retry = await get(base) else { return nil }
            result = retry
            if retry.status == 200 {
                saved.leagueForm = (saved.leagueForm ?? [:]).merging([league.short: "plain"]) { _, new in new }
            }
        }
        guard result.status == 200 else {
            CrashRecorder.note("schedule \(league.short) \(month): HTTP \(result.status)")
            return nil
        }
        let data = result.data
        // Parsed off the main thread (a week of college football is a few MB).
        let games = await Task.detached(priority: .utility) { () -> [SportsGame]? in
            // Only the fields used are decoded; the full object tree is the
            // fallback if that ever fails. Only the week ahead is kept.
            let list = SportsParse.decode(data, league: league) ?? autoreleasepool { () -> [SportsGame]? in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = object["events"] as? [[String: Any]] else { return nil }
                return events.compactMap { SportsParse.game($0, league: league) }
            }
            return list?.filter { $0.start >= from && $0.start <= to }
        }.value
        CrashRecorder.note("schedule \(league.short) \(month): \(data.count / 1024) KB, \(games.map { String($0.count) } ?? "unreadable") games")
        return games
    }
}

/// Scoreboard JSON → games. Outside the main actor so it can run anywhere.
private enum SportsParse {
    static func game(_ event: [String: Any], league: SportsData.League) -> SportsGame? {
        guard let id = text(event["id"]), let start = date(text(event["date"])),
              let competition = (event["competitions"] as? [[String: Any]])?.first,
              let competitors = competition["competitors"] as? [[String: Any]], competitors.count == 2 else { return nil }
        var home: SportsTeam?
        var away: SportsTeam?
        for competitor in competitors {
            guard let team = self.team(competitor["team"] as? [String: Any]) else { continue }
            if text(competitor["homeAway"]) == "home" { home = team } else { away = team }
        }
        guard let home, let away else { return nil }
        let statusObject = (competition["status"] as? [String: Any]) ?? (event["status"] as? [String: Any])
        let status = statusObject?["type"] as? [String: Any]
        let statusName = text(status?["name"])?.uppercased() ?? ""
        let week = (event["week"] as? [String: Any]).flatMap { text($0["number"]) }.flatMap { Int($0) }
        let showsWeek = league.group == "NFL" || league.group == "College Football"
        return SportsGame(
            id: "\(league.short)|\(id)", league: league.group, leagueShort: league.short, isSoccer: league.soccer,
            weekLabel: showsWeek ? week.map { "Week \($0)" } : nil,
            home: home, away: away, start: start,
            networks: networks(competition),
            venue: venue(competition["venue"] as? [String: Any]),
            postponed: statusName.contains("POSTPONED") || statusName.contains("CANCELED") || statusName.contains("CANCELLED"),
            completed: (status?["completed"] as? Bool) == true || statusName.contains("FINAL")
        )
    }

    private static func team(_ item: [String: Any]?) -> SportsTeam? {
        guard let item, let id = text(item["id"]), let name = text(item["displayName"]) ?? text(item["name"]) else { return nil }
        var alternates: [String] = []
        for key in ["shortDisplayName", "name"] {
            if let value = text(item[key]), value != name, !alternates.contains(value) { alternates.append(value) }
        }
        var logo = text(item["logo"])
        if logo == nil, let logos = item["logos"] as? [[String: Any]] { logo = logos.first.flatMap { text($0["href"]) } }
        return SportsTeam(id: id, name: name, short: text(item["abbreviation"]), alternates: alternates, badge: logo,
                          location: text(item["location"]))
    }

    private static func networks(_ competition: [String: Any]) -> [String] {
        var national: [String] = []
        var other: [String] = []
        for item in competition["broadcasts"] as? [[String: Any]] ?? [] {
            let names = (item["names"] as? [Any] ?? []).compactMap { text($0) }
            if text(item["market"])?.lowercased() == "national" { national += names } else { other += names }
        }
        for item in competition["geoBroadcasts"] as? [[String: Any]] ?? [] {
            guard let name = (item["media"] as? [String: Any]).flatMap({ text($0["shortName"]) }) else { continue }
            let market = (item["market"] as? [String: Any]).flatMap { text($0["type"]) }?.lowercased()
            if market == "national" { national.append(name) } else { other.append(name) }
        }
        var seen = Set<String>()
        return (national + other).filter { seen.insert($0.lowercased()).inserted }
    }

    private static func venue(_ item: [String: Any]?) -> String? {
        guard let item, let name = text(item["fullName"]) else { return nil }
        if let city = (item["address"] as? [String: Any]).flatMap({ text($0["city"]) }), !name.contains(city) {
            return "\(name), \(city)"
        }
        return name
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let minutes: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }()

    /// "2026-10-25T17:00Z" (no seconds) or full ISO 8601.
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return minutes.date(from: value) ?? iso.date(from: value)
    }
}

// MARK: - Lean decoding (only the fields used; any odd value is skipped, never fatal)

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

private struct LenientText: Decodable {
    let value: String?
    init(from decoder: Decoder) {
        guard let container = try? decoder.singleValueContainer() else { value = nil; return }
        if let text = try? container.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self) {
            value = String(number)
        } else {
            value = nil
        }
    }
}

private struct LenientBool: Decodable {
    let value: Bool?
    init(from decoder: Decoder) { value = try? decoder.singleValueContainer().decode(Bool.self) }
}

private struct ScoreboardDoc: Decodable { let events: Lenient<[Lenient<ScoreboardEvent>]>? }
private struct ScoreboardEvent: Decodable {
    let id: LenientText?
    let date: LenientText?
    let week: Lenient<ScoreboardWeek>?
    let competitions: Lenient<[Lenient<ScoreboardCompetition>]>?
    let status: Lenient<ScoreboardStatus>?
}
private struct ScoreboardWeek: Decodable { let number: LenientText? }
private struct ScoreboardCompetition: Decodable {
    let competitors: Lenient<[Lenient<ScoreboardCompetitor>]>?
    let venue: Lenient<ScoreboardVenue>?
    let broadcasts: Lenient<[Lenient<ScoreboardBroadcast>]>?
    let geoBroadcasts: Lenient<[Lenient<ScoreboardGeo>]>?
    let status: Lenient<ScoreboardStatus>?
}
private struct ScoreboardCompetitor: Decodable {
    let homeAway: LenientText?
    let team: Lenient<ScoreboardTeam>?
}
private struct ScoreboardTeam: Decodable {
    let id: LenientText?
    let displayName: LenientText?
    let shortDisplayName: LenientText?
    let name: LenientText?
    let location: LenientText?
    let abbreviation: LenientText?
    let logo: LenientText?
    let logos: Lenient<[Lenient<ScoreboardHref>]>?
}
private struct ScoreboardHref: Decodable { let href: LenientText? }
private struct ScoreboardVenue: Decodable {
    let fullName: LenientText?
    let address: Lenient<ScoreboardCity>?
}
private struct ScoreboardCity: Decodable { let city: LenientText? }
private struct ScoreboardBroadcast: Decodable {
    let market: LenientText?
    let names: Lenient<[LenientText]>?
}
private struct ScoreboardGeo: Decodable {
    let media: Lenient<ScoreboardShortName>?
    let market: Lenient<ScoreboardMarket>?
}
private struct ScoreboardShortName: Decodable { let shortName: LenientText? }
private struct ScoreboardMarket: Decodable { let type: LenientText? }
private struct ScoreboardStatus: Decodable { let type: Lenient<ScoreboardStatusType>? }
private struct ScoreboardStatusType: Decodable {
    let name: LenientText?
    let completed: LenientBool?
}

extension SportsParse {
    /// Games from a scoreboard document, decoding only what's used.
    static func decode(_ data: Data, league: SportsData.League) -> [SportsGame]? {
        guard let doc = try? JSONDecoder().decode(ScoreboardDoc.self, from: data),
              let events = doc.events?.value else { return nil }
        return events.compactMap { $0.value.flatMap { game($0, league: league) } }
    }

    private static func game(_ event: ScoreboardEvent, league: SportsData.League) -> SportsGame? {
        guard let id = event.id?.value, let start = date(event.date?.value),
              let competition = event.competitions?.value?.first?.value,
              let competitors = competition.competitors?.value?.compactMap({ $0.value }), competitors.count == 2 else { return nil }
        var home: SportsTeam?
        var away: SportsTeam?
        for competitor in competitors {
            guard let item = competitor.team?.value, let teamID = item.id?.value,
                  let name = item.displayName?.value ?? item.name?.value else { continue }
            var alternates: [String] = []
            for value in [item.shortDisplayName?.value, item.name?.value].compactMap({ $0 }) where value != name && !alternates.contains(value) {
                alternates.append(value)
            }
            let logo = item.logo?.value ?? item.logos?.value?.first?.value?.href?.value
            let team = SportsTeam(id: teamID, name: name, short: item.abbreviation?.value, alternates: alternates, badge: logo,
                                  location: item.location?.value)
            if competitor.homeAway?.value == "home" { home = team } else { away = team }
        }
        guard let home, let away else { return nil }
        let status = (competition.status?.value ?? event.status?.value)?.type?.value
        let statusName = status?.name?.value?.uppercased() ?? ""
        var national: [String] = []
        var other: [String] = []
        for item in competition.broadcasts?.value ?? [] {
            guard let broadcast = item.value else { continue }
            let names = broadcast.names?.value?.compactMap { $0.value } ?? []
            if broadcast.market?.value?.lowercased() == "national" { national += names } else { other += names }
        }
        for item in competition.geoBroadcasts?.value ?? [] {
            guard let geo = item.value, let name = geo.media?.value?.shortName?.value else { continue }
            if geo.market?.value?.type?.value?.lowercased() == "national" { national.append(name) } else { other.append(name) }
        }
        var seen = Set<String>()
        let networks = (national + other).filter { seen.insert($0.lowercased()).inserted }
        var venue: String?
        if let venueItem = competition.venue?.value, let name = venueItem.fullName?.value {
            if let city = venueItem.address?.value?.city?.value, !name.contains(city) { venue = "\(name), \(city)" } else { venue = name }
        }
        let week = event.week?.value?.number?.value.flatMap { Int($0) }
        let showsWeek = league.group == "NFL" || league.group == "College Football"
        return SportsGame(
            id: "\(league.short)|\(id)", league: league.group, leagueShort: league.short, isSoccer: league.soccer,
            weekLabel: showsWeek ? week.map { "Week \($0)" } : nil,
            home: home, away: away, start: start, networks: networks, venue: venue,
            postponed: statusName.contains("POSTPONED") || statusName.contains("CANCELED") || statusName.contains("CANCELLED"),
            completed: status?.completed?.value == true || statusName.contains("FINAL")
        )
    }
}
