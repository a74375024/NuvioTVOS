import Foundation

/// Free TV listings from outside the user's server, gathered on the Apple TV
/// itself. While the app is open, a background-priority job downloads free
/// XMLTV guides, streams through them keeping only the channels in the
/// user's lineup, merges the same channel across sources (filling gaps from
/// lower-priority ones) and caches the small result. It pauses during
/// playback and runs at most about once a day.
enum OutsideGuide {
    // MARK: Sources

    struct Shard: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let defaultOn: Bool
    }

    struct Source {
        let name: String
        let shard: String
        let url: String
        /// A locals file: bare four-letter call signs count as call signs.
        var locals = false
    }

    static let shards: [Shard] = [
        Shard(id: "us-locals", title: "US local stations", detail: "ABC, CBS, NBC, FOX, PBS, CW and other locals, matched by call sign or by network and city", defaultOn: true),
        Shard(id: "us", title: "US national & sports", detail: "Cable networks, premium and sports channels", defaultOn: true),
        Shard(id: "fast", title: "Free streaming channels", detail: "Pluto TV, Samsung TV Plus, Plex and Roku channels", defaultOn: true),
        Shard(id: "ca", title: "Canada", detail: "Canadian networks and locals", defaultOn: false),
        Shard(id: "uk", title: "United Kingdom", detail: "UK channels", defaultOn: false)
    ]

    /// In priority order: when two sources list the same channel, the first
    /// one's listings win and later ones only fill gaps.
    static let sources: [Source] = [
        Source(name: "US locals", shard: "us-locals", url: "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz", locals: true),
        Source(name: "US national", shard: "us", url: "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz"),
        Source(name: "US sports", shard: "us", url: "https://epgshare01.online/epgshare01/epg_ripper_US_SPORTS1.xml.gz"),
        Source(name: "Pluto TV", shard: "fast", url: "https://i.mjh.nz/PlutoTV/us.xml.gz"),
        Source(name: "Samsung TV Plus", shard: "fast", url: "https://i.mjh.nz/SamsungTVPlus/us.xml.gz"),
        Source(name: "Plex", shard: "fast", url: "https://i.mjh.nz/Plex/us.xml.gz"),
        Source(name: "Roku", shard: "fast", url: "https://i.mjh.nz/Roku/all.xml.gz"),
        Source(name: "Canada", shard: "ca", url: "https://epgshare01.online/epgshare01/epg_ripper_CA2.xml.gz"),
        Source(name: "UK", shard: "uk", url: "https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz")
    ]

    /// Rebuild when the saved listings are older than this. The sources cover
    /// several days ahead, so a day-old build still fills the guide.
    static let refreshAge: TimeInterval = 20 * 3600
    /// How far ahead listings are kept.
    static let keepHours: TimeInterval = 48

    // MARK: Settings

    private static let enabledKey = "nuvio.tv.livetv.outsideGuide.enabled"
    private static let shardsKey = "nuvio.tv.livetv.outsideGuide.shards"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var enabledShards: Set<String> {
        get {
            if let saved = UserDefaults.standard.stringArray(forKey: shardsKey) { return Set(saved) }
            return Set(shards.filter(\.defaultOn).map(\.id))
        }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: shardsKey) }
    }

    // MARK: Data

    struct RawProgram: Codable {
        let s: Int        // start, minutes since 1970
        let m: Int        // length in minutes
        let t: String     // title
        let st: String?   // subtitle / episode title
        let d: String?    // description
        let f: Int        // flags: 1 movie, 2 sports, 4 news, 8 kids, 16 live, 32 new
    }

    /// A US / Canadian broadcast station from the station directory.
    struct Station: Codable {
        let callsign: String
        let network: String
        let cityTokens: [String]
        let channelNumber: String
    }

    /// The saved result: listings for the user's channels only.
    struct Saved: Codable {
        var built: Date
        var shards: [String]
        var channelCount: Int
        var programs: [String: [RawProgram]]
        /// How each channel was matched ("US locals: WNBC-DT, by call sign WNBC").
        var notes: [String: String]?
    }

    // MARK: Cache

    private static func folder() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("OutsideGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func savedURL(signature: String) -> URL? {
        let safe = String(signature.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(80))
        return folder()?.appendingPathComponent("listings-\(safe).json")
    }

    static func loadSaved(signature: String) -> Saved? {
        guard let url = savedURL(signature: signature), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, signature: String) {
        guard let url = savedURL(signature: signature), let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func needsRebuild(_ saved: Saved?, shards: Set<String>, channelCount: Int) -> Bool {
        guard let saved else { return true }
        if Date().timeIntervalSince(saved.built) > refreshAge { return true }
        if Set(saved.shards) != shards { return true }
        // A much bigger lineup than last time: new channels need matching.
        return channelCount > saved.channelCount + max(25, saved.channelCount / 10)
    }

    // MARK: Building

    /// Builds listings for `channels` from the enabled sources. Runs on
    /// background threads; `progress` reports a short status line.
    static func build(
        for channels: [LiveTVChannel],
        shards: Set<String>,
        progress: @escaping @Sendable (String) -> Void
    ) async -> (programs: [String: [RawProgram]], problems: [String], notes: [String: String]) {
        let targets = await Task.detached(priority: .background) { () -> Targets in
            progress("Getting the station directory…")
            let stations = shards.contains("us-locals") || shards.contains("ca")
                ? await StationDirectory.load() : []
            return Targets(channels: channels, stations: stations)
        }.value

        var merged: [String: [RawProgram]] = [:]
        var notes: [String: String] = [:]
        var problems: [String] = []
        let now = Int(Date().timeIntervalSince1970 / 60)
        let window = (low: now - 180, high: now + Int(keepHours * 60))
        let chosen = sources.filter { shards.contains($0.shard) }
        for (index, source) in chosen.enumerated() {
            if Task.isCancelled { break }
            progress("Updating listings: \(source.name) (\(index + 1) of \(chosen.count))…")
            do {
                let found = try await XMLTVReader.read(source: source, targets: targets, window: window)
                for (channelID, entry) in found {
                    merged[channelID] = mergePrograms(merged[channelID] ?? [], entry.programs)
                    let note = "\(source.name): \(entry.note)"
                    notes[channelID] = notes[channelID].map { "\($0); \(note)" } ?? note
                }
            } catch {
                problems.append("\(source.name): \(error.localizedDescription)")
            }
        }
        return (merged, problems, notes)
    }

    /// Adds `extra` programs that don't overlap `base` by more than 5 minutes.
    static func mergePrograms(_ base: [RawProgram], _ extra: [RawProgram]) -> [RawProgram] {
        guard !base.isEmpty else { return extra.sorted { $0.s < $1.s } }
        var result = base
        for program in extra {
            let end = program.s + program.m
            let clashes = result.contains { other in
                min(end, other.s + other.m) - max(program.s, other.s) > 5
            }
            if !clashes { result.append(program) }
        }
        return result.sorted { $0.s < $1.s }
    }

    /// Programs for one channel inside `from...to`. `idPrefix` "pg" marks the
    /// provider's own guide (which counts as the server's, not outside).
    static func programs(_ raw: [RawProgram], channelID: String, from: Date, to: Date,
                         idPrefix: String = "og", outside: Bool = true) -> [LiveTVProgram] {
        let low = Int(from.timeIntervalSince1970 / 60)
        let high = Int(to.timeIntervalSince1970 / 60)
        return raw.compactMap { item in
            let end = item.s + item.m
            guard end > low, item.s < high else { return nil }
            var program = LiveTVProgram(
                id: "\(idPrefix)|\(channelID)|\(item.s)",
                channelID: channelID,
                title: item.t,
                episodeTitle: item.st,
                overview: item.d,
                start: Date(timeIntervalSince1970: TimeInterval(item.s * 60)),
                end: Date(timeIntervalSince1970: TimeInterval(end * 60)),
                isMovie: item.f & 1 != 0,
                isSports: item.f & 2 != 0,
                isNews: item.f & 4 != 0,
                isKids: item.f & 8 != 0,
                isLive: item.f & 16 != 0,
                isPremiere: item.f & 32 != 0,
                imageURL: nil
            )
            program.fromOutsideGuide = outside
            // Listings saved before titles were read for genres.
            return item.f & ProgramGenre.genreBits == 0 ? ProgramGenre.withTitleFlags(program) : program
        }
    }

    // MARK: Matching

    /// The user's channels as lookup keys: call signs (from the name, or from
    /// network + city via the station directory) and normalized names.
    struct Targets {
        var bySign: [String: [String]] = [:]
        var byName: [String: [String]] = [:]

        init(channels: [LiveTVChannel], stations: [Station]) {
            let stationsByNetwork = Dictionary(grouping: stations, by: \.network)
            for channel in channels {
                let isLocal = (channel.group ?? "").lowercased().contains("local")
                var signs = OutsideGuide.callsigns(in: channel.name, strongContext: isLocal)
                // A call sign written alone in capitals ("(US) (Prime) KAGS").
                if signs.isEmpty, let sign = ChannelCatalog.bareCallsign(channel.name) { signs = [sign] }
                if signs.isEmpty, let sign = OutsideGuide.stationCallsign(for: channel.name, stations: stationsByNetwork) {
                    signs = [sign]
                }
                // The provider's XMLTV id ("KGO.us", "ESPN.us") is another key.
                if let epg = channel.epgID {
                    signs += OutsideGuide.callsigns(in: epg, strongContext: true).filter { !signs.contains($0) }
                }
                for sign in signs { bySign[sign, default: []].append(channel.id) }
                var texts = Set([channel.displayName, channel.name])
                if let epg = channel.epgID {
                    texts.insert(epg.rxReplace("\\.[a-z]{2,3}$", with: "", caseInsensitive: true))
                }
                for text in texts {
                    let key = OutsideGuide.normalize(text)
                    if key.count >= 2 { byName[key, default: []].append(channel.id) }
                }
            }
        }

        /// The user's channels a guide channel stands for. Call signs win over
        /// names, since a call sign can't be ambiguous.
        func matches(names: [String], xmltvID: String, locals: Bool) -> [(id: String, how: String)] {
            var found: [(id: String, how: String)] = []
            for sign in OutsideGuide.callsigns(in: (names + [xmltvID]).joined(separator: " | "), strongContext: locals) {
                found += (bySign[sign] ?? []).map { ($0, "by call sign \(sign)") }
            }
            if !found.isEmpty { return found }
            for name in names {
                let key = OutsideGuide.normalize(name)
                if key.count >= 2 { found += (byName[key] ?? []).map { ($0, "by name") } }
            }
            return found
        }
    }

    /// Network words as they show up in IPTV channel names.
    private static let networkWords: [String: String] = [
        "abc": "ABC", "cbs": "CBS", "nbc": "NBC", "fox": "FOX", "cw": "CW",
        "mynetworktv": "MYNETWORKTV", "mytv": "MYNETWORKTV", "pbs": "PBS",
        "telemundo": "TELEMUNDO", "univision": "UNIVISION", "ion": "ION"
    ]

    /// "NBC 5 Chicago" → WMAQ: a network word plus the station's city in the
    /// name (the channel number breaks ties).
    static func stationCallsign(for name: String, stations: [String: [Station]]) -> String? {
        guard !stations.isEmpty else { return nil }
        let lowered = name.lowercased()
            .rxReplace("^\\s*[^:|]{1,24}[:|]\\s*", with: "")
            // "PBS12" → "pbs 12", "[Denver]" → "denver"
            .rxReplace("([a-z])(\\d)", with: "$1 $2")
        let tokens = lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        // "NBC Sports Chicago" / "CBS News Chicago" are their own channels.
        guard !tokens.contains(where: { ["sports", "news", "network", "plus"].contains($0) }),
              let network = tokens.lazy.compactMap({ networkWords[$0] }).first,
              let candidates = stations[network] else { return nil }
        let words = Set(tokens)
        let numbers = Set(tokens.filter { $0.allSatisfy(\.isNumber) })
        var best: (sign: String, score: Int)?
        for station in candidates where station.cityTokens.allSatisfy(words.contains) {
            var score = station.cityTokens.count * 10
            if !station.channelNumber.isEmpty, numbers.contains(station.channelNumber) { score += 5 }
            if best == nil || score > best!.score { best = (station.callsign, score) }
        }
        return best?.sign
    }

    private static let callPattern = try? NSRegularExpression(
        pattern: "(?<![A-Z0-9])([KW][A-Z]{2,3})(?:[- ]?(DT|TV|LD|LP|CD|CA|HD)(\\d)?)?(?![A-Z])"
    )
    private static let callStop: Set<String> = ["WWE", "WNBA", "WEST", "WILD", "KIDS", "WORK", "WIRE", "WAVE", "WARS", "WOW", "KICK", "WINE", "WORD", "WEEK"]
    private static let dropTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "50fps", "60fps", "backup", "alt", "vip", "raw", "feed", "usa", "us", "ca", "uk", "tv",
        "east", "west", "pacific"
    ]

    /// Call signs ("WNBC", "KABC-2" for a sub-channel). A bare four-letter
    /// word only counts in a locals context, in parentheses, or with a -DT
    /// style suffix, so "WILD" or "KIDS" in a network name don't.
    static func callsigns(in text: String, strongContext: Bool) -> [String] {
        guard let callPattern else { return [] }
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        var found: [String] = []
        for match in callPattern.matches(in: upper, range: range) {
            guard let signRange = Range(match.range(at: 1), in: upper),
                  let wholeRange = Range(match.range(at: 0), in: upper) else { continue }
            let sign = String(upper[signRange])
            if callStop.contains(sign) { continue }
            let hasSuffix = match.range(at: 2).location != NSNotFound
            let digit = Range(match.range(at: 3), in: upper).map { String(upper[$0]) }
            let inParens = upper[..<wholeRange.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix("(")
            guard strongContext || hasSuffix || inParens else { continue }
            let key = (digit == nil || digit == "1") ? sign : "\(sign)-\(digit!)"
            if !found.contains(key) { found.append(key) }
        }
        return found
    }

    /// Comparable form of a channel name. East is the default feed and is
    /// dropped; West / Pacific feeds keep a marker so they never match East.
    static func normalize(_ name: String) -> String {
        var s = name.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        let west = RX.test("\\b(west|pacific)\\b", s)
        s = s.rxReplace("[\\[\\(][^\\]\\)]*[\\]\\)]", with: " ")
        s = s.rxReplace("^\\s*[^:|]{1,24}[:|]\\s*", with: "")
        let tokens = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
            .map(String.init)
            .filter { !dropTokens.contains($0) }
        let key = tokens.joined()
        return west && !key.isEmpty ? key + "~west" : key
    }
}
