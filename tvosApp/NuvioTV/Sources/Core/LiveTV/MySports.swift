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

    /// Row groups of the picked leagues, in the order picked.
    var pickedGroups: [String] {
        var groups: [String] = []
        for id in prefs.leagues {
            guard let league = SportsData.leagues.first(where: { $0.short == id }), !groups.contains(league.group) else { continue }
            groups.append(league.group)
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
            for league in leagues where league.group == event.league || (league.soccer && event.league == "Soccer") {
                if !league.keywords.isEmpty {
                    guard league.keywords.contains(where: { text.contains($0) }) else { continue }
                } else if league.short == "NCAAM", text.contains("women") {
                    continue
                } else if league.soccer, league.group == "Soccer" {
                    continue
                }
                counts[league.short, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Reminders for favorite teams

    /// Adds a reminder for favorite teams' games starting in the next day
    /// (once per game, so removing one by hand sticks).
    func scheduleTeamReminders(_ events: [SportsEvent]) {
        guard prefs.reminders, !prefs.teams.isEmpty else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.remindedKey) ?? [])
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
            changed = true
        }
        if changed { UserDefaults.standard.set(Array(done.suffix(200)), forKey: Self.remindedKey) }
    }
}
