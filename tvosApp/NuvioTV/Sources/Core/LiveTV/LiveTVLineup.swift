import Foundation

/// The user's My Lineup choices, saved per profile.
struct LineupPrefs: Codable, Equatable {
    var configured = false
    var markets: [MarketChoice] = []
    var categories: Set<LineupCategory> = LineupCategory.defaultOn
    /// National channels only join the suggested lineup when they have a guide.
    var requireGuide = true
    /// Suggested members from the last build (entry ids), kept stable so the
    /// lineup doesn't shift as guide data loads.
    var suggested: Set<String> = []
    var added: Set<String> = []
    var removed: Set<String> = []
    var showHidden = false
    var builtAt: Date?
    /// Countries / languages whose channels can be suggested and browsed:
    /// "US" (US English), "US-ES" (US Spanish), "MX", "UK"… US English by
    /// default; the rest are opt-in.
    var countries: Set<String> = LineupPrefs.defaultCountries
    /// The market Live Events treats as home (its stations come first);
    /// nil = the first market picked.
    var homeMarket: String? = nil

    static let defaultCountries: Set<String> = ["US"]

    private static let key = "nuvio.tv.livetv.lineup"

    init() {}

    /// Tolerates older saved prefs (fields added later keep their defaults),
    /// so an update never resets someone's lineup.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        markets = try c.decodeIfPresent([MarketChoice].self, forKey: .markets) ?? []
        categories = try c.decodeIfPresent(Set<LineupCategory>.self, forKey: .categories) ?? LineupCategory.defaultOn
        requireGuide = try c.decodeIfPresent(Bool.self, forKey: .requireGuide) ?? true
        suggested = try c.decodeIfPresent(Set<String>.self, forKey: .suggested) ?? []
        added = try c.decodeIfPresent(Set<String>.self, forKey: .added) ?? []
        removed = try c.decodeIfPresent(Set<String>.self, forKey: .removed) ?? []
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        builtAt = try c.decodeIfPresent(Date.self, forKey: .builtAt)
        countries = try c.decodeIfPresent(Set<String>.self, forKey: .countries) ?? LineupPrefs.defaultCountries
        homeMarket = try c.decodeIfPresent(String.self, forKey: .homeMarket)
    }

    /// Country prefixes the provider's own guide should cover ("US-ES" → "US").
    var guideCountries: Set<String> {
        Set(countries.map { $0.components(separatedBy: "-").first ?? $0 })
    }

    /// Whether a channel / event from `market` belongs to the chosen countries.
    func includes(market: String?) -> Bool {
        guard let market else { return false }
        return countries.contains(market)
    }

    static func load() -> LineupPrefs {
        guard let data = ProfileSettings.current.data(forKey: key),
              let prefs = try? JSONDecoder().decode(LineupPrefs.self, from: data) else { return LineupPrefs() }
        return prefs
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        ProfileSettings.current.set(data, forKey: Self.key)
    }

    var marketCallsigns: Set<String> {
        Set(markets.flatMap(\.callsigns))
    }

    var marketCityParts: [String] {
        markets.flatMap(\.cityParts)
    }

    /// Places that count as "here" for regional channels: the market's
    /// cities plus common names for the area ("Bay Area", "California").
    var marketPlaces: Set<String> {
        var places = Set(marketCityParts)
        let aliases: [(String, [String])] = [
            ("san francisco", ["bay area", "northern california", "norcal", "california"]),
            ("sacramento", ["northern california", "norcal", "california"]),
            ("los angeles", ["southern california", "socal", "california"]),
            ("san diego", ["southern california", "socal", "california"]),
            ("new york", ["tri state", "new york", "long island", "brooklyn", "bronx", "queens"]),
            ("boston", ["new england", "massachusetts"]),
            ("chicago", ["illinois", "great lakes"]),
            ("washington", ["washington dc", "mid atlantic"]),
            ("philadelphia", ["pennsylvania", "mid atlantic"]),
            ("dallas", ["texas", "southwest"]),
            ("houston", ["texas", "southwest"]),
            ("atlanta", ["georgia", "southeast"]),
            ("miami", ["florida", "sun"]),
            ("tampa", ["florida", "sun"]),
            ("seattle", ["washington", "northwest"]),
            ("denver", ["colorado", "rocky mountain"]),
            ("phoenix", ["arizona"]),
            ("detroit", ["michigan"]),
            ("minneapolis", ["minnesota"])
        ]
        for (city, extra) in aliases where places.contains(where: { $0.contains(city) }) {
            places.formUnion(extra)
        }
        return places
    }
}

/// Works out which channels the suggested lineup holds.
enum LineupEngine {
    /// Whether an entry belongs in the suggested lineup.
    static func suggests(
        _ entry: LiveTVEntryInfo,
        prefs: LineupPrefs,
        hasGuide: Bool,
        name: String
    ) -> Bool {
        // Only the chosen countries / languages.
        guard prefs.includes(market: entry.market) else { return false }
        switch entry.kind {
        case .channel: break
        case .fast, .loop247:
            // Free streaming and 24/7 channels are opt-in.
            return prefs.categories.contains(.free) && (hasGuide || !prefs.requireGuide)
        case .radio:
            return prefs.categories.contains(.radio) && hasGuide
        case .event, .placeholder, .separator:
            return false
        }
        // Core national networks: always, in the categories picked.
        if entry.core != nil { return prefs.categories.contains(entry.category) }
        if entry.scope == "team" { return false }
        // Other countries / US Spanish: the user chose them; channels with a guide.
        if entry.market != "US" {
            if let sign = entry.callsign {
                // A station (Univision, Telemundo…): only the user's market's.
                let base = sign.split(separator: "-").first.map(String.init) ?? sign
                return prefs.categories.contains(.local) && prefs.marketCallsigns.contains(base)
            }
            return hasGuide || !prefs.requireGuide
        }
        // Regional channels (another city's locals, regional sports) only for their market.
        if entry.scope.hasPrefix("regional") {
            let place = String(entry.scope.dropFirst("regional:".count))
            let lower = name.lowercased()
            let here = prefs.marketPlaces.contains(place)
                || (place == "?" && prefs.marketCityParts.contains(where: { lower.contains($0) }))
            guard here, prefs.categories.contains(entry.category == .local ? .local : entry.category) else { return false }
            return hasGuide || entry.category == .sports || entry.category == .local
        }
        switch entry.category {
        case .local:
            guard prefs.categories.contains(.local), let sign = entry.callsign else { return false }
            let base = sign.split(separator: "-").first.map(String.init) ?? sign
            return prefs.marketCallsigns.contains(base)
        case .sports:
            guard prefs.categories.contains(.sports) else { return false }
            // Regional sports for the user's market join even without a guide.
            let lower = name.lowercased()
            if prefs.marketCityParts.contains(where: { lower.contains($0) }) { return true }
            return hasGuide || !prefs.requireGuide
        case .international, .radio:
            return prefs.categories.contains(entry.category) && hasGuide
        default:
            return prefs.categories.contains(entry.category) && (hasGuide || !prefs.requireGuide)
        }
    }

}
