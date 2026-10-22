import Foundation

/// A TV market the user picked for My Lineup, with its stations' call signs.
struct MarketChoice: Codable, Hashable, Identifiable {
    let name: String
    let template: String?
    var callsigns: [String]
    var id: String { name }

    /// City names in the market name ("San Francisco–Oakland–San Jose" →
    /// san francisco, oakland, san jose), for regional sports channels.
    var cityParts: [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "–—-/,&()"))
            .map { $0.replacingOccurrences(of: "\\b(ft|st)\\.?\\b", with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
    }
}

/// US TV markets (Nielsen DMAs) and the stations in each, from Wikipedia:
/// the market list is fetched once, and only the picked market's station
/// list after that. Falls back to station-directory cities if Wikipedia
/// can't be reached.
enum MarketDirectory {
    struct Market: Codable, Hashable, Identifiable {
        let name: String
        let template: String?
        var id: String { name }
    }

    private static let listPage = "List of television stations in North America by media market"
    private static let maxAge: TimeInterval = 90 * 24 * 3600

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("OutsideGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// All markets, biggest first (the page's DMA ranking order).
    static func markets() async -> [Market] {
        let cache = folder?.appendingPathComponent("markets.json")
        if let cache, let data = try? Data(contentsOf: cache),
           let saved = try? JSONDecoder().decode([Market].self, from: data), !saved.isEmpty,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge {
            return saved
        }
        var list: [Market] = []
        if let text = await Wiki.wikitext(listPage) {
            list = parseMarkets(text)
        }
        if list.isEmpty {
            // Fallback: cities from the station directory.
            let stations = await StationDirectory.load()
            var seen = Set<String>()
            for station in stations {
                let city = station.cityTokens.map(\.capitalized).joined(separator: " ")
                if seen.insert(city).inserted { list.append(Market(name: city, template: nil)) }
            }
            list.sort { $0.name < $1.name }
        } else if let cache, let data = try? JSONEncoder().encode(list) {
            try? data.write(to: cache, options: .atomic)
        }
        return list
    }

    /// Markets are template links on the list page:
    /// `[[Template:San Francisco Bay Area TV|San Francisco–Oakland–San Jose]]`.
    static func parseMarkets(_ text: String) -> [Market] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[\\s*(Template:[^|\\]]+)\\|([^\\]]+)\\]\\]") else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var list: [Market] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let template = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var name = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\\s*\\(\\d+\\)\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            name = name.replacingOccurrences(of: "&nbsp;", with: " ")
            // Skip navigation templates ("Template:TV lists" etc.).
            let lowerName = name.lowercased()
            guard !name.isEmpty, name.count < 60, !lowerName.contains("list"), !lowerName.contains("template"),
                  seen.insert(name.lowercased()).inserted else { continue }
            list.append(Market(name: name, template: template))
        }
        return list
    }

    /// Call signs of the stations in one market.
    static func callsigns(for market: Market) async -> [String] {
        if let template = market.template, let text = await Wiki.wikitext(template) {
            let signs = callsigns(inWikitext: text)
            if !signs.isEmpty { return signs }
        }
        // Fallback: station-directory stations whose city is in the market name.
        let parts = MarketChoice(name: market.name, template: nil, callsigns: []).cityParts
        let stations = await StationDirectory.load()
        return Array(Set(stations.filter { station in
            let city = station.cityTokens.joined(separator: " ")
            return parts.contains { $0 == city || $0.contains(city) || city.contains($0) }
        }.map(\.callsign))).sorted()
    }

    static func callsigns(inWikitext text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[\\s*([KW][A-Z]{2,3})(?:-(?:TV|DT|LD|CD|LP|CA))?\\s*(?:\\|[^\\]]*)?\\]\\]") else { return [] }
        let ns = text as NSString
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let sign = ns.substring(with: match.range(at: 1))
            if !found.contains(sign) { found.append(sign) }
        }
        return found
    }

    /// Markets the user's channel names point to most ("San Francisco"
    /// appears in 30 local channel names → that market first).
    static func suggested(from markets: [Market], channelNames: [String], limit: Int = 6) -> [Market] {
        let names = channelNames.map { $0.lowercased() }
        var scored: [(Market, Int)] = []
        for market in markets {
            let parts = MarketChoice(name: market.name, template: nil, callsigns: []).cityParts
            guard !parts.isEmpty else { continue }
            let hits = names.reduce(0) { count, name in count + (parts.contains { name.contains($0) } ? 1 : 0) }
            if hits > 0 { scored.append((market, hits)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

/// Small Wikipedia API helper (background traffic, cached by callers).
enum Wiki {
    static func wikitext(_ title: String) async -> String? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "parse"), URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "wikitext"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "redirects", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("NuvioTV/1.0 (Apple TV; personal use)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode == 429 { continue }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parse = root["parse"] as? [String: Any],
                  let wikitext = parse["wikitext"] as? [String: Any] else { return nil }
            return wikitext["*"] as? String
        }
        return nil
    }
}
