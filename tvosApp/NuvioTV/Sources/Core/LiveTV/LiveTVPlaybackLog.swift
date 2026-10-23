import Foundation

/// What happened each time Live TV tuned a channel: which version was tried,
/// how long the picture took, stalls, reconnects, switches and why. Kept on
/// this Apple TV (last few thousand events, survives restarts) and exported
/// from Guide Listings for diagnosing playback. No links, passwords or tokens.
@MainActor
final class LiveTVPlaybackLog {
    static let shared = LiveTVPlaybackLog()

    struct Entry: Codable {
        let at: Date
        /// Tune session number: groups the events of one channel start.
        let session: Int
        let event: String
        let channel: String
        let feed: String
        let provider: String
        let detail: String
    }

    private(set) var entries: [Entry] = []
    private let cap = 4000
    private var saveTask: Task<Void, Never>?
    private(set) var lastSession = 0

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveTVPlaybackLog.json")
    }

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
            lastSession = saved.last?.session ?? 0
        }
    }

    /// Starts a new tune session and returns its number.
    func newSession() -> Int {
        lastSession += 1
        return lastSession
    }

    func add(_ event: String, session: Int, channel: String = "", feed: String = "", provider: String = "", detail: String = "") {
        // Player errors can quote the stream link, and Xtream links carry the
        // username and password: never keep a link.
        let safe = detail.rxReplace("[a-z][a-z0-9+.-]*://\\S+", with: "<link>", caseInsensitive: true)
        entries.append(Entry(at: Date(), session: session, event: event, channel: channel, feed: feed,
                             provider: provider, detail: safe))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, let url = Self.fileURL,
                  let data = try? JSONEncoder().encode(self.entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// A spreadsheet (CSV) of the log, newest last.
    func csv() -> String {
        func cell(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        var lines = ["time,session,event,channel,feed,provider,detail"]
        for entry in entries {
            lines.append([
                cell(formatter.string(from: entry.at)), cell(String(entry.session)), cell(entry.event),
                cell(entry.channel), cell(entry.feed), cell(entry.provider), cell(entry.detail)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
