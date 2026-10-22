import Foundation

/// The full guide an Xtream provider publishes for its whole lineup
/// (`xmltv.php`). Built on the Apple TV like the outside listings: a
/// background job downloads the file to disk, streams through it keeping
/// only the user's in-scope channels (matched by their exact guide id), and
/// caches the small result. Rebuilt about twice a day.
enum ProviderGuide {
    /// Rebuild when the saved guide is older than this.
    static let refreshAge: TimeInterval = 12 * 3600
    /// How far ahead listings are kept.
    static let keepHours: TimeInterval = 48

    /// Countries whose channels take part (the provider's group prefix, e.g.
    /// "US|"). Groups without a country prefix always do.
    /// Until country selection exists in setup this is US only.
    static var countries: Set<String> = ["US"]

    struct Saved: Codable {
        var built: Date
        /// In-scope channels when this was built (a big jump means rebuild).
        var channelCount: Int
        var programs: [String: [OutsideGuide.RawProgram]]
        var notes: [String: String]
        /// Channels and programmes in the provider's whole file.
        var guideChannels: Int
        var guideProgrammes: Int
        var bytes: Int64
    }

    enum Status: Equatable {
        case updating(String)
        case ready(matched: Int, total: Int, guideChannels: Int, updated: Date)
        /// The provider doesn't publish a usable guide.
        case unavailable(String)
        case failed(String)
    }

    struct State: Equatable {
        var name: String
        var status: Status
    }

    enum Outcome {
        case built(Saved)
        case unavailable(String)
        case failed(String)
    }

    // MARK: Scope

    /// "US| NBC ᴴᴰ" → "US". Nil when the group has no country prefix.
    static func countryPrefix(of group: String?) -> String? {
        guard let group, let regex = RX.get("^\\s*([A-Z]{2,4})\\s*\\|") else { return nil }
        let range = NSRange(group.startIndex..<group.endIndex, in: group)
        guard let match = regex.firstMatch(in: group, range: range),
              let found = Range(match.range(at: 1), in: group) else { return nil }
        return String(group[found])
    }

    /// Whether a channel's listings come from the provider's guide: it has a
    /// guide id and is from a selected country.
    static func inScope(_ channel: LiveTVChannel) -> Bool {
        guard let epg = channel.epgID, !epg.isEmpty else { return false }
        if let prefix = countryPrefix(of: channel.group) { return countries.contains(prefix) }
        return true
    }

    // MARK: Cache

    private static func folder() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("OutsideGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func cacheKey(profile: String, sourceID: String) -> String {
        let raw = "\(profile)-\(sourceID)"
        return String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(90))
    }

    private static func savedURL(_ key: String) -> URL? {
        folder()?.appendingPathComponent("provider-\(key).json")
    }

    static func loadSaved(_ key: String) -> Saved? {
        guard let url = savedURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, key: String) {
        guard let url = savedURL(key), let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func needsRebuild(_ saved: Saved?, channelCount: Int) -> Bool {
        guard let saved else { return true }
        if Date().timeIntervalSince(saved.built) > refreshAge { return true }
        return channelCount > saved.channelCount + max(25, saved.channelCount / 10)
    }

    // MARK: Building

    /// Downloads and reads the provider's guide for `channels` (already
    /// in scope). Runs on background threads.
    static func build(
        url: URL,
        channels: [LiveTVChannel],
        progress: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        var ids: [String: [String]] = [:]
        for channel in channels {
            guard let epg = channel.epgID?.trimmingCharacters(in: .whitespacesAndNewlines), !epg.isEmpty else { continue }
            ids[epg.lowercased(), default: []].append(channel.id)
        }
        guard !ids.isEmpty else { return .unavailable("None of your channels have a guide id from the provider.") }
        let now = Int(Date().timeIntervalSince1970 / 60)
        let window = (low: now - 180, high: now + Int(keepHours * 60))
        progress("Downloading your provider's guide…")
        do {
            let found = try await XMLTVReader.readExact(url: url, userAgent: XtreamClient.userAgent, ids: ids, window: window)
            if found.guideChannels == 0 && found.programmes == 0 {
                return .unavailable(found.bytes < 512
                    ? "The provider's guide is empty."
                    : "The provider didn't send a TV guide file.")
            }
            var programs: [String: [OutsideGuide.RawProgram]] = [:]
            var notes: [String: String] = [:]
            for (channelID, entry) in found.programs {
                programs[channelID] = entry.programs.sorted { $0.s < $1.s }
                notes[channelID] = "Provider guide: \(entry.note)"
            }
            return .built(Saved(
                built: Date(), channelCount: channels.count, programs: programs, notes: notes,
                guideChannels: found.guideChannels, guideProgrammes: found.programmes, bytes: found.bytes
            ))
        } catch let error as GuideFiles.HTTPStatusError {
            if [401, 403, 404, 405, 501].contains(error.status) {
                return .unavailable("This provider doesn't publish a full guide (\(error.status)).")
            }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Screenshot tour

    /// A small XMLTV file in the provider's format, for the CI screenshot
    /// tour (`live-demo-provider`): `channels` are (guide id, display name).
    static func writeDemoFile(channels: [(String, String)], titles: [String]) -> URL? {
        func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmmss"
            return formatter.string(from: date) + " +0000"
        }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"demo\">\n"
        for (id, name) in channels {
            xml += "  <channel id=\"\(escape(id))\"><display-name>\(escape(name))</display-name></channel>\n"
        }
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 1800).rounded(.down) * 1800 - 1800)
        for (index, (id, _)) in channels.enumerated() {
            var cursor = base
            for slot in 0..<12 {
                let end = cursor.addingTimeInterval(slot % 3 == 0 ? 3600 : 1800)
                let title = titles[(index + slot) % titles.count]
                xml += "  <programme start=\"\(stamp(cursor))\" stop=\"\(stamp(end))\" channel=\"\(escape(id))\">"
                xml += "<title lang=\"en\">\(escape(title))</title><desc lang=\"en\">From the provider's own guide.</desc></programme>\n"
                cursor = end
            }
        }
        xml += "</tv>\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("provider-demo.xml")
        do {
            try Data(xml.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
