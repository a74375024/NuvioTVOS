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
struct SportsEvent: Identifiable, Hashable {
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

    static func == (lhs: SportsEvent, rhs: SportsEvent) -> Bool {
        lhs.id == rhs.id && lhs.sources == rhs.sources && lhs.game == rhs.game
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var channels: [EventSource] { sources.filter { $0.kind != .provider } }
    var feeds: [EventSource] { sources.filter { $0.kind == .provider } }

    /// Rough length by sport; past it a game "may have ended", and a while
    /// after that it's dropped from Live now.
    var expectedLength: TimeInterval {
        switch league {
        case "NFL", "College Football": return 3.6 * 3600
        case "MLB": return 3.1 * 3600
        case "NBA", "WNBA", "NHL", "College Basketball": return 2.6 * 3600
        case "Soccer", "MLS": return 2.1 * 3600
        case "Fighting": return 5 * 3600
        case "Motorsport", "Golf": return 4 * 3600
        default: return 2.5 * 3600
        }
    }

    enum State: Equatable {
        case upcoming, live, mayHaveEnded, finished, postponed, unknownTime
    }

    func state(at now: Date) -> State {
        if let game {
            if game.postponed { return .postponed }
            if game.isFinished { return .finished }
        }
        guard let start else { return .unknownTime }
        if now < start { return .upcoming }
        let end = start.addingTimeInterval(expectedLength)
        if now < end { return .live }
        if now < end.addingTimeInterval(30 * 60) { return .mayHaveEnded }
        return game == nil ? .finished : .mayHaveEnded
    }

    /// Fraction of the expected length gone by (for the progress bar).
    func progress(at now: Date) -> Double {
        guard let start else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / expectedLength))
    }
}

/// Matches TheSportsDB games with provider event feeds and guide listings.
/// Pure and off the main thread.
enum SportsMatcher {
    struct GuideListing {
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

    static func build(games: [SportsGame], events: [ProviderEvent], listings: [GuideListing],
                      preferSpanish: Bool, now: Date) -> [SportsEvent] {
        let variants = Dictionary(games.map { ($0.id, (teamVariants($0.home), teamVariants($0.away))) }, uniquingKeysWith: { a, _ in a })
        var byGame: [String: SportsEvent] = [:]
        var unmatched: [ProviderEvent] = []

        // 1. Provider event feeds → games.
        for event in events {
            let text = normalized(event.title)
            var best: (SportsGame, TimeInterval)?
            for game in games {
                guard compatible(event.league, game), let pair = variants[game.id],
                      contains(text, pair.0), contains(text, pair.1) else { continue }
                let gap: TimeInterval
                if let start = event.start {
                    gap = abs(start.timeIntervalSince(game.start))
                    guard gap <= 3 * 3600 else { continue }
                } else {
                    guard game.start > now.addingTimeInterval(-6 * 3600), game.start < now.addingTimeInterval(18 * 3600) else { continue }
                    gap = abs(game.start.timeIntervalSince(now))
                }
                if best == nil || gap < best!.1 { best = (game, gap) }
            }
            guard let game = best?.0 else { unmatched.append(event); continue }
            var value = byGame[game.id] ?? SportsEvent(
                id: "sev|\(game.id)", title: game.title, league: game.league, leagueShort: game.leagueShort,
                start: game.start, game: game, sources: [], family: event.family
            )
            for feed in event.feeds where !value.sources.contains(where: { $0.channelID == feed }) {
                value.sources.append(EventSource(channelID: feed, kind: .provider, spanish: event.spanish,
                                                 detail: "Provider event channel"))
            }
            byGame[game.id] = value
        }

        // 2. Guide listings → games (only the game itself, not the shows around it).
        let relevant = games.filter { !$0.isFinished && $0.start > now.addingTimeInterval(-5 * 3600) && $0.start < now.addingTimeInterval(16 * 3600) }
        if !relevant.isEmpty {
            for listing in listings {
                let text = normalized(listing.title)
                guard !excluded(text) else { continue }
                for game in relevant {
                    let windowStart = game.start.addingTimeInterval(-15 * 60)
                    let windowEnd = game.start.addingTimeInterval(2 * 3600)
                    guard listing.start < windowEnd, listing.end > windowStart,
                          let pair = variants[game.id], contains(text, pair.0), contains(text, pair.1) else { continue }
                    var value = byGame[game.id] ?? SportsEvent(
                        id: "sev|\(game.id)", title: game.title, league: game.league, leagueShort: game.leagueShort,
                        start: game.start, game: game, sources: [], family: nil
                    )
                    if !value.sources.contains(where: { $0.channelID == listing.entryID }) {
                        let time = timeFormatter.string(from: listing.start)
                        value.sources.append(EventSource(
                            channelID: listing.entryID, kind: listing.inLineup ? .lineup : .guide, spanish: listing.spanish,
                            detail: listing.inLineup ? "In My Lineup · \(time)" : "In your guide · \(time)"
                        ))
                    }
                    byGame[game.id] = value
                }
            }
        }

        // Games with no way to watch still show (schedule, results).
        for game in games where byGame[game.id] == nil {
            byGame[game.id] = SportsEvent(
                id: "sev|\(game.id)", title: game.title, league: game.league, leagueShort: game.leagueShort,
                start: game.start, game: game, sources: [], family: nil
            )
        }

        // 3. Provider events that matched no game: grouped forgivingly
        // (either team order, start within 90 minutes).
        var loose: [SportsEvent] = []
        for event in unmatched {
            let key = pairKey(event.title)
            if let key, let index = loose.firstIndex(where: { other in
                pairKey(other.title) == key && closeEnough(other.start, event.start)
            }) {
                for feed in event.feeds where !loose[index].sources.contains(where: { $0.channelID == feed }) {
                    loose[index].sources.append(EventSource(channelID: feed, kind: .provider, spanish: event.spanish,
                                                            detail: "Provider event channel"))
                }
                continue
            }
            loose.append(SportsEvent(
                id: event.id, title: event.title, league: event.league, leagueShort: shortLeague(event.league),
                start: event.start, game: nil,
                sources: event.feeds.map { EventSource(channelID: $0, kind: .provider, spanish: event.spanish, detail: "Provider event channel") },
                family: event.family
            ))
        }

        // Source order: My Lineup, other guide channels, provider feeds;
        // Spanish after English unless the viewer picked US Spanish.
        func ordered(_ sources: [SportsEvent]) -> [SportsEvent] {
            sources.map { event in
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
        }
        var seenIDs = Set<String>()
        let unique = (Array(byGame.values) + loose).filter { seenIDs.insert($0.id).inserted }
        return ordered(unique).sorted {
            switch ($0.start, $1.start) {
            case let (a?, b?): return a == b ? $0.title < $1.title : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title < $1.title
            }
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

    /// Ways a team is written: full name, alternates, the nickname (last
    /// word or two), and its abbreviation (3+ letters).
    static func teamVariants(_ team: SportsTeam) -> [String] {
        var names = [team.name] + team.alternates
        let words = normalized(team.name).split(separator: " ").map(String.init)
        if words.count >= 2 {
            let last = words[words.count - 1]
            if last.count >= 4, !genericWords.contains(last) { names.append(last) }
            let lastTwo = words.suffix(2).joined(separator: " ")
            if !genericWords.contains(words[words.count - 2]) { names.append(lastTwo) }
        }
        if let short = team.short, short.count >= 3 { names.append(short) }
        var seen = Set<String>()
        return names.map { normalized($0) }.filter { $0.count > 3 && seen.insert($0).inserted }
    }

    static func contains(_ text: String, _ variants: [String]) -> Bool {
        variants.contains { text.contains($0) }
    }

    private static func compatible(_ league: String, _ game: SportsGame) -> Bool {
        if league.isEmpty || league == "Other" || league == game.league { return true }
        let soccer: Set<String> = ["Soccer", "MLS"]
        return soccer.contains(league) && soccer.contains(game.league)
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
        case "": return "EVENT"
        default: return league.uppercased()
        }
    }
}
