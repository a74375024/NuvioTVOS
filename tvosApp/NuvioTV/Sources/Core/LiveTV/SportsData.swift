import Foundation

// MARK: - TheSportsDB (free tier)
//
// Schedules, team badges, venues, event art and final scores for the major
// leagues, from TheSportsDB's public API with its free key. No live scores
// (that's their paid tier). Fetched at most every 30 minutes, one request
// at a time (the free tier allows 30 a minute), and kept in Caches. Only
// league ids go out; nothing about the viewer is sent.

struct SportsTeam: Codable, Hashable {
    let id: String
    let name: String
    var short: String?
    var alternates: [String] = []
    var badge: String?

    /// "LAR", or initials when the database has no short name.
    var abbreviation: String {
        if let short, !short.isEmpty, short.count <= 4 { return short.uppercased() }
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        if words.count >= 2 { return words.prefix(3).compactMap { $0.first.map(String.init) }.joined().uppercased() }
        return String(name.prefix(3)).uppercased()
    }
}

struct SportsGame: Codable, Hashable, Identifiable {
    let id: String
    /// Row / chip group: "NFL", "NBA", "Soccer"…
    let league: String
    /// Chip text: "NFL", "EPL", "UCL"…
    let leagueShort: String
    let leagueName: String
    let isSoccer: Bool
    let round: String?
    let home: SportsTeam
    let away: SportsTeam
    let start: Date
    var status: String?
    var homeScore: Int?
    var awayScore: Int?
    let venue: String?
    let thumb: String?
    var postponed = false

    var isFinished: Bool {
        let text = (status ?? "").lowercased()
        if ["match finished", "ft", "aet", "pen", "final", "finished", "ended", "game over"].contains(where: { text.contains($0) }) {
            return true
        }
        // Final scores are only filled in once a game is over.
        return homeScore != nil && awayScore != nil && Date().timeIntervalSince(start) > 3600
    }

    var title: String {
        isSoccer ? "\(home.name) vs \(away.name)" : "\(away.name) at \(home.name)"
    }

    /// "Week 8", "Round 9", or nil.
    var roundLabel: String? {
        guard let round, let number = Int(round), number > 0 else { return nil }
        switch league {
        case "NFL", "College Football": return "Week \(number)"
        case "Soccer", "MLS": return "Matchday \(number)"
        default: return nil
        }
    }
}

@MainActor
final class SportsData: ObservableObject {
    static let shared = SportsData()

    struct League {
        let id: String
        let group: String
        let short: String
        let soccer: Bool
        /// The league name returned must contain one of these (guards
        /// against a wrong id quietly filling a row with another sport).
        let expect: [String]
    }

    static let leagues: [League] = [
        League(id: "4391", group: "NFL", short: "NFL", soccer: false, expect: ["nfl"]),
        League(id: "4479", group: "College Football", short: "NCAAF", soccer: false, expect: ["ncaa", "college"]),
        League(id: "4387", group: "NBA", short: "NBA", soccer: false, expect: ["nba"]),
        League(id: "4424", group: "MLB", short: "MLB", soccer: false, expect: ["mlb", "major league baseball"]),
        League(id: "4380", group: "NHL", short: "NHL", soccer: false, expect: ["nhl"]),
        League(id: "4346", group: "MLS", short: "MLS", soccer: true, expect: ["mls", "major league soccer"]),
        League(id: "4328", group: "Soccer", short: "EPL", soccer: true, expect: ["premier league"]),
        League(id: "4480", group: "Soccer", short: "UCL", soccer: true, expect: ["champions league"]),
        League(id: "4335", group: "Soccer", short: "LIGA", soccer: true, expect: ["la liga", "laliga"])
    ]

    static let enabledKey = "nuvio.tv.livetv.sportsInfo"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    @Published private(set) var games: [SportsGame] = []
    @Published private(set) var revision = 0

    private struct Saved: Codable {
        var games: [SportsGame]
        var teams: [String: [SportsTeam]]      // league id → teams
        var fetchedAt: Date?
        var teamsFetchedAt: Date?
    }

    private static let base = "https://www.thesportsdb.com/api/v1/json/123/"
    private static let refreshEvery: TimeInterval = 30 * 60
    private var saved = Saved(games: [], teams: [:], fetchedAt: nil, teamsFetchedAt: nil)
    private var task: Task<Void, Never>?
    private var loadedFromDisk = false
    private let file: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("sportsdb.json")
    }

    /// Uses the saved schedule right away and refreshes it when it's older
    /// than half an hour.
    func refreshIfNeeded() {
        guard Self.isEnabled else {
            if !games.isEmpty { games = []; revision &+= 1 }
            return
        }
        if !loadedFromDisk {
            loadedFromDisk = true
            if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) {
                saved = value
                publish()
            }
        } else if games.isEmpty, !saved.games.isEmpty {
            // Turned back on.
            publish()
        }
        guard task == nil else { return }
        if let fetched = saved.fetchedAt, Date().timeIntervalSince(fetched) < Self.refreshEvery { return }
        task = Task { [weak self] in
            await self?.fetchAll()
            self?.task = nil
        }
    }

    private func publish() {
        let cutoff = Date().addingTimeInterval(-4 * 24 * 3600)
        games = saved.games.filter { $0.start > cutoff }.sorted { $0.start < $1.start }
        revision &+= 1
    }

    private func fetchAll() async {
        let refreshTeams = saved.teamsFetchedAt.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true
        var byID: [String: SportsGame] = [:]
        for game in saved.games { byID[game.id] = game }
        var anyOK = false
        for league in Self.leagues {
            if refreshTeams, let teams = await fetchTeams(league) {
                saved.teams[league.id] = teams
            }
            // The free key returns only one game for "next" and "past", so
            // also ask for today's and tomorrow's games by date.
            let dayFormat = DateFormatter()
            dayFormat.locale = Locale(identifier: "en_US_POSIX")
            dayFormat.timeZone = TimeZone(identifier: "UTC")
            dayFormat.dateFormat = "yyyy-MM-dd"
            let days = [0, 1].map { dayFormat.string(from: Date().addingTimeInterval(Double($0) * 86_400)) }
            let requests = ["eventsnextleague.php?id=\(league.id)", "eventspastleague.php?id=\(league.id)"]
                + days.map { "eventsday.php?d=\($0)&l=\(league.id)" }
            for path in requests {
                guard let list = await fetchEvents(path, league: league) else { continue }
                anyOK = true
                for game in list { byID[game.id] = game }
            }
        }
        guard anyOK else { return }
        if refreshTeams { saved.teamsFetchedAt = Date() }
        saved.games = Array(byID.values)
        saved.fetchedAt = Date()
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        publish()
    }

    // MARK: Requests

    /// One request at a time, spaced to stay well inside the free limit.
    private func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: Self.base + path) else { return nil }
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return nil }
        return object
    }

    private func fetchTeams(_ league: League) async -> [SportsTeam]? {
        guard let object = await get("lookup_all_teams.php?id=\(league.id)"),
              let list = object["teams"] as? [[String: Any]] else { return nil }
        let teams = list.compactMap { item -> SportsTeam? in
            guard let id = SportsParse.text(item["idTeam"]), let name = SportsParse.text(item["strTeam"]) else { return nil }
            let alternates = (SportsParse.text(item["strTeamAlternate"]) ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return SportsTeam(id: id, name: name, short: SportsParse.text(item["strTeamShort"]), alternates: alternates,
                              badge: SportsParse.text(item["strBadge"]) ?? SportsParse.text(item["strTeamBadge"]))
        }
        return teams.isEmpty ? nil : teams
    }

    private func fetchEvents(_ path: String, league: League) async -> [SportsGame]? {
        guard let object = await get(path) else { return nil }
        guard let list = object["events"] as? [[String: Any]] else { return [] }
        let teams = Dictionary((saved.teams[league.id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return list.compactMap { item -> SportsGame? in
            guard let id = SportsParse.text(item["idEvent"]),
                  let leagueName = SportsParse.text(item["strLeague"]),
                  league.expect.contains(where: { leagueName.lowercased().contains($0) }),
                  let homeName = SportsParse.text(item["strHomeTeam"]), let awayName = SportsParse.text(item["strAwayTeam"]),
                  let start = SportsParse.date(item) else { return nil }
            func team(_ idKey: String, _ name: String, _ badgeKey: String) -> SportsTeam {
                let teamID = SportsParse.text(item[idKey]) ?? name
                var value = teams[teamID] ?? SportsTeam(id: teamID, name: name)
                if value.badge == nil { value.badge = SportsParse.text(item[badgeKey]) }
                return value
            }
            let postponed = (SportsParse.text(item["strPostponed"]) ?? "").lowercased() == "yes"
                || (SportsParse.text(item["strStatus"]) ?? "").lowercased().contains("postponed")
            return SportsGame(
                id: id, league: league.group, leagueShort: league.short, leagueName: leagueName, isSoccer: league.soccer,
                round: SportsParse.text(item["intRound"]),
                home: team("idHomeTeam", homeName, "strHomeTeamBadge"),
                away: team("idAwayTeam", awayName, "strAwayTeamBadge"),
                start: start, status: SportsParse.text(item["strStatus"]),
                homeScore: SportsParse.text(item["intHomeScore"]).flatMap(Int.init),
                awayScore: SportsParse.text(item["intAwayScore"]).flatMap(Int.init),
                venue: SportsParse.text(item["strVenue"]),
                thumb: SportsParse.text(item["strThumb"]),
                postponed: postponed
            )
        }
    }
}

/// JSON helpers, outside the main actor so the parsing closures can use them.
private enum SportsParse {
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

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let plainFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Start time in UTC: strTimestamp, else dateEvent + strTime.
    static func date(_ item: [String: Any]) -> Date? {
        if let stamp = text(item["strTimestamp"]) {
            if let date = isoFormatter.date(from: stamp) { return date }
            if let date = plainFormatter.date(from: String(stamp.prefix(19))) { return date }
        }
        guard let day = text(item["dateEvent"]) else { return nil }
        let time = text(item["strTime"]).map { String($0.prefix(8)) } ?? "00:00:00"
        return plainFormatter.date(from: "\(day)T\(time.count == 5 ? time + ":00" : time)")
    }
}
