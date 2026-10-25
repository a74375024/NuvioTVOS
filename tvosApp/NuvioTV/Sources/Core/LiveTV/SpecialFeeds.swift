import Foundation

/// A camera or alternate view of an event: F1 onboards, the driver tracker,
/// NASCAR driver cams, a race's main and Sky feeds.
struct CameraFeed: Identifiable, Equatable {
    enum Kind: Int {
        case main = 0, alt, mixed, tracker, data, podium, multiview, driver
    }
    let channel: LiveTVChannel
    /// "Lewis Hamilton", "Driver Tracker", "Sky Sports F1".
    let title: String
    /// "Ferrari", "Bird's-eye map", "Follows the leader".
    let detail: String
    let kind: Kind
    /// Team, for drivers (colors and grouping).
    let team: String?
    /// Other channels carrying the same camera (automatic backups).
    var alternates: [LiveTVChannel] = []
    /// The car number (NASCAR in-car feeds).
    var number: Int? = nil
    var id: String { channel.id }
}

/// Recognizes the lineup's special sports feeds by name: whip-around channels
/// (NFL RedZone, MLB Strike Zone, soccer conference feeds) and the cameras of
/// a race. Pure; no requests.
enum SpecialFeeds {

    // MARK: Whip-arounds

    struct Whip: Equatable {
        /// Live Events row group the tile goes in ("NFL", "MLB", "Soccer").
        let group: String
        let short: String
        let title: String
        let subtitle: String
        /// Live games in the group before the tile shows.
        let minimumLive: Int
        /// NFL RedZone only runs on Sunday afternoons (Eastern).
        let sundayAfternoon: Bool
    }

    /// The whip-around a channel is, by its name; nil for anything else.
    static func whip(named name: String) -> Whip? {
        let lower = name.lowercased()
        if lower.contains("redzone") || lower.contains("red zone") {
            return Whip(group: "NFL", short: "NFL", title: "NFL RedZone", subtitle: "Every game, every score",
                        minimumLive: 1, sundayAfternoon: true)
        }
        if lower.contains("strike zone") {
            return Whip(group: "MLB", short: "MLB", title: "MLB Strike Zone", subtitle: "Every big moment",
                        minimumLive: 2, sundayAfternoon: false)
        }
        if lower.contains("big inning") {
            return Whip(group: "MLB", short: "MLB", title: "MLB Big Inning", subtitle: "Every big moment",
                        minimumLive: 2, sundayAfternoon: false)
        }
        if lower.contains("konferenz") || lower.contains("goal zone") || lower.contains("goal rush") || lower.contains("multiplex") {
            return Whip(group: "Soccer", short: "SOC", title: "Conference feed", subtitle: "Every match, one feed",
                        minimumLive: 2, sundayAfternoon: false)
        }
        return nil
    }

    // MARK: Cameras

    /// A channel worth indexing as a camera (cheap test over the whole list).
    static func isCameraName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("f1 cam") || lower.contains("f1 tv cam") || lower.contains("driver cam")
            || (lower.contains("multiview") && (lower.contains("nascar") || lower.contains("driver")))
            || carCamera(lower) != nil || isF1CameraName(name)
    }

    /// An in-car camera named by car: "YellaWood 500: No. 5 Kyle Larson
    /// (10.25 1:45PM ET)" → (5, "Kyle Larson"). Cheap test first.
    static func carCamera(_ title: String) -> (number: Int, driver: String)? {
        // Not a ranked game ("No. 5 Texas vs No. 8 Ohio State").
        guard title.range(of: ": no", options: .caseInsensitive) != nil, !SportsMatcher.looksLikeGame(title),
              let range = title.range(of: ": ?No\\.? ?[0-9]{1,3} ", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let number = Int(title[range].filter(\.isNumber)) ?? 0
        let rest = title[range.upperBound...]
        let name = (rest.components(separatedBy: "(").first ?? String(rest)).trimmingCharacters(in: .whitespaces)
        // A person's name: two to four words, no digits or dashes, not
        // another ranking ("No. 5 Oregon - No. 8 Ohio State").
        let words = name.split(separator: " ")
        guard number > 0, (2...4).contains(words.count), !name.contains(where: { $0.isNumber }), !name.contains(" - "),
              name.range(of: "no.", options: .caseInsensitive) == nil else { return nil }
        // Not a team sport's show ("College GameDay: No. 3 Texas A&M Aggies").
        let head = title[..<range.lowerBound].lowercased()
        let teamWords = ["football", "basketball", "volleyball", "soccer", "tennis", "golf", "court", "gameday", "network",
                         "baseball", "hockey", "softball", "wimbledon"]
        guard !teamWords.contains(where: { head.contains($0) }) else { return nil }
        return (number, name)
    }

    /// Race parts of in-car and multiview titles that name no particular race.
    static let genericNascarRaces: Set<String> = ["nascar", "nascar cup", "nascar cup series"]

    /// The race an in-car feed or multiview belongs to: "YellaWood 500:
    /// No. 5 Kyle Larson" → "yellawood 500"; nil for other cameras.
    static func cameraRace(_ title: String) -> String? {
        let lower = title.lowercased()
        if carCamera(title) != nil, let cut = lower.range(of: ": no") {
            let race = lower[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
            return race.count >= 4 ? race : nil
        }
        // The time in brackets ("(10.25 1:40PM ET)") isn't part of the name.
        let base = lower.components(separatedBy: "(").first ?? lower
        if base.contains("multiview"), let cut = base.range(of: ":", options: .backwards) {
            let race = base[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
            return race.count >= 4 ? race : nil
        }
        return nil
    }

    /// 2026 teams, longest names first (so "Red Bull Racing" wins over "Red Bull").
    static let f1Teams: [(name: String, color: String)] = [
        ("Haas F1 Team", "B6BABD"), ("Red Bull Racing", "1E41FF"), ("Racing Bulls", "6692FF"), ("Aston Martin", "00665E"),
        ("Kick Sauber", "52E252"), ("McLaren", "FF8000"), ("Ferrari", "DC0000"), ("Mercedes", "00D2BE"), ("Williams", "00A0DE"),
        ("Alpine", "FF87BC"), ("Audi", "E00000"), ("Cadillac", "C9A227"), ("Sauber", "52E252"), ("Haas", "B6BABD")
    ]

    static func teamColor(_ team: String?) -> String? {
        guard let team else { return nil }
        return f1Teams.first { $0.name == team }?.color
    }

    static func isF1(_ event: SportsEvent) -> Bool {
        if event.leagueShort == "NASCAR" || event.game?.leagueShort == "NASCAR" { return false }
        if event.leagueShort == "F1" { return true }
        let text = (event.title + " " + event.league + " " + (event.family ?? "")).lowercased()
        return RX.test("\\b(formula ?1|formula one|f1)\\b", text)
    }

    static func isNASCAR(_ event: SportsEvent) -> Bool {
        if event.leagueShort == "NASCAR" || event.game?.leagueShort == "NASCAR" { return true }
        let text = (event.title + " " + event.league).lowercased()
        if text.contains("nascar") || text.contains("cup series") || text.contains("xfinity") || text.contains("truck series") { return true }
        // A race named only by its sponsor ("YellaWood 500", league
        // Motorsport or unknown): its cameras still have to share its name.
        return (event.league == "Motorsport" || event.league == "Other" || event.league.isEmpty) && event.game == nil && !isF1(event)
    }

    private static let stopWords: Set<String> = [
        "nascar", "series", "motor", "sports", "racing", "race", "cup", "xfinity", "truck", "trucks", "driver", "drivers",
        "multiview", "featured", "chase", "leaders", "live", "practice", "qualifying", "round", "stage", "formula"
    ]

    /// Distinctive words of a title ("YellaWood 500 at Talladega" → yellawood, talladega).
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 5 && !stopWords.contains($0) })
    }

    /// The cameras for an event, best first: its own feeds (main, Sky…),
    /// then mixed onboard, tracker, data, podium feeds, multiviews and
    /// every driver. Empty for events without cameras.
    static func cameras(for event: SportsEvent, eventFeeds: [LiveTVChannel], candidates: [LiveTVChannel]) -> [CameraFeed] {
        var feeds: [CameraFeed] = []
        if isF1(event) { feeds = f1Cameras(eventFeeds: eventFeeds, candidates: candidates) }
        else if isNASCAR(event) { feeds = nascarCameras(event: event, eventFeeds: eventFeeds, candidates: candidates) }
        // Only the race's own feeds isn't a cameras panel.
        guard feeds.contains(where: { $0.kind != .main && $0.kind != .alt }) else { return [] }
        return feeds
    }

    private static func ownFeeds(_ eventFeeds: [LiveTVChannel]) -> [CameraFeed] {
        var result: [CameraFeed] = []
        for (index, channel) in eventFeeds.enumerated() {
            let lower = channel.name.lowercased()
            if lower.contains("sky sports") {
                result.append(CameraFeed(channel: channel, title: "Sky Sports", detail: "Sky commentary", kind: .alt, team: nil))
            } else if lower.contains("main broadcast") || index == 0 {
                result.append(CameraFeed(channel: channel, title: "Main broadcast", detail: "The race feed", kind: .main, team: nil))
            } else {
                result.append(CameraFeed(channel: channel, title: "Feed \(index + 1)", detail: "Another feed", kind: .alt, team: nil))
            }
        }
        return result
    }

    private static func f1Cameras(eventFeeds: [LiveTVChannel], candidates: [LiveTVChannel]) -> [CameraFeed] {
        // The provider family of the race feed first ("(Apple) (F1) …" →
        // "(Apple F1 CAM) …"); every other set of the same cameras (F1 TV
        // cams, "Driver | Team | CODE" channels) joins as automatic backups.
        let apple = candidates.filter { $0.name.lowercased().contains("apple f1 cam") }
        let f1tv = candidates.filter { $0.name.lowercased().contains("f1 tv cam") }
        let others = candidates.filter { channel in
            let lower = channel.name.lowercased()
            return !lower.contains("apple f1 cam") && !lower.contains("f1 tv cam") && isF1CameraName(channel.name)
        }
        let prefersApple = eventFeeds.contains { $0.name.lowercased().contains("apple") }
        var result = ownFeeds(eventFeeds)
        for channel in (prefersApple ? apple + f1tv : f1tv + apple) + others {
            if let feed = f1Camera(channel) { result.append(feed) }
        }
        return sorted(result, f1: true)
    }

    /// The other F1 camera sets: "Lewis Hamilton | Ferrari | HAM",
    /// "F1: LEWIS HAMILTON | FERRARI | HAM", "F1 DATA", "F1: F1-TRACKER".
    static func isF1CameraName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if ["f1 data", "f1 tracker", "f1: f1-data", "f1: f1-tracker"].contains(lower) { return true }
        return pipeDriver(name) != nil
    }

    /// "F1: LEWIS HAMILTON | FERRARI | HAM" → ("Lewis Hamilton", "Ferrari").
    private static func pipeDriver(_ name: String) -> (driver: String, team: String?)? {
        guard name.contains(" | ") else { return nil }
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.uppercased().hasPrefix("F1: ") { text = String(text.dropFirst(4)) }
        let parts = text.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[2].count == 3, parts[2].allSatisfy({ $0.isLetter }), parts[2] == parts[2].uppercased(),
              parts[0].contains(" ") else { return nil }
        let driver = parts[0] == parts[0].uppercased() ? parts[0].capitalized : parts[0]
        // Only an F1 team ("BBC One | UK | ENG" isn't a driver).
        guard let team = f1Teams.first(where: { $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame })?.name else { return nil }
        return (driver, team)
    }

    /// One F1 camera channel as a camera, in any of the naming sets.
    private static func f1Camera(_ channel: LiveTVChannel) -> CameraFeed? {
        if let pipe = pipeDriver(channel.name) {
            return CameraFeed(channel: channel, title: pipe.driver, detail: pipe.team ?? "Onboard", kind: .driver, team: pipe.team)
        }
        let label: String
        if let close = channel.name.firstIndex(of: ")") {
            label = channel.name[channel.name.index(after: close)...].trimmingCharacters(in: .whitespaces)
        } else {
            // "F1 DATA", "F1: F1-TRACKER".
            label = channel.name.replacingOccurrences(of: "F1:", with: "").replacingOccurrences(of: "F1-", with: "")
                .replacingOccurrences(of: "F1 ", with: "").trimmingCharacters(in: .whitespaces)
        }
        guard !label.isEmpty else { return nil }
        let lower = label.lowercased()
        if lower.contains("mixed") {
            return CameraFeed(channel: channel, title: "Mixed onboard", detail: "Switches cars", kind: .mixed, team: nil)
        }
        if lower.contains("tracker") {
            return CameraFeed(channel: channel, title: "Driver Tracker", detail: "Bird's-eye map", kind: .tracker, team: nil)
        }
        if lower.contains("data") {
            return CameraFeed(channel: channel, title: "Driver Data", detail: "Live telemetry", kind: .data, team: nil)
        }
        if let podium = lower.range(of: "^p[1-3]\\b", options: .regularExpression) {
            let place = lower[podium].uppercased()
            return CameraFeed(channel: channel, title: "\(place) driver", detail: "Follows \(place)", kind: .podium, team: nil)
        }
        let team = f1Teams.first { lower.hasPrefix($0.name.lowercased() + " ") }
        let driver = team.map { String(label.dropFirst($0.name.count)).trimmingCharacters(in: .whitespaces) } ?? label
        return CameraFeed(channel: channel, title: driver, detail: team?.name ?? "Onboard", kind: .driver, team: team?.name)
    }

    private static func nascarCameras(event: SportsEvent, eventFeeds: [LiveTVChannel], candidates: [LiveTVChannel]) -> [CameraFeed] {
        let key = words(event.title)
        guard !key.isEmpty else { return [] }
        var result = ownFeeds(eventFeeds)
        var seen = Set(eventFeeds.map(\.id))
        for channel in candidates where seen.insert(channel.id).inserted {
            let title = channel.name.components(separatedBy: "|").last ?? channel.name
            let lower = title.lowercased()
            // Its own name, or a NASCAR feed that names no race ("NASCAR: No 5 Kyle Larson").
            guard !words(title).isDisjoint(with: key) || genericNascarRaces.contains(cameraRace(title) ?? "") else { continue }
            if let car = carCamera(title) {
                // "YellaWood 500: No. 5 Kyle Larson" (HBO's in-car feeds).
                result.append(CameraFeed(channel: channel, title: car.driver, detail: "No. \(car.number)", kind: .driver,
                                         team: nil, number: car.number))
            } else if lower.contains("multiview") {
                // "YellaWood 500: NASCAR Chase Leaders Multiview (10.25 1:40PM ET)" → "Chase Leaders Multiview".
                let bare = title.components(separatedBy: "(").first ?? title
                var label = (bare.components(separatedBy: ":").last ?? bare).trimmingCharacters(in: .whitespaces)
                if label.lowercased().hasPrefix("nascar ") { label = String(label.dropFirst(7)) }
                result.append(CameraFeed(channel: channel, title: label, detail: "Several cars at once", kind: .multiview, team: nil))
            } else if let cam = title.range(of: "driver cam", options: .caseInsensitive) {
                // "Motor Sports: Sheldon Creed Talladega Driver Cam (…)" → "Sheldon Creed".
                let before = String(title[title.startIndex..<cam.lowerBound])
                let tail = (before.components(separatedBy: ":").last ?? before)
                let name = (tail.components(separatedBy: "•").last ?? tail)
                    .split(separator: " ").filter { !key.contains($0.lowercased()) }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                result.append(CameraFeed(channel: channel, title: name.isEmpty ? "Driver cam" : name, detail: "In-car camera",
                                         kind: .driver, team: nil))
            }
        }
        // Drivers by car number.
        let drivers = result.filter { $0.kind == .driver }.sorted { ($0.number ?? 999) < ($1.number ?? 999) }
        return sorted(result.filter { $0.kind != .driver } + drivers)
    }

    /// One entry per camera (the same driver on several feeds keeps the
    /// others as backups), in kind order.
    private static func sorted(_ feeds: [CameraFeed], f1: Bool = false) -> [CameraFeed] {
        var merged: [CameraFeed] = []
        var index: [String: Int] = [:]
        for feed in feeds {
            // F1 drivers by surname (one per surname on the grid): "Carlos
            // Sainz Jr." and "Carlos Sainz", "Kimi Antonelli" and "Andrea Kimi
            // Antonelli" are one camera.
            var name = feed.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            if f1, feed.kind == .driver {
                name = name.replacingOccurrences(of: " jr.", with: "").replacingOccurrences(of: " jr", with: "")
                name = name.split(separator: " ").last.map(String.init) ?? name
            }
            let key = "\(feed.kind.rawValue)|\(name)"
            if let at = index[key] {
                merged[at].alternates.append(feed.channel)
            } else {
                index[key] = merged.count
                merged.append(feed)
            }
        }
        return merged.enumerated().sorted { a, b in
            a.element.kind.rawValue != b.element.kind.rawValue ? a.element.kind.rawValue < b.element.kind.rawValue : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Followed drivers

    private static let followedKey = "nuvio.tv.livetv.followedDrivers"

    static var followedDrivers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: followedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: followedKey) }
    }
}
