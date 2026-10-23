import Foundation

/// Core US national networks: anyone with these gets them in My Lineup (in
/// the categories they picked). Each alias is matched against the
/// `ChannelCatalog.coreKey` of a channel's cleaned name, so every provider's
/// spelling ("US: ESPN FHD", "AT&T: A&E ᴿᴬᵂ", "USA  HBO EAST") lands on one entry
/// with a clean name. Generated from a data table; keep it data, not logic.
enum CoreChannels {
    static let list: [(name: String, category: LineupCategory, aliases: [String])] = [
        ("CNN", .news, ["cnn", "cnn us", "cnn usa"]),
        ("HLN", .news, ["hln", "headline news", "cnn headline news"]),
        ("Fox News", .news, ["fox news", "fox news channel", "fnc"]),
        ("Fox Business", .news, ["fox business", "fox business network", "fbn"]),
        ("MSNBC", .news, ["msnbc", "ms now"]),
        ("CNBC", .news, ["cnbc"]),
        ("Bloomberg TV", .news, ["bloomberg", "bloomberg tv", "bloomberg television"]),
        ("NewsNation", .news, ["newsnation", "news nation"]),
        ("Newsmax", .news, ["newsmax", "newsmax tv"]),
        ("C-SPAN", .news, ["c span", "cspan", "c span 1"]),
        ("C-SPAN 2", .news, ["c span 2", "cspan 2", "cspan2"]),
        ("The Weather Channel", .news, ["weather channel", "the weather channel", "twc"]),
        ("ABC News Live", .news, ["abc news live", "abc news"]),
        ("CBS News", .news, ["cbs news", "cbs news 24 7"]),
        ("NBC News Now", .news, ["nbc news now", "nbc news"]),
        ("Court TV", .news, ["court tv"]),
        ("Scripps News", .news, ["scripps news"]),
        ("ESPN", .sports, ["espn"]),
        ("ESPN2", .sports, ["espn2", "espn 2"]),
        ("ESPNU", .sports, ["espnu", "espn u"]),
        ("ESPNews", .sports, ["espnews", "espn news"]),
        ("SEC Network", .sports, ["sec network", "espn sec network", "secn"]),
        ("ACC Network", .sports, ["acc network", "espn acc network", "accn"]),
        ("Big Ten Network", .sports, ["big ten network", "btn", "b1g network", "big ten"]),
        ("FS1", .sports, ["fs1", "fox sports 1", "fox sports1"]),
        ("FS2", .sports, ["fs2", "fox sports 2", "fox sports2"]),
        ("NFL Network", .sports, ["nfl network"]),
        ("NFL RedZone", .sports, ["nfl redzone", "redzone", "nfl red zone"]),
        ("MLB Network", .sports, ["mlb network"]),
        ("NBA TV", .sports, ["nba tv", "nbatv"]),
        ("NHL Network", .sports, ["nhl network"]),
        ("Golf Channel", .sports, ["golf channel", "golf"]),
        ("Tennis Channel", .sports, ["tennis channel"]),
        ("CBS Sports Network", .sports, ["cbs sports network", "cbssn", "cbs sports"]),
        ("beIN Sports", .sports, ["bein sports", "bein sports usa"]),
        ("TNT", .entertainment, ["tnt", "tnt east"]),
        ("TBS", .entertainment, ["tbs", "tbs east"]),
        ("truTV", .entertainment, ["trutv", "tru tv"]),
        ("USA Network", .entertainment, ["usa network", "usa"]),
        ("FX", .entertainment, ["fx"]),
        ("FXX", .entertainment, ["fxx"]),
        ("AMC", .entertainment, ["amc"]),
        ("BBC America", .entertainment, ["bbc america"]),
        ("Bravo", .entertainment, ["bravo"]),
        ("E!", .entertainment, ["e", "e entertainment", "e entertainment television"]),
        ("Syfy", .entertainment, ["syfy"]),
        ("Paramount Network", .entertainment, ["paramount network"]),
        ("Comedy Central", .entertainment, ["comedy central"]),
        ("A&E", .entertainment, ["a and e", "ae"]),
        ("History", .entertainment, ["history", "history channel"]),
        ("Lifetime", .entertainment, ["lifetime"]),
        ("LMN", .entertainment, ["lmn", "lifetime movies", "lifetime movie network"]),
        ("Hallmark Channel", .entertainment, ["hallmark", "hallmark channel"]),
        ("Hallmark Movies & Mysteries", .entertainment, ["hallmark movies and mysteries", "hallmark mystery", "hallmark mysteries", "hmm"]),
        ("Discovery Channel", .entertainment, ["discovery", "discovery channel"]),
        ("TLC", .entertainment, ["tlc"]),
        ("Animal Planet", .entertainment, ["animal planet"]),
        ("Investigation Discovery", .entertainment, ["investigation discovery", "id", "id investigation discovery", "investigation discovery us"]),
        ("Science Channel", .entertainment, ["science", "science channel"]),
        ("HGTV", .entertainment, ["hgtv"]),
        ("Food Network", .entertainment, ["food network", "food"]),
        ("Travel Channel", .entertainment, ["travel channel", "travel"]),
        ("Cooking Channel", .entertainment, ["cooking channel"]),
        ("Magnolia Network", .entertainment, ["magnolia network", "magnolia"]),
        ("National Geographic", .entertainment, ["national geographic", "nat geo", "national geographic channel"]),
        ("Nat Geo Wild", .entertainment, ["nat geo wild", "national geographic wild", "nat geo wild us"]),
        ("Smithsonian Channel", .entertainment, ["smithsonian channel", "smithsonian"]),
        ("Freeform", .entertainment, ["freeform"]),
        ("Oxygen", .entertainment, ["oxygen", "oxygen true crime"]),
        ("WE tv", .entertainment, ["we tv", "wetv"]),
        ("OWN", .entertainment, ["own", "oprah winfrey network"]),
        ("TV Land", .entertainment, ["tv land", "tvland"]),
        ("IFC", .entertainment, ["ifc"]),
        ("SundanceTV", .entertainment, ["sundance", "sundance tv", "sundancetv"]),
        ("Reelz", .entertainment, ["reelz"]),
        ("Game Show Network", .entertainment, ["game show network", "gsn"]),
        ("BET", .entertainment, ["bet"]),
        ("VH1", .entertainment, ["vh1"]),
        ("Pop TV", .entertainment, ["pop", "pop tv"]),
        ("Motor Trend", .entertainment, ["motor trend", "motortrend"]),
        ("AXS TV", .entertainment, ["axs", "axs tv"]),
        ("MTV", .music, ["mtv"]),
        ("CMT", .music, ["cmt"]),
        ("Disney Channel", .kids, ["disney channel", "disney"]),
        ("Disney Junior", .kids, ["disney junior", "disney jr"]),
        ("Disney XD", .kids, ["disney xd"]),
        ("Nickelodeon", .kids, ["nickelodeon", "nick"]),
        ("Nick Jr.", .kids, ["nick jr", "nickjr", "nick junior"]),
        ("Nicktoons", .kids, ["nicktoons"]),
        ("TeenNick", .kids, ["teennick", "teen nick"]),
        ("Cartoon Network", .kids, ["cartoon network"]),
        ("Boomerang", .kids, ["boomerang"]),
        ("Universal Kids", .kids, ["universal kids"]),
        ("Discovery Family", .kids, ["discovery family"]),
        ("HBO", .movies, ["hbo"]),
        ("HBO 2", .movies, ["hbo 2", "hbo2"]),
        ("HBO Signature", .movies, ["hbo signature"]),
        ("HBO Family", .movies, ["hbo family"]),
        ("HBO Comedy", .movies, ["hbo comedy"]),
        ("HBO Zone", .movies, ["hbo zone"]),
        ("HBO Hits", .movies, ["hbo hits"]),
        ("HBO Drama", .movies, ["hbo drama"]),
        ("HBO Movies", .movies, ["hbo movies"]),
        ("Cinemax", .movies, ["cinemax"]),
        ("Showtime", .movies, ["showtime", "sho"]),
        ("Showtime 2", .movies, ["showtime 2", "sho 2"]),
        ("Starz", .movies, ["starz"]),
        ("Starz Encore", .movies, ["starz encore", "encore"]),
        ("MGM+", .movies, ["mgm plus", "mgm", "epix"]),
        ("TCM", .movies, ["tcm", "turner classic movies"]),
        ("The Movie Channel", .movies, ["the movie channel", "tmc", "movie channel"]),
        ("FXM", .movies, ["fxm", "fx movie channel"])
    ]

    /// Alias (core key) → network.
    static let byAlias: [String: (name: String, category: LineupCategory)] = {
        var map: [String: (name: String, category: LineupCategory)] = [:]
        for entry in list { for alias in entry.aliases where map[alias] == nil { map[alias] = (entry.name, entry.category) } }
        return map
    }()
}

/// US states, cities and regions: a channel named after one ("FOX 5 [SAN
/// DIEGO]", "NBC Sports Boston") is regional and only suggested to viewers
/// in that market.
enum RegionWords {
    static let words: [String] = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware",
        "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky",
        "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi",
        "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island",
        "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont", "virginia", "washington",
        "west virginia", "wisconsin", "wyoming", "atlanta", "austin", "baltimore", "birmingham", "boston",
        "brooklyn", "buffalo", "charlotte", "chicago", "cincinnati", "cleveland", "columbus", "dallas",
        "denver", "detroit", "el paso", "fresno", "hartford", "honolulu", "houston", "indianapolis",
        "jacksonville", "kansas city", "las vegas", "los angeles", "louisville", "memphis", "miami",
        "milwaukee", "minneapolis", "nashville", "new orleans", "newark", "oakland", "oklahoma city",
        "omaha", "orlando", "philadelphia", "phoenix", "pittsburgh", "portland", "providence", "raleigh",
        "richmond", "sacramento", "salt lake", "san antonio", "san diego", "san francisco", "san jose",
        "seattle", "st louis", "saint louis", "tampa", "tucson", "tulsa", "washington dc", "bay area",
        "new england", "mid atlantic", "midwest", "northwest", "southwest", "southeast", "sun",
        "rocky mountain", "great lakes", "carolinas", "tri state", "socal", "norcal", "long island",
        "hudson valley", "westchester", "bronx", "queens", "staten island", "abilene", "burlington",
        "gainesville", "wheeling"
    ]

    /// One alternation, longest first ("new york" before "york").
    static let pattern: String = "\\b(" + words.sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
}
