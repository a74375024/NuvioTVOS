import Foundation

// MARK: - Live status and scores
//
// While Live Events is open, each league with a game on now (or starting
// within 5 minutes) is asked for today's scoreboard: one request covers
// every game in it. That gives each game's state (not started, live,
// delayed, final, postponed), its clock, and the score and situation.
//
// Kept gentle on the source:
// - only while Live Events is on screen, never in the background or
//   while watching;
// - only leagues with a game in its window, one request at a time;
// - once a minute while a game is live (every 2 minutes with scores off,
//   or when a league's scoreboard is large); every 2 minutes around a
//   game's start;
// - a failed request backs that league off (2 → 5 → 15 → 30 minutes);
// - at most `dailyCap` requests a day, then nothing until tomorrow.
// Nothing about the viewer is sent.

/// Where a game stands, from the live scoreboard.
enum LivePhase: String, Codable {
    case pre, live, delayed, final, postponed
}

struct LiveStatus: Equatable {
    var phase: LivePhase
    /// "Q3 4:12", "Halftime", "Bot 8th", "67'", "2nd 11:02", "Final/OT".
    var detail: String
    var homeScore: String?
    var awayScore: String?
    /// The team with the ball (football), by team id.
    var possession: String?
    /// "3rd & 7 at MICH 35", "2 outs · 3-1 count".
    var situation: String?
    var redZone = false
    /// Runners on first, second and third (baseball).
    var bases: [Bool]?
    var lastPlay: String?
    /// A fight card part: fights finished and in all, and the fight on now
    /// (or next): names and country codes. Never who won.
    var boutsDone: Int?
    var boutsTotal: Int?
    var boutA: String?
    var boutB: String?
    var boutACountry: String?
    var boutBCountry: String?
}

@MainActor
final class LiveScores: ObservableObject {
    static let shared = LiveScores()

    static let showScoresKey = "nuvio.tv.livetv.showScores"
    /// Show scores and the game situation. Off still uses the live status
    /// (clock, halftime, final) to keep rows right, without numbers.
    static var showsScores: Bool {
        get { UserDefaults.standard.object(forKey: showScoresKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showScoresKey) }
    }

    /// Requests a day, at most.
    static let dailyCap = 500
    private static let dayKeyDefaults = "nuvio.tv.livetv.scoresDay"
    private static let countDefaults = "nuvio.tv.livetv.scoresCount"

    /// Game id ("NFL|401…", "UFC|600…|main") → its live status.
    private(set) var statuses: [String: LiveStatus] = [:]
    /// Game id → when it was first seen final (finished games stay in their
    /// row as Final for a while).
    private(set) var finalSeen: [String: Date] = [:]
    /// Bumped when statuses change.
    @Published private(set) var revision = 0

    private var loop: Task<Void, Never>?
    private var nextDue: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var lastBytes: [String: Int] = [:]
    private var cappedNoted = false
    /// Game id → polls whose scoreboard didn't list it; after 3 it stops
    /// keeping its league polled.
    private var missing: [String: Int] = [:]
    /// Request times in the last hour (pace: at most `hourlyPace` an hour
    /// before intervals stretch to 5 minutes).
    private var recent: [Date] = []
    private static let hourlyPace = 120

    private static let etDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let localDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Who's looking: "board" (Live Events on screen) and "guide" (the
    /// in-player event guide). Polling runs while anyone is.
    private var holders = Set<String>()

    /// Live Events opened (or the in-player guide): start looking, right
    /// away for anything due. The guide also polls while a channel plays.
    func start(_ holder: String = "board") {
        holders.insert(holder)
        guard SportsData.isEnabled else { return }
        if holder == "guide", loop != nil {
            // Look now instead of after the current wait (due times still apply).
            loop?.cancel()
            loop = nil
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.pollDue()
                try? await Task.sleep(nanoseconds: UInt64(max(15, wait) * 1_000_000_000))
            }
        }
    }

    /// Live Events (or the guide) closed: stop asking once nobody's looking.
    func stop(_ holder: String = "board") {
        holders.remove(holder)
        guard holders.isEmpty else { return }
        loop?.cancel()
        loop = nil
    }

    /// The scores setting changed: the next poll uses the new pace.
    func settingsChanged() {
        revision &+= 1
    }

    /// Statuses for the parts of one card, by part game id.
    func status(_ gameID: String) -> LiveStatus? { statuses[gameID] }

    // MARK: Polling

    /// Asks each league that's due, one at a time. Returns seconds until
    /// the next league is due (5 minutes when nothing is on).
    private func pollDue() async -> TimeInterval {
        let now = Date()
        // Nothing while a channel is playing (Live Events may sit under the
        // player), unless the in-player guide is open.
        if LiveTVStore.shared.isWatching, !holders.contains("guide") { return 60 }
        var windows: [String: [SportsGame]] = [:]
        for game in SportsData.shared.games {
            let phase = statuses[game.id]?.phase
            if phase == .final || phase == .postponed { continue }
            if phase == nil, (missing[game.id] ?? 0) >= 3 { continue }
            // A game "live" for half a day is a status that never flipped: stop asking.
            let inProgress = (phase == .live || phase == .delayed) && now <= game.start.addingTimeInterval(12 * 3600)
            let inWindow = !game.completed && now >= game.start.addingTimeInterval(-5 * 60)
                && now <= game.start.addingTimeInterval(6 * 3600)
            guard inProgress || inWindow else { continue }
            windows[game.leagueShort, default: []].append(game)
        }
        guard !windows.isEmpty else { return 300 }
        recent.removeAll { now.timeIntervalSince($0) > 3600 }
        // Several leagues on at once share the pace: each waits longer.
        let spread = max(1, Double(windows.count) / 2)
        var soonest: TimeInterval = 300
        for (short, games) in windows.sorted(by: { $0.key < $1.key }) {
            if Task.isCancelled { return 300 }
            if let due = nextDue[short], due > now {
                soonest = min(soonest, due.timeIntervalSince(now))
                continue
            }
            guard let league = SportsData.allLeagues.first(where: { $0.short == short }) else { continue }
            guard takeRequest() else {
                if !cappedNoted {
                    cappedNoted = true
                    CrashRecorder.note("scores: daily cap of \(Self.dailyCap) reached, paused until tomorrow")
                }
                return 1800
            }
            let days = Set(games.map { Self.etDay.string(from: $0.start) }).sorted()
            var merged: [String: LiveStatus] = [:]
            var ok = false
            var bytes = 0
            for (index, day) in days.prefix(2).enumerated() {
                if index > 0 {
                    guard takeRequest() else { break }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                guard let data = await fetch(league, day: day) else { continue }
                recent.append(Date())
                bytes += data.count
                let parsed = await Task.detached(priority: .utility) { () -> [String: LiveStatus] in
                    autoreleasepool { SportsLiveParse.statuses(data, league: league) }
                }.value
                merged.merge(parsed) { _, new in new }
                ok = true
            }
            // Live Events closed mid-request: not a failure, nothing to record.
            if Task.isCancelled { return 300 }
            let anyLive = merged.values.contains { $0.phase == .live || $0.phase == .delayed }
            if ok {
                for game in games {
                    if merged[game.id] == nil { missing[game.id, default: 0] += 1 } else { missing[game.id] = nil }
                }
                failures[short] = 0
                lastBytes[short] = bytes
                apply(merged, now: Date())
                var interval: TimeInterval = anyLive ? (Self.showsScores ? 60 : 120) : 120
                if bytes > 700_000 { interval = max(interval, 120) }
                interval *= spread
                if recent.count >= Self.hourlyPace { interval = max(interval, 300) }
                nextDue[short] = Date().addingTimeInterval(interval)
                CrashRecorder.note("scores: \(short) \(bytes / 1024) KB, \(merged.count) games, "
                                   + "\(merged.values.filter { $0.phase == .live || $0.phase == .delayed }.count) live, "
                                   + "next in \(Int(interval)) s, \(requestsToday) requests today")
                soonest = min(soonest, interval)
            } else {
                let count = (failures[short] ?? 0) + 1
                failures[short] = count
                let backoff: [TimeInterval] = [120, 300, 900, 1800]
                let wait = backoff[min(count - 1, backoff.count - 1)]
                nextDue[short] = Date().addingTimeInterval(wait)
                CrashRecorder.note("scores: \(short) failed, waiting \(Int(wait)) s")
                soonest = min(soonest, wait)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return soonest
    }

    private func fetch(_ league: SportsData.League, day: String) async -> Data? {
        let address = "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard?dates=\(day)" + league.extra
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private var requestsToday: Int {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.dayKeyDefaults) == Self.localDay.string(from: Date()) else { return 0 }
        return defaults.integer(forKey: Self.countDefaults)
    }

    /// Counts a request against today's cap; false when the cap is reached.
    private func takeRequest() -> Bool {
        let defaults = UserDefaults.standard
        let today = Self.localDay.string(from: Date())
        if defaults.string(forKey: Self.dayKeyDefaults) != today {
            defaults.set(today, forKey: Self.dayKeyDefaults)
            defaults.set(0, forKey: Self.countDefaults)
            cappedNoted = false
        }
        let count = defaults.integer(forKey: Self.countDefaults)
        guard count < Self.dailyCap else { return false }
        defaults.set(count + 1, forKey: Self.countDefaults)
        return true
    }

    private func apply(_ fresh: [String: LiveStatus], now: Date) {
        var changed = false
        for (id, status) in fresh {
            if statuses[id] != status {
                if status.phase == .final, finalSeen[id] == nil {
                    // Seen ending now, or already over when first looked at.
                    let wasLive = statuses[id].map { $0.phase == .live || $0.phase == .delayed } ?? false
                    finalSeen[id] = wasLive ? now : now.addingTimeInterval(-20 * 60)
                }
                statuses[id] = status
                changed = true
            }
        }
        // Forget games from earlier days.
        if statuses.count > 600 {
            let keep = Set(SportsData.shared.games.map(\.id))
            statuses = statuses.filter { keep.contains($0.key) }
            finalSeen = finalSeen.filter { keep.contains($0.key) }
        }
        if changed { revision &+= 1 }
    }
}
