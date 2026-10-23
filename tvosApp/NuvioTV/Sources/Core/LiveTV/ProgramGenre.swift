import Foundation

/// Sorts guide programs into Movies / Sports / News / Kids (the same bits as
/// `OutsideGuide.RawProgram.f`). Guides tag programs when they can: XMLTV
/// `<category>`, Emby's flags. The Xtream short guide has no categories at
/// all, so titles are read as well ("NFL Football", "Eyewitness News").
enum ProgramGenre {
    static let movie = 1
    static let sports = 2
    static let news = 4
    static let kids = 8
    static let genreBits = 15

    private static let movieWords = ["movie", "film", "cinema"]
    private static let sportsWords = [
        "sport", "football", "basketball", "baseball", "hockey", "soccer", "golf", "tennis", "boxing",
        "wrestling", "mixed martial", "mma", "racing", "motorsport", "olympic", "rugby", "cricket",
        "volleyball", "softball", "lacrosse", "bowling", "skiing", "swimming", "athletics", "cycling",
        "gymnastics", "track and field", "rodeo", "billiards", "darts", "poker"
    ]
    private static let newsWords = ["news", "weather", "public affairs", "current affairs", "newsmagazine"]
    private static let kidsWords = ["kids", "children", "animation", "animated", "cartoon", "preschool"]

    /// From XMLTV categories (lowercased, joined with spaces).
    static func flags(categories joined: String) -> Int {
        guard !joined.isEmpty else { return 0 }
        var flags = 0
        if movieWords.contains(where: joined.contains) { flags |= movie }
        if sportsWords.contains(where: joined.contains) { flags |= sports }
        if newsWords.contains(where: joined.contains) { flags |= news }
        if kidsWords.contains(where: joined.contains) { flags |= kids }
        return flags
    }

    private static let sportsTitle = "\\b(NFL|NBA|WNBA|MLB|MiLB|NHL|MLS|NWSL|NCAA[A-Z]*|UFC|WWE|AEW|PGA|LPGA|NASCAR|IndyCar|MotoGP|Formula 1|F1|UEFA|FIFA|Premier League|Champions League|La Liga|Serie A|Bundesliga|Ligue 1|Super Bowl|World Series|Stanley Cup|SportsCenter|Pregame|Postgame|Pre-Game|Post-Game)\\b"
        + "|\\b(College |Pro |High School |Women's |Men's )?(Football|Basketball|Baseball|Hockey|Soccer|Softball|Volleyball|Lacrosse|Golf|Tennis|Boxing|Rugby|Cricket|Auto Racing|Horse Racing|Bowling|Gymnastics|Wrestling)\\b"
    private static let newsTitle = "\\b(news|newscast|newsroom|newsnight|newshour|good morning america|cbs mornings|meet the press|face the nation|this week with|60 minutes|20/20|dateline|nightline|first alert|eyewitness|action news|weather)\\b|^today( show)?(\\b(?!['’])|$)"

    /// From a program's title (and episode title) when a guide gives no
    /// categories. Only sports and news can be told from titles.
    static func flags(title: String, episode: String? = nil) -> Int {
        let text = episode.map { "\(title) \($0)" } ?? title
        var flags = 0
        if RX.test(sportsTitle, text, caseInsensitive: true) { flags |= sports }
        if RX.test(newsTitle, title, caseInsensitive: true) { flags |= news }
        return flags
    }

    /// Fills in genre flags a program doesn't have yet, from its title.
    static func withTitleFlags(_ program: LiveTVProgram) -> LiveTVProgram {
        guard !program.isMovie, !program.isSports, !program.isNews, !program.isKids else { return program }
        let flags = flags(title: program.title, episode: program.episodeTitle)
        guard flags != 0 else { return program }
        var updated = program
        updated.isSports = flags & sports != 0
        updated.isNews = flags & news != 0
        return updated
    }

    /// Genre tags from `other` for programs in `list` that have none: guides
    /// for the same channel often differ only in which one tags programs.
    static func mergeFlags(_ list: [LiveTVProgram], from other: [LiveTVProgram]) -> [LiveTVProgram] {
        guard !other.isEmpty else { return list }
        let tagged = other.filter { $0.isMovie || $0.isSports || $0.isNews || $0.isKids }
        guard !tagged.isEmpty else { return list }
        return list.map { program in
            guard !program.isMovie, !program.isSports, !program.isNews, !program.isKids else { return program }
            let length = program.end.timeIntervalSince(program.start)
            guard length > 0, let match = tagged.first(where: { candidate in
                min(candidate.end, program.end).timeIntervalSince(max(candidate.start, program.start)) > length / 2
            }) else { return program }
            var updated = program
            updated.isMovie = match.isMovie
            updated.isSports = match.isSports
            updated.isNews = match.isNews
            updated.isKids = match.isKids
            return updated
        }
    }
}
