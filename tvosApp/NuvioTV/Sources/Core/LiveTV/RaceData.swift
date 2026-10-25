import Foundation

// MARK: - Race weekend extras (F1)
//
// Driver photos, numbers and official team colors (for the cameras panel),
// and each finished session's top 3 (for the race tile, scores on only),
// from OpenF1's free data.
//
// Kept to a handful of requests a race weekend:
// - the weekend's session list: once, then again only when a session the
//   schedule has isn't in it (at most every 3 hours) or after a day;
// - the drivers: once a weekend;
// - a session's result: once, 10 minutes after it ends (retried every 20
//   minutes until it's there);
// - only while Live Events or the cameras panel shows an F1 weekend, one
//   request at a time, at most `dailyCap` a day; a failure waits 30 minutes.
// Nothing about the viewer is sent.

struct RaceDriver: Codable, Hashable {
    let number: Int
    /// "NOR".
    let code: String
    /// "Lando Norris".
    let name: String
    let team: String
    /// "F47600".
    let color: String?
    let headshot: String?
}

@MainActor
final class RaceData: ObservableObject {
    static let shared = RaceData()

    /// Bumped when drivers or results change.
    @Published private(set) var revision = 0

    struct Session: Codable {
        let key: Int
        /// "fp1", "qual", "race"… (`RaceSession.kind`).
        let kind: String
        let start: Date
        let end: Date?
    }

    private struct Saved: Codable {
        var meetingKey: Int?
        var sessions: [Session] = []
        var sessionsAt: Date?
        var drivers: [RaceDriver] = []
        var driversMeeting: Int?
        var driversAt: Date?
        /// Session key → driver numbers, first three places.
        var results: [String: [Int]] = [:]
        var resultTried: [String: Date] = [:]
        /// Session key → tries so far (a session with no result is given up after 6).
        var resultTries: [String: Int]? = nil
        var requestDay: String?
        var requestCount = 0
    }

    private static let dailyCap = 60
    private static let base = "https://api.openf1.org/v1/"

    private var saved = Saved()
    private var loaded = false
    private var task: Task<Void, Never>?
    private var nextAllowed = Date.distantPast
    private var byName: [String: RaceDriver] = [:]
    private let file: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("race-data.json")
    }

    // MARK: Lookups (no requests)

    /// A driver by a camera's name ("Lewis Hamilton", "Hamilton").
    func driver(named name: String) -> RaceDriver? {
        load()
        let key = Self.fold(name).replacingOccurrences(of: " jr.", with: "").trimmingCharacters(in: .whitespaces)
        if let match = byName[key] { return match }
        if let last = key.split(separator: " ").last { return byName[String(last)] }
        return nil
    }

    /// The top 3 of a finished session of the weekend, when known.
    func top3(kind: String, start: Date) -> [RaceDriver]? {
        load()
        guard let session = saved.sessions.first(where: { $0.kind == kind && abs($0.start.timeIntervalSince(start)) < 3 * 3600 }),
              let numbers = saved.results[String(session.key)], !numbers.isEmpty else { return nil }
        let drivers = numbers.prefix(3).compactMap { number in saved.drivers.first { $0.number == number } }
        return drivers.isEmpty ? nil : drivers
    }

    // MARK: Refresh

    /// An F1 weekend is on screen: fetch what's missing, if anything. Cheap
    /// to call often (returns right away when nothing is due).
    /// - Parameters:
    ///   - sessions: the weekend's sessions from the schedule (kind, start).
    ///   - results: also finished sessions' top 3 (Show scores on).
    func refreshIfNeeded(sessions: [(kind: String, start: Date)], results: Bool) {
        load()
        let now = Date()
        guard task == nil, now >= nextAllowed else { return }
        let plan = due(sessions: sessions, results: results, now: now)
        guard plan.sessions || plan.drivers || !plan.results.isEmpty else { return }
        var asked: [String] = []
        if plan.sessions { asked.append("sessions") }
        if plan.drivers { asked.append("drivers") }
        if !plan.results.isEmpty { asked.append("\(plan.results.count) results") }
        CrashRecorder.note("race data: asking for " + asked.joined(separator: ", "))
        task = Task { [weak self] in
            await self?.run(plan)
            self?.task = nil
        }
    }

    private struct Plan {
        var sessions = false
        var drivers = false
        var results: [Int] = []
    }

    private func due(sessions wanted: [(kind: String, start: Date)], results: Bool, now: Date) -> Plan {
        var plan = Plan()
        let known = wanted.allSatisfy { item in
            saved.sessions.contains { $0.kind == item.kind && abs($0.start.timeIntervalSince(item.start)) < 3 * 3600 }
        }
        let sessionsAge = saved.sessionsAt.map { now.timeIntervalSince($0) } ?? .infinity
        plan.sessions = sessionsAge > 24 * 3600 || (!known && sessionsAge > 3 * 3600)
        let driversAge = saved.driversAt.map { now.timeIntervalSince($0) } ?? .infinity
        plan.drivers = saved.drivers.isEmpty || driversAge > 4 * 86_400
            || (saved.meetingKey != nil && saved.driversMeeting != saved.meetingKey && driversAge > 3600)
        if results {
            for session in saved.sessions where saved.results[String(session.key)] == nil {
                let end = session.end ?? session.start.addingTimeInterval(RaceSession.length(session.kind))
                guard now.timeIntervalSince(end) > 10 * 60, now.timeIntervalSince(end) < 4 * 86_400 else { continue }
                if let tried = saved.resultTried[String(session.key)], now.timeIntervalSince(tried) < 20 * 60 { continue }
                if (saved.resultTries?[String(session.key)] ?? 0) >= 6 { continue }
                plan.results.append(session.key)
                if plan.results.count == 2 { break }
            }
        }
        return plan
    }

    private func run(_ plan: Plan) async {
        var changed = false
        var failed = false
        if plan.sessions {
            if let data = await get("sessions?meeting_key=latest") {
                let parsed = await Task.detached(priority: .utility) { Self.parseSessions(data) }.value
                if let meeting = parsed.meeting { saved.meetingKey = meeting }
                if !parsed.sessions.isEmpty { saved.sessions = parsed.sessions.sorted { $0.start < $1.start } }
                saved.sessionsAt = Date()
                changed = true
            } else {
                failed = true
            }
        }
        if plan.drivers || (changed && saved.driversMeeting != saved.meetingKey), !failed {
            if plan.sessions { try? await Task.sleep(nanoseconds: 700_000_000) }
            if let data = await get("drivers?session_key=latest") {
                let parsed = await Task.detached(priority: .utility) { Self.parseDrivers(data) }.value
                if !parsed.drivers.isEmpty {
                    saved.drivers = parsed.drivers
                    saved.driversMeeting = parsed.meeting ?? saved.meetingKey
                    rebuildNames()
                }
                saved.driversAt = Date()
                changed = true
            } else {
                failed = true
            }
        }
        for key in plan.results where !failed {
            try? await Task.sleep(nanoseconds: 700_000_000)
            saved.resultTried[String(key)] = Date()
            saved.resultTries = (saved.resultTries ?? [:]).merging([String(key): (saved.resultTries?[String(key)] ?? 0) + 1]) { _, new in new }
            if let data = await get("session_result?session_key=\(key)") {
                let top = await Task.detached(priority: .utility) { Self.parseResult(data) }.value
                if !top.isEmpty {
                    saved.results[String(key)] = top
                    changed = true
                }
            } else {
                failed = true
            }
        }
        if failed { nextAllowed = Date().addingTimeInterval(30 * 60) }
        // Only this weekend's results are kept.
        let keys = Set(saved.sessions.map { String($0.key) })
        saved.results = saved.results.filter { keys.contains($0.key) }
        saved.resultTried = saved.resultTried.filter { keys.contains($0.key) }
        saved.resultTries = saved.resultTries?.filter { keys.contains($0.key) }
        save()
        if changed { revision &+= 1 }
        CrashRecorder.note("race data: \(saved.sessions.count) sessions, \(saved.drivers.count) drivers, "
                           + "\(saved.results.count) results, \(saved.requestCount) requests today\(failed ? ", failed" : "")")
    }

    // MARK: Requests

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// One request; nil on failure or when today's cap is reached.
    private func get(_ path: String) async -> Data? {
        let today = Self.dayKey.string(from: Date())
        if saved.requestDay != today { saved.requestDay = today; saved.requestCount = 0 }
        guard saved.requestCount < Self.dailyCap, let url = URL(string: Self.base + path) else { return nil }
        saved.requestCount += 1
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }

    // MARK: Parsing

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    nonisolated private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// "Nico Hülkenberg" → "nico hulkenberg".
    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    nonisolated private static func list(_ data: Data) -> [[String: Any]] {
        autoreleasepool { ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? [] }
    }

    nonisolated private static func parseSessions(_ data: Data) -> (meeting: Int?, sessions: [Session]) {
        let items = list(data)
        return (items.first.flatMap { int($0["meeting_key"]) }, items.compactMap { session($0) })
    }

    nonisolated private static func parseDrivers(_ data: Data) -> (meeting: Int?, drivers: [RaceDriver]) {
        let items = list(data)
        return (items.first.flatMap { int($0["meeting_key"]) }, items.compactMap { parseDriver($0) })
    }

    /// Driver numbers of the first three places.
    nonisolated private static func parseResult(_ data: Data) -> [Int] {
        let placed = list(data).compactMap { item -> (Int, Int)? in
            guard let position = int(item["position"]), let number = int(item["driver_number"]) else { return nil }
            return (position, number)
        }.sorted { $0.0 < $1.0 }
        return placed.prefix(3).map { $0.1 }
    }

    nonisolated private static func session(_ item: [String: Any]) -> Session? {
        guard let key = int(item["session_key"]), let start = date(item["date_start"]) else { return nil }
        let name = (item["session_name"] as? String) ?? (item["session_type"] as? String) ?? ""
        return Session(key: key, kind: RaceSession.kind(name), start: start, end: date(item["date_end"]))
    }

    nonisolated private static func parseDriver(_ item: [String: Any]) -> RaceDriver? {
        guard let number = int(item["driver_number"]) else { return nil }
        let first = item["first_name"] as? String ?? ""
        let last = item["last_name"] as? String ?? ""
        var name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if name.isEmpty { name = item["full_name"] as? String ?? "#\(number)" }
        let color = (item["team_colour"] as? String).flatMap { $0.count == 6 ? $0.uppercased() : nil }
        return RaceDriver(number: number, code: item["name_acronym"] as? String ?? String(last.prefix(3)).uppercased(),
                          name: name, team: item["team_name"] as? String ?? "", color: color,
                          headshot: item["headshot_url"] as? String)
    }

    // MARK: NASCAR drivers
    //
    // Photos and car numbers for the cameras panel's in-car feeds, from
    // NASCAR's driver list: fetched at most once a week (6 hours after a
    // failure), only when a NASCAR race's cameras panel opens.

    private struct NascarSaved: Codable {
        var drivers: [RaceDriver] = []
        var fetchedAt: Date?
    }
    private var nascarSaved: NascarSaved?
    private var nascarByName: [String: RaceDriver] = [:]
    private var nascarTask: Task<Void, Never>?
    private var nascarNextAllowed = Date.distantPast
    private var nascarFile: URL { file.deletingLastPathComponent().appendingPathComponent("nascar-drivers.json") }

    /// A NASCAR driver by an in-car feed's name ("Kyle Larson").
    func nascarDriver(named name: String) -> RaceDriver? {
        loadNascar()
        return nascarByName[Self.fold(Self.bareName(name))]
    }

    /// The cameras panel opened on a NASCAR race: the driver list if it's
    /// missing or a week old.
    func refreshNascarIfNeeded() {
        loadNascar()
        let now = Date()
        guard nascarTask == nil, now >= nascarNextAllowed else { return }
        if let fetched = nascarSaved?.fetchedAt, now.timeIntervalSince(fetched) < 7 * 86_400, !(nascarSaved?.drivers.isEmpty ?? true) { return }
        CrashRecorder.note("race data: asking for NASCAR drivers")
        nascarTask = Task { [weak self] in
            guard let self else { return }
            var drivers: [RaceDriver] = []
            if let url = URL(string: "https://cf.nascar.com/cacher/drivers.json") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                if let result = try? await URLSession.shared.data(for: request),
                   (result.1 as? HTTPURLResponse)?.statusCode == 200 {
                    let data = result.0
                    drivers = await Task.detached(priority: .utility) { Self.parseNascar(data) }.value
                }
            }
            if drivers.isEmpty {
                self.nascarNextAllowed = Date().addingTimeInterval(6 * 3600)
            } else {
                self.nascarSaved = NascarSaved(drivers: drivers, fetchedAt: Date())
                self.rebuildNascarNames()
                if let data = try? JSONEncoder().encode(self.nascarSaved) { try? data.write(to: self.nascarFile, options: .atomic) }
                self.revision &+= 1
            }
            CrashRecorder.note("race data: NASCAR \(drivers.count) drivers with photos\(drivers.isEmpty ? ", failed" : "")")
            self.nascarTask = nil
        }
    }

    private func loadNascar() {
        guard nascarSaved == nil else { return }
        if let data = try? Data(contentsOf: nascarFile), let value = try? JSONDecoder().decode(NascarSaved.self, from: data) {
            nascarSaved = value
        } else {
            nascarSaved = NascarSaved()
        }
        rebuildNascarNames()
    }

    private func rebuildNascarNames() {
        var names: [String: RaceDriver] = [:]
        for driver in nascarSaved?.drivers ?? [] {
            let key = Self.fold(Self.bareName(driver.name))
            if names[key] == nil { names[key] = driver }
        }
        nascarByName = names
    }

    /// "Sammy Smith (C)" → "Sammy Smith".
    nonisolated private static func bareName(_ name: String) -> String {
        var value = (name.components(separatedBy: "(").first ?? name).replacingOccurrences(of: ".", with: "")
        value = value.trimmingCharacters(in: .whitespaces)
        for suffix in [" Jr", " Sr", " II", " III"] where value.hasSuffix(suffix) { value = String(value.dropLast(suffix.count)) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Drivers with a real photo, Cup Series first (the same name can be in
    /// several series).
    nonisolated private static func parseNascar(_ data: Data) -> [RaceDriver] {
        let root = autoreleasepool { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        let items = (root?["response"] as? [[String: Any]]) ?? []
        var cup: [RaceDriver] = []
        var other: [RaceDriver] = []
        for item in items {
            let name = bareName(item["Full_Name"] as? String ?? "")
            guard name.contains(" ") else { continue }
            let small = item["Image_Small"] as? String
            let large = item["Image"] as? String
            guard let photo = [small, large].compactMap({ $0 }).first(where: { url in
                url.hasPrefix("https://") && !url.contains("default.png") && !url.lowercased().contains("silhouette")
            }) else { continue }
            let badge = (item["Badge"] as? String) ?? int(item["Badge"]).map(String.init) ?? ""
            let driver = RaceDriver(number: Int(badge) ?? 0, code: badge, name: name, team: item["Team"] as? String ?? "",
                                    color: nil, headshot: photo)
            if (item["Driver_Series"] as? String) == "nascar-cup-series" { cup.append(driver) } else { other.append(driver) }
        }
        return cup + other
    }

    // MARK: Storage

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value
            rebuildNames()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    private func rebuildNames() {
        var names: [String: RaceDriver] = [:]
        for driver in saved.drivers {
            let full = Self.fold(driver.name)
            names[full] = driver
            if let last = full.split(separator: " ").last { names[String(last)] = driver }
        }
        byName = names
    }
}
