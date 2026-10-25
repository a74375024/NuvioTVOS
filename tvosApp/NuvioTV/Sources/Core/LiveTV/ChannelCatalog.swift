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

/// What a raw channel is, before anything is matched.
enum ChannelKind: String, Codable {
    case channel
    /// An event slot (PPV, ESPN+, league pass…): Live Events, never My Lineup.
    case event
    /// "NO EVENT STREAMING", "tvg-id=…", "ENDED |…": hidden.
    case placeholder
    /// "#### PRIME ####" headings some providers put in their lists: hidden.
    case separator
    /// 24/7 loops of one show or genre.
    case loop247
    /// Free ad-supported streaming channels (Pluto, Roku, Prime, Tubi…).
    case fast
    case radio
}

/// Everything learned from one channel's name and provider group.
struct ChannelTraits: Codable {
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
    var kind: ChannelKind = .channel
    /// "US", "US-ES" (Spanish-language US), "MX", "UK"…; nil when unknown.
    var market: String?
    /// Core US network this is ("CNN"), if any.
    var core: String?
    /// "national", "local" (call sign), "team", or "regional:<place>".
    var scope = "national"
}

/// A real-world channel: one guide entry with its variants as backups.
struct LiveTVEntryInfo: Codable {
    let id: String              // "e|<cluster key>"
    let name: String
    var members: [String]       // raw channel ids, best first
    let category: LineupCategory
    let callsign: String?
    let country: String?
    let virtualNumber: Int?     // e.g. 11 for "NBC 11"
    var kind: ChannelKind = .channel
    var market: String?
    var core: String?
    var scope = "national"
}

/// One live event, deduplicated across event families.
struct LiveEvent: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let league: String
    let start: Date?
    var feeds: [String]         // raw channel ids, best first
    let family: String
    var market: String? = nil
    /// The title gave only a clock time ("8:20pm"), so the day is a guess
    /// (today). Matching against the schedule decides the real day.
    var startGuessed: Bool? = nil

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
struct EventFamily: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    var feeds: [String]         // raw channel ids, by feed number
    let hasNames: Bool          // feed names carry event titles
    let league: String
    var market: String? = nil
}

/// Turns a raw channel list into entries, event families and events. Works
/// from naming conventions common to IPTV lineups rather than any one
/// provider's exact format.
enum ChannelCatalog {
    struct Result: Codable {
        var traits: [String: ChannelTraits] = [:]
        var entries: [LiveTVEntryInfo] = []
        var entryOf: [String: String] = [:]
        var families: [EventFamily] = []
        var events: [LiveEvent] = []
    }

    // MARK: Build

    static func build(_ channels: [LiveTVChannel], now: Date = Date(), stations: [OutsideGuide.Station] = []) -> Result {
        var result = Result()
        // Pass 0: which call signs are real here (the station directory, plus
        // signs seen in local groups or next to a network name), and each
        // sign's usual network.
        let context = CallsignContext(channels: channels, stations: stations)
        // Pass 1: traits and candidate event families.
        var familyCounts: [String: Int] = [:]
        var familySeparators: [String: Int] = [:]
        for channel in channels {
            let traits = traitsFor(channel, context: context)
            result.traits[channel.id] = traits
            if let family = traits.familyKey {
                familyCounts[family, default: 0] += 1
                if traits.hasSeparator { familySeparators[family, default: 0] += 1 }
            }
        }
        // A family is either large (15+ numbered feeds) or clearly event slots
        // (5+ feeds, most named "NN: …" / "NN | …"). This keeps numbered
        // regular channels ("beIN Sports 4", "Fox 23") out. Event slots
        // grouped by their provider group always count.
        func isFamily(_ key: String) -> Bool {
            if key.hasPrefix("grp:") { return true }
            let count = familyCounts[key] ?? 0
            return count >= 15 || (count >= 5 && (familySeparators[key] ?? 0) * 10 >= count * 4)
        }
        for channel in channels {
            guard var traits = result.traits[channel.id] else { continue }
            if let family = traits.familyKey, !isFamily(family) {
                traits.familyKey = nil
                traits.familyNumber = nil
                traits.eventText = nil
            }
            // Event slots (and placeholders in event groups) outside a
            // numbered family: one family per provider group.
            let group = channel.group ?? channel.tags.first ?? ""
            if traits.familyKey == nil,
               traits.kind == .event || (traits.kind == .placeholder && isEventGroup(group.lowercased())) {
                traits.familyKey = "grp:" + group.lowercased()
                traits.familyNumber = trailingNumber(channel.name)
                traits.eventText = channel.name
                traits.hasSeparator = true
            }
            if traits.familyKey != nil, traits.kind == .channel { traits.kind = .event }
            result.traits[channel.id] = traits
        }

        // Pass 2: entries (clusters of variants).
        var clusters: [String: [LiveTVChannel]] = [:]
        var order: [String] = []
        for channel in channels {
            guard let traits = result.traits[channel.id] else { continue }
            if traits.familyKey != nil { continue }
            // Placeholders and headings outside event groups are hidden.
            if traits.kind == .placeholder || traits.kind == .separator || traits.kind == .event { continue }
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
            let name: String
            if let core = traits.core {
                name = traits.isWest ? "\(core) West" : core
            } else {
                name = bestDisplayName(ranked.compactMap { result.traits[$0.id]?.displayName })
            }
            result.entries.append(LiveTVEntryInfo(
                id: id, name: name, members: ranked.map(\.id),
                category: traits.category, callsign: traits.callsign, country: traits.country,
                virtualNumber: virtualNumber(in: name),
                kind: traits.kind, market: traits.market, core: traits.core, scope: traits.scope
            ))
            for member in ranked { result.entryOf[member.id] = id }
        }

        // Pass 3: event families and events.
        (result.families, result.events) = buildEvents(channels, traits: result.traits, now: now)
        return result
    }

    /// Event families (numbered event feeds and event-slot groups) and the
    /// events they carry, from channels whose traits name a family.
    static func buildEvents(_ channels: [LiveTVChannel], traits: [String: ChannelTraits], now: Date) -> (families: [EventFamily], events: [LiveEvent]) {
        var familyMembers: [String: [LiveTVChannel]] = [:]
        var familyOrder: [String] = []
        for channel in channels {
            guard let family = traits[channel.id]?.familyKey else { continue }
            if familyMembers[family] == nil { familyOrder.append(family) }
            familyMembers[family, default: []].append(channel)
        }
        var families: [EventFamily] = []
        var eventsByKey: [String: LiveEvent] = [:]
        for family in familyOrder {
            guard let members = familyMembers[family] else { continue }
            let sorted = members.sorted {
                (traits[$0.id]?.familyNumber ?? 0) < (traits[$1.id]?.familyNumber ?? 0)
            }
            let market = sorted.lazy.compactMap { traits[$0.id]?.market }.first
            var named = 0
            let league = leagueFor(family: family, group: sorted.first?.group ?? "", title: "")
            for channel in sorted {
                guard let text = traits[channel.id]?.eventText, !isPlaceholder(text),
                      traits[channel.id]?.kind != .placeholder,
                      !RX.test("^\\W*(ended|end)\\b", text, caseInsensitive: true) else { continue }
                named += 1
                let parsed = parseEventDetailed(text, now: now, market: market)
                let title = parsed.title, start = parsed.start
                guard !title.isEmpty else { continue }
                if let start, now.timeIntervalSince(start) > 8 * 3600 { continue }       // long over
                if let start, start.timeIntervalSince(now) > 6 * 24 * 3600 { continue }  // stale or far off
                let eventLeague = leagueFor(family: family, group: channel.group ?? "", title: title)
                let key = eventKey(title: title, start: start)
                if var existing = eventsByKey[key] {
                    existing.feeds.append(channel.id)
                    eventsByKey[key] = existing
                } else {
                    var event = LiveEvent(
                        id: "ev|\(key)", title: title, league: eventLeague, start: start,
                        feeds: [channel.id], family: family, market: market
                    )
                    // Always set when there's a time (nil means "saved by an older build").
                    if start != nil { event.startGuessed = parsed.guessed }
                    eventsByKey[key] = event
                }
            }
            families.append(EventFamily(
                id: "fam|\(family)", name: familyDisplayName(sorted.first, family: family),
                feeds: sorted.map(\.id), hasNames: named * 4 >= sorted.count, league: league, market: market
            ))
        }
        let events = eventsByKey.values.sorted {
            switch ($0.start, $1.start) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title < $1.title
            }
        }
        return (families, events)
    }

    /// After a refresh in which only event slots were renamed (the same
    /// channels, regular channels unchanged): re-reads those slots and
    /// rebuilds Live Events, without classifying everything again.
    static func refreshEvents(_ result: inout Result, channels: [LiveTVChannel], renamed: [LiveTVChannel], now: Date = Date()) {
        for channel in renamed {
            guard var traits = result.traits[channel.id], let family = traits.familyKey else { continue }
            let fresh = traitsFor(channel, context: .empty)
            if family.hasPrefix("grp:") {
                traits.eventText = channel.name
                traits.familyNumber = trailingNumber(channel.name)
            } else if fresh.familyKey == family {
                traits.eventText = fresh.eventText
                traits.familyNumber = fresh.familyNumber
            } else {
                traits.eventText = channel.name
            }
            switch fresh.kind {
            case .placeholder: traits.kind = .placeholder
            case .channel, .event: traits.kind = .event
            default: traits.kind = fresh.kind
            }
            traits.displayName = fresh.displayName
            result.traits[channel.id] = traits
        }
        (result.families, result.events) = buildEvents(channels, traits: result.traits, now: now)
    }

    // MARK: Traits

    private static let qualityTokens: [(String, Int)] = [("uhd", 3), ("4k", 3), ("fhd", 2), ("1080", 2), ("hd", 1), ("720", 1), ("sd", 0)]
    private static let dropTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "backup", "alt", "vip", "raw", "feed", "usa", "us", "east", "e"
    ]

    /// Which call signs are real in this lineup, and each one's network.
    struct CallsignContext {
        var known: Set<String> = []
        var networkOf: [String: String] = [:]
        var stationsByNetwork: [String: [OutsideGuide.Station]] = [:]

        static let empty = CallsignContext()

        init() {}

        init(channels: [LiveTVChannel], stations: [OutsideGuide.Station]) {
            var counts: [String: [String: Int]] = [:]
            for station in stations {
                known.insert(station.callsign)
                counts[station.callsign, default: [:]][station.network, default: 0] += 1
            }
            stationsByNetwork = Dictionary(grouping: stations, by: \.network)
            for channel in channels {
                let group = channel.group ?? channel.tags.first ?? ""
                let strong = group.lowercased().contains("local")
                    || RX.test("^\\s*US\\s*\\|\\s*(NBC|FOX|CBS|ABC|CW|PBS)\\b", group)
                let network = ChannelCatalog.networkWord(channel.name)
                for candidate in ChannelCatalog.callsignCandidates(channel.name) {
                    if strong || (network != nil && candidate.inParens) { known.insert(candidate.sign) }
                    if let network { counts[candidate.sign, default: [:]][network, default: 0] += 3 }
                }
            }
            networkOf = counts.compactMapValues { $0.max { $0.value < $1.value }?.key }
        }
    }

    static func traitsFor(_ channel: LiveTVChannel, context: CallsignContext = .empty) -> ChannelTraits {
        let name = channel.name
        let lower = name.lowercased()
        let rawGroup = channel.group ?? channel.tags.first ?? ""
        let group = rawGroup.lowercased()

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
        let country = countryFor(name: name, lower: lower, rawGroup: rawGroup, group: group,
                                 xtream: channel.serverID.hasPrefix("xt:"))
        var market = country
        if country == "US", isSpanishUS(name: name, group: group) { market = "US-ES" }
        let display = cleanName(name)
        let core = market == "US" ? coreMatch(display) : nil
        var kind = kindFor(name: name, lower: lower, group: group, isCore: core != nil)

        // Event family?
        var familyKey: String?
        var familyNumber: Int?
        var eventText: String?
        var hasSeparator = false
        let isLocalish = group.contains("local") || RX.test("\\([kw][a-z]{2,3}\\b", lower)
        if core == nil, kind != .separator, !isLocalish || kind == .event, let family = familyParts(name) {
            familyKey = family.key
            familyNumber = family.number
            eventText = family.rest
            hasSeparator = family.separator
        }

        // Call sign: only real ones (station directory, local groups, or
        // written next to a network name), never for other countries.
        var callsign: String?
        if kind == .channel, core == nil, familyKey == nil, country == nil || country == "US" {
            let candidates = callsignCandidates(name).filter { context.known.contains($0.sign) || group.contains("local") }
            callsign = (candidates.first { $0.inParens } ?? candidates.first)?.sign
            // "FOX 2 LOCAL SAN FRANCISCO": network + city → the station.
            if callsign == nil, networkWord(display) != nil, !isNationalish(display), !context.stationsByNetwork.isEmpty {
                callsign = OutsideGuide.stationCallsign(for: display, stations: context.stationsByNetwork)
            }
        }
        if familyKey != nil, kind == .channel { kind = .event }

        let key: String
        if kind == .event || kind == .placeholder || kind == .separator {
            key = "x:\(channel.id)"
        } else if let core {
            key = "core:\(core.name)" + (isWest ? "~west" : "")
        } else if let callsign {
            // Subchannels and sister stations stay apart: WGBC-NBC ≠ WGBC-FOX.
            key = "cs:\(callsign)|\(networkWord(name) ?? context.networkOf[callsign] ?? "")"
        } else {
            let normalized = OutsideGuide.normalize(display)
            // Never merged across countries: a Mexican feed isn't a backup for a US one.
            key = "n:\(market ?? "?"):\(normalized.isEmpty ? lower : normalized)\(isWest && !normalized.hasSuffix("~west") ? "~west" : "")"
        }

        let scope: String
        if core != nil {
            scope = "national"
        } else if callsign != nil {
            scope = "local"
        } else if market == "US" || market == "US-ES" {
            scope = scopeFor(display)
        } else {
            scope = "national"
        }

        let category: LineupCategory
        switch kind {
        case .fast, .loop247: category = .free
        case .radio: category = .radio
        default:
            if let market, market != "US", market != "US-ES" {
                category = .international
            } else if market == "US-ES" {
                category = .spanish
            } else if let core {
                category = core.category
            } else if callsign != nil || (scope.hasPrefix("regional") && networkWord(display) != nil && !isNationalish(display)) {
                category = .local
            } else {
                category = categoryFor(lower: lower, group: group, country: country, callsign: nil)
            }
        }
        var traits = ChannelTraits(
            clusterKey: key, displayName: core.map { isWest ? "\($0.name) West" : $0.name } ?? display,
            quality: quality, sourceTag: sourceTag,
            callsign: callsign, isWest: isWest, country: country, category: category,
            familyKey: familyKey, familyNumber: familyNumber, eventText: eventText, hasSeparator: hasSeparator
        )
        traits.kind = kind
        traits.market = market
        traits.core = core?.name
        traits.scope = scope
        return traits
    }

    // MARK: Classification

    /// Country from the provider's group prefix ("US| …", Xtream), the
    /// group's name, or a name prefix ("(US)", "MEX:", "UK |").
    private static let countryCodes: Set<String> = [
        "US", "UK", "CA", "MX", "AR", "ES", "FR", "DE", "IT", "NL", "SE", "NO", "DK", "FI", "PL", "PT", "BR", "TR", "AL",
        "IR", "IL", "GR", "CZ", "SK", "HU", "RO", "BG", "HR", "RS", "BA", "MK", "ME", "AT", "CH", "BE", "IE", "AU", "NZ",
        "PH", "ID", "TH", "IN", "PK", "RU", "UA", "MA", "AE", "SA", "EG", "CO", "VE", "PE", "CL", "EC", "DO", "PR", "VN",
        "JP", "KR", "CN", "HK", "TW", "MY", "SG", "LB", "QA", "KW", "TN", "DZ", "NG", "ZA", "KE", "GH", "HN", "GT", "SV",
        "NI", "CR", "PA", "UY", "PY", "BO", "CU", "JM", "LT", "LV", "EE", "SI", "CY", "IS", "LU", "MT", "AM", "GE", "AZ",
        "KZ", "UZ", "AF", "BD", "LK", "NP"
    ]
    private static let threeLetterCodes: [String: String] = [
        "USA": "US", "MEX": "MX", "CAN": "CA", "GBR": "UK", "ARG": "AR", "ESP": "ES", "FRA": "FR", "DEU": "DE",
        "GER": "DE", "ITA": "IT", "BRA": "BR", "POR": "PT"
    ]

    private static func countryFor(name: String, lower: String, rawGroup: String, group: String, xtream: Bool) -> String? {
        if xtream, let regex = RX.get("^\\s*([A-Z0-9]{2,5})\\s*\\|"),
           let match = regex.firstMatch(in: rawGroup, range: NSRange(rawGroup.startIndex..<rawGroup.endIndex, in: rawGroup)),
           let range = Range(match.range(at: 1), in: rawGroup) {
            let code = String(rawGroup[range])
            if code.first?.isNumber == true { return nil }       // "4K|", "8K|" blocks
            return code == "GB" ? "UK" : code
        }
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
        for pattern in ["^\\s*\\(([A-Za-z]{2,3})\\)", "^\\s*([A-Z]{2,3})\\s*[:|]", "^\\s*(USA?)\\s"] {
            guard let regex = RX.get(pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
                  let range = Range(match.range(at: 1), in: name) else { continue }
            var code = String(name[range]).uppercased()
            code = threeLetterCodes[code] ?? code
            if code == "VT" { return "VN" }
            if code == "GB" { return "UK" }
            if countryCodes.contains(code) { return code }
        }
        if group.hasPrefix("us") || group.contains("usa") || group.contains("united states") { return "US" }
        return nil
    }

    /// US channels in Spanish (Univision, Telemundo, ESPN Deportes…).
    private static func isSpanishUS(name: String, group: String) -> Bool {
        RX.test("\\b(univision|unimas|unimás|telemundo|galavision|galavisión|estrella|azteca|telehit|cine ?latino|deportes|tudn|vix|discovery familia|pasiones|de pel[ií]cula|sorpresa|latino|espa[nñ]ola?|noticias|universo|nuestra tele|wapa|tr3s|bandamax|ritmoson|cnn en espa)",
                name, caseInsensitive: true)
            || RX.test("latino|telemundo|univision|spanish|espa[nñ]ol|hispan", group)
    }

    /// Provider groups that hold event slots rather than channels.
    static func isEventGroup(_ group: String) -> Bool {
        RX.test("\\bppv\\b|event|league pass|espn ?\\+|espn plus|\\bdazn\\b|\\bflo|ncaa|uefa|formula|\\bf1\\b|hbo max|vidio|monomax|\\bnfl\\b|\\bnba\\b|\\bnhl\\b|\\bmlb\\b|\\bmls\\b|\\bwnba\\b|\\bmilb\\b|^football$|replay|sport on air", group)
    }

    private static func isEventish(_ name: String) -> Bool {
        RX.test("\\b(vs\\.?|v)\\b|\\s@\\s|\\bat\\b.*\\d|^(next|live|ended|end|now|upcoming)\\s*\\||\\b\\d{1,2}([:.]\\d\\d)?\\s*(am|pm)\\b|\\b\\d{1,2}:\\d{2}\\b|\\bevent\\s*\\d{1,3}\\b|\\bppv\\s*\\d{1,3}\\b",
                name, caseInsensitive: true)
    }

    static func kindFor(name: String, lower: String, group: String, isCore: Bool) -> ChannelKind {
        if RX.test("^\\s*(#{2,}|={2,}|-{3,}|\\*{2,}|▬|━|═|~{2,})|#{3,}\\s*$", name) { return .separator }
        if RX.test("no event|no stream|no games?\\b|no live|offline|off ?air|coming soon|^\\W*ended\\b|^\\W*end\\s*\\||tvg-id=|2098 12 31|2099 01 0", lower) {
            return .placeholder
        }
        // A numbered slot ("NCAAF 16: USA NETWORK") is an event even when it names a network.
        if RX.test("^\\W*[A-Za-z+][A-Za-z+ ()]{1,20}?\\s*\\d{1,3}\\s*\\)?\\s*[:|]", name) { return .event }
        if isCore { return .channel }
        if isEventGroup(group), RX.test("\\b\\d{1,3}\\b", name) || isEventish(name) || cleanName(name).count < 4 { return .event }
        if RX.test("^(next|live|ended|end|now|upcoming)\\s*\\||\\bevent\\s*\\d{1,3}\\b|\\bppv\\s*\\d{1,3}\\b", lower) { return .event }
        // "NCAAF 16 Auburn at Georgia 3:30PM": league word, slot number, event.
        if RX.test("^[A-Za-z+]{2,12}( [A-Za-z+]{2,12})?\\s+\\d{1,3}\\s+", name), isEventish(name) { return .event }
        if name.contains("24/7") || group.contains("24/7") || RX.test("\\b247\\b", lower) { return .loop247 }
        if RX.test("\\b(prime|roku|tubi|pluto|samsung|plex|xumo|free tv|fast|netflix on air|vizio|local now|distro|stirr)\\b", group)
            || RX.test("^\\s*\\((pluto[^)]*|rk|roku|tubi|samsung[^)]*|plex|xumo)\\)|^\\s*(pluto|roku|tubi|prime|samsung|plex|xumo)[^:]{0,8}:", name, caseInsensitive: true) {
            return .fast
        }
        if group.contains("radio") || RX.test("\\b(radio|iheart)\\b", lower) { return .radio }
        return .channel
    }

    /// Call sign candidates ("KTVU", "KGO" in parentheses, "KABC-DT") and
    /// whether each was written in parentheses.
    static func callsignCandidates(_ name: String) -> [(sign: String, inParens: Bool)] {
        let upper = name.uppercased()
        guard let regex = RX.get("(?<![A-Z0-9])([KW][A-Z]{2,3})(?:[- ]?(DT|TV|LD|LP|CD|CA)\\d?)?(?![A-Z0-9])") else { return [] }
        var found: [(sign: String, inParens: Bool)] = []
        for match in regex.matches(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper)) {
            guard let signRange = Range(match.range(at: 1), in: upper) else { continue }
            let sign = String(upper[signRange])
            let inParens = signRange.lowerBound > upper.startIndex && upper[upper.index(before: signRange.lowerBound)] == "("
            // Three-letter call signs (KGO, WGN) only in parentheses or with a suffix.
            guard sign.count == 4 || inParens || match.range(at: 2).location != NSNotFound else { continue }
            if !found.contains(where: { $0.sign == sign }) { found.append((sign, inParens)) }
        }
        return found
    }

    /// The broadcast network named in a channel name, normalized.
    static func networkWord(_ name: String) -> String? {
        guard let regex = RX.get("\\b(ABC|CBS|NBC|FOX|CW|PBS|MYTV|MyNetworkTV|ION|Telemundo|Univision|UniMas|Independent|IND|TMO)\\b", caseInsensitive: true),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        switch name[range].uppercased() {
        case "TMO": return "TELEMUNDO"
        case "MYNETWORKTV": return "MYTV"
        case "IND": return "INDEPENDENT"
        case let other: return other
        }
    }

    /// Names that use a network word but aren't a local station.
    private static func isNationalish(_ name: String) -> Bool {
        RX.test("\\b(sports?|news|soul|business|weather|kids|deportes|life|movies?|classics?|now|live)\\b", name, caseInsensitive: true)
    }

    /// "team" (NFL Buffalo Bills), "regional:<place>" (FOX 5 [SAN DIEGO],
    /// NBC Sports Boston), or "national".
    private static func scopeFor(_ display: String) -> String {
        if RX.test("^\\s*\\(?(nfl|nba|nhl|mlb|mls|wnba)\\)?\\s+(\\([A-Z]{2,4}\\)\\s+)?[A-Za-z]", display, caseInsensitive: true) {
            return "team"
        }
        if let regex = RX.get(RegionWords.pattern, caseInsensitive: true),
           let match = regex.firstMatch(in: display, range: NSRange(display.startIndex..<display.endIndex, in: display)),
           let range = Range(match.range(at: 1), in: display) {
            return "regional:" + display[range].lowercased()
        }
        if networkWord(display) != nil, !isNationalish(display) { return "regional:?" }
        return "national"
    }

    /// A channel name reduced for matching core networks: lower-case words,
    /// "&" → "and", "+" → "plus", quality tags and "East" dropped.
    static func coreKey(_ display: String) -> (key: String, west: Bool) {
        let lowered = display.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        let tokens = lowered.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
        let drop: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "8k", "hevc", "h265", "h264", "raw", "vip", "60fps", "50fps",
                                 "1080p", "720p", "1080", "720", "backup", "east", "feed", "alt"]
        let west = tokens.contains("west") || tokens.contains("pacific")
        let kept = tokens.filter { !drop.contains($0) && $0 != "west" && $0 != "pacific" }
        return (kept.joined(separator: " "), west)
    }

    static func coreMatch(_ display: String) -> (name: String, category: LineupCategory)? {
        let key = coreKey(display).key
        if let hit = CoreChannels.byAlias[key] { return hit }
        // "NAT GEO WILD HD US": a leading / trailing US marker.
        let trimmed = key.split(separator: " ").filter { $0 != "us" && $0 != "usa" }.joined(separator: " ")
        if trimmed != key, !trimmed.isEmpty, let hit = CoreChannels.byAlias[trimmed] { return hit }
        return nil
    }

    static func trailingNumber(_ name: String) -> Int? {
        guard let range = RX.range("\\d{1,4}(?=\\D*$)", in: name) else { return nil }
        return Int(name[range])
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
        if callsign != nil { return .local }
        // Racing feeds and onboard cameras ("(Apple F1 CAM) Ferrari …", "… Driver Cam").
        if group.contains("formula") || has(lower, ["formula ?1", "formula one", "f1", "f1 cam", "f1 tv cam", "motogp", "nascar", "indycar",
                                                    "driver cam", "driver tracker", "driver data", "mixed on board"]) {
            return .sports
        }
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
        // Superscript markers ("ᴿᴬᵂ ⁶⁰ᶠᵖˢ ⱽᴵᴾ"), "ⓧ".
        var s = name.rxReplace("[\\x{1D2C}-\\x{1D6A}\\x{1D78}-\\x{1DBF}\\x{2070}-\\x{209F}\\x{2C7D}\\x{24B6}-\\x{24E9}\\x{02B0}-\\x{02FF}ⓧ]", with: "")
        // Provider prefixes in capitals: "TV:", "AT&T:", "PRIME:", "PL VIP:".
        s = s.rxReplace("^\\s*[A-Z0-9&+]{1,8}(\\s[A-Z0-9&+]{1,6})?\\s*:\\s+(?=\\S{2})", with: "")
        let patterns = [
            "^\\s*(\\([A-Za-z0-9 ]{1,14}\\)\\s*)+",           // (US) (A)
            "^\\s*(USA?|US|REG|MEX|MX|UK|CA)\\s*[:|]\\s*",    // US: / USA |
            "^\\s*(USA?|US)\\s+",                             // US / USA
            "^\\s*\\[[^\\]]{1,30}\\]\\s*",                    // [Denver]
            "\\s*\\((A|H|D|S|P|SP|RK|GT|DZ|XV|F|X|Prime|SD|HD|FHD|UHD|4K|Backup)\\)",
            "\\s*\\(\\d{3,4}p[^)]*\\)",                        // (720p29 @ 3.2Mbps)
            "\\b(FHD|UHD|4K|8K|HEVC|RAW|VIP|60FPS|50FPS)\\b",
            "\\bBackup\\b",
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
        if family.hasPrefix("grp:") {
            // A provider group of event slots: its name without the country prefix.
            let group = first?.group ?? String(family.dropFirst(4))
            let cleaned = cleanName(group.rxReplace("^\\s*[A-Z0-9]{2,5}\\s*\\|\\s*", with: ""))
                .rxReplace("\\s{2,}", with: " ").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? group : cleaned
        }
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
    /// The zone a provider writes unmarked times in, from its country tag.
    static func eventZone(market: String?) -> TimeZone? {
        let id: String?
        switch market?.uppercased() {
        case "AU": id = "Australia/Sydney"
        case "NZ": id = "Pacific/Auckland"
        case "UK", "GB", "IE": id = "Europe/London"
        case "MX": id = "America/Mexico_City"
        case "CA": id = "America/Toronto"
        case "ES": id = "Europe/Madrid"
        case "FR": id = "Europe/Paris"
        case "DE": id = "Europe/Berlin"
        case "IT": id = "Europe/Rome"
        case "NL": id = "Europe/Amsterdam"
        case "PT": id = "Europe/Lisbon"
        case "BR": id = "America/Sao_Paulo"
        default: id = nil
        }
        return id.flatMap { TimeZone(identifier: $0) }
    }

    static func parseEvent(_ text: String, now: Date, market: String? = nil) -> (String, Date?) {
        let parsed = parseEventDetailed(text, now: now, market: market)
        return (parsed.title, parsed.start)
    }

    /// As `parseEvent`, plus whether the day was guessed (a clock time only).
    static func parseEventDetailed(_ text: String, now: Date, market: String? = nil) -> (title: String, start: Date?, guessed: Bool) {
        var title = text
        var start: Date?
        var guessed = false
        let usEastern = TimeZone(identifier: "America/New_York") ?? .current
        // Unmarked times follow the provider's country when it has one;
        // otherwise US formats are Eastern and European formats UK time.
        let providerZone = eventZone(market: market)
        let eastern = providerZone ?? usEastern
        let london = providerZone ?? TimeZone(identifier: "Europe/London") ?? .current
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
        /// AM/PM times are a US habit (a UK provider writes "Oct 22 08:15 PM"
        /// for an 8:15 PM ET kickoff), so they're US Eastern. Providers that
        /// differ are corrected by the offset learned from scheduled games.
        func zoneOf(_ r: Range<String.Index>) -> TimeZone { usEastern }
        func groups(_ pattern: String) -> ([String], Range<String.Index>)? {
            guard let regex = RX.get(pattern, caseInsensitive: true),
                  let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)),
                  let whole = Range(m.range, in: title) else { return nil }
            let parts = (1..<m.numberOfRanges).map { i -> String in
                Range(m.range(at: i), in: title).map { String(title[$0]) } ?? ""
            }
            return (parts, whole)
        }

        // Provider decorations: "NEXT |" / "LIVE |" status, "| 8K EXCLUSIVE | US: ESPN+ PPV 951"
        // tail, "LIVE EVENT 01 -" / "NFL | 06" slot heads, ":Paramount+  07" service tails.
        title = title.rxReplace("^\\W*(next|live|now|upcoming)\\s*\\|\\s*", with: "", caseInsensitive: true)
        title = title.rxReplace("\\|\\s*8K EXCLUSIV.*$", with: "", caseInsensitive: true)
        title = title.rxReplace("^\\s*live event\\s*\\d{1,3}\\s*-?\\s*", with: "", caseInsensitive: true)
        title = title.rxReplace("^\\s*[A-Za-z+]{2,10}\\s*\\|\\s*\\d{1,3}\\s*-?\\s*", with: "")
        title = title.rxReplace("\\s:\\s?[A-Za-z][\\w+ ]{0,24}?\\s+\\d{1,3}\\s*$", with: "")
        // Fri 23 Oct 18:00 EDT (US) / Fri 23 Oct 02:05 CEST (SE) / … 19:40 +03 (SA)
        if let (p, r) = groups("(?:[A-Za-z]{3}\\s+)?(\\d{1,2})\\s+([A-Za-z]{3})\\s+(\\d{1,2}):(\\d{2})\\s+(?!AM\\b|PM\\b)([A-Z]{2,5}|[+-]\\d{2})(?:\\s*\\([A-Z]{2}\\))?") {
            let offsets: [String: Int] = ["EDT": -4, "EST": -5, "CDT": -5, "CST": -6, "MDT": -6, "MST": -7, "PDT": -7, "PST": -8,
                                          "GMT": 0, "UTC": 0, "BST": 1, "CET": 1, "CEST": 2, "EET": 2, "EEST": 3, "MSK": 3,
                                          "AEST": 10, "AEDT": 11]
            let zoneText = p[4].uppercased()
            let hours = offsets[zoneText] ?? Int(zoneText)
            if let d = Int(p[0]), let mo = months[p[1].lowercased()], let h = Int(p[2]), let mi = Int(p[3]),
               let hours, let zone = TimeZone(secondsFromGMT: hours * 3600) {
                start = nearestYear(mo, d, h, mi, zone)
                title.removeSubrange(r)
            }
        }
        // … | 2026-10-18 | 15:30 (GMT)  /  22-10-2026 | 00:00 (GMT)
        if start == nil, let (p, r) = groups("(\\d{4})-(\\d{2})-(\\d{2})\\s*\\|?\\s*(\\d{1,2}):(\\d{2})\\s*\\((?:GMT|UTC)\\)") {
            if let y = Int(p[0]), let mo = Int(p[1]), let d = Int(p[2]), let h = Int(p[3]), let mi = Int(p[4]) {
                start = date(y, mo, d, h, mi, TimeZone(identifier: "UTC") ?? london)
            }
            title.removeSubrange(r)
        }
        if start == nil, let (p, r) = groups("(\\d{2})-(\\d{2})-(\\d{4})\\s*\\|?\\s*(\\d{1,2}):(\\d{2})\\s*\\((?:GMT|UTC)\\)") {
            if let d = Int(p[0]), let mo = Int(p[1]), let y = Int(p[2]), let h = Int(p[3]), let mi = Int(p[4]) {
                start = date(y, mo, d, h, mi, TimeZone(identifier: "UTC") ?? london)
            }
            title.removeSubrange(r)
        }
        // Oct 22 20:45 (24-hour, no AM/PM): provider time, taken as UK.
        if start == nil, let (p, r) = groups("\\b([A-Za-z]{3}) (\\d{1,2}) (\\d{1,2}):(\\d{2})\\b(?!\\s*(?:AM|PM))") {
            if let mo = months[p[0].lowercased()], let d = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, h, mi, london)
            }
            title.removeSubrange(r)
        }
        // (2026 10 21 19:30:55), (2026-10-22 15:00:25) or "start:2026 10 17 20:25:00 stop:…"
        if start == nil, let (p, r) = groups("(?:\\(|start:\\s*)(\\d{4})[ -](\\d{2})[ -](\\d{2})[ T](\\d{2}):(\\d{2})(?::\\d{2})?\\)?(?:\\s*stop:\\s*[\\d :-]+)?") {
            if let y = Int(p[0]), y < 2090, let mo = Int(p[1]), let d = Int(p[2]), let h = Int(p[3]), let mi = Int(p[4]) {
                start = date(y, mo, d, h, mi, eastern)
            }
            title.removeSubrange(r)
        }
        // "- 22/10 11:30" (24-hour): day/month, or month/day when only that
        // reads as a date; when both do, the one nearer today.
        if start == nil, let (p, r) = groups("(?:^|\\s)-?\\s*(\\d{1,2})/(\\d{1,2})\\s+(\\d{1,2}):(\\d{2})\\b(?!\\s*(?:AM|PM))") {
            if let a = Int(p[0]), let b = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]), h < 24, mi < 60 {
                var options: [Date] = []
                if b >= 1, b <= 12, a >= 1, a <= 31, let d = nearestYear(b, a, h, mi, eastern) { options.append(d) }
                if a >= 1, a <= 12, b >= 1, b <= 31, let d = nearestYear(a, b, h, mi, eastern) { options.append(d) }
                start = options.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
            }
            title.removeSubrange(r)
        }
        // (10.21 7:30PM ET)
        if start == nil, let (p, r) = groups("\\((\\d{1,2})\\.(\\d{1,2}) (\\d{1,2}):(\\d{2})\\s*(AM|PM)(?: ET)?\\)") {
            if let mo = Int(p[0]), let d = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, hour24(h, p[4]), mi, zoneOf(r))
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
                start = nearestYear(mo, d, hour24(h, p[4]), mi, zoneOf(r))
            }
            title.removeSubrange(r)
        }
        // Oct 21 2:30AM ET
        if start == nil, let (p, r) = groups("\\b([A-Za-z]{3})[a-z]*\\.? (\\d{1,2}),? (\\d{1,2}):(\\d{2})\\s*(AM|PM)(?:\\s*ET)?") {
            if let mo = months[p[0].lowercased()], let d = Int(p[1]), let h = Int(p[2]), let mi = Int(p[3]) {
                start = nearestYear(mo, d, hour24(h, p[4]), mi, zoneOf(r))
            }
            title.removeSubrange(r)
        } else if let (_, r) = groups("\\b[A-Za-z]{3}[a-z]*\\.? \\d{1,2},? \\d{1,2}:\\d{2}\\s*(AM|PM)(?:\\s*ET)?") {
            title.removeSubrange(r)
        }
        // "12PM" / "730PM" / "7:30 PM ET" / "8.30 PM ET" → that day when the
        // title names one ("02:00PM UFC 333 … (OCT 24)"), else today (Eastern).
        if start == nil, let (p, r) = groups("\\b(\\d{1,2})(?:[:.]?(\\d{2}))?\\s*(AM|PM)(?:\\s*ET)?\\b") {
            title.removeSubrange(r)
            if let h = Int(p[0]) {
                let mi = Int(p[1]) ?? 0
                let zone = zoneOf(r)
                if let (dp, dr) = groups("\\(?\\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\.?\\s+(\\d{1,2})\\b\\)?"),
                   let mo = months[String(dp[0].lowercased().prefix(3))], let d = Int(dp[1]), d >= 1, d <= 31 {
                    start = nearestYear(mo, d, hour24(h, p[2]), mi, zone)
                    title.removeSubrange(dr)
                } else {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = zone
                    let today = cal.dateComponents([.year, .month, .day], from: now)
                    if let y = today.year, let mo = today.month, let d = today.day {
                        start = date(y, mo, d, hour24(h, p[2]), mi, zone)
                        guessed = start != nil
                    }
                }
            }
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
        title = title.rxReplace("\\s*@\\s*$", with: "")
        title = title.rxReplace("\\s*\\|\\s*", with: " · ")
        title = title.rxReplace("^[A-Za-z]{3}, \\d{1,2}/\\d{1,2}\\s+", with: "")
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|-–:,")))
        return (title, start, guessed)
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
        let titleText = title.lowercased()
        let text = "\(family) \(group) \(title)".lowercased()
        // 1. A sport named at the start of the title ("Football: …",
        // "volleyball:  …") says more than the channel's group.
        if let range = RX.range("^\\s*[a-z][a-z ]{1,20}(?=:)", in: titleText) {
            let sport = titleText[range].trimmingCharacters(in: .whitespaces)
            switch sport {
            // Level unknown → the plain sport, which matches pro and college games.
            case "football", "american football":
                if text.contains("nfl") { return "NFL" }
                return RX.test("\\b(ncaa|ncaaf|college|fbs|fcs)\\b", text) ? "College Football" : "Football"
            case "basketball":
                if text.contains("wnba") { return "WNBA" }
                if RX.test("\\bnba\\b", text) { return "NBA" }
                return RX.test("\\b(ncaa|ncaab|ncaam|ncaaw|college|men's|women's)\\b", text) ? "College Basketball" : "Basketball"
            case "hockey", "ice hockey": return text.contains("nhl") ? "NHL" : "Hockey"
            case "field hockey": return "Field Hockey"
            case "volleyball", "beach volleyball": return "Volleyball"
            case "soccer", "fc", "football soccer": return "Soccer"
            case "baseball": return text.contains("mlb") ? "MLB" : "Baseball"
            case "softball": return "Softball"
            case "lacrosse": return "Lacrosse"
            case "wrestling": return "Wrestling"
            default: break
            }
        }
        // 2. Words anywhere. A "PPV" group says nothing about the sport, so
        // it no longer makes everything in it "Fighting".
        let rules: [(String, [String])] = [
            ("NFL", ["nfl", "football: good morning football"]),
            ("College Football", ["ncaaf", "college football", "fbs", "fcs"]),
            ("WNBA", ["wnba"]),
            ("NBA", ["nba", "basketball: nba"]),
            ("College Basketball", ["ncaab", "college basketball", "men's basketball", "women's basketball"]),
            ("MiLB", ["milb"]),
            ("MLB", ["mlb"]),
            ("Field Hockey", ["field hockey"]),
            ("NHL", ["nhl"]),
            ("Hockey", ["hockey"]),
            ("Baseball", ["baseball"]),
            ("MLS", ["mls"]),
        ]
        for (league, words) in rules where words.contains(where: { text.contains($0) }) { return league }
        // Fights before soccer, as whole words: soccer's "fc " also matches
        // the end of "ufc " (UFC cards were landing in Soccer).
        if RX.test(Self.fightWords, text) { return "Fighting" }
        let laterRules: [(String, [String])] = [
            ("Soccer", ["uefa", "premier league", "champions league", "la liga", "laliga", "serie a", "bundesliga", "ligue1", "ligue 1", "football event", "soccer", "fc ", " united", "liga", "eredivisie", "a-league", "concacaf", "nwsl"]),
            ("Motorsport", ["f1", "formula", "nascar", "indycar", "motogp", "rally", "wrc", "supercross", "motocross"]),
            ("Tennis", ["wta", "atp", "tennis"]),
            ("Golf", ["pga", "lpga", "golf", "liv "]),
            ("Darts", ["pdc", "darts"]),
            ("Cricket", ["cricket", "ipl"]),
            ("Rugby", ["rugby", "nrl"]),
            ("Volleyball", ["volleyball"])
        ]
        for (league, words) in laterRules where words.contains(where: { text.contains($0) }) { return league }
        return "Other"
    }

    /// Fight promotions and terms, as whole words.
    /// ("ufc_ppv" and "ufc333" count; "Boxing Day" football doesn't.)
    static let fightWords = "\\b(ufc|bkfc|pfl)(\\b|_|\\d)|\\b(mma|bellator|wwe|aew|kickboxing|muay thai)\\b|\\bboxing\\b(?! day)"
        + "|fight night|one fight|combat fc|fight pass|fightpass"
}
