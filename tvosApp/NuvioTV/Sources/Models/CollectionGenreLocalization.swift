import Foundation

/// Localizes unchanged labels from Discover by Genre at display time. A title
/// alone is not enough: custom/add-on folders and edited source groups keep
/// their saved labels. The collection JSON and filter values stay untouched.
enum CollectionGenreLocalization {
    private struct Label {
        let key: String
        let english: String
        let movie: String
        let series: String
        var keyword: Bool = false
    }

    private static let labels: [Label] = [
        Label(key: "action", english: "Action & Adventure", movie: "28|12", series: "10759"),
        Label(key: "animation", english: "Animation", movie: "16", series: "16"),
        Label(key: "comedy", english: "Comedy", movie: "35", series: "35"),
        Label(key: "crime", english: "Crime", movie: "80", series: "80"),
        Label(key: "documentary", english: "Documentary", movie: "99", series: "99"),
        Label(key: "drama", english: "Drama", movie: "18", series: "18"),
        Label(key: "family", english: "Family", movie: "10751", series: "10751"),
        Label(key: "horror", english: "Horror", movie: "27", series: "315058", keyword: true),
        Label(key: "mystery", english: "Mystery & Thriller", movie: "9648|53", series: "9648"),
        Label(key: "romance", english: "Romance", movie: "10749", series: "9840", keyword: true),
        Label(key: "fantasy", english: "Sci-Fi & Fantasy", movie: "878|14", series: "10765"),
        Label(key: "history", english: "War & History", movie: "10752|36", series: "10768")
    ]

    static func title(
        for destination: CollectionHomeDestination,
        localize: (String, String) -> String = { L10n.string($0, fallback: $1) }
    ) -> String {
        let saved = destination.folder.title
        guard destination.templateID == "discover-genres", destination.isGenreDestination,
              let label = labels.first(where: { $0.english == saved }),
              destination.folder.sources.contains(where: {
                  $0.mediaType == "movie" && $0.filters?.withGenres == label.movie
              }),
              destination.folder.sources.allSatisfy({ source in
                  guard source.normalizedProvider == "tmdb",
                        source.tmdbSourceType == "DISCOVER", let filters = source.filters else { return false }
                  switch source.mediaType {
                  case "movie":
                      return filters.withGenres == label.movie && filters.withKeywords == nil
                  case "tv":
                      return label.keyword
                          ? filters.withKeywords == label.series && filters.withGenres == nil
                          : filters.withGenres == label.series && filters.withKeywords == nil
                  default:
                      return false
                  }
              }) else { return saved }
        return localize("sidebar_genre_\(label.key)", saved)
    }
}
