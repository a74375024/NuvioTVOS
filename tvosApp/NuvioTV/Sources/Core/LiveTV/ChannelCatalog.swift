import Foundation

/// Compiled-regex cache: channel-name analysis runs the same patterns over
/// thousands of names, so each pattern is compiled once.
enum RX {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func get(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        cache[key] = regex
        return regex
    }

    static func test(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        guard let regex = get(pattern, caseInsensitive: caseInsensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    static func replace(_ text: String, _ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = get(pattern, caseInsensitive: caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: template)
    }

    static func range(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> Range<String.Index>? {
        guard let regex = get(pattern, caseInsensitive: caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return Range(match.range, in: text)
    }
}

extension String {
    /// Regex replace through the compiled-pattern cache.
    func rxReplace(_ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        RX.replace(self, pattern, with: template, caseInsensitive: caseInsensitive)
    }
}

/// What kind of channel an entry is, for building a lineup.
enum LineupCategory: String, CaseIterable, Codable, Identifiable {
    case local, news, sports, entertainment, movies, kids, music, spanish, free, international, radio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local stations"
        case .news: return "News"
        case .sports: return "Sports networks"
        case .entertainment: return "Entertainment"
        case .movies: return "Movies & premium"
        case .kids: return "Kids & family"
        case .music: return "Music"
        case .spanish: return "Spanish-language"
        case .free: return "Free streaming channels"
        case .international: return "International"
        case .radio: return "Radio"
        }
    }

    var detail: String {
        switch self {
        case .local: return "ABC, CBS, NBC, FOX, PBS and other stations in your market"
        case .news: return "CNN, Fox News, MSNBC, CNBC, Weather and more"
        case .sports: return "ESPN, FS1, NFL Network, regional sports for your area"
        case .entertainment: return "Cable networks: USA, TNT, HGTV, Food, Discovery…"
        case .movies: return "HBO, Showtime, Starz, Cinemax, MGM+, TCM…"
        case .kids: return "Disney, Nickelodeon, Cartoon Network, PBS Kids…"
        case .music: return "MTV, CMT, BET Jams and music channels"
        case .spanish: return "Univision, Telemundo, ESPN Deportes and other US Spanish channels"
        case .free: return "Pluto TV, Roku, Samsung TV Plus, Plex, Tubi channels"
        case .international: return "Channels from other countries"
        case .radio: return "Audio-only stations"
        }
    }

    /// Cable-style number blocks for My Lineup.
    var numberBlock: Int {
        switch self {
        case .local: return 1
        case .news: return 100
        case .sports: return 200
        case .entertainment: return 300
        case .movies: return 600
        case .kids: return 700
        case .music: return 750
        case .spanish: return 800
        case .free: return 1000
        case .international: return 2000
        case .radio: return 3000
        }
    }

    var symbol: String {
        switch self {
        case .local: return "antenna.radiowaves.left.and.right"
        case .news: return "newspaper"
        case .sports: return "sportscourt"
        case .entertainment: return "tv"
        case .movies: return "film"
        case .kids: return "teddybear"
        case .music: return "music.note"
        case .spanish: return "globe.americas"
        case .free: return "play.tv"
        case .international: return "globe"
        case .radio: return "radio"
        }
    }

    static let defaultOn: Set<LineupCategory> = [.local, .news, .sports, .entertainment, .movies, .kids, .music]
}

/// Everything learned from one channel's name and provider group.
struct ChannelTraits {
    var clusterKey: String
    var displayName: String
    var quality: Int            // 0 SD, 1 HD, 2 FHD, 3 UHD
    var sourceTag: String       // "(A)", "US:", "(RK)"… — which upstream it came from
    var callsign: String?
    var isWest: Bool
    var country: String?        // "US", "UK", "MX"… when known
    var category: LineupCategory
    var familyKey: String?      // numbered event family, e.g. "us (espn+ #)"
    var familyNumber: Int?
    var eventText: String?      // event part of the name, if any
    var hasSeparator = false    // "NN:" / "NN |" style event slot naming
}

/// A real-world channel: one guide entry with its variants as backups.
struct LiveTVEntryInfo {
    let id: String              // "e|<cluster key>"
    let name: String
    var members: [String]       // raw channel ids, best first
    let category: LineupCategory
    let callsign: String?
    let country: String?
    let virtualNumber: Int?     // e.g. 11 for "NBC 11"
}

/// One live event, deduplicated across event families.
struct LiveEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let league: String
    let start: Date?
    var feeds: [String]         // raw channel ids, best first
    let family: String

    static func == (lhs: LiveEvent, rhs: LiveEvent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Rough length by sport, for "live now".
    var expectedLength: TimeInterval {
        switch league {
        case "NFL", "College Football": return 3.75 * 3600
        case "MLB", "MiLB": return 3.25 * 3600
        case "Soccer", "NBA", "WNBA", "NHL", "College Basketball", "MLS": return 2.5 * 3600
        case "Fighting": return 5 * 3600
        case "Motorsport", "Golf": return 4 * 3600
        default: return 2.5 * 3600
        }
    }

    func isLive(at now: Date) -> Bool {
        guard let start else { return false }
        return start <= now && now < start.addingTimeInterval(expectedLength)
    }
}

/// A numbered family of event feeds ("ESPN PLUS 00–110").
struct EventFamily: Identifiable, Hashable {
    let id: String
    let name: String
    var feeds: [String]         // raw channel ids, by feed number
    let hasNames: Bool          // feed names carry event titles
    let league: String
}

/// Turns a raw channel list into entries, event families and events. Works
/// from naming conventions common to IPTV lineups rather than any one
/// provider's exact format.
enum ChannelCatalog {
    struct Result {
        var traits: [String: ChannelTraits] = [:]
        var entries: [LiveTVEntryInfo] = []
        var entryOf: [String: String] = [:]
        var families: [EventFamily] = []
        var events: [LiveEvent] = []
    }

    // MARK: Build

    static func build(_ channels: [LiveTVChannel], now: Date = Date()) -> Result {
        var result = Result()
        // Pass 1: traits and candidate event families.
        var familyCounts: [String: Int] = [:]
        var familySeparators: [String: Int] = [:]
        for channel in channels {
            let traits = traitsFor(channel)
            result.traits[channel.id] = traits
            if let family = traits.familyKey {
                familyCounts[family, default: 0] += 1
                if traits.hasSeparator { familySeparators[family, default: 0] += 1 }
            }
        }
        // A family is either large (15+ numbered feeds) or clearly event slots
        // (5+ feeds, most named "NN: …" / "NN | …"). This keeps numbered
        // regular channels ("beIN Sports 4", "Fox 23") out.
        func isFamily(_ key: String) -> Bool {
            let count = familyCounts[key] ?? 0
            return count >= 15 || (count >= 5 && (familySeparators[key] ?? 0) * 10 >= count * 4)
        }
        for channel in channels {
            guard var traits = result.traits[channel.id], let family = traits.familyKey else { continue }
            if !isFamily(family) {
                traits.familyKey = nil
                traits.familyNumber = nil
                traits.eventText = nil
                result.traits[channel.id] = traits
            }
        }

        // Pass 2: entries (clusters of variants).
        var clusters: [String: [LiveTVChannel]] = [:]
        var order: [String] = []
        var familyMembers: [String: [LiveTVChannel]] = [:]
        var familyOrder: [String] = []
        for channel in channels {
            guard let traits = result.traits[channel.id] else { continue }
            if let family = traits.familyKey {
                if familyMembers[family] == nil { familyOrder.append(family) }
                familyMembers[family, default: []].append(channel)
                continue
            }
            if clusters[traits.clusterKey] == nil { order.append(traits.clusterKey) }
            clusters[traits.clusterKey, default: []].append(channel)
        }
        for key in order {
            guard let members = clusters[key], let first = members.first, let traits = result.traits[first.id] else { continue }
            let ranked = members.sorted { a, b in
                let ta = result.traits[a.id], tb = result.traits[b.id]
                // Xtream versions first, server (Emby / Jellyfin) as backup.
                let xa = a.serverID.hasPrefix("xt:"), xb = b.serverID.hasPrefix("xt:")
                if xa != xb { return xa }
                if a.isFavorite != b.isFavorite { return a.isFavorite }
                if (ta?.isWest ?? false) != (tb?.isWest ?? false) { return !(ta?.isWest ?? false) }
                if (ta?.quality ?? 0) != (tb?.quality ?? 0) { return (ta?.quality ?? 0) > (tb?.quality ?? 0) }
                return a.name.count < b.name.count
            }
            let id = "e|\(key)"
            let name = bestDisplayName(ranked.compactMap { result.traits[$0.id]?.displayName })
            result.entries.append(LiveTVEntryInfo(
                id: id, name: name, members: ranked.map(\.id),
                category: traits.category, callsign: traits.callsign, country: traits.country,
                virtualNumber: virtualNumber(in: name)
            ))
            for member in ranked { result.entryOf[member.id] = id }
        }

        // Pass 3: event families and events.
        var eventsByKey: [String: LiveEvent] = [:]
        for family in familyOrder {
            guard let members = familyMembers[family] else { continue }
            let sorted = members.sorted {
                (result.traits[$0.id]?.familyNumber ?? 0) < (result.traits[$1.id]?.familyNumber ?? 0)
            }
            var named = 0
            let league = leagueFor(family: family, group: sorted.first?.group ?? "", title: "")
            for channel in sorted {
                guard let text = result.traits[channel.id]?.eventText, !isPlaceholder(text) else { continue }
                named += 1
                let (title, start) = parseEvent(text, now: now)
                guard !title.isEmpty else { continue }
                if let start, now.timeIntervalSince(start) > 8 * 3600 { continue }       // long over
                if let start, start.timeIntervalSince(now) > 6 * 24 * 3600 { continue }  // stale or far off
                let eventLeague = leagueFor(family: family, group: channel.group ?? "", title: title)
                let key = eventKey(title: title, start: start)
                if var existing = eventsByKey[key] {
                    existing.feeds.append(channel.id)
                    eventsByKey[key] = existing
                } else {
                    eventsByKey[key] = LiveEvent(
                        id: "ev|\(key)", title: title, league: eventLeague, start: start,
                        feeds: [channel.id], family: family
                    )
                }
            }
            result.families.append(EventFamily(
                id: "fam|\(family)", name: familyDisplayName(sorted.first, family: family),
                feeds: sorted.map(\.id), hasNames: named * 4 >= sorted.count, league: league
            ))
        }
        result.events = eventsByKey.values.sorted {
            switch ($0.start, $1.start) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title < $1.title
            }
        }
        return result
    }

    // MARK: Traits

    private static let qualityTokens: [(String, Int)] = [("uhd", 3), ("4k", 3), ("fhd", 2), ("1080", 2), ("hd", 1), ("720", 1), ("sd", 0)]
    private static let dropTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "backup", "alt", "vip", "raw", "feed", "usa", "us", "east", "e"
    ]

    static func traitsFor(_ channel: LiveTVChannel) -> ChannelTraits {
        let name = channel.name
        let lower = name.lowercased()
        let group = (channel.group ?? channel.tags.first ?? "").lowercased()

        // Source marker: trailing "(A)" style, or the leading prefix style.
        var sourceTag = ""
        if let match = RX.range("\\((a|h|d|s|p|sp|rk|gt|dz|xv|prime)\\)", in: lower) {
            sourceTag = String(lower[match])
        } else if let match = RX.range("^\\s*(usa?|us|reg|mex|mx|uk|ca)\\s*[:|]", in: lower) {
            sourceTag = String(lower[match]).trimmingCharacters(in: .whitespaces)
        }

        var quality = 1
        for (token, value) in qualityTokens where RX.test("\\b\(token)\\b", lower) {
            quality = value
            break
        }
        let isWest = RX.test("\\b(west|pacific)\\b", lower)
        let country = countryFor(lower: lower, group: group)

        // Event family?
        var familyKey: String?
        var familyNumber: Int?
        var eventText: String?
        var hasSeparator = false
        let isLocalish = group.contains("local") || RX.test("\\([kw][a-z]{2,3}\\b", lower)
        if !isLocalish, let family = familyParts(name) {
            familyKey = family.key
            familyNumber = family.number
            eventText = family.rest
            hasSeparator = family.separator
        }

        let callsign = OutsideGuide.callsigns(in: name, strongContext: group.contains("local"))
            .first ?? bareCallsign(name)
        let display = cleanName(name)
        let key: String
        if let callsign {
            key = "cs:\(callsign)"
        } else {
            let normalized = OutsideGuide.normalize(display)
            key = "n:\(normalized.isEmpty ? lower : normalized)\(isWest && !normalized.hasSuffix("~west") ? "~west" : "")"
        }
        let category = categoryFor(lower: lower, group: group, country: country, callsign: callsign)
        return ChannelTraits(
            clusterKey: key, displayName: display, quality: quality, sourceTag: sourceTag,
            callsign: callsign, isWest: isWest, country: country, category: category,
            familyKey: familyKey, familyNumber: familyNumber, eventText: eventText, hasSeparator: hasSeparator
        )
    }

    /// A call sign written on its own in capitals ("(US) (Prime) KAGS",
    /// "USA: WITI (FOX)"). Common words are excluded.
    static func bareCallsign(_ name: String) -> String? {
        let stop: Set<String> = ["WWE", "WNBA", "WEST", "WILD", "KIDS", "WORK", "WIRE", "WAVE", "WARS", "WOW", "KICK", "WINE", "WORD", "WEEK", "WGN", "KING"]
        let pattern = "(?<![A-Za-z0-9])([KW][A-Z]{2,3})(?:-(?:DT|TV|LD|CD)\\d?)?(?![A-Za-z0-9])"
        guard let regex = RX.get(pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        for match in regex.matches(in: name, range: range) {
            guard let r = Range(match.range(at: 1), in: name) else { continue }
            let sign = String(name[r])
            if !stop.contains(sign), sign.count == 4 { return sign }
        }
        return nil
    }

    /// "US (ESPN+ 006) | The Pat McAfee Show…", "ESPN+ 48: Title", "PPV 03",
    /// "DAZN UK | Event 7", "NCAAF 02 Florida @ Texas 12PM".
    static func familyParts(_ name: String) -> (key: String, number: Int, rest: String?, separator: Bool)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let patterns = [
            // head ending in a number, then ":" or "|" and the event (or nothing)
            "^(.{1,40}?\\d{1,3}\\s*ⓧ?\\)?)\\s*(?:[:|]\\s*(.*))?$",
            // "NCAAF 02 Florida @ Texas 12PM": short word prefix, number, text
            "^([A-Za-z+]{2,12}(?: [A-Za-z+]{2,12})?\\s+\\d{1,3})\\s+(.+)$"
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = RX.get(pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
                  let headRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let head = String(trimmed[headRange])
            guard let numberRange = RX.range("\\d{1,3}(?=\\D*$)", in: head),
                  let number = Int(head[numberRange]) else { continue }
            let key = head.lowercased()
                .rxReplace("\\d+", with: "#")
                .rxReplace("\\s+", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let rest = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]).trimmingCharacters(in: .whitespaces) }
            if index == 1 {
                // Word-prefix form only counts when the rest looks like an event.
                guard let rest, RX.test("\\b(vs\\.?|v\\.?|at)\\b|@|\\b\\d{1,2}([:.]\\d{2})?\\s*(am|pm)\\b",
                                        rest, caseInsensitive: true) else { continue }
            }
            let separator = index == 1 || RX.test("^.{1,40}?\\d{1,3}\\s*ⓧ?\\)?\\s*[:|]", trimmed)
            return (key, number, rest?.isEmpty == true ? nil : rest, separator)
        }
        return nil
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        if RX.test("no (scheduled )?events?|no games?|no live|not live|off ?air|2098 12 31|^\\W*$|^\\d+\\.?\\s*$", lower) {
            return true
        }
        return lower.trimmingCharacters(in: .whitespacesAndNewlines).count < 3
    }

    private static func countryFor(lower: String, group: String) -> String? {
        let groupMap: [(String, String)] = [
            ("mexico", "MX"), ("vietnam", "VN"), ("arabic", "AR"), ("indonesia", "ID"), ("thailand", "TH"),
            ("united kingdom", "UK"), ("canada", "CA"), ("india", "IN"), ("brazil", "BR"), ("spain", "ES"),
            ("france", "FR"), ("germany", "DE"), ("italy", "IT"), ("portugal", "PT"), ("philippines", "PH")
        ]
        for (word, code) in groupMap where group.contains(word) { return code }
        if let match = RX.range("^\\(pluto ([a-z]+)\\)", in: lower) {
            let place = String(lower[match]).replacingOccurrences(of: "(pluto ", with: "").replacingOccurrences(of: ")", with: "")
            return place == "usa" || place == "us" ? "US" : place.uppercased()
        }
        let prefixes: [(String, String)] = [
            ("^\\s*\\((us|usa)\\)", "US"), ("^\\s*(us|usa)\\b", "US"), ("^\\s*reg:", "US"),
            ("^\\s*\\(uk\\)|^\\s*uk\\s*[:|]", "UK"), ("^\\s*\\(mx\\)|^\\s*(mx|mex)\\s*[:|]", "MX"),
            ("^\\s*\\(ca\\)|^\\s*ca\\s*[:|]", "CA"), ("^\\s*\\(vt\\)", "VN"), ("^\\s*\\(it\\)", "IT"),
            ("^\\s*\\(de\\)", "DE"), ("^\\s*\\(es\\)", "ES"), ("^\\s*\\(fr\\)", "FR"), ("^\\s*\\(pt\\)", "PT")
        ]
        for (pattern, code) in prefixes where RX.test(pattern, lower) { return code }
        if group.hasPrefix("us") || group.contains("usa") || group.contains("united states") { return "US" }
        return nil
    }

    private static func has(_ lower: String, _ words: [String]) -> Bool {
        // One alternation per word list (compiled once, then cached).
        RX.test("\\b(?:" + words.joined(separator: "|") + ")\\b", lower)
    }

    private static func categoryFor(lower: String, group: String, country: String?, callsign: String?) -> LineupCategory {
        if group.contains("radio") || has(lower, ["radio", "iheart", "fm"]) { return .radio }
        if let country, country != "US" { return .international }
        if lower.hasPrefix("(pluto") || group.contains("roku") || group.contains("free tv") || has(lower, ["pluto", "\\(rk\\)", "samsung tv plus", "xumo", "tubi", "plex"]) || lower.contains("(rk)") {
            return .free
        }
        if callsign != nil || group.contains("local") { return .local }
        if has(lower, ["univision", "unimas", "telemundo", "galavision", "estrella", "azteca", "telehit", "cine latino", "deportes", "tudn", "vix", "discovery familia", "cinelatino", "pasiones", "de pelicula", "de película", "canal 22", "sorpresa"]) { return .spanish }
        if has(lower, ["cnn", "msnbc", "fox news", "cnbc", "bloomberg", "newsmax", "news", "weather", "c-span", "cspan", "hln", "newsnation", "fox business", "cheddar", "yahoo finance", "scripps", "euronews", "al jazeera", "local now"]) { return .news }
        if group.contains("sport") || has(lower, ["espn", "espn2", "espnu", "fox sports", "fs1", "fs2", "nfl", "nba", "mlb", "nhl", "golf", "tennis", "bein", "sportsnet", "sec network", "acc network", "big ten", "cbs sports", "tnt sports", "yes network", "nesn", "msg", "fanduel", "bally", "marquee", "root sports", "altitude", "nbc sports", "olympic", "outdoor", "racing", "fight", "ufc", "wwe", "dazn", "pac 12", "pac-12", "redbull", "red bull", "stadium", "draftkings", "fubo sports"]) {
            return .sports
        }
        if has(lower, ["disney", "nick", "nickelodeon", "nicktoons", "teennick", "cartoon", "boomerang", "baby ?first", "pbs kids", "universal kids", "discovery family", "kids", "toon"]) { return .kids }
        if has(lower, ["hbo", "cinemax", "showtime", "starz", "encore", "mgm\\+?", "epix", "tmc", "movie", "movies", "flix", "sundance", "ifc", "tcm", "fxm", "lmn", "cinebox", "film", "filmrise", "hallmark movies", "screenpix", "paramount\\+"]) { return .movies }
        if has(lower, ["mtv", "mtv2", "cmt", "bet jams", "music", "vevo", "stingray", "revolt", "axs", "palladia", "fuse"]) { return .music }
        return .entertainment
    }

    /// Display name without provider decorations: country / source prefixes,
    /// quality tags and source markers.
    static func cleanName(_ name: String) -> String {
        var s = name
        let patterns = [
            "^\\s*(\\([A-Za-z0-9 ]{1,12}\\)\\s*)+",           // (US) (A)
            "^\\s*(USA?|US|REG|MEX|MX|UK|CA)\\s*[:|]\\s*",    // US: / USA |
            "^\\s*(USA?|US)\\s+",                             // US / USA
            "^\\s*\\[[^\\]]{1,30}\\]\\s*",                    // [Denver]
            "\\s*\\((A|H|D|S|P|SP|RK|GT|DZ|XV|Prime|SD|HD|FHD|UHD|4K)\\)",
            "\\b(FHD|UHD|4K|HEVC)\\b",
            "\\s{2,}"
        ]
        for (index, pattern) in patterns.enumerated() {
            s = s.rxReplace(pattern, with: index == patterns.count - 1 ? " " : "", caseInsensitive: true)
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":|-")))
        return s.isEmpty ? name : s
    }

    private static func bestDisplayName(_ names: [String]) -> String {
        // Prefer a mixed-case, reasonably short name.
        let mixed = names.filter { $0 != $0.uppercased() }
        return (mixed.isEmpty ? names : mixed).min { $0.count < $1.count } ?? names.first ?? "Channel"
    }

    static func virtualNumber(in name: String) -> Int? {
        guard let regex = RX.get("\\b(?:ABC|CBS|NBC|FOX|PBS|CW|MyTV|MyNet|IND|TMO|Univision|Telemundo|UniMas)\\s+(\\d{1,2})\\b", caseInsensitive: true),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              let r = Range(match.range(at: 1), in: name) else { return nil }
        return Int(name[r])
    }

    private static func familyDisplayName(_ first: LiveTVChannel?, family: String) -> String {
        var name = family.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "ⓧ", with: "")
        name = name.rxReplace("[()|:]", with: " ")
            .rxReplace("\\s+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("us ") { name.removeFirst(3) }
        return name.uppercased() == name ? name : name.capitalized
    }

    // MARK: Events

    /// Title and start time from an event name. Handles the formats seen in
    /// IPTV lineups; times without a zone are US Eastern unless written
    /// European-style ("22 October 2026 17:45", taken as UK time).
    static func parseEvent(_ text: String, now: Date) -> (String, Date?) {
        var title = text
        var start: Date?
        let eastern = TimeZone(identifier: "America/New_York") ?? .current
        let london = TimeZone(identifier: "Europe/London") ?? .current
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let calendarYear = Calendar(identifier: .gregorian).component(.year, from: now)

        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ zone: TimeZone) -> Date? {
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            return cal.date(from: c)
        }
        func nearestYear(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ zone: TimeZone) -> Date? {
            let candidates = [calendarYear - 1, calendarYear, calendarYear + 1].compactMap { date($0, mo, d, h, mi, zone) }
            return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
        }
        func hour24(_ h: Int, _ ampm: String) -> Int {
            let pm = ampm.lowercased() == "pm"
            return h % 12 + (pm ? 12 : 0)
        }
        func groups(_ pattern: String) -> ([String], Range<String.Index>)? {
            guard let regex = RX.get(pattern, caseInsensitive: true),
                  let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)),
                  let whole = Range(m.range, in: title) else { return nil }
            let parts = (1..<m.numberOfRanges).map { i -> String in
                Range(m.range(at: i), in: title).map { String(title[$0]) } ?? ""
            }
            return (parts, whole)
        }

        // (2026 10 21 19:30:55) or "start:2026 10 17 20:25:00 stop:…"
        if let (p, r) = groups("(?:\\(|start:\\s*)(\\d{4}) (\\d{2}) (\\d{2}) (\\d{2}):(\\d{2})(?::\\d{2})?\\)?(?:\\s*stop:\\s*[\\d :]+)?") {
            if let y = Int(p[0]), y < 2090, let mo = Int(p[1]), let d = Int(p[2]), let h = Int(p[3]), let mi = Int(p[4]) {
                start = date(y, mo, d, h, mi, eastern)
            }
            title.removeSubrange(r)
        }
        // (10.21 7:30PM ET)
        if start == nil, let (p, r) = groups("\\((\\d{1,2})\\.(\\d{1,2}) (\\d{1,2}):(\\d{2})\\s*(AM|PM)(?: ET)?\\)") {
            if let mo = Int(p[0]), let d = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, hour24(h, p[4]), mi, eastern)
            }
            title.removeSubrange(r)
        }
        // [23.09 16:04] (day.month, European)
        if start == nil, let (p, r) = groups("\\[(\\d{1,2})\\.(\\d{1,2}) (\\d{1,2}):(\\d{2})\\]") {
            if let d = Int(p[0]), let mo = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, h, mi, london)
            }
            title.removeSubrange(r)
        }
        // Thursday, 22 October 2026 17:45
        if start == nil, let (p, r) = groups("(?:[A-Za-z]+,?\\s+)?(\\d{1,2})\\s+([A-Za-z]{3})[a-z]*\\s+(\\d{4})\\s+(\\d{1,2}):(\\d{2})") {
            if let d = Int(p[0]), let mo = months[p[1].lowercased()], let y = Int(p[2]), let h = Int(p[3]), let mi = Int(p[4]) {
                start = date(y, mo, d, h, mi, london)
            }
            title.removeSubrange(r)
        }
        // Wed 21st Oct 8:00PM ET
        if start == nil, let (p, r) = groups("(?:[A-Za-z]{3}\\s+)?(\\d{1,2})(?:st|nd|rd|th)\\s+([A-Za-z]{3})[a-z]*\\s+(\\d{1,2}):(\\d{2})\\s*(AM|PM)(?:\\s*ET)?") {
            if let d = Int(p[0]), let mo = months[p[1].lowercased()], let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, hour24(h, p[4]), mi, eastern)
            }
            title.removeSubrange(r)
        }
        // Oct 21 2:30AM ET
        if start == nil, let (p, r) = groups("\\b([A-Za-z]{3})[a-z]*\\.? (\\d{1,2}),? (\\d{1,2}):(\\d{2})\\s*(AM|PM)(?:\\s*ET)?") {
            if let mo = months[p[0].lowercased()], let d = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, hour24(h, p[4]), mi, eastern)
            }
            title.removeSubrange(r)
        } else if let (_, r) = groups("\\b[A-Za-z]{3}[a-z]*\\.? \\d{1,2},? \\d{1,2}:\\d{2}\\s*(AM|PM)(?:\\s*ET)?") {
            title.removeSubrange(r)
        }
        // "12PM" / "730PM" / "7:30 PM ET" / "8.30 PM ET" → today (Eastern)
        if start == nil, let (p, r) = groups("\\b(\\d{1,2})(?:[:.]?(\\d{2}))?\\s*(AM|PM)(?:\\s*ET)?\\b") {
            if let h = Int(p[0]) {
                let mi = Int(p[1]) ?? 0
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = eastern
                let today = cal.dateComponents([.year, .month, .day], from: now)
                if let y = today.year, let mo = today.month, let d = today.day {
                    start = date(y, mo, d, hour24(h, p[2]), mi, eastern)
                }
            }
            title.removeSubrange(r)
        }

        // Tidy: drop a trailing "(X)" that repeats the title, leading "ESPN+:"
        // style tags, separators and doubled spaces.
        title = title.rxReplace("\\s{2,}", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|-–:,")))
        if let open = title.lastIndex(of: "("), title.hasSuffix(")") {
            let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
            let outer = title[..<open]
            if outer.lowercased().contains(inner.lowercased().trimmingCharacters(in: .whitespaces)) || inner.trimmingCharacters(in: .whitespaces).isEmpty {
                title = String(outer).trimmingCharacters(in: .whitespaces)
            }
        }
        title = title.rxReplace("^(ESPN\\+|ESPN PLUS):\\s*", with: "", caseInsensitive: true)
        title = title.rxReplace("^[A-Za-z]{3}, \\d{1,2}/\\d{1,2}\\s+", with: "")
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|-–:,")))
        return (title, start)
    }

    private static func eventKey(title: String, start: Date?) -> String {
        let normalized = title.lowercased()
            .rxReplace("^[a-z+ ]{2,20}:\\s*", with: "")
            .rxReplace("\\([^)]*\\)?", with: "")
            .rxReplace("\\b(vs|v|at)\\b\\.?|@", with: " ")
            .rxReplace("\\(spanish\\)|\\(english\\)", with: "")
            .rxReplace("[^a-z0-9]+", with: "")
        let slot = start.map { Int($0.timeIntervalSince1970 / 1800) } ?? 0
        return "\(normalized)|\(slot)"
    }

    static func leagueFor(family: String, group: String, title: String) -> String {
        let text = "\(family) \(group) \(title)".lowercased()
        let rules: [(String, [String])] = [
            ("NFL", ["nfl", "football: good morning football"]),
            ("College Football", ["ncaaf", "college football", "fbs", "fcs"]),
            ("WNBA", ["wnba"]),
            ("NBA", ["nba", "basketball: nba"]),
            ("College Basketball", ["ncaab", "college basketball", "men's basketball", "women's basketball"]),
            ("MiLB", ["milb"]),
            ("MLB", ["mlb", "baseball"]),
            ("NHL", ["nhl", "hockey"]),
            ("MLS", ["mls"]),
            ("Soccer", ["uefa", "premier league", "champions league", "la liga", "laliga", "serie a", "bundesliga", "ligue1", "ligue 1", "football event", "soccer", "fc ", " united", "liga", "eredivisie", "a-league", "concacaf"]),
            ("Motorsport", ["f1", "formula", "nascar", "indycar", "motogp", "rally", "wrc", "supercross", "motocross"]),
            ("Fighting", ["ufc", "boxing", "mma", "fight night", "pfl", "one fight", "wwe", "aew", "bellator", "ppv"]),
            ("Tennis", ["wta", "atp", "tennis"]),
            ("Golf", ["pga", "lpga", "golf", "liv "]),
            ("Darts", ["pdc", "darts"]),
            ("Cricket", ["cricket", "ipl"]),
            ("Rugby", ["rugby", "nrl"]),
            ("Volleyball", ["volleyball"])
        ]
        for (league, words) in rules where words.contains(where: { text.contains($0) }) { return league }
        return "Other"
    }
}
