import SwiftUI
import Combine

// MARK: - Names and badges

enum SportsNames {
    private static let twoWord: Set<String> = [
        "red sox", "white sox", "blue jays", "maple leafs", "red wings", "golden knights", "blue jackets",
        "trail blazers", "black hawks", "st louis", "golden state"
    ]

    /// "Rams" for "Los Angeles Rams", "Utah", "Man City".
    static func short(_ team: SportsTeam, soccer: Bool) -> String {
        // A doubles pair: "Bucsa / Melichar-Martinez" as is.
        if team.name.contains(" / ") { return team.name }
        if let first = team.alternates.first, first.count <= 16 { return first }
        if soccer { return team.name }
        let words = team.name.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return team.name }
        let lastTwo = words.suffix(2).joined(separator: " ")
        if twoWord.contains(lastTwo.lowercased()) { return lastTwo }
        return words.last ?? team.name
    }

    static func title(_ game: SportsGame) -> String {
        // A fight card part: "UFC 333 Prelims".
        if let custom = game.customTitle { return custom }
        let away = short(game.away, soccer: game.isSoccer), home = short(game.home, soccer: game.isSoccer)
        return game.isSoccer ? "\(home) vs \(away)" : "\(away) at \(home)"
    }

    static func symbol(_ league: String) -> String {
        switch league {
        case "NFL", "College Football": return "football.fill"
        case "NBA", "WNBA", "College Basketball": return "basketball.fill"
        case "MLB": return "baseball.fill"
        case "NHL", "Hockey": return "hockey.puck.fill"
        case "Field Hockey": return "figure.field.hockey"
        case "Volleyball": return "volleyball.fill"
        case "Baseball", "Softball", "MiLB": return "baseball.fill"
        case "Lacrosse": return "figure.lacrosse"
        case "Soccer", "MLS": return "soccerball"
        case "Fighting": return "figure.boxing"
        case "Motorsport": return "flag.checkered"
        case "Golf": return "figure.golf"
        case "Tennis": return "tennisball.fill"
        default: return "sportscourt.fill"
        }
    }
}

/// A team's logo, or its initials when there's none.
struct TeamBadge: View {
    let team: SportsTeam
    let size: CGFloat
    var focused = false

    var body: some View {
        ChannelLogoView(urls: team.badge.flatMap(URL.init(string:)).map { [$0] } ?? [], width: size, height: size, focused: focused) {
            ZStack {
                Circle().fill(Color.white.opacity(focused ? 0.15 : 0.12))
                Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
                Text(team.abbreviation)
                    .font(.system(size: size * 0.3, weight: .heavy))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(6)
            }
            .frame(width: size, height: size)
        }
    }
}

private func chipLabel(_ text: String, fill: Color, foreground: Color = .white, outlined: Bool = false) -> some View {
    Text(text)
        .font(.system(size: 15, weight: .heavy))
        .tracking(0.4)
        .foregroundColor(foreground)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(outlined ? 0.7 : 0), lineWidth: 2))
}

private let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
}()

private func leagueLine(_ event: SportsEvent) -> String {
    var parts: [String] = [event.leagueShort]
    if let week = event.game?.weekLabel { parts.append(week) }
    return parts.joined(separator: "  ·  ")
}

/// "On NBA League Pass · not in your channels".
private func notInChannels(_ event: SportsEvent) -> String {
    if let network = event.game?.networks.first {
        return L10n.format("live_event_on_not_yours", fallback: "On %@ · not in your channels", network)
    }
    return L10n.string("live_event_not_in_channels", fallback: "Not in your channels")
}

private let shortWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
}()

private let longWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return formatter
}()

private func dayTime(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return clock.string(from: date) }
    if calendar.isDateInTomorrow(date) { return L10n.string("live_time_tomorrow", fallback: "Tomorrow") + " " + clock.string(from: date) }
    return shortWeekday.string(from: date) + " " + clock.string(from: date)
}

/// "1:35" (or "13:35"): a time next to words that already say when.
private let shortClock: DateFormatter = {
    let formatter = DateFormatter()
    let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
    formatter.dateFormat = twelveHour ? "h:mm" : "H:mm"
    return formatter
}()

/// One part of a fight card on its tile's timeline.
struct CardPart: Equatable {
    let label: String
    let start: Date
    /// How far into this part we are (0 before it starts, 1 once the next began).
    let fill: Double
    let current: Bool
    /// Show its start time under it (race sessions: only the current one).
    var timed = true
}

/// Where a tile's game is on and what the tile says, worked out once per
/// update (not per draw).
struct EventWhere: Equatable {
    var channelName: String?
    var channelDisplay: String?
    var logoURLs: [URL] = []
    var inLineup = false
    var feeds = 0
    /// One of your teams plays.
    var favorite = false
    /// "World Series · Game 1", "Sunday Night", "League Phase".
    var tag: String?
    /// The tag is an alert ("RED ZONE"): shown in red.
    var tagAlert = false
    /// The footer pill when no channel has it: the event channel family,
    /// "Event feed", or the network (outlined) for games you don't have.
    var pill: String?
    var pillOutlined = false
    /// "Your local station", "Also in Spanish", "3 feeds", "Streaming only"…
    var footer = ""
    /// The tile's two sides, in reading order, and which one is at home.
    var top: SportsTeam?
    var bottom: SportsTeam?
    var homeIsTop: Bool?
    /// A tile without sides: its title and subtitle.
    var title = ""
    var subtitle: String?
    /// A fight card: its parts in order, and the one on now (or next).
    var parts: [CardPart] = []
    var partLabel: String?
    /// The card's sides are the fight on now, not the headline bout.
    var boutNow = false

    // From the live scoreboard:
    /// "Q3 4:12", "Halftime", "Bot 8th", "67'", "Final/OT", "Rain Delay".
    var clock: String?
    /// Past its start time but not underway yet.
    var notStarted = false
    /// When a finished game ended (shown for a while as Final).
    var endedAt: Date?
    /// Scores for the top and bottom lines (only with scores on).
    var topScore: String?
    var bottomScore: String?
    /// Which line has the ball (football), with scores on.
    var possessionTop: Bool?
    /// "3rd & 7 at MICH 35", "2 outs · 3-1 count" (scores on).
    var situation: String?
    var redZone = false
    var bases: [Bool]?
    var lastPlay: String?
    /// Progress from the game clock, when known (0…1).
    var liveProgress: Double?
    /// A studio show (pregame, countdown): no live status of its own.
    var studio = false
    /// Tennis: games per set for the top and bottom lines (scores on), and
    /// player photos on the sides.
    var topSets: [String] = []
    var bottomSets: [String] = []
    var photos = false
    /// A race weekend: the latest finished session's top 3 (scores on), and its name.
    var podium: [RaceDriver] = []
    var podiumLabel: String?
}

// MARK: - Model

/// Live Events' rows, built when their inputs change and every 30 seconds,
/// never while drawing. If the tile you're on would disappear in an update,
/// the update waits until you move or 5 seconds pass.
@MainActor
final class LiveEventsModel: ObservableObject {
    static let shared = LiveEventsModel()

    struct Row: Identifiable {
        let id: String
        let title: String
        let events: [SportsEvent]
        var families: [EventFamily] = []
        let live: Int
        /// Event id → the group label shown above it ("Live", "Earlier",
        /// "Starting Soon", "Later Today", "Tomorrow", "Saturday"…), on the
        /// first tile of each group.
        var headers: [String: String] = [:]
        /// More than one league in the row: tiles name theirs.
        var mixed = false
        var count: Int { events.count + families.count }
        var grouped: Bool { !headers.isEmpty }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var hero: SportsEvent?
    @Published private(set) var now = Date()
    private(set) var places: [String: EventWhere] = [:]
    /// A fight card's tile id → its parts (early prelims, prelims, main), in order.
    private(set) var cards: [String: [SportsEvent]] = [:]

    private struct Built {
        let rows: [Row]
        let hero: SportsEvent?
        let places: [String: EventWhere]
        let cards: [String: [SportsEvent]]
        let studio: Set<String>
    }
    private var pending: Built?
    /// Tiles that are studio shows (kept out of Live now and the flip list).
    private(set) var studioIDs = Set<String>()
    /// Event id → studio show or not (titles don't change, so worked out once).
    private var studioCache: [String: Bool] = [:]
    /// The focused tile's key: row id + "|" + event id.
    private var focusedKey: String?
    private var lastInput = Date()
    private var sinks: [AnyCancellable] = []
    private var ticker: AnyCancellable?
    private var scheduled = false
    private var builds = 0
    private var buildMS = 0

    private static let sportOrder = ["NFL", "College Football", "NBA", "WNBA", "College Basketball", "MLB", "NHL",
                                     "MLS", "Soccer", "Fighting", "Motorsport", "Golf", "Tennis"]

    /// Services that are an app, not a channel.
    private static let streamingServices = ["espn+", "disney+", "peacock", "paramount+", "prime video", "amazon", "netflix",
                                            "apple tv", "apple tv+", "max", "dazn", "fubo", "youtube", "nfl+", "fox one",
                                            "mls season pass", "nba league pass", "nhl power play", "mlb.tv", "victory+",
                                            "flosports", "espn app", "hulu"]

    func start() {
        guard ticker == nil else { return }
        CrashRecorder.liveEventsOpen = true
        let store = LiveTVStore.shared
        now = Date()
        sinks = [
            store.$sportsEvents.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$events.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$families.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$logosRevision.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            LiveScores.shared.$revision.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            RaceData.shared.$revision.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            PlayerPhotos.shared.$revision.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() }
        ]
        LiveScores.shared.start()
        ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }
            self.now = date
            LiveTVStore.shared.sportsTick()
            self.recompute()
            if self.builds > 0 {
                CrashRecorder.note("events board: \(self.builds) row builds, \(self.buildMS) ms in 30 s")
                self.builds = 0
                self.buildMS = 0
            }
        }
        recompute()
    }

    func stop() {
        CrashRecorder.liveEventsOpen = false
        LiveScores.shared.stop()
        sinks = []
        ticker = nil
        pending = nil
    }

    func place(for event: SportsEvent?) -> EventWhere {
        event.flatMap { places[$0.id] } ?? EventWhere()
    }

    /// For a fight card tile: the part on now, else the first one.
    func cardCurrent(_ event: SportsEvent, at date: Date = Date()) -> SportsEvent? {
        guard let parts = cards[event.id] else { return nil }
        return Self.currentPart(parts, now: date, statuses: LiveScores.shared.statuses)
    }

    /// The part on now by its fights' status; without it, by start times.
    private static func currentPart(_ parts: [SportsEvent], now: Date, statuses: [String: LiveStatus]) -> SportsEvent? {
        guard let first = parts.first else { return nil }
        if first.game?.racing == true { return raceCurrent(parts, now: now, statuses: statuses) }
        let phases = parts.map { part in part.game.flatMap { statuses[$0.id]?.phase } }
        if phases.contains(where: { $0 != nil }) {
            if let index = phases.firstIndex(where: { $0 == .live || $0 == .delayed }) { return parts[index] }
            // Between parts: the first one not finished yet.
            if let index = phases.firstIndex(where: { $0 != .final && $0 != .postponed }) {
                if index > 0 || (parts[index].start ?? .distantFuture) <= now { return parts[index] }
                return first
            }
            return parts.last
        }
        return parts.last { ($0.start ?? .distantFuture) <= now } ?? first
    }

    /// A race weekend: the session on now, else the next one not over (by
    /// its status, else its usual length), else the last.
    private static func raceCurrent(_ parts: [SportsEvent], now: Date, statuses: [String: LiveStatus]) -> SportsEvent? {
        func phase(_ part: SportsEvent) -> LivePhase? { part.game.flatMap { statuses[$0.id]?.phase } }
        // Past its usual end (plus half an hour): a status nobody refreshed
        // while it ran (not polled while watching) doesn't hold it.
        func over(_ part: SportsEvent) -> Bool {
            guard let start = part.start else { return false }
            return now > start.addingTimeInterval(part.expectedLength + 30 * 60)
        }
        func stale(_ part: SportsEvent) -> Bool {
            guard let start = part.start else { return false }
            return now > start.addingTimeInterval(12 * 3600)
        }
        if let live = parts.first(where: { ($0.live == .live || phase($0) == .live || phase($0) == .delayed) && !stale($0) }) {
            return live
        }
        for part in parts {
            let value = phase(part)
            if value == .final || value == .postponed || part.game?.completed == true { continue }
            if (value == nil || value == .pre) && over(part) { continue }
            if (value == .live || value == .delayed) && stale(part) { continue }
            return part
        }
        return parts.last
    }

    /// A race weekend's tile: the session on now (or next) decides its time,
    /// status and where to watch; the weekend is over once its last one is.
    private static func raceWeekendTile(id: String, parts: [SportsEvent], current: SportsEvent) -> SportsEvent {
        var tile = SportsEvent(id: id, title: current.game?.home.name ?? current.title, league: current.league,
                               leagueShort: current.leagueShort, start: current.start, game: current.game,
                               sources: current.sources, family: current.family)
        tile.listingEnd = current.listingEnd
        tile.feedsEndedAt = current.feedsEndedAt
        tile.moreStations = current.moreStations
        tile.teams = current.teams
        switch current.live {
        case .live?, .delayed?: tile.live = .live
        case .final?: tile.live = current.id == parts.last?.id ? .final : .pre
        case .postponed?: tile.live = .postponed
        case .pre?: tile.live = .pre
        case nil: break
        }
        return tile
    }

    /// From the board: which tile is focused (its key; nil when none).
    func focusChanged(to key: String?) {
        lastInput = Date()
        let old = focusedKey
        focusedKey = key
        if pending != nil, key != old { applyPending() }
    }

    /// The latest version of a game shown (a focused copy can be older).
    func current(_ event: SportsEvent?) -> SportsEvent? {
        guard let event else { return nil }
        for row in rows { if let match = row.events.first(where: { $0.id == event.id }) { return match } }
        return event
    }

    /// Settings changed (e.g. games not in my channels).
    func refresh() { scheduleRecompute() }

    // MARK: In-player event guide

    /// Rebuilds now (the in-player guide, when Live Events isn't ticking).
    func refreshNow() {
        now = Date()
        recompute()
    }

    /// A tile is the game on screen: the same event, or a fight card whose
    /// part is playing.
    func matches(_ event: SportsEvent, eventID: String) -> Bool {
        event.id == eventID || cards[event.id]?.contains { $0.id == eventID } == true
    }

    /// Rows the in-player guide offers (not event channels or untimed feeds).
    var guideRows: [Row] {
        rows.filter { $0.id != "families" && $0.id != "untimed" && !$0.events.isEmpty }
    }

    /// The row the guide opens on: the game's sport, else any row with it.
    func guideRowID(for eventID: String?) -> String? {
        let candidates = guideRows
        if let eventID {
            if let row = candidates.first(where: { $0.id.hasPrefix("sport|") && $0.events.contains { matches($0, eventID: eventID) } }) {
                return row.id
            }
            if let row = candidates.first(where: { $0.events.contains { matches($0, eventID: eventID) } }) { return row.id }
        }
        return candidates.first?.id
    }

    /// The games of a row you can switch to (in a channel or feed you have).
    func guideEvents(rowID: String) -> [SportsEvent] {
        guideRows.first { $0.id == rowID }?.events.filter { !$0.sources.isEmpty } ?? []
    }

    /// Up / Down while watching: the live games of the game's sport, in row
    /// order (the game on screen is kept even if it just ended).
    func flipEvents(around eventID: String) -> [SportsEvent] {
        guard let rowID = guideRowID(for: eventID) else { return [] }
        let date = Date()
        return guideEvents(rowID: rowID).filter { event in
            matches(event, eventID: eventID)
                || (!studioIDs.contains(event.id) && (event.state(at: date) == .live || event.state(at: date) == .mayHaveEnded))
        }
    }

    private func scheduleRecompute() {
        guard !scheduled else { return }
        scheduled = true
        // @Published sends before the value changes: read it next turn.
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.recompute()
        }
    }

    /// A card's parts become one tile: its id "card|UFC|<event>", starting
    /// with the first part, the headline bout's sides, and every part's
    /// sources (the part on now first). Cards that aren't split stay as is.
    private static func mergingCards(_ events: [SportsEvent], now: Date,
                                     statuses: [String: LiveStatus]) -> (events: [SportsEvent], cards: [String: [SportsEvent]]) {
        var groups: [String: [Int]] = [:]
        for (index, event) in events.enumerated() {
            guard let game = event.game, let key = game.cardKey, !key.hasSuffix("|"),
                  let cut = game.id.lastIndex(of: "|") else { continue }
            groups[String(game.id[..<cut]), default: []].append(index)
        }
        guard groups.values.contains(where: { $0.count >= 2 }) else { return (events, [:]) }
        var cards: [String: [SportsEvent]] = [:]
        var replaced: [Int: SportsEvent] = [:]
        var dropped = Set<Int>()
        for (card, indices) in groups where indices.count >= 2 {
            let parts = indices.map { events[$0] }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            guard let first = parts.first, let main = parts.last, let start = first.start, var game = main.game,
                  let current = currentPart(parts, now: now, statuses: statuses) else { continue }
            if game.racing == true {
                let id = "card|" + card
                cards[id] = parts
                let sortedIndices = indices.sorted()
                replaced[sortedIndices[0]] = raceWeekendTile(id: id, parts: parts, current: current)
                dropped.formUnion(sortedIndices.dropFirst())
                continue
            }
            var seen = Set<String>()
            var sources: [EventSource] = []
            for source in current.sources + parts.flatMap(\.sources) where seen.insert(source.channelID).inserted {
                sources.append(source)
            }
            if let key = game.cardKey, let cut = key.lastIndex(of: "|") { game.cardKey = String(key[..<cut]) + "|card" }
            let id = "card|" + card
            var merged = SportsEvent(id: id, title: main.title, league: main.league, leagueShort: main.leagueShort, start: start,
                                     game: game, sources: sources, family: current.family)
            // Live until the main card's usual end.
            if let mainStart = main.start {
                var end = mainStart.addingTimeInterval(main.expectedLength)
                if let listing = main.listingEnd, listing > end { end = listing }
                merged.listingEnd = end
            }
            merged.feedsEndedAt = main.feedsEndedAt
            // The card's phase from its parts' fights.
            let phases = parts.compactMap { $0.live }
            if !phases.isEmpty {
                if phases.contains(where: { $0 == .live || $0 == .delayed }) {
                    merged.live = .live
                } else if phases.count == parts.count, phases.allSatisfy({ $0 == .final || $0 == .postponed }) {
                    merged.live = phases.contains(.final) ? .final : .postponed
                } else if phases.contains(.final) {
                    merged.live = .live   // between parts
                } else {
                    merged.live = .pre
                }
            }
            cards[id] = parts
            let sortedIndices = indices.sorted()
            replaced[sortedIndices[0]] = merged
            dropped.formUnion(sortedIndices.dropFirst())
        }
        var result: [SportsEvent] = []
        result.reserveCapacity(events.count)
        for (index, event) in events.enumerated() where !dropped.contains(index) {
            result.append(replaced[index] ?? event)
        }
        return (result, cards)
    }

    struct WhipInfo {
        let live: Int
        let redZone: [String]
        let subtitle: String
    }

    /// A provider feed that's one driver's camera (it lives in its race's cameras panel).
    private static func isCameraFeed(_ event: SportsEvent) -> Bool {
        // F1 and NASCAR cameras, in-car feeds by car ("No. 5 Kyle Larson") and race multiviews.
        event.game == nil && SpecialFeeds.isCameraName(event.title)
    }

    /// An empty slot's name: "No Match Scheduled", "No Event Scheduled".
    private static func isPlaceholder(_ event: SportsEvent) -> Bool {
        guard event.game == nil else { return false }
        let lower = event.title.lowercased()
        return lower.hasSuffix("no match scheduled") || lower.hasSuffix("no event scheduled") || lower.hasSuffix("no events scheduled")
            || lower.hasSuffix("no game scheduled") || lower.hasSuffix("no games scheduled")
    }

    /// Camera feeds that move to their race's cameras panel. An in-car feed
    /// or multiview only goes when a tile for its race is on the board (its
    /// name in another tile's title); otherwise it stays a tile of its own.
    private static func hiddenCameras(_ events: [SportsEvent]) -> Set<String> {
        var hidden = Set<String>()
        var byRace: [String: [String]] = [:]
        for event in events where isCameraFeed(event) {
            if let race = SpecialFeeds.cameraRace(event.title) {
                byRace[race, default: []].append(event.id)
            } else {
                hidden.insert(event.id)
            }
        }
        guard !byRace.isEmpty else { return hidden }
        var found = Set<String>()
        for event in events where !isCameraFeed(event) {
            let title = event.title.lowercased()
            for race in byRace.keys where !found.contains(race) && title.contains(race) { found.insert(race) }
            if found.count == byRace.count { break }
        }
        for race in found { hidden.formUnion(byRace[race] ?? []) }
        return hidden
    }

    private static let eastern: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    /// Whip-around tiles (NFL RedZone, MLB Strike Zone, soccer conference
    /// feeds) for sports with enough games live; first in their row.
    private func addWhipArounds(to all: inout [SportsEvent], states: inout [String: SportsEvent.State],
                                statuses: [String: LiveStatus], store: LiveTVStore, now: Date) -> [String: WhipInfo] {
        let channels = store.whipChannels()
        guard !channels.isEmpty else { return [:] }
        var info: [String: WhipInfo] = [:]
        let groups = Dictionary(grouping: channels, by: { $0.whip.group })
        for (group, members) in groups {
            guard let whip = members.first?.whip else { continue }
            if whip.sundayAfternoon {
                let weekday = Self.eastern.component(.weekday, from: now)
                let hour = Self.eastern.component(.hour, from: now)
                // RedZone airs from the 1 PM ET kickoffs to the end of the late window.
                guard weekday == 1, (13..<20).contains(hour) else { continue }
            }
            let liveGames = all.filter { event in
                event.game != nil && states[event.id] == .live
                    && (event.league == group || (group == "Soccer" && event.league == "MLS"))
            }
            guard liveGames.count >= whip.minimumLive else { continue }
            let id = "whip|" + group
            let sources = members.map { member in
                EventSource(channelID: member.channel.id, kind: member.inLineup ? .lineup : .guide, spanish: false,
                            detail: member.inLineup ? L10n.string("live_event_in_lineup", fallback: "In your lineup")
                                                    : L10n.string("live_event_in_guide_short", fallback: "In your guide"))
            }
            let title = group == "Soccer" ? (members.first?.channel.displayName ?? whip.title) : whip.title
            var tile = SportsEvent(id: id, title: title, league: group, leagueShort: whip.short,
                                   start: liveGames.compactMap(\.start).min() ?? now, game: nil, sources: sources, family: nil)
            tile.live = .live
            all.insert(tile, at: 0)
            states[id] = .live
            // Games in the red zone now (the team with the ball).
            var redZone: [String] = []
            for event in liveGames {
                guard let game = event.game, let status = statuses[game.id], status.phase == .live, status.redZone else { continue }
                let team = status.possession == game.home.id ? game.home : (status.possession == game.away.id ? game.away : nil)
                redZone.append(team.map { SportsNames.short($0, soccer: false) } ?? SportsNames.title(game))
            }
            info[id] = WhipInfo(live: liveGames.count, redZone: redZone, subtitle: whip.subtitle)
        }
        return info
    }

    private struct Bucket {
        let order: Int
        let label: String
    }

    private func recompute() {
        let started = Date()
        let store = LiveTVStore.shared
        let now = self.now
        // Driver-cam feeds belong to their race (its cameras panel), not the rows.
        let source = store.sportsEvents.isEmpty ? store.plainSportsEvents : store.sportsEvents
        let cameras = Self.hiddenCameras(source)
        // Placeholder slots ("No Match Scheduled") aren't events.
        let raw = source.filter { !cameras.contains($0.id) && !Self.isPlaceholder($0) }
        // Where each game stands, from the live scoreboard.
        let scores = LiveScores.shared
        let statuses = scores.statuses
        let withLive: [SportsEvent] = statuses.isEmpty ? raw : raw.map { event in
            guard let id = event.game?.id, let status = statuses[id] else { return event }
            var copy = event
            copy.live = status.phase
            return copy
        }
        let merged = Self.mergingCards(withLive, now: now, statuses: statuses)
        var all = merged.events
        let newCards = merged.cards
        var states: [String: SportsEvent.State] = [:]
        states.reserveCapacity(all.count)
        for event in all { states[event.id] = event.state(at: now) }
        let whipInfo = addWhipArounds(to: &all, states: &states, statuses: statuses, store: store, now: now)
        // Studio shows (pregame, countdown, weigh-ins) aren't games: never
        // Live now, at the end of their sport's row.
        if studioCache.count > 4000 { studioCache.removeAll() }
        var studio = Set<String>()
        for event in all where event.game == nil && !event.id.hasPrefix("whip|") {
            let value: Bool
            if let cached = studioCache[event.id] {
                value = cached
            } else {
                value = SportsMatcher.isStudioShow(event.title)
                studioCache[event.id] = value
            }
            if value { studio.insert(event.id) }
        }
        // Live now is only what's surely on; "likely over" stays in its sport's row.
        func isLive(_ event: SportsEvent) -> Bool { states[event.id] == .live && !studio.contains(event.id) }
        var result: [Row] = []
        let horizon = now.addingTimeInterval(8 * 24 * 3600)
        let showUnwatchable = SportsData.showsUnwatchable
        // A game the scoreboard says is over stays as Final for 30 minutes.
        func endedAt(_ event: SportsEvent) -> Date? {
            guard event.live == .final, let id = event.game?.id else { return nil }
            return scores.finalSeen[id]
        }
        func recentFinal(_ event: SportsEvent) -> Bool {
            guard let ended = endedAt(event) else { return false }
            return now.timeIntervalSince(ended) < 30 * 60
        }
        func shown(_ event: SportsEvent) -> Bool {
            let state = states[event.id]
            guard state == .live || state == .mayHaveEnded || state == .upcoming || state == .postponed || recentFinal(event),
                  let start = event.start, start < horizon else { return false }
            // Tennis lists every match on every court: only the ones you can watch.
            if event.game?.tennis == true { return !event.sources.isEmpty }
            return !event.sources.isEmpty || showUnwatchable
        }

        // Groups within a row: live, likely over, starting soon, later
        // today, then by day; postponed; then games not in your channels.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let labels = (
            live: L10n.string("live_events_group_live", fallback: "Live"),
            earlier: L10n.string("live_events_group_earlier", fallback: "Earlier"),
            whip: L10n.string("live_events_group_whip", fallback: "Whip-around"),
            final: L10n.string("live_events_group_final", fallback: "Final"),
            soon: L10n.string("live_events_group_soon", fallback: "Starting Soon"),
            today: L10n.string("live_events_group_today", fallback: "Later Today"),
            tomorrow: L10n.string("live_time_tomorrow", fallback: "Tomorrow"),
            postponed: L10n.string("live_events_group_postponed", fallback: "Postponed"),
            notYours: L10n.string("live_event_not_in_channels", fallback: "Not in your channels"),
            studio: L10n.string("live_events_group_studio", fallback: "Shows")
        )
        var dayLabels: [Int: String] = [:]
        func bucket(_ event: SportsEvent) -> Bucket {
            if event.id.hasPrefix("whip|") { return Bucket(order: -1, label: labels.whip) }
            if event.sources.isEmpty { return Bucket(order: 90, label: labels.notYours) }
            if studio.contains(event.id) { return Bucket(order: 70, label: labels.studio) }
            switch states[event.id] {
            case .live?: return Bucket(order: 0, label: labels.live)
            case .finished?: return Bucket(order: 1, label: labels.final)
            case .mayHaveEnded?: return Bucket(order: 2, label: labels.earlier)
            case .postponed?: return Bucket(order: 80, label: labels.postponed)
            default: break
            }
            guard let start = event.start else { return Bucket(order: 85, label: "") }
            if start.timeIntervalSince(now) <= 3600 { return Bucket(order: 3, label: labels.soon) }
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: start)).day ?? 0
            if days <= 0 { return Bucket(order: 4, label: labels.today) }
            if days == 1 { return Bucket(order: 5, label: labels.tomorrow) }
            if let label = dayLabels[days] { return Bucket(order: 5 + days, label: label) }
            let label = longWeekday.string(from: start)
            dayLabels[days] = label
            return Bucket(order: 5 + days, label: label)
        }
        func grouped(_ list: [SportsEvent]) -> (events: [SportsEvent], headers: [String: String]) {
            let keyed: [(event: SportsEvent, bucket: Bucket)] = list.map { (event: $0, bucket: bucket($0)) }
            let sorted = keyed.sorted { a, b in
                if a.bucket.order != b.bucket.order { return a.bucket.order < b.bucket.order }
                let x = a.event.start ?? .distantFuture, y = b.event.start ?? .distantFuture
                return x != y ? x < y : a.event.id < b.event.id
            }
            var headers: [String: String] = [:]
            var last = -1
            for item in sorted where item.bucket.order != last {
                last = item.bucket.order
                if !item.bucket.label.isEmpty { headers[item.event.id] = item.bucket.label }
            }
            return (sorted.map(\.event), headers)
        }
        func mixed(_ list: [SportsEvent]) -> Bool {
            guard let first = list.first?.leagueShort else { return false }
            return list.contains { $0.leagueShort != first }
        }
        let mySports = MySports.shared
        let picked = mySports.prefs.configured ? Set(mySports.pickedGroups) : nil

        // My Sports: your teams first.
        if picked != nil {
            let mine = all.filter { event in event.game.map { mySports.isFavorite($0) } == true && shown(event) }
            if !mine.isEmpty {
                let list = grouped(mine)
                result.append(Row(id: "teams", title: L10n.string("live_events_your_teams", fallback: "Your teams"),
                                  events: list.events, live: mine.filter { isLive($0) && !$0.sources.isEmpty }.count,
                                  headers: list.headers, mixed: true))
            }
        }
        let live = all.filter { isLive($0) && !$0.sources.isEmpty && (picked?.contains($0.league) ?? true) }
            .sorted { a, b in
                let wa = a.id.hasPrefix("whip|"), wb = b.id.hasPrefix("whip|")
                if wa != wb { return wa }
                return (a.start ?? .distantFuture, a.id) < (b.start ?? .distantFuture, b.id)
            }
        if !live.isEmpty {
            result.append(Row(id: "live", title: L10n.string("live_events_now", fallback: "Live now"), events: live,
                              live: live.count, mixed: mixed(live)))
        }
        var bySport: [String: [SportsEvent]] = [:]
        var more: [SportsEvent] = []
        for event in all where shown(event) {
            let group = event.league.isEmpty ? "Other" : event.league
            if let picked, !picked.contains(group) {
                // Other sports fold into "More events" (only what you can watch).
                if !event.sources.isEmpty { more.append(event) }
                continue
            }
            bySport[group, default: []].append(event)
        }
        let sports: [String]
        if picked != nil {
            sports = mySports.pickedGroups.filter { bySport[$0] != nil }
        } else {
            sports = bySport.keys.sorted { a, b in
                let ia = Self.sportOrder.firstIndex(of: a) ?? 99, ib = Self.sportOrder.firstIndex(of: b) ?? 99
                return ia != ib ? ia < ib : a < b
            }
        }
        for sport in sports {
            let source = bySport[sport] ?? []
            let list = grouped(source)
            let liveCount = source.filter { isLive($0) && !$0.sources.isEmpty }.count
            result.append(Row(id: "sport|\(sport)", title: sport, events: list.events, live: liveCount,
                              headers: list.headers, mixed: mixed(source)))
        }
        if !more.isEmpty {
            let list = grouped(more)
            result.append(Row(id: "more", title: L10n.string("live_events_more", fallback: "More events"), events: list.events,
                              live: more.filter(isLive).count, headers: list.headers, mixed: true))
        }
        let untimed = all.filter { states[$0.id] == .unknownTime && !$0.sources.isEmpty }
        if !untimed.isEmpty {
            result.append(Row(id: "untimed", title: L10n.string("live_events_unknown", fallback: "Time not listed"), events: untimed,
                              live: 0, mixed: true))
        }
        if !store.families.isEmpty {
            result.append(Row(id: "families", title: L10n.string("live_event_channels_title", fallback: "Event channels"),
                              events: [], families: store.families, live: 0))
        }
        // What each shown tile says.
        var familyNames: [String: String] = [:]
        for family in store.families where familyNames[family.id] == nil { familyNames[family.id] = family.name }
        var newPlaces: [String: EventWhere] = [:]
        for row in result {
            for event in row.events where newPlaces[event.id] == nil {
                var place = describe(event, parts: newCards[event.id], now: now, store: store,
                                     statuses: statuses, endedAt: endedAt(event), whip: whipInfo[event.id],
                                     familyNames: familyNames, mySports: mySports)
                if studio.contains(event.id) {
                    place.studio = true
                    place.tag = L10n.string("live_event_studio_tag", fallback: "STUDIO")
                }
                newPlaces[event.id] = place
            }
        }
        // Race weekends you can watch: their drivers and results (a few
        // requests a weekend; nothing for weekends not in your channels).
        for (id, parts) in newCards where parts.first?.game?.leagueShort == "F1"
            && newPlaces[id] != nil && all.contains(where: { $0.id == id && !$0.sources.isEmpty }) {
            RaceData.shared.refreshIfNeeded(sessions: parts.compactMap { part -> (kind: String, start: Date)? in
                guard let start = part.start, let key = part.game?.cardKey, let cut = key.lastIndex(of: "|") else { return nil }
                return (kind: String(key[key.index(after: cut)...]), start: start)
            }, results: LiveScores.showsScores)
        }
        // Tennis players on screen (singles, live or within a day): their photos.
        var players: [String] = []
        for row in result {
            for event in row.events {
                guard let game = event.game, game.tennis == true, !event.sources.isEmpty,
                      let start = event.start, start < now.addingTimeInterval(24 * 3600) else { continue }
                for team in [game.away, game.home] where !team.name.contains("/") { players.append(team.name) }
            }
        }
        if !players.isEmpty { PlayerPhotos.shared.request(players) }
        mySports.scheduleTeamReminders(raw)
        // The top of the screen shows a game, not a whip-around.
        let watchable = all.filter { !$0.sources.isEmpty && !$0.id.hasPrefix("whip|") && !studio.contains($0.id) }
        let newHero = watchable.first(where: isLive) ?? watchable.first { states[$0.id] == .upcoming }
        builds += 1
        buildMS += Int(Date().timeIntervalSince(started) * 1000)

        let built = Built(rows: result, hero: newHero, places: newPlaces, cards: newCards, studio: studio)
        // Keep the focused tile until you move (or 5 s pass).
        if let focusedKey, contains(rows, focusedKey), !contains(result, focusedKey), Date().timeIntervalSince(lastInput) < 5 {
            pending = built
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.pending != nil, Date().timeIntervalSince(self.lastInput) >= 5 else { return }
                self.applyPending()
            }
            return
        }
        pending = nil
        apply(built)
    }

    private func apply(_ built: Built) {
        places = built.places
        cards = built.cards
        studioIDs = built.studio
        rows = built.rows
        hero = built.hero
    }

    private func applyPending() {
        guard let pending else { return }
        self.pending = nil
        apply(pending)
    }

    private func contains(_ rows: [Row], _ key: String) -> Bool {
        rows.contains { row in
            key.hasPrefix(row.id + "|") && (row.events.contains { key == row.id + "|" + $0.id }
                                            || row.families.contains { key == row.id + "|" + $0.id })
        }
    }

    private static func isStreaming(_ network: String) -> Bool {
        let lowered = network.lowercased()
        return streamingServices.contains { lowered == $0 || lowered.hasPrefix($0 + " ") }
    }

    private static func partNames(_ part: SportsEvent) -> (short: String, long: String) {
        let key = part.game?.cardKey ?? ""
        if part.game?.racing == true, let cut = key.lastIndex(of: "|") {
            let kind = String(key[key.index(after: cut)...])
            return (RaceSession.short(kind), RaceSession.name(kind))
        }
        if key.hasSuffix("|early") {
            return (L10n.string("live_card_early_short", fallback: "Early"), L10n.string("live_card_early", fallback: "Early Prelims"))
        }
        if key.hasSuffix("|prelims") {
            let name = L10n.string("live_card_prelims", fallback: "Prelims")
            return (name, name)
        }
        return (L10n.string("live_card_main_short", fallback: "Main"), L10n.string("live_card_main", fallback: "Main Card"))
    }

    /// How far into the game the clock says it is (0…1), or nil.
    private static func clockProgress(_ status: LiveStatus, league: String, isSoccer: Bool) -> Double? {
        let detail = status.detail
        if detail == "Halftime" { return 0.5 }
        let pieces = detail.split(separator: " ")
        guard let head = pieces.first else { return nil }
        let digits = Int(head.filter(\.isNumber))
        if isSoccer {
            // "67'", "90'+3'".
            guard let minute = digits.map({ Double($0) }) else { return nil }
            return min(1, minute / 95)
        }
        if league == "MLB" || league == "Baseball" {
            // "Top 6th", "Mid 5th", "Bot 8th", "End 5th".
            guard pieces.count >= 2, let inning = Int(pieces[1].filter(\.isNumber)) else { return nil }
            let half: Double
            switch head.lowercased() {
            case "top": half = 0
            case "mid", "bot": half = 0.5
            default: half = 1
            }
            return min(1, max(0, (Double(inning - 1) + half + 0.25) / 9))
        }
        if head.hasSuffix("OT") || head == "SO" { return 1 }
        guard pieces.count >= 2 else { return nil }
        let clockParts = pieces[1].split(separator: ":")
        guard clockParts.count == 2, let minutes = Double(clockParts[0]), let seconds = Double(clockParts[1]) else { return nil }
        let remaining = minutes * 60 + seconds
        let count: Double
        let length: Double
        if head.hasPrefix("Q") {
            count = 4
            switch league {
            case "NFL", "College Football", "Football": length = 900
            case "NBA": length = 720
            default: length = 600
            }
        } else if league == "College Basketball" {
            count = 2
            length = 1200
        } else {
            count = 3
            length = 1200
        }
        let period = min(max(1, digits ?? 1), Int(count))
        return min(1, max(0, (Double(period - 1) + 1 - min(1, remaining / length)) / count))
    }

    /// The long name of a card part ("Early Prelims", "Prelims", "Main Card").
    static func partName(_ part: SportsEvent) -> String { partNames(part).long }

    /// "A vs B", "A vs. B", "A at B" in a title with no schedule game.
    private static func sides(in title: String) -> (String, String, homeSecond: Bool)? {
        let body = title.components(separatedBy: ": ").count > 1
            ? title.components(separatedBy: ": ").dropFirst().joined(separator: ": ") : title
        for (separator, homeSecond) in [(" vs. ", false), (" vs ", false), (" v ", false), (" at ", true), (" @ ", true)] {
            let pieces = body.components(separatedBy: separator)
            guard pieces.count == 2 else { continue }
            let a = pieces[0].trimmingCharacters(in: .whitespaces), b = pieces[1].trimmingCharacters(in: .whitespaces)
            guard a.count >= 2, b.count >= 2, a.count <= 40, b.count <= 40 else { continue }
            return (a, b, homeSecond)
        }
        return nil
    }

    private func describe(_ event: SportsEvent, parts: [SportsEvent]?, now: Date, store: LiveTVStore,
                          statuses: [String: LiveStatus], endedAt: Date?, whip: WhipInfo? = nil,
                          familyNames: [String: String], mySports: MySports) -> EventWhere {
        var place = EventWhere()
        let current = parts.flatMap { Self.currentPart($0, now: now, statuses: statuses) }
        let basis = current ?? event
        place.feeds = basis.feeds.count
        place.favorite = event.game.map { mySports.isFavorite($0) } ?? false
        place.tag = event.game?.note

        // Sides, or a title.
        if let game = event.game, game.racing == true {
            // A race weekend: the Grand Prix and its circuit.
            place.title = game.home.name
            place.subtitle = game.venue
        } else if let game = event.game {
            let first = game.isSoccer ? game.home : game.away
            let second = game.isSoccer ? game.away : game.home
            place.top = first
            place.bottom = second
            place.homeIsTop = game.cardKey == nil && game.tennis != true ? game.isSoccer : nil
            let full = game.customTitle ?? event.title
            place.title = full.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? full
        } else if let teams = event.teams, teams.count == 2 {
            place.top = teams[0]
            place.bottom = teams[1]
            place.title = event.title
        } else if let pair = Self.sides(in: event.title) {
            place.top = SportsTeam(id: "t|" + pair.0, name: pair.0)
            place.bottom = SportsTeam(id: "t|" + pair.1, name: pair.1)
            place.homeIsTop = pair.homeSecond ? false : nil
            place.title = event.title
        } else {
            let pieces = event.title.components(separatedBy: ": ")
            if pieces.count >= 2 {
                let head = pieces[0].trimmingCharacters(in: .whitespaces)
                let rest = pieces.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                // "F1: Mexico Grand Prix" → the race first; "ESPN KnockOut: …" → the show first.
                if head.count <= 12 {
                    place.title = rest
                    place.subtitle = head.prefix(1).uppercased() + head.dropFirst()
                } else {
                    place.title = head
                    place.subtitle = rest
                }
            } else {
                place.title = event.title
                if !event.league.isEmpty, event.league != event.title { place.subtitle = event.league }
            }
        }

        // A fight card's timeline: by its fights' status when known, else by time.
        if let parts, !parts.isEmpty {
            place.parts = parts.enumerated().map { index, part -> CardPart in
                let start = part.start ?? now
                if let status = part.game.flatMap({ statuses[$0.id] }) {
                    let fill: Double
                    switch status.phase {
                    case .final, .postponed: fill = 1
                    case .live, .delayed:
                        let total = max(1, status.boutsTotal ?? 1)
                        fill = max(0.05, Double(status.boutsDone ?? 0) / Double(total))
                    case .pre: fill = 0
                    }
                    return CardPart(label: Self.partNames(part).short, start: start, fill: fill, current: part.id == current?.id)
                }
                let next = index + 1 < parts.count ? (parts[index + 1].start ?? start) : start.addingTimeInterval(3 * 3600)
                let span = max(60, next.timeIntervalSince(start))
                return CardPart(label: Self.partNames(part).short, start: start,
                                fill: min(1, max(0, now.timeIntervalSince(start) / span)), current: part.id == current?.id)
            }
            if let current {
                place.partLabel = Self.partNames(current).long
                if let status = current.game.flatMap({ statuses[$0.id] }) {
                    if status.phase == .live || status.phase == .delayed, !status.detail.isEmpty {
                        place.partLabel = Self.partNames(current).long + " · " + status.detail
                    }
                    // The fight on now (or next), never a result.
                    if let a = status.boutA, let b = status.boutB, status.phase != .final {
                        place.top = SportsTeam(id: "b|" + a, name: a, country: status.boutACountry)
                        place.bottom = SportsTeam(id: "b|" + b, name: b, country: status.boutBCountry)
                        place.boutNow = status.phase == .live || status.phase == .delayed
                    }
                }
            }
        }

        // A race weekend: each session's own fill (they're days apart), the
        // time under the current one only, and the latest finished
        // session's top 3 with scores on.
        if let parts, parts.first?.game?.racing == true {
            place.parts = parts.map { part -> CardPart in
                let start = part.start ?? now
                let fill: Double
                switch part.game.flatMap({ statuses[$0.id]?.phase }) {
                case .final?, .postponed?: fill = 1
                case .live?, .delayed?: fill = max(0.05, min(0.95, now.timeIntervalSince(start) / part.expectedLength))
                case .pre?: fill = 0
                case nil: fill = part.game?.completed == true ? 1 : min(1, max(0, now.timeIntervalSince(start) / part.expectedLength))
                }
                let isCurrent = part.id == current?.id
                return CardPart(label: Self.partNames(part).short, start: start, fill: fill, current: isCurrent, timed: isCurrent)
            }
            place.top = nil
            place.bottom = nil
            if LiveScores.showsScores, parts.first?.game?.leagueShort == "F1" {
                for part in parts.reversed() {
                    guard let start = part.start, start < now, let key = part.game?.cardKey,
                          let cut = key.lastIndex(of: "|") else { continue }
                    let kind = String(key[key.index(after: cut)...])
                    if let top = RaceData.shared.top3(kind: kind, start: start) {
                        place.podium = top
                        place.podiumLabel = RaceSession.name(kind)
                        break
                    }
                }
            }
        }

        // The live scoreboard: clock, and with scores on, the score and situation.
        if parts == nil, let game = event.game, let status = statuses[game.id] {
            if !status.detail.isEmpty { place.clock = status.detail }
            if status.phase == .pre, let start = event.start, now > start { place.notStarted = true }
            if status.phase == .final { place.endedAt = endedAt }
            if status.phase == .live || status.phase == .delayed {
                place.liveProgress = Self.clockProgress(status, league: game.league, isSoccer: game.isSoccer)
            }
            if LiveScores.showsScores, status.phase == .live, status.redZone {
                place.tag = L10n.string("live_event_red_zone", fallback: "RED ZONE")
                place.tagAlert = true
            }
            if game.tennis == true {
                // Games per set; the match has no single score.
                if LiveScores.showsScores, status.phase != .pre {
                    place.topSets = status.awaySets ?? []
                    place.bottomSets = status.homeSets ?? []
                }
            } else if LiveScores.showsScores, status.phase != .pre {
                let topIsHome = game.isSoccer
                place.topScore = topIsHome ? status.homeScore : status.awayScore
                place.bottomScore = topIsHome ? status.awayScore : status.homeScore
                if let possession = status.possession {
                    if possession == (place.top?.id ?? "") { place.possessionTop = true }
                    else if possession == (place.bottom?.id ?? "") { place.possessionTop = false }
                }
                place.situation = status.situation
                place.redZone = status.redZone
                place.bases = status.bases
                place.lastPlay = status.lastPlay
            }
        } else if parts != nil, event.live == .final {
            place.clock = L10n.string("live_events_group_final", fallback: "Final")
            place.endedAt = endedAt
        }

        // Where to watch.
        let spanishToo = basis.sources.contains { $0.spanish } && basis.sources.contains { !$0.spanish }
        let streaming = event.game?.networks.first(where: Self.isStreaming)
        if let source = basis.channels.first, let channel = store.sourceChannel(source) {
            place.channelName = channel.name
            place.channelDisplay = channel.displayName
            place.logoURLs = store.logoSpec(for: channel).urls
            place.inLineup = source.kind == .lineup
            if source.rank == 0 || source.rank == 2 {
                place.footer = L10n.string("live_event_local_station", fallback: "Your local station")
            } else if place.inLineup {
                place.footer = L10n.string("live_event_in_lineup", fallback: "In your lineup")
            } else if spanishToo, !source.spanish {
                place.footer = L10n.string("live_event_spanish_too", fallback: "Also in Spanish")
            } else if place.feeds > 0 {
                place.footer = L10n.format("live_event_backup_feeds", fallback: "+ %d backup feeds", place.feeds)
            } else if let streaming {
                place.footer = L10n.format("live_event_streaming_too", fallback: "Also streaming on %@", streaming)
            }
        } else if place.feeds > 0 {
            if let family = basis.family, let name = familyNames[family], name.count <= 16 {
                place.pill = name
            } else {
                place.pill = L10n.string("live_event_feed", fallback: "Event feed")
            }
            if spanishToo {
                place.footer = L10n.string("live_event_spanish_too", fallback: "Also in Spanish")
            } else {
                place.footer = place.feeds == 1
                    ? L10n.string("live_event_one_feed", fallback: "1 feed")
                    : L10n.format("live_event_n_feeds", fallback: "%d feeds", place.feeds)
            }
        } else if let network = event.game?.networks.first {
            place.pill = network
            place.pillOutlined = true
            place.footer = Self.isStreaming(network)
                ? L10n.string("live_event_streaming_only", fallback: "Streaming only")
                : L10n.string("live_event_not_in_channels", fallback: "Not in your channels")
        } else {
            place.footer = L10n.string("live_event_not_in_channels", fallback: "Not in your channels")
        }
        // Tennis: the court where the feed's match is, and photos.
        if let game = event.game, game.tennis == true {
            if let court = game.venue { place.footer = court }
            place.photos = true
        }
        // A whip-around: what it's showing across the sport.
        if let whip {
            place.tag = L10n.string("live_event_whip_tag", fallback: "WHIP-AROUND")
            place.title = event.title
            if LiveScores.showsScores, !whip.redZone.isEmpty {
                place.subtitle = L10n.format("live_event_red_zone_now", fallback: "Red zone: %@", whip.redZone.joined(separator: ", "))
            } else {
                place.subtitle = whip.subtitle
            }
            place.footer = whip.live == 1
                ? L10n.string("live_event_one_game_live", fallback: "1 game live")
                : L10n.format("live_event_n_games_live", fallback: "%d games live", whip.live)
        }
        return place
    }
}

// MARK: - Tile

/// "00274C" → the team color; nil for anything else.
private func teamColor(_ hex: String?) -> Color? {
    guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

/// Whether white text reads on a team color ("FFCB05" → no).
private func isLight(_ hex: String?) -> Bool {
    guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return false }
    let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.62
}

/// A team's logo, or a circle in its colors with its abbreviation.
/// Live Events tile size (points on a 1920-wide TV screen).
enum LiveTileSize {
    static let width: CGFloat = 360
    static let height: CGFloat = 210
}

private struct SideBadge: View {
    let team: SportsTeam
    let focused: Bool

    var body: some View {
        if let url = team.badge.flatMap(URL.init(string:)) {
            ChannelLogoView(urls: [url], width: 32, height: 32, focused: focused) { colors }
        } else {
            colors
        }
    }

    private var colors: some View {
        let fill = teamColor(team.color) ?? Color(red: 0.23, green: 0.25, blue: 0.28)
        let ring = teamColor(team.altColor) ?? Color.white.opacity(0.3)
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(ring, lineWidth: 2.5)
            Text(team.abbreviation)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(isLight(team.color) ? .black : .white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(4)
        }
        .frame(width: 32, height: 32)
    }
}

/// A country code chip ("AUS") standing in for a fighter's flag.
private func countryChip(_ code: String, focused: Bool, size: CGFloat = 13) -> some View {
    Text(code)
        .font(.system(size: size, weight: .heavy))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder((focused ? Color.black : Color.white).opacity(0.6), lineWidth: 2))
}

/// A tennis player's photo in a circle (TheSportsDB's small size first, the
/// full one if that fails); initials until there is one.
private struct PlayerPhotoView: View {
    let name: String
    let focused: Bool
    @ObservedObject private var photos = PlayerPhotos.shared
    @State private var full = false

    var body: some View {
        let url = photos.photo(for: name)
        ZStack {
            Circle().fill((focused ? Color.black : Color.white).opacity(0.14))
            if name.contains("/") {
                // Doubles: no single face.
                Image(systemName: "person.2.fill").font(.system(size: 14)).opacity(0.6)
            } else if let url {
                AsyncImage(url: full ? url : url.appendingPathComponent("small")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        initials.onAppear { if !full { full = true } }
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
            .font(.system(size: 12, weight: .heavy))
            .opacity(0.7)
    }
}

/// Runners on first, second and third, as a small diamond.
private struct BasesView: View {
    let bases: [Bool]
    let ink: Color

    var body: some View {
        ZStack {
            base(on: bases.count > 1 && bases[1]).offset(x: 0, y: -5)
            base(on: bases.count > 2 && bases[2]).offset(x: -7.5, y: 2.5)
            base(on: !bases.isEmpty && bases[0]).offset(x: 7.5, y: 2.5)
        }
        .frame(width: 26, height: 20)
    }

    private func base(on: Bool) -> some View {
        Rectangle()
            .fill(on ? ink.opacity(0.9) : Color.clear)
            .overlay(Rectangle().strokeBorder(ink.opacity(0.8), lineWidth: 1.5))
            .frame(width: 7.5, height: 7.5)
            .rotationEffect(.degrees(45))
    }
}

struct LiveEventTile: View {
    let event: SportsEvent
    let place: EventWhere
    let focused: Bool
    let now: Date
    /// The row has more than one league: name it when there's no tag.
    var showLeague = false

    private var ink: Color { focused ? .black : .white }
    private var watchable: Bool { !event.sources.isEmpty }

    var body: some View {
        let state = event.state(at: now)
        VStack(alignment: .leading, spacing: 0) {
            statusRow(state)
                .frame(height: 28)
            Spacer(minLength: 3)
            middle
            Spacer(minLength: 3)
            footer
                .frame(height: 28)
        }
        .opacity(watchable || focused ? 1 : 0.6)
        .foregroundColor(ink)
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 15)
        .frame(width: LiveTileSize.width, height: LiveTileSize.height, alignment: .topLeading)
        .background(cardBackground(state))
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    /// The card, with the progress edge along the bottom while live.
    private func cardBackground(_ state: SportsEvent.State) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let fill: Color = focused ? .white : Color.white.opacity(watchable && state != .finished ? 0.09 : 0.06)
        return ZStack(alignment: .bottomLeading) {
            fill
            if state == .live, place.parts.isEmpty, !place.studio {
                Rectangle().fill((focused ? Color.black : Color.white).opacity(focused ? 0.12 : 0.15)).frame(height: 6)
                Rectangle().fill(focused ? Color.black : Color.white.opacity(0.75))
                    .frame(width: LiveTileSize.width * CGFloat(place.liveProgress ?? event.progress(at: now)), height: 6)
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 16 : 0, y: focused ? 8 : 0)
    }

    // MARK: Status row

    @ViewBuilder
    private func statusRow(_ state: SportsEvent.State) -> some View {
        HStack(spacing: 10) {
            statusPill(state)
            statusText(state)
            Spacer(minLength: 8)
            if place.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 19))
                    .foregroundColor(Color(red: 0.88, green: 0.63, blue: 0))
            }
            if let tag = place.tag {
                Text(tag)
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                    .foregroundColor(place.tagAlert || focused ? .white : .black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(place.tagAlert ? Color(red: 0.78, green: 0.16, blue: 0.16)
                                                                       : (focused ? Color(white: 0.1) : Color.white.opacity(0.9))))
                    .layoutPriority(-1)
            } else if showLeague {
                Text(event.leagueShort)
                    .font(.system(size: 18, weight: .bold))
                    .opacity(0.55)
                    .lineLimit(1)
            }
        }
    }

    private func pill(_ text: String, fill: Color, foreground: Color, outline: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .heavy))
            .tracking(0.5)
            .foregroundColor(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(outline ?? .clear, lineWidth: 2))
    }

    @ViewBuilder
    private func statusPill(_ state: SportsEvent.State) -> some View {
        let outline = ink.opacity(0.6)
        switch state {
        case .live:
            if place.studio {
                // A show, not a game: on now, without the live badge.
                pill(L10n.string("live_event_on_now", fallback: "ON NOW"), fill: .clear, foreground: ink, outline: outline)
            } else if event.live == .delayed {
                pill(L10n.string("live_event_delayed", fallback: "DELAYED"), fill: Color(red: 0.88, green: 0.63, blue: 0), foreground: .black)
            } else if watchable {
                pill(L10n.string("live_badge_live", fallback: "LIVE"), fill: LiveStyle.watching, foreground: .white)
            } else {
                pill(L10n.string("live_badge_live", fallback: "LIVE"), fill: .clear, foreground: focused ? LiveStyle.watching : Color(red: 0.96, green: 0.7, blue: 0.68),
                     outline: LiveStyle.watching.opacity(0.8))
            }
        case .mayHaveEnded:
            pill(L10n.string("live_event_likely_over", fallback: "Likely over"), fill: .clear, foreground: ink, outline: outline)
        case .postponed:
            pill(L10n.string("live_event_postponed", fallback: "POSTPONED"), fill: Color(red: 0.88, green: 0.48, blue: 0.12), foreground: .black)
        case .finished:
            pill(place.clock ?? L10n.string("live_event_ended_short", fallback: "Ended"), fill: .clear, foreground: ink, outline: outline)
        case .unknownTime:
            pill(L10n.string("live_events_no_time", fallback: "Time not listed"), fill: .clear, foreground: ink, outline: outline)
        case .upcoming:
            if place.notStarted {
                pill(L10n.string("live_event_not_started", fallback: "Not started"), fill: .clear, foreground: ink, outline: outline)
            }
        }
    }

    @ViewBuilder
    private func statusText(_ state: SportsEvent.State) -> some View {
        switch state {
        case .live:
            if let part = place.partLabel {
                Text(part).font(.system(size: 19, weight: .semibold)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.75)
            } else if let liveClock = place.clock {
                Text(liveClock).font(.system(size: 19, weight: .semibold)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8)
                if let bases = place.bases { BasesView(bases: bases, ink: ink) }
            } else if let end = endTime {
                Text(L10n.format("live_event_ends_about", fallback: "ends ~%@", shortClock.string(from: end)))
                    .font(.system(size: 19, weight: .semibold)).opacity(0.8).lineLimit(1)
            }
        case .mayHaveEnded:
            if let start = event.start {
                Text(L10n.format("live_event_started_at", fallback: "started %@", shortClock.string(from: start)))
                    .font(.system(size: 19)).opacity(0.75).lineLimit(1)
            }
        case .upcoming:
            if place.notStarted, let start = event.start {
                Text(L10n.format("live_event_due_at", fallback: "due %@", shortClock.string(from: start)))
                    .font(.system(size: 19)).opacity(0.75).lineLimit(1)
            } else if let start = event.start {
                HStack(spacing: 8) {
                    Text(clock.string(from: start)).font(.system(size: 19, weight: .heavy)).lineLimit(1)
                    if let until = untilText(start) {
                        Text(until).font(.system(size: 19)).opacity(0.7).lineLimit(1)
                    }
                }
            }
        case .postponed:
            if let start = event.start {
                Text(L10n.format("live_event_was_at", fallback: "was %@", clock.string(from: start)))
                    .font(.system(size: 19)).opacity(0.7).lineLimit(1)
            }
        case .finished:
            if let ended = place.endedAt {
                Text(L10n.format("live_event_ended_at", fallback: "ended %@", shortClock.string(from: ended)))
                    .font(.system(size: 19)).opacity(0.7).lineLimit(1)
            }
        case .unknownTime:
            EmptyView()
        }
    }

    /// When it's expected to end: the sport's usual length, or the guide
    /// listing's end when that's later.
    private var endTime: Date? {
        guard let start = event.start else { return nil }
        var end = start.addingTimeInterval(event.expectedLength)
        if let listing = event.listingEnd, listing > end, listing < start.addingTimeInterval(8 * 3600) { end = listing }
        return end
    }

    /// "in 25 m", "in 2 h" for the next few hours.
    private func untilText(_ start: Date) -> String? {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        guard minutes >= 0, minutes < 6 * 60 else { return nil }
        if minutes < 60 { return L10n.format("live_event_in_minutes", fallback: "in %d m", max(1, minutes)) }
        return L10n.format("live_event_in_hours", fallback: "in %d h", (minutes + 30) / 60)
    }

    // MARK: Middle

    @ViewBuilder
    private var middle: some View {
        if !place.parts.isEmpty {
            cardMiddle
        } else if let top = place.top, let bottom = place.bottom {
            let leader = Self.leader(place.topScore, place.bottomScore)
            VStack(alignment: .leading, spacing: 2) {
                sideLine(top, home: place.homeIsTop == true, score: place.topScore, leads: leader.map { $0 == 0 },
                         ball: place.possessionTop == true, sets: place.topSets)
                sideLine(bottom, home: place.homeIsTop == false, score: place.bottomScore, leads: leader.map { $0 == 1 },
                         ball: place.possessionTop == false, sets: place.bottomSets)
            }
        } else {
            HStack(spacing: 14) {
                Image(systemName: SportsNames.symbol(event.league))
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ink.opacity(focused ? 0.08 : 0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.title)
                        .font(.system(size: 24, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(.system(size: 18))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// 0 when the top line leads, 1 when the bottom does, nil when level or unknown.
    private static func leader(_ top: String?, _ bottom: String?) -> Int? {
        guard let a = top.flatMap({ Int($0) }), let b = bottom.flatMap({ Int($0) }), a != b else { return nil }
        return a > b ? 0 : 1
    }

    private func sideLine(_ team: SportsTeam, home: Bool, score: String? = nil, leads: Bool? = nil, ball: Bool = false,
                          sets: [String] = []) -> some View {
        HStack(spacing: 11) {
            if place.photos {
                PlayerPhotoView(name: team.name, focused: focused)
            }
            if let country = team.country {
                countryChip(country, focused: focused)
                    .frame(width: 32)
            } else if !place.photos {
                SideBadge(team: team, focused: focused)
            }
            if let rank = team.rank {
                Text("\(rank)").font(.system(size: 18, weight: .heavy)).opacity(0.55)
            }
            Text(SportsNames.short(team, soccer: event.game?.isSoccer ?? true))
                .font(.system(size: 23, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if home {
                Text(L10n.string("live_event_home", fallback: "home")).font(.system(size: 16)).opacity(0.5)
            }
            if !sets.isEmpty {
                // Tennis: games per set, the current set bold.
                Spacer(minLength: 6)
                HStack(spacing: 9) {
                    ForEach(Array(sets.enumerated()), id: \.offset) { index, value in
                        Text(value)
                            .font(.system(size: 24, weight: index == sets.count - 1 ? .heavy : .bold).monospacedDigit())
                            .opacity(index == sets.count - 1 ? 1 : 0.55)
                    }
                }
                .fixedSize()
            } else if let score {
                Spacer(minLength: 6)
                if ball {
                    Image(systemName: "arrowtriangle.left.fill").font(.system(size: 11)).opacity(0.85)
                }
                Text(score)
                    .font(.system(size: 27, weight: leads == false ? .bold : .heavy).monospacedDigit())
                    .opacity(leads == false ? 0.55 : 1)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 40)
    }

    /// A fight card: its name, the headline bout, and its parts' timeline.
    private var cardMiddle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.title)
                .font(.system(size: 24, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let top = place.top, let bottom = place.bottom {
                HStack(spacing: 8) {
                    if place.boutNow {
                        Text(L10n.string("live_card_now", fallback: "Now:")).opacity(0.6)
                    }
                    if let country = top.country { countryChip(country, focused: focused, size: 12) }
                    Text(lastName(top)).lineLimit(1)
                    Text("vs.").opacity(0.5)
                    if let country = bottom.country { countryChip(country, focused: focused, size: 12) }
                    Text(lastName(bottom)).lineLimit(1)
                }
                .font(.system(size: 18))
                .minimumScaleFactor(0.8)
            } else if !place.podium.isEmpty {
                podiumLine
            } else if let subtitle = place.subtitle {
                Text(subtitle)
                    .font(.system(size: 18))
                    .opacity(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(place.parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.opacity(0.14))
                            Capsule().fill(ink.opacity(part.current ? 1 : 0.4))
                                .frame(width: part.fill > 0 ? max(6, partWidth * CGFloat(part.fill)) : 0)
                        }
                        .frame(width: partWidth, height: 6)
                        Text(part.timed ? "\(part.label) \(shortClock.string(from: part.start))" : part.label)
                            .font(.system(size: 16, weight: part.current ? .heavy : .regular))
                            .opacity(part.current ? 1 : 0.65)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: partWidth, alignment: .leading)
                    }
                }
            }
            .padding(.top, 3)
        }
    }

    /// A race weekend's latest finished session: "Qualifying 1 ANT 2 VER 3 HAD"
    /// in team colors.
    private var podiumLine: some View {
        HStack(spacing: 8) {
            if let label = place.podiumLabel {
                Text(label).opacity(0.6).lineLimit(1)
            }
            ForEach(Array(place.podium.prefix(3).enumerated()), id: \.offset) { index, driver in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(teamColor(driver.color) ?? ink.opacity(0.4))
                        .frame(width: 4, height: 18)
                    Text("\(index + 1)").opacity(0.55)
                    Text(driver.code).fontWeight(.heavy)
                }
                .fixedSize()
            }
        }
        .font(.system(size: 17))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Each part's share of the timeline (the tile's inner width).
    private var partWidth: CGFloat {
        let count = CGFloat(max(1, place.parts.count))
        return (LiveTileSize.width - 32 - 8 * (count - 1)) / count
    }

    private func lastName(_ fighter: SportsTeam) -> String {
        fighter.name.split(separator: " ").last.map(String.init) ?? fighter.name
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if let display = place.channelDisplay {
                ChannelLogoView(urls: place.logoURLs, width: 72, height: 26, focused: focused) {
                    channelPill(display, outlined: false)
                }
            } else if let pill = place.pill {
                channelPill(pill, outlined: place.pillOutlined)
            }
            if let situation = place.situation {
                Text(situation)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(place.redZone ? (focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching) : ink)
                    .opacity(place.redZone ? 1 : 0.85)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if !place.footer.isEmpty {
                Text(place.footer)
                    .font(.system(size: 18))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func channelPill(_ text: String, outlined: Bool) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .heavy))
            .lineLimit(1)
            .foregroundColor(outlined ? ink : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(outlined ? Color.clear
                                                                : (focused ? Color(red: 0.05, green: 0.1, blue: 0.17) : Color.white.opacity(0.18))))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(outlined ? ink.opacity(0.5) : .clear, lineWidth: 2))
    }
}

// MARK: - Hero and backdrop

/// The top of Live Events: the focused game, big.
struct LiveEventsHero: View {
    /// The focused game; nil shows the model's pick (first live game).
    let focused: SportsEvent?
    let now: Date
    @ObservedObject private var model = LiveEventsModel.shared

    var body: some View {
        let event = model.current(focused) ?? model.hero
        let place = model.place(for: event)
        return VStack(alignment: .leading, spacing: 10) {
            if let event {
                HStack(spacing: 10) {
                    chipLabel(leagueLine(event),
                              fill: Color.white.opacity(0.18))
                    Spacer()
                    Text(clock.string(from: now))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                }
                HStack(spacing: 16) {
                    if let game = event.game {
                        TeamBadge(team: game.isSoccer ? game.home : game.away, size: 52)
                        TeamBadge(team: game.isSoccer ? game.away : game.home, size: 52)
                    } else if let teams = event.teams, teams.count == 2 {
                        TeamBadge(team: teams[0], size: 52)
                        TeamBadge(team: teams[1], size: 52)
                    }
                    Text(heroTitle(event, place))
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                statusLine(event, place)
                if event.state(at: now) == .live {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white).frame(width: 420 * CGFloat(place.liveProgress ?? event.progress(at: now)))
                    }
                    .frame(width: 420, height: 6)
                }
                whereLine(event, place)
            } else {
                HStack {
                    Text(L10n.string("live_events_title", fallback: "Live Events"))
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(clock.string(from: now))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                }
                Text(L10n.string("live_events_empty_hero", fallback: "This week's games, and where you can watch them."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 36)
    }

    /// "Indiana 24 – 17 Michigan" with scores; the game's title without.
    private func heroTitle(_ event: SportsEvent, _ place: EventWhere) -> String {
        if let a = place.topScore, let b = place.bottomScore, let top = place.top, let bottom = place.bottom, place.parts.isEmpty {
            let soccer = event.game?.isSoccer ?? true
            return "\(SportsNames.short(top, soccer: soccer)) \(a)  –  \(b) \(SportsNames.short(bottom, soccer: soccer))"
        }
        return event.game.map(SportsNames.title) ?? event.title
    }

    @ViewBuilder
    private func statusLine(_ event: SportsEvent, _ place: EventWhere) -> some View {
        let state = event.state(at: now)
        HStack(spacing: 12) {
            switch state {
            case .live:
                if event.live == .delayed {
                    chipLabel(L10n.string("live_event_delayed", fallback: "DELAYED"), fill: Color(red: 0.88, green: 0.63, blue: 0),
                              foreground: .black)
                } else {
                    chipLabel(L10n.string("live_badge_live", fallback: "LIVE"), fill: LiveStyle.watching)
                }
            case .upcoming:
                chipLabel(L10n.string("live_badge_later", fallback: "LATER"), fill: .clear, outlined: true)
            case .finished:
                chipLabel(place.clock?.uppercased() ?? L10n.string("live_event_ended", fallback: "ENDED"), fill: Color.white.opacity(0.18))
            case .postponed:
                chipLabel(L10n.string("live_event_postponed", fallback: "POSTPONED"), fill: Color.orange.opacity(0.85))
            case .mayHaveEnded:
                chipLabel(L10n.string("live_event_may_have_ended", fallback: "MAY HAVE ENDED"), fill: .clear, outlined: true)
            case .unknownTime:
                EmptyView()
            }
            Text(statusText(event, state, place))
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func statusText(_ event: SportsEvent, _ state: SportsEvent.State, _ place: EventWhere) -> String {
        var parts: [String] = []
        switch state {
        case .live where place.partLabel != nil || place.clock != nil:
            // The hero has room for one status line: clock, then the situation.
            parts.append(place.partLabel ?? place.clock ?? "")
            if let situation = place.situation { parts.append(situation) }
            return parts.joined(separator: "   ·   ")
        case .live, .mayHaveEnded:
            if let start = event.start { parts.append(L10n.format("live_events_started", fallback: "Started %@", clock.string(from: start))) }
        case .upcoming:
            if let start = event.start {
                parts.append(dayTime(start, now: now))
                let minutes = Int(start.timeIntervalSince(now) / 60)
                if minutes < 180 {
                    parts.append(L10n.format("live_starts_in", fallback: "Starts in %@", minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(max(1, minutes)) m"))
                }
            }
        case .finished, .postponed, .unknownTime:
            break
        }
        if let venue = event.game?.venue { parts.append(venue) }
        return parts.joined(separator: "   ·   ")
    }

    @ViewBuilder
    private func whereLine(_ event: SportsEvent, _ place: EventWhere) -> some View {
        let feeds = place.feeds
        HStack(spacing: 14) {
            if let display = place.channelDisplay, let name = place.channelName {
                ChannelLogoView(urls: place.logoURLs, width: 80, height: 32) {
                    Text(display).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                }
                let parts: [String?] = [
                    place.inLineup
                        ? L10n.format("live_event_on_lineup", fallback: "On %@, in your lineup", name)
                        : L10n.format("live_event_on_guide", fallback: "On %@", name),
                    feeds > 0 ? L10n.format("live_event_backups_long", fallback: "%d backup feeds from your provider", feeds) : nil
                ]
                Text(parts.compactMap { $0 }.joined(separator: "   ·   "))
            } else if feeds > 0 {
                Text(L10n.format("live_event_provider_feeds", fallback: "%d feeds from your provider", feeds))
            } else {
                Text(notInChannels(event))
            }
        }
        .font(.system(size: 20))
        .foregroundColor(.white.opacity(0.7))
        .lineLimit(1)
    }
}

/// The focused game's two team logos, big and faded over a glow, behind
/// the top right of Live Events.
struct LiveEventBackdrop: View {
    let focused: SportsEvent?
    @ObservedObject private var model = LiveEventsModel.shared

    var body: some View {
        let event = model.current(focused) ?? model.hero
        let pair: (SportsTeam, SportsTeam)? = event?.game.map { $0.isSoccer ? ($0.home, $0.away) : ($0.away, $0.home) }
            ?? event?.teams.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        return GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let pair {
                    ZStack {
                        RadialGradient(colors: [Color(red: 0.05, green: 0.2, blue: 0.55).opacity(0.85), .clear],
                                       center: .center, startRadius: 40, endRadius: geo.size.width * 0.32)
                        HStack(spacing: 40) {
                            TeamBadge(team: pair.0, size: geo.size.height * 0.3)
                            Text("VS")
                                .font(.system(size: geo.size.height * 0.08, weight: .heavy))
                                .foregroundColor(.white.opacity(0.7))
                            TeamBadge(team: pair.1, size: geo.size.height * 0.3)
                        }
                        .opacity(0.45)
                    }
                    .frame(width: geo.size.width * 0.55, height: geo.size.height * 0.48)
                    .mask(
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: UnitPoint(x: 0.35, y: 0.5))
                            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    )
                    .id(pair.0.id + pair.1.id)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.35), value: event?.id)
    }
}

// MARK: - Board

/// Live Events: a row of what's live, a row per sport for the week (games
/// none of your channels has dimmed at the end), events without a time,
/// and the provider's event channels. Left from a
/// row's first game opens the Sports column (like the guide's Jump to).
struct LiveEventsBoard: View {
    @Binding var focusedEvent: SportsEvent?
    let onPickFamily: (EventFamily) -> Void
    let onDetail: (SportsEvent) -> Void
    let onWhere: (SportsEvent) -> Void
    var onFirstOpen: () -> Void = {}

    private let store = LiveTVStore.shared
    @ObservedObject private var model = LiveEventsModel.shared
    @ObservedObject private var reminders = LiveReminders.shared
    @FocusState private var focus: String?
    @State private var columnOpen = false
    @State private var columnOrigin: String?
    @State private var columnReturn: String?
    @FocusState private var columnFocus: String?
    @State private var lastFocus: String?
    @State private var lastRedirect = Date.distantPast
    @Environment(\.isEnabled) private var isEnabled

    typealias Row = LiveEventsModel.Row
    private var now: Date { model.now }

    var body: some View {
        let rows = model.rows
        return ScrollViewReader { scroller in
            ZStack(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if rows.isEmpty {
                            Text(L10n.string("live_events_none", fallback: "No upcoming events found in your channels right now."))
                                .font(.system(size: 24)).foregroundColor(.white.opacity(0.6)).padding(.vertical, 30)
                        }
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.bottom, 80)
                }
                .disabled(columnOpen)
                .overlay(Color.black.opacity(columnOpen ? 0.5 : 0).allowsHitTesting(false))
                .focusSection()
                if columnOpen {
                    sportsColumn(rows, scroller: scroller)
                        .padding(.leading, -16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: columnOpen)
            .onChange(of: focus) { old, new in
                if let new, !new.hasPrefix("h|") { lastFocus = new }
                model.focusChanged(to: new.flatMap { $0.hasPrefix("h|") ? nil : $0 })
                handleFocus(old: old, new: new, rows: rows)
            }
            .onChange(of: isEnabled) { _, enabled in
                // Back from a details card or Where to Watch: the tile again.
                guard enabled, let target = lastFocus else { return }
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if focus == nil, !columnOpen { focus = target }
                    }
                }
            }
            .onChange(of: columnFocus) { old, new in
                if let new {
                    scroller.scrollTo(new, anchor: .top)
                } else if old != nil, columnOpen {
                    columnOpen = false
                }
            }
        }
        .onAppear {
            CrashRecorder.note("events: open, \(store.sportsEvents.count) events, \(CrashRecorder.memoryMB()) MB")
            model.start()
            SportsData.shared.noteSportFeeds(store.events)
            SportsData.shared.refreshIfNeeded()
            store.sportsOpened()
            onFirstOpen()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: Rows

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LiveSectionLabel(text: row.title)
                Text(rowSummary(row))
                    .font(LiveStyle.sectionFont)
                    .tracking(1.2)
                    .foregroundColor(row.live > 0 ? LiveStyle.watching : LiveStyle.sectionColor)
            }
            HStack(spacing: 20) {
                // A focus target in the margin: Left from the first tile
                // lands here and opens the Sports column.
                Color.white.opacity(0.001)
                    .frame(width: 20, height: row.grouped ? LiveTileSize.height + 34 : LiveTileSize.height)
                    .focusable(!columnOpen)
                    .focused($focus, equals: "h|\(row.id)")
                    .focusEffectDisabledIfAvailable()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 24) {
                        ForEach(row.events) { event in
                            if row.grouped {
                                // A group label over the first tile of each
                                // group, with a wider gap before it.
                                let header = row.headers[event.id]
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(header ?? " ")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.white.opacity(header == nil ? 0 : 0.7))
                                        .lineLimit(1)
                                        .frame(height: 26, alignment: .leading)
                                    tileButton(event, row: row)
                                }
                                .padding(.leading, header != nil && event.id != row.events.first?.id ? 32 : 0)
                            } else {
                                tileButton(event, row: row)
                            }
                        }
                        ForEach(row.families) { family in
                            familyButton(family, row: row)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 60)
                }
            }
            .padding(.leading, -40)
        }
    }

    private func rowSummary(_ row: Row) -> String {
        var parts = ["·  \(row.count)"]
        if row.live > 0, row.id != "live" { parts.append(L10n.format("live_events_n_live", fallback: "%d live", row.live)) }
        return parts.joined(separator: "  ·  ")
    }

    private func key(_ row: Row, _ id: String) -> String { "\(row.id)|\(id)" }


    private func tileButton(_ event: SportsEvent, row: Row) -> some View {
        let id = key(row, event.id)
        let isFocused = focus == id
        let upcoming = event.state(at: now) == .upcoming
        return Button {
            select(event)
        } label: {
            LiveEventTile(event: event, place: model.place(for: event), focused: isFocused, now: now, showLeague: row.mixed)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .contextMenu {
            if !event.sources.isEmpty {
                Button {
                    onWhere(event)
                } label: {
                    Label(L10n.string("live_event_where", fallback: "Where to Watch"), systemImage: "list.bullet")
                }
            }
            if upcoming, let target = store.reminderTarget(for: event) {
                let isSet = reminders.isSet(channelID: target.channel.id, start: target.program.start)
                Button {
                    reminders.toggle(channel: target.channel, program: target.program)
                } label: {
                    Label(isSet ? L10n.string("live_reminder_remove", fallback: "Remove Reminder")
                                : L10n.string("live_remind_me", fallback: "Remind Me"),
                          systemImage: isSet ? "bell.slash" : "bell")
                }
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { focusedEvent = event }
        }
    }

    private func familyButton(_ family: EventFamily, row: Row) -> some View {
        let id = key(row, family.id)
        let isFocused = focus == id
        return Button {
            onPickFamily(family)
        } label: {
            // The same layout as a game tile: status row, title, footer.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(L10n.format("live_family_count", fallback: "%d feeds", family.feeds.count))
                        .font(.system(size: 19, weight: .semibold)).opacity(0.8)
                    Spacer(minLength: 8)
                    Text(family.league.isEmpty ? "" : SportsMatcher.shortLeague(family.league))
                        .font(.system(size: 18, weight: .bold)).opacity(0.55).lineLimit(1)
                }
                .frame(height: 28)
                Spacer(minLength: 3)
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill((isFocused ? Color.black : Color.white).opacity(isFocused ? 0.08 : 0.12)))
                    Text(family.name)
                        .font(.system(size: 24, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 3)
                Text(L10n.string("live_family_surf", fallback: "Up/Down to surf"))
                    .font(.system(size: 18)).opacity(0.7)
                    .frame(height: 28)
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.top, 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
            .frame(width: LiveTileSize.width, height: LiveTileSize.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.09))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0))
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
    }

    private func select(_ event: SportsEvent) {
        CrashRecorder.note("events: select \(event.leagueShort) \(event.state(at: now))")
        switch event.state(at: now) {
        case .live, .mayHaveEnded, .unknownTime:
            // A fight card plays the part that's on now.
            let target = model.cardCurrent(event).flatMap { $0.sources.isEmpty ? nil : $0 } ?? event
            if target.sources.isEmpty { onDetail(event) } else { store.watchSportsEvent(target) }
        case .upcoming, .postponed, .finished:
            onDetail(event)
        }
    }

    // MARK: Sports column

    /// The margin target only opens the column when reached with Left from
    /// that row's first tile; arriving any other way moves on to the row.
    private func handleFocus(old: String?, new: String?, rows: [Row]) {
        guard let new, new.hasPrefix("h|") else { return }
        let rowID = String(new.dropFirst(2))
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        let first = row.events.first.map { key(row, $0.id) } ?? row.families.first.map { key(row, $0.id) }
        if let old, old.hasPrefix(rowID + "|"), rows.count > 1 {
            CrashRecorder.note("events: sports column")
            columnReturn = old
            columnOrigin = rowID
            columnOpen = true
            columnFocus = rowID
            DispatchQueue.main.async { if columnOpen { columnFocus = rowID } }
        } else if let first {
            // Never bounce focus back and forth.
            guard Date().timeIntervalSince(lastRedirect) > 0.4 else { return }
            lastRedirect = Date()
            DispatchQueue.main.async { focus = (old?.hasPrefix(rowID + "|") == true ? old : first) }
        }
    }

    private func closeColumn(to rowID: String?, rows: [Row], scroller: ScrollViewProxy) {
        columnOpen = false
        let target: String?
        if let rowID, let row = rows.first(where: { $0.id == rowID }) {
            scroller.scrollTo(rowID, anchor: .top)
            target = row.events.first.map { key(row, $0.id) } ?? row.families.first.map { key(row, $0.id) }
        } else {
            target = columnReturn
        }
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !columnOpen, let target, focus != target else { return }
                focus = target
            }
        }
    }

    private func sportsColumn(_ rows: [Row], scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LiveSectionLabel(text: L10n.string("live_sports", fallback: "Sports"))
                .padding(.leading, 22)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        columnButton(row, rows: rows, scroller: scroller)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 14)
        .padding(.horizontal, 12)
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: 640, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 8, y: 8)
        )
        .focusSection()
        .onExitCommand { closeColumn(to: nil, rows: rows, scroller: scroller) }
    }

    private func columnButton(_ row: Row, rows: [Row], scroller: ScrollViewProxy) -> some View {
        let focused = columnFocus == row.id
        return Button {
            closeColumn(to: row.id, rows: rows, scroller: scroller)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(LiveStyle.watching)
                    .frame(width: 9, height: 9)
                    .opacity(row.id == columnOrigin && !focused ? 1 : 0)
                Text(row.title)
                    .font(LiveStyle.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if row.live > 0, row.id != "live" {
                    Text(L10n.format("live_events_n_live", fallback: "%d live", row.live))
                        .font(LiveStyle.rowValue)
                        .foregroundColor(focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching)
                }
                Text("\(row.count)")
                    .font(LiveStyle.rowValue.monospacedDigit())
                    .opacity(0.6)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused))
        .focused($columnFocus, equals: row.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .right { closeColumn(to: row.id, rows: rows, scroller: scroller) }
        }
    }
}

// MARK: - Where to watch

struct LiveEventWherePanel: View {
    let event: SportsEvent
    let onClose: () -> Void
    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        LiveSidePanel(edge: .trailing, width: 800) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    LiveSectionLabel(text: L10n.string("live_event_where", fallback: "Where to Watch"))
                        .padding(.leading, 4)
                    Text(event.game.map(SportsNames.title) ?? event.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .padding(.bottom, 10)
                    if let parts = LiveEventsModel.shared.cards[event.id] {
                        // A fight card: each part's channels and feeds.
                        ForEach(parts, id: \.id) { part in
                            if !part.sources.isEmpty {
                                section(LiveEventsModel.partName(part), part.sources, watching: part)
                            }
                        }
                    } else {
                        let english = event.channels.filter { !$0.spanish }
                        let spanish = event.sources.filter { $0.spanish }
                        let feeds = event.feeds.filter { !$0.spanish }
                        if !english.isEmpty { section(L10n.string("live_event_your_channels", fallback: "Your channels"), english, watching: event) }
                        if let more = event.moreStations, more > 0 {
                            Text(more == 1
                                 ? L10n.string("live_event_one_more_station", fallback: "1 more station in your channels is showing it")
                                 : L10n.format("live_event_more_stations", fallback: "%d more stations in your channels are showing it", more))
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.leading, 4)
                                .padding(.top, 4)
                        }
                        if !spanish.isEmpty { section(L10n.string("live_event_spanish", fallback: "Spanish"), spanish, watching: event) }
                        if !feeds.isEmpty { section(L10n.string("live_event_provider_section", fallback: "Event feeds from your provider"), feeds, watching: event) }
                    }
                    Text(L10n.string("live_event_where_hint", fallback: "Whichever you pick, the others stay as automatic backups."))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 14)
                }
                .padding(.top, 50)
                .padding(.bottom, 60)
                .padding(.trailing, 70)
            }
            .focusSection()
        }
        .onExitCommand { onClose() }
    }

    @ViewBuilder
    private func section(_ title: String, _ sources: [EventSource], watching target: SportsEvent) -> some View {
        LiveSectionLabel(text: title)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .padding(.leading, 4)
        ForEach(sources, id: \.channelID) { source in
            if let channel = store.sourceChannel(source) {
                LivePanelRow(title: channel.name, detail: detail(source, channel), accessory: .chevron(nil)) {
                    onClose()
                    store.watchSportsEvent(target, preferring: source.channelID)
                }
            }
        }
    }

    private func detail(_ source: EventSource, _ channel: LiveTVChannel) -> String {
        source.kind == .provider ? [source.detail, store.feedSummary(channel)].filter { !$0.isEmpty }.joined(separator: " · ") : source.detail
    }
}

// MARK: - Details for a game that hasn't started

struct LiveEventDetailCard: View {
    let event: SportsEvent
    let onClose: () -> Void
    let onWhere: () -> Void
    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var reminders = LiveReminders.shared
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    chipLabel(leagueLine(event),
                              fill: Color.white.opacity(0.18))
                    Spacer()
                }
                HStack(spacing: 18) {
                    if let game = event.game {
                        TeamBadge(team: game.isSoccer ? game.home : game.away, size: 70)
                        TeamBadge(team: game.isSoccer ? game.away : game.home, size: 70)
                    }
                    Text(event.game.map(SportsNames.title) ?? event.title)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Text(summary)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    if let target = store.reminderTarget(for: event), event.state(at: Date()) == .upcoming {
                        let isSet = reminders.isSet(channelID: target.channel.id, start: target.program.start)
                        pill(isSet ? L10n.string("live_reminder_set", fallback: "Reminder Set") : L10n.string("live_remind_me", fallback: "Remind Me"),
                             symbol: isSet ? "bell.fill" : "bell", id: "remind") {
                            reminders.toggle(channel: target.channel, program: target.program)
                        }
                    }
                    if let source = event.channels.first, let channel = store.sourceChannel(source) {
                        pill(L10n.format("live_watch_now", fallback: "Watch %@ Now", channel.name), symbol: "play.fill", id: "watch") {
                            onClose()
                            store.watchSportsEvent(event, preferring: source.channelID)
                        }
                    }
                    if !event.sources.isEmpty {
                        pill(L10n.string("live_event_where", fallback: "Where to Watch"), symbol: "list.bullet", id: "where") {
                            onWhere()
                        }
                    }
                }
                .padding(.top, 8)
                if event.sources.isEmpty {
                    Text(notInChannels(event) + ". " + L10n.string("live_event_none_yet", fallback: "If one of your channels or event feeds picks it up, it'll show here."))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(44)
            .frame(width: 1150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.black.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 12)
            )
            .focusSection()
        }
        .onExitCommand { onClose() }
        .onAppear {
            DispatchQueue.main.async {
                focus = store.reminderTarget(for: event) != nil ? "remind" : (event.channels.isEmpty ? "where" : "watch")
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let start = event.start {
            let calendar = Calendar.current
            let day: String
            if calendar.isDateInToday(start) {
                day = calendar.component(.hour, from: start) >= 17
                    ? L10n.string("live_time_tonight", fallback: "Tonight") : L10n.string("live_time_today", fallback: "Today")
            } else if calendar.isDateInTomorrow(start) {
                day = L10n.string("live_time_tomorrow", fallback: "Tomorrow")
            } else {
                day = longWeekday.string(from: start)
            }
            parts.append("\(day) \(clock.string(from: start))")
        }
        if let venue = event.game?.venue { parts.append(venue) }
        if let source = event.channels.first, let channel = store.sourceChannel(source) {
            parts.append(L10n.format("live_event_on_guide", fallback: "On %@", channel.name))
        } else if event.feeds.isEmpty, let network = event.game?.networks.first {
            parts.append(L10n.format("live_event_on_guide", fallback: "On %@", network))
        }
        if !event.feeds.isEmpty {
            parts.append(L10n.format("live_event_provider_feeds", fallback: "%d feeds from your provider", event.feeds.count))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func pill(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        let focused = focus == id
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 30)
            .frame(height: 70)
            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
