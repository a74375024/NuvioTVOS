import Foundation
import Combine

/// The leagues and teams the viewer follows. Live Events leads with their
/// teams, gives each picked league a row, and folds every other sport into
/// "More events". The game schedule is only looked up for picked leagues.
struct MySportsPrefs: Codable, Equatable {
    var configured = false
    /// League ids ("NFL", "EPL"…), in the order picked.
    var leagues: [String] = []
    /// "LEAGUE|teamID".
    var teams: [String] = []
    /// A reminder before each favorite team's game (off unless turned on).
    var reminders = false
    /// The setup has been offered once.
    var prompted = false
}

@MainActor
final class MySports: ObservableObject {
    static let shared = MySports()
    private static let key = "nuvio.tv.livetv.mySports"
    private static let remindedKey = "nuvio.tv.livetv.mySportsReminded"

    @Published private(set) var prefs: MySportsPrefs

    /// For code outside the main actor's views (schedule lookups).
    static var current: MySportsPrefs { shared.prefs }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let value = try? JSONDecoder().decode(MySportsPrefs.self, from: data) {
            prefs = value
        } else {
            prefs = MySportsPrefs()
        }
    }

    func update(_ change: (inout MySportsPrefs) -> Void) {
        var value = prefs
        change(&value)
        guard value != prefs else { return }
        let leaguesChanged = value.leagues != prefs.leagues || value.configured != prefs.configured
        prefs = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.key) }
        if leaguesChanged { SportsData.shared.leaguesChanged() }
        LiveTVStore.shared.scheduleSportsRebuild(delay: 0.3, reason: "my sports")
        LiveEventsModel.shared.refresh()
    }

    func markPrompted() { update { $0.prompted = true } }

    // MARK: Lookups

    static func teamKey(league: String, teamID: String) -> String { "\(league)|\(teamID)" }

    func isFavorite(_ game: SportsGame) -> Bool {
        guard !prefs.teams.isEmpty else { return false }
        return prefs.teams.contains(Self.teamKey(league: game.leagueShort, teamID: game.home.id))
            || prefs.teams.contains(Self.teamKey(league: game.leagueShort, teamID: game.away.id))
    }

    /// A sport with no schedule behind it: picking it gives it a row of its
    /// own, built from your channels. No requests.
    struct OtherSport {
        let id: String       // "S:Golf"
        let group: String    // the row ("Golf")
        let name: String
    }

    static let otherSports: [OtherSport] = [
        OtherSport(id: "S:Fighting", group: "Fighting", name: L10n.string("my_sports_fighting", fallback: "UFC, boxing & wrestling")),
        OtherSport(id: "S:Motorsport", group: "Motorsport", name: L10n.string("my_sports_motorsport", fallback: "Racing")),
        OtherSport(id: "S:Tennis", group: "Tennis", name: L10n.string("my_sports_tennis", fallback: "Tennis")),
        OtherSport(id: "S:Golf", group: "Golf", name: L10n.string("my_sports_golf", fallback: "Golf")),
        OtherSport(id: "S:Rugby", group: "Rugby", name: L10n.string("my_sports_rugby", fallback: "Rugby")),
        OtherSport(id: "S:Cricket", group: "Cricket", name: L10n.string("my_sports_cricket", fallback: "Cricket")),
        OtherSport(id: "S:Darts", group: "Darts", name: L10n.string("my_sports_darts", fallback: "Darts")),
    ]

    /// Display name of a picked id (league or other sport).
    static func name(of id: String) -> String? {
        SportsData.leagues.first(where: { $0.short == id })?.name ?? otherSports.first(where: { $0.id == id })?.name
    }

    /// Row groups of the picked leagues and sports, in the order picked.
    var pickedGroups: [String] {
        var groups: [String] = []
        for id in prefs.leagues {
            let group = SportsData.leagues.first(where: { $0.short == id })?.group
                ?? Self.otherSports.first(where: { $0.id == id })?.group
            guard let group, !groups.contains(group) else { continue }
            groups.append(group)
        }
        return groups
    }

    /// How many of the provider's events look like each league (for the
    /// "in your channels" suggestions).
    static func suggestionCounts(_ events: [LiveEvent]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let leagues = SportsData.leagues
        for event in events {
            let text = (event.title + " " + event.family).lowercased()
            let family = SportsMatcher.sportFamilies[event.league] ?? []
            for league in leagues where league.group == event.league || family.contains(league.group) || (league.soccer && event.league == "Soccer") {
                if !league.keywords.isEmpty {
                    guard league.keywords.contains(where: { text.contains($0) }) else { continue }
                } else if league.short == "NCAAM", text.contains("women") {
                    continue
                } else if league.soccer, league.group == "Soccer" {
                    continue
                }
                counts[league.short, default: 0] += 1
            }
            for sport in otherSports where sport.group == event.league { counts[sport.id, default: 0] += 1 }
        }
        return counts
    }

    // MARK: Reminders for favorite teams

    /// Adds a reminder for favorite teams' games starting in the next day
    /// (once per game, so removing one by hand sticks).
    func scheduleTeamReminders(_ events: [SportsEvent]) {
        guard prefs.reminders, !prefs.teams.isEmpty else { return }
        var order = UserDefaults.standard.stringArray(forKey: Self.remindedKey) ?? []
        var done = Set(order)
        let now = Date()
        var changed = false
        for event in events {
            guard let game = event.game, isFavorite(game), let start = event.start,
                  start > now, start < now.addingTimeInterval(24 * 3600), !done.contains(event.id),
                  let target = LiveTVStore.shared.reminderTarget(for: event) else { continue }
            if !LiveReminders.shared.isSet(channelID: target.channel.id, start: target.program.start) {
                LiveReminders.shared.toggle(channel: target.channel, program: target.program)
            }
            done.insert(event.id)
            order.append(event.id)
            changed = true
        }
        // Oldest first, so trimming drops the oldest.
        if changed { UserDefaults.standard.set(Array(order.suffix(200)), forKey: Self.remindedKey) }
    }
}
