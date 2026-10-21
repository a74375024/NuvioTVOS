import Foundation

/// One catalog request that feeds a channel: a Cinemeta catalog filtered by genre.
struct ChannelSourceQuery: Hashable, Sendable {
    let type: String       // "series" or "movie"
    let genre: String      // Cinemeta genre name
}

/// A ready-made channel. Membership is decided by `accepts`; across the lineup
/// every title belongs to exactly one channel (the first in `priorityOrder`
/// that accepts it), so channels never overlap.
struct ChannelDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let tagline: String
    let symbol: String
    let queries: [ChannelSourceQuery]
    /// Month/day window when a seasonal channel is on the guide; nil = always.
    let season: (start: (month: Int, day: Int), end: (month: Int, day: Int))?
    let accepts: @Sendable (NuvioMeta) -> Bool

    func isAvailable(on date: Date = Date()) -> Bool {
        guard let season else { return true }
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return true }
        let today = month * 100 + day
        let start = season.start.month * 100 + season.start.day
        let end = season.end.month * 100 + season.end.day
        return start <= end ? (start...end).contains(today) : (today >= start || today <= end)
    }
}

enum ChannelLineup {
    /// Order that decides which channel "owns" a title with several genres.
    static let priorityOrder: [String] = [
        "fright", "homefood", "reality", "scifi", "crime", "sitcoms", "cozy", "comedymovies",
    ]

    /// Display order in the guide (seasonal first while it's on).
    static let displayOrder: [String] = [
        "fright", "sitcoms", "crime", "reality", "homefood", "scifi", "comedymovies", "cozy",
    ]

    static let all: [ChannelDefinition] = [
        ChannelDefinition(
            id: "fright",
            name: L10n.string("channel_fright", fallback: "Fright Fest"),
            tagline: L10n.string("channel_fright_tagline", fallback: "Horror movies and series, all October long"),
            symbol: "moon.stars.fill",
            queries: [
                ChannelSourceQuery(type: "movie", genre: "Horror"),
                ChannelSourceQuery(type: "series", genre: "Horror"),
            ],
            season: (start: (9, 15), end: (11, 7)),
            accepts: { meta in
                let g = genres(meta)
                return g.contains("horror") && g.isDisjoint(with: ["animation", "family", "documentary"])
            }
        ),
        ChannelDefinition(
            id: "homefood",
            name: L10n.string("channel_homefood", fallback: "Home & Food"),
            tagline: L10n.string("channel_homefood_tagline", fallback: "Cooking, baking, renovations and house hunting"),
            symbol: "fork.knife",
            queries: [ChannelSourceQuery(type: "series", genre: "Reality-TV")],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return meta.isSeries && g.contains("reality-tv")
                    && g.isDisjoint(with: ["animation", "talk-show"])
                    && matchesHomeOrFood(meta)
            }
        ),
        ChannelDefinition(
            id: "reality",
            name: L10n.string("channel_reality", fallback: "Reality & Competition"),
            tagline: L10n.string("channel_reality_tagline", fallback: "Reality shows, competitions and game shows"),
            symbol: "trophy.fill",
            queries: [
                ChannelSourceQuery(type: "series", genre: "Reality-TV"),
                ChannelSourceQuery(type: "series", genre: "Game-Show"),
            ],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return meta.isSeries && !g.isDisjoint(with: ["reality-tv", "game-show"])
                    && g.isDisjoint(with: ["animation", "talk-show", "documentary"])
            }
        ),
        ChannelDefinition(
            id: "scifi",
            name: L10n.string("channel_scifi", fallback: "Sci-Fi & Fantasy"),
            tagline: L10n.string("channel_scifi_tagline", fallback: "Space, the future and other worlds"),
            symbol: "sparkles",
            queries: [
                ChannelSourceQuery(type: "series", genre: "Sci-Fi"),
                ChannelSourceQuery(type: "series", genre: "Fantasy"),
                ChannelSourceQuery(type: "movie", genre: "Sci-Fi"),
            ],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return !g.isDisjoint(with: ["sci-fi", "fantasy"])
                    && g.isDisjoint(with: ["animation", "family", "documentary"])
            }
        ),
        ChannelDefinition(
            id: "crime",
            name: L10n.string("channel_crime", fallback: "Crime & Procedurals"),
            tagline: L10n.string("channel_crime_tagline", fallback: "Detectives, cops, lawyers and mysteries"),
            symbol: "magnifyingglass",
            queries: [
                ChannelSourceQuery(type: "series", genre: "Crime"),
                ChannelSourceQuery(type: "series", genre: "Mystery"),
            ],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return meta.isSeries && !g.isDisjoint(with: ["crime", "mystery"])
                    && g.isDisjoint(with: ["animation", "documentary", "reality-tv"])
            }
        ),
        ChannelDefinition(
            id: "sitcoms",
            name: L10n.string("channel_sitcoms", fallback: "Sitcom Central"),
            tagline: L10n.string("channel_sitcoms_tagline", fallback: "Live-action comedy series, nonstop"),
            symbol: "face.smiling.fill",
            queries: [ChannelSourceQuery(type: "series", genre: "Comedy")],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return meta.isSeries && g.contains("comedy")
                    && g.isDisjoint(with: ["animation", "reality-tv", "talk-show", "documentary", "game-show"])
            }
        ),
        ChannelDefinition(
            id: "cozy",
            name: L10n.string("channel_cozy", fallback: "Cozy Movies"),
            tagline: L10n.string("channel_cozy_tagline", fallback: "Feel-good romance and family films"),
            symbol: "heart.fill",
            queries: [
                ChannelSourceQuery(type: "movie", genre: "Romance"),
                ChannelSourceQuery(type: "movie", genre: "Family"),
            ],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return !meta.isSeries && !g.isDisjoint(with: ["romance", "family"])
                    && g.isDisjoint(with: ["animation", "horror", "thriller", "crime", "war"])
            }
        ),
        ChannelDefinition(
            id: "comedymovies",
            name: L10n.string("channel_comedymovies", fallback: "Comedy Movies"),
            tagline: L10n.string("channel_comedymovies_tagline", fallback: "Big laughs, back to back"),
            symbol: "theatermasks.fill",
            queries: [ChannelSourceQuery(type: "movie", genre: "Comedy")],
            season: nil,
            accepts: { meta in
                let g = genres(meta)
                return !meta.isSeries && g.contains("comedy") && !g.contains("animation")
            }
        ),
    ]

    static func channel(id: String) -> ChannelDefinition? {
        all.first { $0.id == id }
    }

    /// Channels on the guide today, in display order.
    static func available(on date: Date = Date()) -> [ChannelDefinition] {
        let available = all.filter { $0.isAvailable(on: date) }
        return displayOrder.compactMap { id in available.first { $0.id == id } }
    }

    /// The single channel that owns this title among today's channels.
    static func owner(of meta: NuvioMeta, among channels: [ChannelDefinition]) -> String? {
        let ids = Set(channels.map(\.id))
        for id in priorityOrder where ids.contains(id) {
            if let channel = channel(id: id), channel.accepts(meta) { return id }
        }
        return nil
    }

    static func genres(_ meta: NuvioMeta) -> Set<String> {
        Set((meta.genres ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private static let homeFoodWords = [
        "cook", "chef", "kitchen", "bake", "baking", "baker", "food", "restaurant", "recipe", "cake", "diner",
        "house", "home", "renovat", "flip", "property", "real estate", "makeover", "design", "garden",
    ]

    static func matchesHomeOrFood(_ meta: NuvioMeta) -> Bool {
        let text = "\(meta.name) \(meta.description ?? "")".lowercased()
        return homeFoodWords.contains { text.contains($0) }
    }
}
