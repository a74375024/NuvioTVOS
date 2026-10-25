import Foundation

// MARK: - Tennis player photos
//
// Cut-out photos for the players on tennis tiles (and F1 drivers when the
// race data has none), from TheSportsDB's free
// player search. Kept light:
// - only players in matches you can watch, live or within the next day;
// - one search per player, saved for 90 days (a miss is tried again after
//   a week), on disk in Caches;
// - one search every 6 seconds at most (their free limit is 30 a minute),
//   at most `dailyCap` a day, and a 30-minute pause after a failure.
// Only the player's name is sent.

@MainActor
final class PlayerPhotos: ObservableObject {
    static let shared = PlayerPhotos()

    /// Bumped when photos arrive.
    @Published private(set) var revision = 0

    private struct Entry: Codable {
        /// Empty when the search found no photo.
        let url: String
        let at: Date
    }

    private struct Saved: Codable {
        var entries: [String: Entry] = [:]
        var requestDay: String?
        var requestCount = 0
    }

    private static let dailyCap = 120
    private static let base = "https://www.thesportsdb.com/api/v1/json/123/searchplayers.php?p="

    private var saved = Saved()
    private var loaded = false
    private var queue: [String] = []
    private var queued = Set<String>()
    private var task: Task<Void, Never>?
    private var pausedUntil = Date.distantPast
    private var lastRequestAt = Date.distantPast
    private var dirty = false
    private let file: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("player-photos.json")
    }

    /// "Francisco Cerúndolo" → "francisco cerundolo".
    nonisolated static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The player's photo, when saved (no request).
    func photo(for name: String) -> URL? {
        load()
        guard let entry = saved.entries[Self.key(name)], !entry.url.isEmpty else { return nil }
        return URL(string: entry.url)
    }

    /// Players on screen: look up the ones not saved yet (or stale), in the
    /// background, one at a time. Cheap to call often.
    func request(_ names: [String]) {
        load()
        let now = Date()
        for name in names {
            let key = Self.key(name)
            guard key.contains(" "), !queued.contains(key) else { continue }
            if let entry = saved.entries[key] {
                let life: TimeInterval = entry.url.isEmpty ? 7 * 86_400 : 90 * 86_400
                if now.timeIntervalSince(entry.at) < life { continue }
            }
            queued.insert(key)
            queue.append(name)
        }
        guard task == nil, !queue.isEmpty, now >= pausedUntil else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
        }
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func drain() async {
        var found = 0
        var asked = 0
        while let name = queue.first, !Task.isCancelled {
            let key = Self.key(name)
            // Saved meanwhile (another pass): nothing to ask.
            if let entry = saved.entries[key], Date().timeIntervalSince(entry.at) < 7 * 86_400 {
                queue.removeFirst()
                queued.remove(key)
                continue
            }
            let today = Self.dayKey.string(from: Date())
            if saved.requestDay != today { saved.requestDay = today; saved.requestCount = 0 }
            guard saved.requestCount < Self.dailyCap else {
                // Done for today: nothing until tomorrow.
                pausedUntil = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
                break
            }
            // At least 6 s between searches, across passes too.
            let wait = 6 - Date().timeIntervalSince(lastRequestAt)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            lastRequestAt = Date()
            asked += 1
            saved.requestCount += 1
            dirty = true
            let query = name.folding(options: .diacriticInsensitive, locale: nil)
                .replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let url = URL(string: Self.base + query) else {
                queue.removeFirst()
                queued.remove(key)
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let result = try? await URLSession.shared.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else {
                // Rate limited or offline: pause; the name stays queued.
                pausedUntil = Date().addingTimeInterval(30 * 60)
                break
            }
            let data = result.0
            let photo = await Task.detached(priority: .utility) { Self.parse(data, wanted: key) }.value
            saved.entries[key] = Entry(url: photo ?? "", at: Date())
            if let index = queue.firstIndex(of: name) { queue.remove(at: index) }
            queued.remove(key)
            dirty = true
            if photo != nil {
                found += 1
                revision &+= 1
            }
            // Saved as it goes (a long pass can be cut short).
            if asked % 10 == 0 { persist() }
        }
        persist()
        guard asked > 0 else { return }
        CrashRecorder.note("player photos: \(asked) searched, \(found) found, \(saved.entries.count) saved, "
                           + "\(saved.requestCount) today\(Date() < pausedUntil ? ", paused" : "")")
    }

    private func persist() {
        guard dirty else { return }
        dirty = false
        let now = Date()
        saved.entries = saved.entries.filter { now.timeIntervalSince($0.value.at) < 120 * 86_400 }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    /// The tennis player whose name matches: cut-out first, else the photo.
    nonisolated private static func parse(_ data: Data, wanted: String) -> String? {
        let root = autoreleasepool { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        for player in root?["player"] as? [[String: Any]] ?? [] {
            // Tennis players, and racing drivers for the F1 cameras panel.
            guard let sport = (player["strSport"] as? String)?.lowercased(), sport == "tennis" || sport == "motorsport",
                  let name = player["strPlayer"] as? String, key(name) == wanted else { continue }
            for field in ["strCutout", "strThumb"] {
                if let url = player[field] as? String, url.hasPrefix("https://") { return url }
            }
        }
        return nil
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value
        }
    }
}
