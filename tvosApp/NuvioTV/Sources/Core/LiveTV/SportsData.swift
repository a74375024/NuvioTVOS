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
        enum Mode { case month, week, days(Int) }
        let path: String
        /// Row group: "NFL", "College Football", "Soccer"…
        let group: String
        /// Id and chip text: "NFL", "EPL"…
        let short: String
        /// Name in My Sports: "Premier League".
        let name: String
        /// Section in My Sports: "Football", "Basketball"…
        let sport: String
        let soccer: Bool
        var extra = ""
        /// How the week ahead is asked for: a month (one or two requests),
        /// this week and next (college football: a month comes back cut
        /// short), or day by day (college basketball has too many games).
        var mode: Mode = .month
        /// Fetched before My Sports is set up.
        var standard = false
        /// Words in provider event titles that mean this league (for
        /// suggestions); empty means the row group decides.
        var keywords: [String] = []
        var college: Bool { group.hasPrefix("College") }
    }

    static let leagues: [League] = [
        League(path: "football/nfl", group: "NFL", short: "NFL", name: "NFL", sport: "Football", soccer: false, standard: true),
        League(path: "football/college-football", group: "College Football", short: "NCAAF", name: "College Football", sport: "Football",
               soccer: false, extra: "&groups=80", mode: .week, standard: true),
        League(path: "basketball/nba", group: "NBA", short: "NBA", name: "NBA", sport: "Basketball", soccer: false, standard: true),
        League(path: "basketball/wnba", group: "WNBA", short: "WNBA", name: "WNBA", sport: "Basketball", soccer: false),
        League(path: "basketball/mens-college-basketball", group: "College Basketball", short: "NCAAM", name: "Men's College",
               sport: "Basketball", soccer: false, extra: "&groups=50", mode: .days(3)),
        League(path: "basketball/womens-college-basketball", group: "College Basketball", short: "NCAAW", name: "Women's College",
               sport: "Basketball", soccer: false, extra: "&groups=50", mode: .days(3), keywords: ["women"]),
        League(path: "baseball/mlb", group: "MLB", short: "MLB", name: "MLB", sport: "Baseball", soccer: false, standard: true),
        League(path: "hockey/nhl", group: "NHL", short: "NHL", name: "NHL", sport: "Hockey", soccer: false, standard: true),
        League(path: "soccer/usa.1", group: "MLS", short: "MLS", name: "MLS", sport: "Soccer", soccer: true, standard: true,
               keywords: ["mls", "major league soccer"]),
        League(path: "soccer/eng.1", group: "Soccer", short: "EPL", name: "Premier League", sport: "Soccer", soccer: true,
               standard: true, keywords: ["premier league", "epl"]),
        League(path: "soccer/uefa.champions", group: "Soccer", short: "UCL", name: "Champions League", sport: "Soccer", soccer: true,
               standard: true, keywords: ["champions league"]),
        League(path: "soccer/esp.1", group: "Soccer", short: "LIGA", name: "La Liga", sport: "Soccer", soccer: true,
               standard: true, keywords: ["laliga", "la liga"]),
        League(path: "soccer/mex.1", group: "Soccer", short: "LMX", name: "Liga MX", sport: "Soccer", soccer: true, keywords: ["liga mx"]),
        League(path: "soccer/ita.1", group: "Soccer", short: "SA", name: "Serie A", sport: "Soccer", soccer: true, keywords: ["serie a"]),
        League(path: "soccer/ger.1", group: "Soccer", short: "BUN", name: "Bundesliga", sport: "Soccer", soccer: true, keywords: ["bundesliga"]),
        League(path: "soccer/fra.1", group: "Soccer", short: "L1", name: "Ligue 1", sport: "Soccer", soccer: true, keywords: ["ligue 1", "ligue1"]),
        League(path: "soccer/uefa.europa", group: "Soccer", short: "UEL", name: "Europa League", sport: "Soccer", soccer: true,
               keywords: ["europa league"]),
        League(path: "soccer/uefa.europa.conf", group: "Soccer", short: "UECL", name: "Conference League", sport: "Soccer", soccer: true,
               keywords: ["conference league"]),
        League(path: "soccer/eng.2", group: "Soccer", short: "EFL", name: "Championship", sport: "Soccer", soccer: true,
               keywords: ["championship", "efl"]),
        League(path: "soccer/por.1", group: "Soccer", short: "POR", name: "Liga Portugal", sport: "Soccer", soccer: true,
               keywords: ["liga portugal", "primeira liga"]),
        League(path: "soccer/ned.1", group: "Soccer", short: "ERE", name: "Eredivisie", sport: "Soccer", soccer: true, keywords: ["eredivisie"]),
        League(path: "soccer/usa.nwsl", group: "Soccer", short: "NWSL", name: "NWSL", sport: "Soccer", soccer: true, keywords: ["nwsl"])
    ]

    /// The leagues looked up: My Sports' picks, or the standard set until
    /// it's set up.
    static var activeLeagues: [League] {
        let prefs = MySports.current
        guard prefs.configured else { return leagues.filter(\.standard) }
        let picked = Set(prefs.leagues)
        return leagues.filter { picked.contains($0.short) }
    }

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
    /// League → its teams (from the month's schedule), for picking favorites.
    @Published private(set) var rosters: [String: [SportsTeam]] = [:]
    /// Division I schools, for logos on college events in any sport.
    @Published private(set) var schools: [SportsTeam] = []

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
        /// App build the failure count belongs to (reset on update).
        var failureBuild: String?
        var rosters: [String: [SportsTeam]]?
        var schools: [SportsTeam]?
        var schoolsFetchedAt: Date?
        /// The leagues the saved schedule was fetched for.
        var leagueSet: [String]?
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Set when a request fails for network reasons (offline, timeout):
    /// those don't count toward the backoff.
    private var networkTrouble = false

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
            if self.saved.failureBuild != Self.appBuild { self.saved.failures = 0 }
            let failures = self.saved.failures ?? 0
            if let failed = self.saved.failedAt {
                // 1 h → 6 h → 24 h, then weekly; network trouble waits 1 h.
                let wait: [TimeInterval] = [3600, 3600, 6 * 3600, 24 * 3600, 7 * 86_400]
                if Date().timeIntervalSince(failed) < wait[min(failures, 4)] { return }
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

    /// - Parameter only: leagues to fetch (nil = all active; [] = none,
    ///   just the school list).
    private func start(force: Bool, only: Set<String>? = nil) {
        refreshing = true
        task = Task { [weak self] in
            await self?.fetch(force: force, only: only)
            guard let self else { return }
            self.task = nil
            self.refreshing = false
            // Picks that changed while this ran.
            if self.recheckPending {
                self.recheckPending = false
                self.leaguesChanged()
            }
        }
    }

    /// Picks changed (or Setup asked for teams) during a fetch.
    private var recheckPending = false
    /// Leagues Setup is showing, whose teams are needed before they're saved.
    private var wantedRosters = Set<String>()

    private func publish() {
        if Self.isEnabled {
            let cutoff = Date().addingTimeInterval(-12 * 3600)
            let active = Set(Self.activeLeagues.map(\.short))
            games = saved.games.filter { $0.start > cutoff && active.contains($0.leagueShort) }.sorted { $0.start < $1.start }
            updatedAt = saved.fetchedAt
            rosters = saved.rosters ?? [:]
            schools = Self.activeLeagues.contains(where: \.college) ? (saved.schools ?? []) : []
        } else {
            games = []
            schools = []
        }
        revision &+= 1
    }

    /// My Sports changed: show the saved games for the new picks right away,
    /// and look up any newly picked league.
    func leaguesChanged() {
        loadCached()
        Task { [weak self] in
            await self?.loading?.value
            guard let self else { return }
            self.publish()
            guard Self.isEnabled else { return }
            let fetched = Set(self.saved.leagueSet ?? [])
            var missing = Set(Self.activeLeagues.map(\.short).filter { !fetched.contains($0) })
            missing.formUnion(self.wantedRosters.filter { (self.saved.rosters?[$0] ?? []).isEmpty && !fetched.contains($0) })
            let college = Self.activeLeagues.contains(where: \.college)
                || Self.leagues.contains { self.wantedRosters.contains($0.short) && $0.college }
            let needsSchools = college && (self.saved.schools ?? []).isEmpty
            guard !missing.isEmpty || needsSchools else { return }
            if self.task != nil {
                self.recheckPending = true
                return
            }
            self.start(force: false, only: missing)
        }
    }

    /// Setup: teams for leagues picked there but not saved yet.
    func requestRosters(_ shorts: Set<String>) {
        wantedRosters = shorts
        leaguesChanged()
    }

    /// Teams to pick from: the schedule's, plus every school for college leagues.
    func teams(for league: League) -> [SportsTeam] {
        var byID: [String: SportsTeam] = [:]
        if league.college { for school in saved.schools ?? [] { byID[school.id] = school } }
        for team in saved.rosters?[league.short] ?? [] { byID[team.id] = team }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    private func fetch(force: Bool, only: Set<String>? = nil) async {
        let now = Date()
        networkTrouble = false
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let to = calendar.date(byAdding: .day, value: 8, to: now) ?? now
        // Date ranges stopped working (HTTP 400) in Sept 2026; a whole month,
        // a week number or a single day still do.
        let monthFormat = DateFormatter()
        monthFormat.locale = Locale(identifier: "en_US_POSIX")
        monthFormat.dateFormat = "yyyyMM"
        var months = [monthFormat.string(from: from)]
        if monthFormat.string(from: to) != months[0] { months.append(monthFormat.string(from: to)) }
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyyMMdd"

        // A given list may include leagues Setup is showing but hasn't saved.
        let active = only.map { set in Self.leagues.filter { set.contains($0.short) } } ?? Self.activeLeagues
        let needsSchoolsFor = Self.activeLeagues + active
        var succeeded: [String] = []
        let configured = MySports.current.configured
        var byLeague = Dictionary(grouping: saved.games, by: \.leagueShort)
        var rosters = saved.rosters ?? [:]
        var fetchedAny = false
        var requests = 0
        for league in active {
            // Before setup, leagues you can't watch are checked weekly.
            if !force, !configured, skip(league.short, now: now) { continue }
            if requests > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            requests += 1
            var queries: [String]
            switch league.mode {
            case .month: queries = months.map { "dates=\($0)" }
            case .days(let count): queries = (0..<count).map { "dates=" + dayFormat.string(from: calendar.date(byAdding: .day, value: $0, to: now) ?? now) }
            case .week: queries = [""]
            }
            var list: [SportsGame] = []
            var roster: [String: SportsTeam] = [:]
            var ok = false
            var index = 0
            while index < queries.count {
                if index > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                // Only the first request of a league says which query form works.
                if let part = await fetchLeague(league, query: queries[index], from: from, to: to, learnForm: index == 0) {
                    list += part.games
                    for team in part.teams { roster[team.id] = team }
                    ok = true
                    // This week's response says which week it is: ask for next week too.
                    if case .week = league.mode, index == 0, let week = part.week {
                        queries.append("week=\(week + 1)&seasontype=\(part.seasonType ?? 2)")
                    }
                }
                index += 1
            }
            guard ok else { continue }
            var seen = Set<String>()
            byLeague[league.short] = list.filter { seen.insert($0.id).inserted }
            if !roster.isEmpty {
                // Added to, not replaced: teams on a bye week stay pickable.
                for team in rosters[league.short] ?? [] where roster[team.id] == nil { roster[team.id] = team }
                rosters[league.short] = roster.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            saved.leagueFetched[league.short] = now
            succeeded.append(league.short)
            fetchedAny = true
        }
        // School logos for college events, once a month.
        if needsSchoolsFor.contains(where: \.college),
           saved.schoolsFetchedAt.map({ now.timeIntervalSince($0) > 30 * 86_400 }) ?? true || (saved.schools ?? []).isEmpty {
            if requests > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            if let list = await fetchSchools() {
                saved.schools = list
                saved.schoolsFetchedAt = now
            }
        }
        CrashRecorder.note("schedule: \(requests) leagues, ok=\(fetchedAny), \(saved.requestCount ?? 0) requests today")
        guard fetchedAny || requests == 0 else {
            saved.failedAt = now
            if !networkTrouble {
                saved.failures = (saved.failures ?? 0) + 1
                saved.failureBuild = Self.appBuild
            }
            save()
            return
        }
        saved.failedAt = nil
        saved.failures = 0
        let cutoff = now.addingTimeInterval(-2 * 86_400)
        saved.games = byLeague.values.flatMap { $0 }.filter { $0.start > cutoff }
        saved.rosters = rosters
        saved.leagueSet = Array(Set((saved.leagueSet ?? []) + succeeded))
        if only == nil { saved.fetchedAt = now }
        save()
        publish()
    }

    /// Division I schools (about 360) with their logos.
    private func fetchSchools() async -> [SportsTeam]? {
        guard let result = await get("https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/teams?limit=1000"),
              result.status == 200 else { return nil }
        let data = result.data
        let list = await Task.detached(priority: .utility) { () -> [SportsTeam]? in
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sports = object["sports"] as? [[String: Any]],
                      let leagues = sports.first?["leagues"] as? [[String: Any]],
                      let teams = leagues.first?["teams"] as? [[String: Any]] else { return nil }
                return teams.compactMap { SportsParse.team($0["team"] as? [String: Any]) }
            }
        }.value
        CrashRecorder.note("schedule: schools \(data.count / 1024) KB, \(list.map { String($0.count) } ?? "unreadable")")
        return list
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
            networkTrouble = true
            CrashRecorder.note("schedule: request failed (\((error as NSError).code))")
            return nil
        }
    }

    private struct LeagueResult {
        var games: [SportsGame]
        var teams: [SportsTeam]
        var week: Int?
        var seasonType: Int?
        var total = 0
    }

    private func fetchLeague(_ league: League, query: String, from: Date, to: Date, learnForm: Bool = true) async -> LeagueResult? {
        var base = "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard?"
        base += [query, String(league.extra.dropFirst())].filter { !$0.isEmpty }.joined(separator: "&")
        // Remember which form works, so a league is asked once, not twice.
        let plainForm = saved.leagueForm?[league.short] == "plain"
        guard var result = await get(plainForm ? base : base + "&limit=1000") else { return nil }
        if result.status == 200, !plainForm, learnForm {
            saved.leagueForm = (saved.leagueForm ?? [:]).merging([league.short: "limit"]) { _, new in new }
        }
        if result.status == 400, !plainForm {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let retry = await get(base) else { return nil }
            result = retry
            if retry.status == 200, learnForm {
                saved.leagueForm = (saved.leagueForm ?? [:]).merging([league.short: "plain"]) { _, new in new }
            }
        }
        guard result.status == 200 else {
            CrashRecorder.note("schedule \(league.short) \(query): HTTP \(result.status)")
            return nil
        }
        let data = result.data
        let parsed = await Task.detached(priority: .utility) { () -> LeagueResult? in
            // Only the fields used are decoded; the full object tree is the
            // fallback if that ever fails. Only the week ahead is kept.
            guard let doc = SportsParse.decodeDocument(data, league: league) ?? autoreleasepool(invoking: {
                SportsParse.serializedDocument(data, league: league)
            }) else { return nil }
            var teams: [String: SportsTeam] = [:]
            for game in doc.games { teams[game.home.id] = game.home; teams[game.away.id] = game.away }
            return LeagueResult(games: doc.games.filter { $0.start >= from && $0.start <= to }, teams: Array(teams.values),
                                week: doc.week, seasonType: doc.seasonType, total: doc.games.count)
        }.value
        if let parsed, parsed.total == 100 {
            CrashRecorder.note("schedule \(league.short) \(query): exactly 100 games, may be cut off")
        }
        CrashRecorder.note("schedule \(league.short) \(query.isEmpty ? "this week" : query): \(data.count / 1024) KB, "
                           + "\(parsed.map { "\($0.teams.count) teams, \($0.games.count) this week" } ?? "unreadable")")
        return parsed
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

    static func team(_ item: [String: Any]?) -> SportsTeam? {
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

private struct ScoreboardDoc: Decodable {
    let events: Lenient<[Lenient<ScoreboardEvent>]>?
    let week: Lenient<ScoreboardWeek>?
    let season: Lenient<ScoreboardSeason>?
}
private struct ScoreboardSeason: Decodable { let type: LenientText? }
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
    struct Document {
        var games: [SportsGame]
        var week: Int?
        var seasonType: Int?
    }

    /// Games from a scoreboard document, decoding only what's used.
    static func decodeDocument(_ data: Data, league: SportsData.League) -> Document? {
        guard let doc = try? JSONDecoder().decode(ScoreboardDoc.self, from: data),
              let events = doc.events?.value else { return nil }
        return Document(games: events.compactMap { $0.value.flatMap { game($0, league: league) } },
                        week: doc.week?.value?.number?.value.flatMap { Int($0) },
                        seasonType: doc.season?.value?.type?.value.flatMap { Int($0) })
    }

    /// The same from the full object tree (fallback).
    static func serializedDocument(_ data: Data, league: SportsData.League) -> Document? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return nil }
        let week = (object["week"] as? [String: Any]).flatMap { text($0["number"]) }.flatMap { Int($0) }
        let season = (object["season"] as? [String: Any]).flatMap { text($0["type"]) }.flatMap { Int($0) }
        return Document(games: events.compactMap { game($0, league: league) }, week: week, seasonType: season)
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
