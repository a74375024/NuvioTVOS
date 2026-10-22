import Foundation

/// Free TV listings gathered outside the user's server (see epg/ in the repo:
/// a GitHub Actions job merges several free XMLTV guides into compact shards
/// and publishes them to the "epg-data" release). Used to fill in channels the
/// server has no guide for, matched by call sign or channel name.
enum OutsideGuide {
    struct Shard: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let defaultOn: Bool
    }

    static let shards: [Shard] = [
        Shard(id: "us-locals", title: "US local stations", detail: "ABC, CBS, NBC, FOX, PBS, CW and other locals, matched by call sign", defaultOn: true),
        Shard(id: "us", title: "US national & sports", detail: "Cable networks, premium and sports channels", defaultOn: true),
        Shard(id: "fast", title: "Free streaming channels", detail: "Pluto TV, Samsung TV Plus, Plex and Roku channels", defaultOn: true),
        Shard(id: "ca", title: "Canada", detail: "Canadian networks and locals", defaultOn: false),
        Shard(id: "uk", title: "United Kingdom", detail: "UK channels", defaultOn: false)
    ]

    static let releaseBase = "https://github.com/a74375024/NuvioTVOS/releases/download/epg-data/"
    private static let maxAge: TimeInterval = 6 * 3600

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

    struct RawProgram {
        let startMinute: Int
        let minutes: Int
        let title: String
        let subtitle: String?
        let overview: String?
        let flags: Int
    }

    struct Channel {
        let names: [String]
        let callsigns: [String]
        let programs: [RawProgram]
    }

    struct Loaded {
        var channels: [Channel] = []
        var generated: Date?
        var problems: [String] = []
    }

    /// Loads the enabled shards (cached for a few hours; a stale cache is used
    /// when the download fails). Heavy work runs off the main thread.
    static func load(shardIDs: Set<String>, force: Bool) async -> Loaded {
        await Task.detached(priority: .utility) {
            var result = Loaded()
            for shard in shards where shardIDs.contains(shard.id) {
                do {
                    let data = try await shardData(shard.id, force: force)
                    let parsed = try parse(data)
                    result.channels += parsed.channels
                    if let generated = parsed.generated {
                        result.generated = min(result.generated ?? generated, generated)
                    }
                } catch {
                    result.problems.append("\(shard.title): \(error.localizedDescription)")
                }
            }
            return result
        }.value
    }

    private static func cacheURL(_ shard: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("OutsideGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(shard).json.z")
    }

    private static func shardData(_ shard: String, force: Bool) async throws -> Data {
        let cache = cacheURL(shard)
        if !force, let cache,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: cache) {
            return data
        }
        do {
            guard let url = URL(string: releaseBase + "\(shard).json.z") else { throw URLError(.badURL) }
            var request = URLRequest(url: url, timeoutInterval: 90)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            if let cache { try? data.write(to: cache, options: .atomic) }
            return data
        } catch {
            if let cache, let data = try? Data(contentsOf: cache) { return data }
            throw error
        }
    }

    private static func parse(_ compressed: Data) throws -> (channels: [Channel], generated: Date?) {
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["channels"] as? [[String: Any]] else { return ([], nil) }
        let generated = (root["generated"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let channels: [Channel] = list.compactMap { entry in
            let names = entry["n"] as? [String] ?? []
            let signs = entry["c"] as? [String] ?? []
            let rows = entry["p"] as? [[Any]] ?? []
            let programs: [RawProgram] = rows.compactMap { row in
                guard row.count >= 6,
                      let start = (row[0] as? NSNumber)?.intValue,
                      let minutes = (row[1] as? NSNumber)?.intValue,
                      let title = row[2] as? String else { return nil }
                return RawProgram(
                    startMinute: start, minutes: minutes, title: title,
                    subtitle: row[3] as? String, overview: row[4] as? String,
                    flags: (row[5] as? NSNumber)?.intValue ?? 0
                )
            }
            guard !programs.isEmpty, !names.isEmpty || !signs.isEmpty else { return nil }
            return Channel(names: names, callsigns: signs, programs: programs)
        }
        return (channels, generated)
    }

    // MARK: Matching

    private static let callPattern = try? NSRegularExpression(
        pattern: "(?<![A-Z0-9])([KW][A-Z]{2,3})(?:[- ]?(DT|TV|LD|LP|CD|CA|HD)(\\d)?)?(?![A-Z])"
    )
    private static let callStop: Set<String> = ["WWE", "WNBA", "WEST", "WILD", "KIDS", "WORK", "WIRE", "WAVE", "WARS", "WOW", "KICK", "WINE", "WORD", "WEEK"]
    private static let dropTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "50fps", "60fps", "backup", "alt", "vip", "raw", "feed", "usa", "us", "ca", "uk", "tv",
        "east", "west", "pacific"
    ]

    /// Same rule as the builder: a bare four-letter word only counts as a call
    /// sign in a locals group, in parentheses, or with a -DT style suffix.
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

    /// Same as the builder: East is the default feed and dropped; West /
    /// Pacific feeds keep a marker so they never match the East listing.
    static func normalize(_ name: String) -> String {
        var s = name.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        let west = s.range(of: "\\b(west|pacific)\\b", options: .regularExpression) != nil
        s = s.replacingOccurrences(of: "[\\[\\(][^\\]\\)]*[\\]\\)]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*[^:|]{1,24}[:|]\\s*", with: "", options: .regularExpression)
        let tokens = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
            .map(String.init)
            .filter { !dropTokens.contains($0) }
        let key = tokens.joined()
        return west && !key.isEmpty ? key + "~west" : key
    }

    /// Server channel id → index into `guide`, for every channel that matches.
    static func match(_ channels: [LiveTVChannel], guide: [Channel]) -> [String: Int] {
        var bySign: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]
        for (index, channel) in guide.enumerated() {
            for sign in channel.callsigns { bySign[sign, default: []].append(index) }
            for name in channel.names {
                let key = normalize(name)
                guard key.count >= 2 else { continue }
                byName[key, default: []].append(index)
            }
        }
        func best(_ candidates: [Int]?) -> Int? {
            candidates?.max { guide[$0].programs.count < guide[$1].programs.count }
        }
        var result: [String: Int] = [:]
        for channel in channels {
            let isLocal = (channel.group ?? "").lowercased().contains("local")
            var found: Int?
            for sign in callsigns(in: channel.name, strongContext: isLocal) {
                if let hit = best(bySign[sign]) { found = hit; break }
            }
            if found == nil {
                for text in [channel.displayName, channel.name] {
                    let key = normalize(text)
                    guard key.count >= 2 else { continue }
                    if let hit = best(byName[key]) { found = hit; break }
                }
            }
            if let found { result[channel.id] = found }
        }
        return result
    }

    /// Programs for one matched channel inside `from...to`.
    static func programs(_ channel: Channel, channelID: String, from: Date, to: Date) -> [LiveTVProgram] {
        let low = Int(from.timeIntervalSince1970 / 60)
        let high = Int(to.timeIntervalSince1970 / 60)
        return channel.programs.compactMap { raw in
            let end = raw.startMinute + raw.minutes
            guard end > low, raw.startMinute < high else { return nil }
            var program = LiveTVProgram(
                id: "og|\(channelID)|\(raw.startMinute)",
                channelID: channelID,
                title: raw.title,
                episodeTitle: raw.subtitle,
                overview: raw.overview,
                start: Date(timeIntervalSince1970: TimeInterval(raw.startMinute * 60)),
                end: Date(timeIntervalSince1970: TimeInterval(end * 60)),
                isMovie: raw.flags & 1 != 0,
                isSports: raw.flags & 2 != 0,
                isNews: raw.flags & 4 != 0,
                isKids: raw.flags & 8 != 0,
                isLive: raw.flags & 16 != 0,
                isPremiere: raw.flags & 32 != 0,
                imageURL: nil
            )
            program.fromOutsideGuide = true
            return program
        }
    }
}
