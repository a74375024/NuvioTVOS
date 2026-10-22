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

    private static let key = "nuvio.tv.livetv.lineup"

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
}

/// Builds the suggested lineup and its cable-style numbering.
enum LineupEngine {
    /// Whether an entry belongs in the suggested lineup.
    static func suggests(
        _ entry: LiveTVEntryInfo,
        prefs: LineupPrefs,
        hasGuide: Bool,
        name: String
    ) -> Bool {
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

    /// Lineup numbers: locals on their real channel numbers, the rest in
    /// category blocks (news 100s, sports 200s…), alphabetical within a block.
    static func numbers(for entries: [LiveTVEntryInfo]) -> [String: Int] {
        var result: [String: Int] = [:]
        var used = Set<Int>()
        let locals = entries.filter { $0.category == .local }
            .sorted { ($0.virtualNumber ?? 999, $0.name) < ($1.virtualNumber ?? 999, $1.name) }
        var nextLocal = 2
        for entry in locals {
            if let number = entry.virtualNumber, number >= 1, number < 100, !used.contains(number) {
                result[entry.id] = number
                used.insert(number)
            } else {
                while used.contains(nextLocal) { nextLocal += 1 }
                result[entry.id] = nextLocal
                used.insert(nextLocal)
            }
        }
        let others = Dictionary(grouping: entries.filter { $0.category != .local }, by: \.category)
        for category in LineupCategory.allCases where category != .local {
            var number = category.numberBlock
            for entry in (others[category] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                while used.contains(number) { number += 1 }
                result[entry.id] = number
                used.insert(number)
            }
        }
        return result
    }
}
