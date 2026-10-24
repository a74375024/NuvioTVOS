import Foundation

/// Where an event can be watched, best first (that's also the automatic
/// backup order).
struct EventSource: Hashable, Codable {
    enum Kind: Int, Codable { case lineup = 0, guide = 1, provider = 2 }
    let channelID: String
    let kind: Kind
    let spanish: Bool
    /// "In your guide at 6:15", "Provider event channel".
    let detail: String
}

/// One game or event for Live Events: a TheSportsDB game with everything
/// found showing it (guide channels and provider event feeds), or a
/// provider event that matched no game.
struct SportsEvent: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    /// Row group: "NFL", "College Football", "Soccer"…
    let league: String
    /// Chip text.
    let leagueShort: String
    let start: Date?
    var game: SportsGame?
    var sources: [EventSource]
    var family: String?
    /// The end of the guide listing showing it, when later than usual.
    var listingEnd: Date?
    /// For an event with no game: the two schools named in it (logos only).
    var teams: [SportsTeam]?
    /// When every provider feed that carried it moved on to something else
    /// (the provider's sign it's over).
    var feedsEndedAt: Date? = nil

    static func == (lhs: SportsEvent, rhs: SportsEvent) -> Bool {
        lhs.id == rhs.id && lhs.sources == rhs.sources && lhs.game == rhs.game && lhs.listingEnd == rhs.listingEnd
            && lhs.teams == rhs.teams && lhs.feedsEndedAt == rhs.feedsEndedAt
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The same event under another tile id.
    func with(id newID: String) -> SportsEvent {
        guard newID != id else { return self }
        var copy = SportsEvent(id: newID, title: title, league: league, leagueShort: leagueShort, start: start,
                               game: game, sources: sources, family: family)
        copy.listingEnd = listingEnd
        copy.teams = teams
        copy.feedsEndedAt = feedsEndedAt
        return copy
    }

    var channels: [EventSource] { sources.filter { $0.kind != .provider } }
    var feeds: [EventSource] { sources.filter { $0.kind == .provider } }

    /// Rough length by sport; past it a game "may have ended", and a while
    /// after that it's dropped from Live now.
    var expectedLength: TimeInterval {
        switch league {
        case "NFL", "College Football", "Football": return 3.6 * 3600
        case "MLB", "Baseball": return 3.1 * 3600
        case "NBA", "WNBA", "NHL", "College Basketball", "Basketball", "Hockey": return 2.6 * 3600
        case "Soccer", "MLS": return 2.1 * 3600
        case "Fighting": return 5 * 3600
        case "Motorsport", "Golf": return 4 * 3600
        default: return 2.5 * 3600
        }
    }

    enum State: Equatable {
        case upcoming, live, mayHaveEnded, finished, postponed, unknownTime
    }

    /// Live for the sport's usual length (or until the guide listing ends,
    /// if later), then "may have ended" for half an hour, then gone.
    func state(at now: Date) -> State {
        if let game, game.postponed { return .postponed }
        guard let start else { return .unknownTime }
        if now < start { return .upcoming }
        if let game, game.completed { return .finished }
        if let feedsEndedAt, now >= feedsEndedAt { return .finished }
        var end = start.addingTimeInterval(expectedLength)
        if let listingEnd, listingEnd > end, listingEnd < start.addingTimeInterval(8 * 3600) { end = listingEnd }
        if now < end { return .live }
        if now < end.addingTimeInterval(30 * 60) { return .mayHaveEnded }
        return .finished
    }

    /// Fraction of the expected length gone by (for the progress bar).
    func progress(at now: Date) -> Double {
        guard let start else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / expectedLength))
    }
}

/// Matches the schedule's games with your channels, provider event feeds and
/// guide listings. Pure; runs off the main thread.
///
/// Cost is kept linear: provider events that don't look like a game skip
/// matching; team names are looked up through an index (first word →
/// names) instead of comparing every title with every game; temporary
/// Foundation objects are released per item.
enum SportsMatcher {
    struct GuideListing: Hashable, Codable {
        let entryID: String
        let inLineup: Bool
        let spanish: Bool
        let title: String
        let start: Date
        let end: Date
    }

    struct ProviderEvent {
        let id: String
        let title: String
        let league: String
        let start: Date?
        let feeds: [String]
        let family: String
        let spanish: Bool
    }

    struct Stats {
        var events = 0
        var filtered = 0
        var matchedEvents = 0
        var listings = 0
        var matchedListings = 0
        var games = 0
        var schoolPairs = 0
        var milliseconds: [String: Int] = [:]
        var aborted: String?

        var summary: String {
            let steps = milliseconds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "games \(games), events \(events) → \(filtered) game-like, \(matchedEvents) matched, "
                + "listings \(listings) → \(matchedListings) matched, school pairs \(schoolPairs); ms: \(steps)" + (aborted.map { "; ABORTED: \($0)" } ?? "")
        }
    }

    static let supportedLeagues: Set<String> = ["NFL", "College Football", "NBA", "MLB", "NHL", "MLS", "Soccer"]

    /// - Parameters:
    ///   - previousIDs: game id → the tile id it was shown under last time,
    ///     so tiles keep their identity (and focus) across rebuilds.
    ///   - shouldStop: checked between steps (memory guard); returning a
    ///     reason stops the build and returns nil.
    static func build(games: [SportsGame], channelSources: [String: [EventSource]], events: [ProviderEvent],
                      listings: [GuideListing], preferSpanish: Bool, now: Date, previousIDs: [String: String],
                      schools: [SportsTeam] = [],
                      shouldStop: () -> String?) -> (events: [SportsEvent], stats: Stats)? {
        var stats = Stats()
        stats.events = events.count
        stats.games = games.count
        stats.listings = listings.count
        var clock = Date()
        func lap(_ step: String) {
            stats.milliseconds[step] = Int(Date().timeIntervalSince(clock) * 1000)
            clock = Date()
        }

        let index = TeamIndex(games: games)
        lap("0 index")
        var byGame: [Int: SportsEvent] = [:]
        var firstProviderID: [Int: String] = [:]
        func entry(_ gameIndex: Int) -> SportsEvent {
            if let value = byGame[gameIndex] { return value }
            let game = games[gameIndex]
            return SportsEvent(id: "sev|\(game.id)", title: game.title, league: game.league, leagueShort: game.leagueShort,
                               start: game.start, game: game, sources: [], family: nil)
        }

        // 0. Channels airing each game's TV network.
        for (gameIndex, game) in games.enumerated() {
            guard let sources = channelSources[game.id], !sources.isEmpty else { continue }
            var value = entry(gameIndex)
            value.sources = sources
            byGame[gameIndex] = value
        }

        // 1. Provider event feeds → games. Only titles that look like a game
        // (two sides) or are in a league the schedule covers.
        let low = now.addingTimeInterval(-8 * 3600), high = now.addingTimeInterval(8 * 86_400)
        var plain: [ProviderEvent] = []
        var unmatched: [ProviderEvent] = []
        for event in events {
            autoreleasepool {
                let inWindow = event.start.map { $0 > low && $0 < high } ?? true
                guard inWindow, looksLikeGame(event.title) || supportedLeagues.contains(event.league) else {
                    plain.append(event)
                    return
                }
                stats.filtered += 1
                guard !games.isEmpty else { unmatched.append(event); return }
                let candidates = index.matches(event.title, allowed: { game in
                    compatible(event.league, games[game])
                }, allowLoose: { game in
                    sameLeague(event.league, games[game])
                })
                // An event of unknown league matching games of more than one
                // league (Panthers, Rangers, Kings…) is too ambiguous.
                if event.league.isEmpty || event.league == "Other",
                   Set(candidates.map { games[$0].league }).count > 1 {
                    unmatched.append(event)
                    return
                }
                var best: (game: Int, gap: TimeInterval)?
                for gameIndex in candidates {
                    let game = games[gameIndex]
                    let gap: TimeInterval
                    if let start = event.start {
                        gap = abs(start.timeIntervalSince(game.start))
                        guard gap <= 3 * 3600 else { continue }
                    } else {
                        guard game.start > now.addingTimeInterval(-6 * 3600), game.start < now.addingTimeInterval(18 * 3600) else { continue }
                        gap = abs(game.start.timeIntervalSince(now))
                    }
                    if best.map({ gap < $0.gap }) ?? true { best = (gameIndex, gap) }
                }
                guard let gameIndex = best?.game else { unmatched.append(event); return }
                stats.matchedEvents += 1
                var value = entry(gameIndex)
                for feed in event.feeds where !value.sources.contains(where: { $0.channelID == feed }) {
                    value.sources.append(EventSource(channelID: feed, kind: .provider, spanish: event.spanish,
                                                     detail: "Provider event channel"))
                }
                if value.family == nil { value.family = event.family }
                byGame[gameIndex] = value
                if firstProviderID[gameIndex] == nil { firstProviderID[gameIndex] = event.id }
            }
        }
        lap("1 events")
        if let reason = shouldStop() { stats.aborted = reason; CrashRecorder.note("sports match: \(stats.summary)"); return nil }

        // 2. Guide listings → games (only the game itself, not the shows
        // around it). Capped at 2 s.
        let relevant = Set(games.indices.filter {
            !games[$0].completed && games[$0].start > now.addingTimeInterval(-5 * 3600) && games[$0].start < now.addingTimeInterval(16 * 3600)
        })
        if !relevant.isEmpty {
            let started = Date()
            for listing in listings {
                if Date().timeIntervalSince(started) > 2 { stats.aborted = "listings over 2 s"; break }
                autoreleasepool {
                    let text = normalized(listing.title)
                    guard !excluded(text) else { return }
                    let candidates = index.matches(listing.title, allowed: { relevant.contains($0) })
                    for gameIndex in candidates {
                        let game = games[gameIndex]
                        guard listing.start < game.start.addingTimeInterval(2 * 3600),
                              listing.end > game.start.addingTimeInterval(-15 * 60) else { continue }
                        stats.matchedListings += 1
                        var value = entry(gameIndex)
                        if value.listingEnd.map({ listing.end > $0 }) ?? true { value.listingEnd = listing.end }
                        if !value.sources.contains(where: { $0.channelID == listing.entryID }) {
                            value.sources.append(EventSource(
                                channelID: listing.entryID, kind: listing.inLineup ? .lineup : .guide, spanish: listing.spanish,
                                detail: listing.inLineup ? "In My Lineup" : "In your channels"
                            ))
                        }
                        byGame[gameIndex] = value
                    }
                }
            }
        }
        lap("2 listings")
        if let reason = shouldStop() { stats.aborted = reason; CrashRecorder.note("sports match: \(stats.summary)"); return nil }

        // 3. Provider events that matched no game: grouped by matchup
        // (either team order, start within 90 minutes) through a key lookup.
        var loose: [SportsEvent] = []
        var byPair: [String: [Int]] = [:]
        for event in unmatched {
            autoreleasepool {
                let key = pairKey(event.title)
                if let key, let index = byPair[key]?.first(where: { closeEnough(loose[$0].start, event.start) }) {
                    for feed in event.feeds where !loose[index].sources.contains(where: { $0.channelID == feed }) {
                        loose[index].sources.append(EventSource(channelID: feed, kind: .provider, spanish: event.spanish,
                                                                detail: "Provider event channel"))
                    }
                    return
                }
                loose.append(plainEvent(event))
                if let key { byPair[key, default: []].append(loose.count - 1) }
            }
        }
        // School logos for college events in any sport (volleyball, field
        // hockey…) that no game matched.
        var others = loose + plain.map({ plainEvent($0) })
        if !schools.isEmpty {
            let schoolIndex = TeamIndex(teams: schools)
            // College sports by name; elsewhere (soccer, plain "Football",
            // hockey, "Other") only with a college sign in the title or feed.
            let collegeLeagues: Set<String> = ["College Football", "College Basketball", "Volleyball", "Field Hockey",
                                               "Lacrosse", "Softball", "Wrestling", "Baseball"]
            let pro: Set<String> = ["NFL", "NBA", "WNBA", "MLB", "NHL", "MLS"]
            let clue = "\\b(ncaa\\w*|college|university|univ|women's|men's|espn\\+|accn|acc network|secn|sec network|btn\\+?|big ten)"
            for position in others.indices where !pro.contains(others[position].league) {
                autoreleasepool {
                    let event = others[position]
                    let family = event.family ?? ""
                    guard collegeLeagues.contains(event.league)
                            || RX.test(clue, event.title + " " + family, caseInsensitive: true)
                            || RX.test("\\bflo", family, caseInsensitive: true) else { return }
                    guard looksLikeGame(event.title), let pair = schoolIndex.pair(event.title) else { return }
                    others[position].teams = [pair.0, pair.1]
                    stats.schoolPairs += 1
                }
            }
        }
        var used = Set<String>()
        var result: [SportsEvent] = []
        result.reserveCapacity(games.count + others.count)
        for event in others where used.insert(event.id).inserted {
            result.append(event)
        }

        // 4. Games (no channel showing them: dimmed). Ids stay stable: last
        // time's id, else the provider event it was first shown as — unless
        // a provider tile above already uses it.
        for gameIndex in games.indices {
            let value = entry(gameIndex)
            let game = games[gameIndex]
            var id = previousIDs[game.id] ?? firstProviderID[gameIndex] ?? value.id
            if used.contains(id) { id = firstProviderID[gameIndex] ?? value.id }
            if used.contains(id) { id = value.id }
            guard used.insert(id).inserted else { continue }
            result.append(value.with(id: id))
        }
        lap("3 assemble")

        // Source order: My Lineup, other channels, provider feeds; Spanish
        // after English unless the viewer picked US Spanish.
        let ordered: [SportsEvent] = result.map { event in
            guard event.sources.count > 1 else { return event }
            var copy = event
            copy.sources = event.sources.enumerated().sorted { a, b in
                let sa = (preferSpanish ? !a.element.spanish : a.element.spanish) ? 1 : 0
                let sb = (preferSpanish ? !b.element.spanish : b.element.spanish) ? 1 : 0
                if a.element.kind != b.element.kind { return a.element.kind.rawValue < b.element.kind.rawValue }
                if sa != sb { return sa < sb }
                return a.offset < b.offset
            }.map(\.element)
            return copy
        }
        let sorted = ordered.sorted { a, b in
            switch (a.start, b.start) {
            case let (x?, y?): return x != y ? x < y : (a.title != b.title ? a.title < b.title : a.id < b.id)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title != b.title ? a.title < b.title : a.id < b.id
            }
        }
        lap("4 order")
        CrashRecorder.note("sports match: \(stats.summary)")
        return (sorted, stats)
    }

    /// "rams|seahawks", or the tidied title when it has no two sides.
    static func matchupKey(_ title: String) -> String {
        pairKey(title) ?? normalized(title)
    }

    private static func plainEvent(_ event: ProviderEvent) -> SportsEvent {
        SportsEvent(
            id: event.id, title: event.title, league: event.league, leagueShort: shortLeague(event.league),
            start: event.start, game: nil,
            sources: event.feeds.map { EventSource(channelID: $0, kind: .provider, spanish: event.spanish, detail: "Provider event channel") },
            family: event.family
        )
    }

    /// Two sides: "A vs B", "A v B", "A @ B", "A at B", "A - B" (after a
    /// "Network:" style prefix).
    static func looksLikeGame(_ title: String) -> Bool {
        let full = " " + title.lowercased() + " "
        if full.contains("@") { return true }
        for separator in [" vs ", " vs. ", " v ", " v. ", " at "] where full.contains(separator) { return true }
        // " - " only counts after a "Network:" style prefix.
        if let colon = full.firstIndex(of: ":"), full.distance(from: full.startIndex, to: colon) < 30 {
            let rest = " " + String(full[full.index(after: colon)...])
            return rest.contains(" - ")
        }
        return false
    }

    /// Team names, looked up by their first word. Built from games (two
    /// sides each) or from a plain list of teams (school logos).
    struct TeamIndex {
        struct Name {
            /// The game index (or team index for a plain list).
            let slot: Int
            let side: Int          // 0 home, 1 away
            let team: String       // team id, to keep one team's names apart from another's
            let words: [String]
            /// The abbreviation as written ("LAR"), for names that are one.
            let abbreviation: String?
            /// A city name ("Atlanta"): only counts when the league is known.
            let loose: Bool
        }

        private var byFirstWord: [String: [Name]] = [:]
        private(set) var teams: [SportsTeam] = []

        init(games: [SportsGame]) {
            for (gameIndex, game) in games.enumerated() {
                for (side, team) in [game.home, game.away].enumerated() {
                    add(team, slot: gameIndex, side: side, college: game.league == "College Football" || game.league == "College Basketball")
                }
            }
        }

        /// A plain list (school logos): full names and places only.
        init(teams list: [SportsTeam]) {
            teams = list
            for (index, team) in list.enumerated() {
                add(team, slot: index, side: 0, college: true, abbreviations: false)
            }
        }

        private mutating func add(_ team: SportsTeam, slot: Int, side: Int, college: Bool, abbreviations: Bool = true) {
            var seen = Set<String>()
            for variant in SportsMatcher.teamVariants(team, college: college) {
                let words = variant.split(separator: " ").map(String.init)
                guard let first = words.first, seen.insert(variant).inserted else { continue }
                byFirstWord[first, default: []].append(Name(slot: slot, side: side, team: team.id, words: words, abbreviation: nil, loose: false))
            }
            // Pro teams' city ("Atlanta vs. Chicago"), only when the league is known.
            if !college, let location = team.location {
                let variant = SportsMatcher.normalized(location).trimmingCharacters(in: .whitespaces)
                let words = variant.split(separator: " ").map(String.init)
                if let first = words.first, variant.count >= 4, seen.insert(variant).inserted {
                    byFirstWord[first, default: []].append(Name(slot: slot, side: side, team: team.id, words: words, abbreviation: nil, loose: true))
                }
            }
            if abbreviations, let short = team.short?.trimmingCharacters(in: .whitespaces), short.count >= 2, short.count <= 5 {
                let word = short.lowercased()
                if seen.insert(word).inserted {
                    byFirstWord[word, default: []].append(Name(slot: slot, side: side, team: team.id, words: [word],
                                                               abbreviation: short.uppercased(), loose: false))
                }
            }
        }

        private struct Hit {
            let name: Name
            let start: Int
            let end: Int
            var length: Int { end - start }
        }

        private func hits(_ title: String, allowed: (Int) -> Bool, allowLoose: (Int) -> Bool) -> (hits: [Hit], written: Set<String>) {
            let words = SportsMatcher.normalized(title).split(separator: " ").map(String.init)
            guard words.count >= 2 else { return ([], []) }
            // Words as written, for "abbreviations count only in capitals".
            // In an all-capitals title every word looks like an abbreviation,
            // so none counts on its own there.
            let allCaps = !title.contains(where: { $0.isLowercase })
            let written: Set<String> = allCaps ? [] : Set(title.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
            var hits: [Hit] = []
            for position in words.indices {
                guard let names = byFirstWord[words[position]] else { continue }
                for name in names where allowed(name.slot) && (!name.loose || allowLoose(name.slot)) {
                    let end = position + name.words.count
                    guard end <= words.count, Array(words[position..<end]) == name.words else { continue }
                    hits.append(Hit(name: name, start: position, end: end))
                }
            }
            // The longest name wins its words: "michigan state" keeps
            // "michigan" (another team) from counting.
            let kept = hits.filter { hit in
                !hits.contains { other in
                    other.name.team != hit.name.team && other.length > hit.length && other.start <= hit.start && other.end >= hit.end
                }
            }
            return (kept, written)
        }

        /// Games whose two teams both appear in `title`, on separate words.
        /// `allowLoose`: the event's league is the game's, so city names and
        /// two-letter abbreviations ("NJ") count too.
        func matches(_ title: String, allowed: (Int) -> Bool, allowLoose: (Int) -> Bool = { _ in false }) -> [Int] {
            let (kept, written) = hits(title, allowed: allowed, allowLoose: allowLoose)
            guard kept.count >= 2 else { return [] }
            var byGame: [Int: [Hit]] = [:]
            for hit in kept { byGame[hit.name.slot, default: []].append(hit) }
            var result: [Int] = []
            for (game, list) in byGame {
                let home = list.filter { $0.name.side == 0 }
                let away = list.filter { $0.name.side == 1 }
                let loose = allowLoose(game)
                func strong(_ hit: Hit) -> Bool {
                    guard let abbreviation = hit.name.abbreviation else { return true }
                    guard written.contains(abbreviation) else { return false }
                    return abbreviation.count >= 3 || loose
                }
                func full(_ hit: Hit) -> Bool { hit.name.abbreviation == nil }
                var found = false
                for h in home where !found {
                    for a in away where !found {
                        guard h.end <= a.start || a.end <= h.start else { continue }
                        // An abbreviation in lower case only counts next to a full name.
                        if (strong(h) && strong(a)) || (full(h) && a.name.abbreviation != nil) || (full(a) && h.name.abbreviation != nil) {
                            found = true
                        }
                    }
                }
                if found { result.append(game) }
            }
            return result.sorted()
        }

        /// Two different teams of a plain list named in `title` (left side
        /// first), each by a full name or place of 4+ letters.
        func pair(_ title: String) -> (SportsTeam, SportsTeam)? {
            let (kept, _) = hits(title, allowed: { _ in true }, allowLoose: { _ in false })
            let strong = kept.filter { $0.name.words.joined(separator: " ").count >= 4 }.sorted { $0.start < $1.start }
            // Exactly two schools, on separate words; more is ambiguous.
            guard Set(strong.map(\.name.team)).count == 2, let first = strong.first,
                  let second = strong.first(where: { $0.name.team != first.name.team && $0.start >= first.end }),
                  first.name.slot < teams.count, second.name.slot < teams.count else { return nil }
            return (teams[first.name.slot], teams[second.name.slot])
        }
    }

    // MARK: Names

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// Lower-case words separated by single spaces, padded with spaces so
    /// whole-word checks are a plain `contains(" word ")`.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        var out = ""
        var lastSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return " " + out.trimmingCharacters(in: .whitespaces) + " "
    }

    private static let genericWords: Set<String> = ["fc", "cf", "sc", "afc", "club", "city", "united", "the", "team", "state",
                                                    "university", "college", "real", "athletic", "sporting", "new", "san", "los", "las", "st"]

    /// Ways a team is written: full name, short names, the nickname (last
    /// word or two); the place name only for college teams ("Utah").
    static func teamVariants(_ team: SportsTeam, college: Bool) -> [String] {
        var names = [team.name] + team.alternates
        if college, let location = team.location { names.append(location) }
        let words = normalized(team.name).split(separator: " ").map(String.init)
        if words.count >= 2 {
            let last = words[words.count - 1]
            if last.count >= 4, !genericWords.contains(last) { names.append(last) }
            let lastTwo = words.suffix(2).joined(separator: " ")
            if !genericWords.contains(words[words.count - 2]) { names.append(lastTwo) }
        }
        var seen = Set<String>()
        return names.map { normalized($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && !genericWords.contains($0) && seen.insert($0).inserted }
    }

    /// The event's league is known and is the game's (soccer and MLS as one).
    /// A sport named without its level ("Football: …") covers its pro and
    /// college leagues.
    static let sportFamilies: [String: Set<String>] = [
        "Football": ["NFL", "College Football"],
        "Basketball": ["NBA", "WNBA", "College Basketball"],
        "Hockey": ["NHL", "Hockey"],
        "Baseball": ["MLB", "MiLB", "Baseball"],
        "Soccer": ["Soccer", "MLS"],
        "MLS": ["Soccer", "MLS"],
    ]

    private static func sameLeague(_ league: String, _ game: SportsGame) -> Bool {
        if league.isEmpty || league == "Other" { return false }
        if league == game.league { return true }
        return sportFamilies[league]?.contains(game.league) == true
    }

    private static func compatible(_ league: String, _ game: SportsGame) -> Bool {
        if league.isEmpty || league == "Other" || league == game.league { return true }
        return sportFamilies[league]?.contains(game.league) == true
    }

    /// Studio and highlight shows around a game, not the game itself.
    private static func excluded(_ text: String) -> Bool {
        [" pregame ", " pre game ", " postgame ", " post game ", " countdown ", " preview ", " highlights ", " replay ",
         " classic ", " encore ", " rewind ", " recap ", " press conference ", " kickoff show ", " tonight ", " live from "]
            .contains { text.contains($0) }
    }

    /// "rams|seahawks" for "Rams vs Seahawks" or "Seahawks @ Rams".
    static func pairKey(_ title: String) -> String? {
        let cleaned = title.rxReplace("^[A-Za-z+ ]{2,20}:\\s*", with: "").rxReplace("\\([^)]*\\)?", with: " ")
        let parts = cleaned.components(separatedBy: " ")
        guard let split = parts.firstIndex(where: { ["vs", "vs.", "v", "at", "@", "-"].contains($0.lowercased()) }),
              split > 0, split < parts.count - 1 else { return nil }
        let a = normalized(parts[..<split].joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        let b = normalized(parts[(split + 1)...].joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return [a, b].sorted().joined(separator: "|")
    }

    private static func closeEnough(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) <= 90 * 60
    }

    static func shortLeague(_ league: String) -> String {
        switch league {
        case "College Football": return "NCAAF"
        case "College Basketball": return "NCAAB"
        case "Motorsport": return "MOTOR"
        case "Fighting": return "FIGHT"
        case "Field Hockey": return "FIELD H."
        case "Volleyball": return "VOLLEY"
        case "Lacrosse": return "LAX"
        case "Wrestling": return "WREST."
        case "": return "EVENT"
        default: return league.uppercased()
        }
    }
}
