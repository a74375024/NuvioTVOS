import Foundation

/// The heavy, pure parts of Live TV, kept off the main actor so they can run
/// on background threads: tidying raw channel names, merging guide sources,
/// working out My Lineup, telling a real channel-list change from renamed
/// event slots, and the channel list saved on this Apple TV.
enum LiveTVWork {

    // MARK: Log text

    static func ms(since date: Date) -> String { "\(Int(Date().timeIntervalSince(date) * 1000)) ms" }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, bytes / 1000)) KB"
    }

    static func age(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7200 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }

    // MARK: Channel names

    /// Fills in each channel's provider group (its tag, or a name prefix
    /// shared by 3+ channels) and short name ("US: NBC 4" → "NBC 4").
    static func annotated(_ list: [LiveTVChannel]) -> [LiveTVChannel] {
        let pattern = RX.get("^\\s*(?:\\[([^\\]]{1,24})\\]|\\(([^)]{1,24})\\)|([^:|\\[\\(]{1,24}?)\\s*[:|])\\s*(.+)$")
        var parsed: [(prefix: String?, rest: String)] = []
        parsed.reserveCapacity(list.count)
        var prefixCounts: [String: Int] = [:]
        var display: [String: String] = [:]
        for channel in list {
            let name = channel.name
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = pattern?.firstMatch(in: name, range: range) {
                var prefix: String?
                for group in 1...3 {
                    if let r = Range(match.range(at: group), in: name) {
                        prefix = name[r].trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                let rest = Range(match.range(at: 4), in: name).map { String(name[$0]).trimmingCharacters(in: .whitespaces) } ?? name
                if let prefix, !prefix.isEmpty, !rest.isEmpty {
                    let key = prefix.lowercased()
                    prefixCounts[key, default: 0] += 1
                    if display[key] == nil { display[key] = prefix }
                    parsed.append((key, rest))
                    continue
                }
            }
            parsed.append((nil, name))
        }
        return zip(list, parsed).map { channel, info in
            var updated = channel
            if let tag = channel.tags.first {
                updated.group = tag
            } else if let key = info.prefix, (prefixCounts[key] ?? 0) >= 3 {
                updated.group = display[key]
            }
            updated.shortName = info.prefix != nil && updated.group != nil ? info.rest : ""
            return updated
        }
    }

    // MARK: Refresh: what changed

    /// The event slots renamed since `old`, when nothing else changed (same
    /// channels, groups and regular names); nil for a real change that needs
    /// the full classification.
    static func renamedEventSlots(old: [LiveTVChannel], new: [LiveTVChannel], traits: [String: ChannelTraits]) -> [LiveTVChannel]? {
        guard old.count == new.count, !old.isEmpty else { return nil }
        var oldByID: [String: LiveTVChannel] = [:]
        oldByID.reserveCapacity(old.count)
        for channel in old { oldByID[channel.id] = channel }
        var renamed: [LiveTVChannel] = []
        for channel in new {
            guard let previous = oldByID[channel.id], previous.group == channel.group,
                  previous.tags == channel.tags, previous.epgID == channel.epgID else { return nil }
            if previous.name != channel.name {
                guard traits[channel.id]?.familyKey != nil else { return nil }
                renamed.append(channel)
            }
        }
        return renamed
    }

    // MARK: Guide listings

    static let guideHours = 3.0

    /// The guide grid starts at the last half hour.
    static func windowStart(for date: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return calendar.date(from: components) ?? date
    }

    /// One channel's listing from every source: the provider's full guide
    /// and short guide (or the server's), then outside listings for gaps.
    static func listing(
        id: String, server: [LiveTVProgram]?, provider: [OutsideGuide.RawProgram]?,
        outside: [OutsideGuide.RawProgram]?, windowStart: Date
    ) -> [LiveTVProgram] {
        let from = windowStart.addingTimeInterval(-3600)
        let to = from.addingTimeInterval(14 * 3600)
        let short = server ?? []
        var own = short
        if let provider {
            let full = OutsideGuide.programs(provider, channelID: id, from: from, to: to, idPrefix: "pg", outside: false)
            if !full.isEmpty { own = bestListing(server: full, outside: short, windowStart: windowStart) }
        }
        let outsideList = outside.map { OutsideGuide.programs($0, channelID: id, from: from, to: to) }
        return bestListing(server: own, outside: outsideList, windowStart: windowStart)
    }

    /// Picks whichever listing covers more of the next three hours (the
    /// first wins ties), tops it up from the other where it has gaps, and
    /// takes genre tags from the other where its own programs have none.
    static func bestListing(server: [LiveTVProgram]?, outside: [LiveTVProgram]?, windowStart start: Date) -> [LiveTVProgram] {
        let server = server ?? []
        guard let outside, !outside.isEmpty else { return server }
        guard !server.isEmpty else { return outside }
        let end = start.addingTimeInterval(guideHours * 3600)
        func coverage(_ list: [LiveTVProgram]) -> TimeInterval {
            list.reduce(0) { total, p in total + max(0, min(p.end, end).timeIntervalSince(max(p.start, start))) }
        }
        let outsideWins = coverage(outside) > coverage(server) + 15 * 60
        let primary = ProgramGenre.mergeFlags(outsideWins ? outside : server, from: outsideWins ? server : outside)
        let secondary = outsideWins ? server : outside
        var result = primary
        for program in secondary {
            let clashes = result.contains { other in
                min(program.end, other.end).timeIntervalSince(max(program.start, other.start)) > 300
            }
            if !clashes { result.append(program) }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Every channel's merged listing (after a guide source loads or the
    /// window moves on).
    static func mergedListings(
        ids: Set<String>, server: [String: [LiveTVProgram]], provider: [String: [OutsideGuide.RawProgram]],
        outside: [String: [OutsideGuide.RawProgram]], windowStart: Date
    ) -> [String: [LiveTVProgram]] {
        var merged: [String: [LiveTVProgram]] = [:]
        merged.reserveCapacity(ids.count)
        for id in ids {
            let list = listing(id: id, server: server[id], provider: provider[id], outside: outside[id], windowStart: windowStart)
            if !list.isEmpty { merged[id] = list }
        }
        return merged
    }

    // MARK: My Lineup

    struct LineupInput {
        let infos: [LiveTVEntryInfo]
        let channels: [LiveTVChannel]
        let indexByID: [String: Int]
        let prefs: LineupPrefs
        /// Raw channel ids that have any guide data.
        let guideIDs: Set<String>
        let otherGroup: String
    }

    struct LineupOutput {
        let lineupIDs: Set<String>
        let entries: [LiveTVChannel]
        let entryIndex: [String: Int]
        let lineupEntries: [LiveTVChannel]
        let browseEntries: [LiveTVChannel]
        let groups: [(name: String, count: Int)]
    }

    /// Lineup membership and the entry list, in guide order.
    static func lineup(_ input: LineupInput) -> LineupOutput {
        let prefs = input.prefs
        let infos = input.infos
        func member(_ id: String) -> LiveTVChannel? {
            input.indexByID[id].flatMap { $0 < input.channels.count ? input.channels[$0] : nil }
        }
        var lineup = Set<String>()
        for info in infos {
            if prefs.removed.contains(info.id) { continue }
            let favorite = info.members.contains { member($0)?.isFavorite ?? false }
            if favorite || prefs.added.contains(info.id) {
                lineup.insert(info.id)
            } else if prefs.configured {
                let hasGuide = info.members.contains { input.guideIDs.contains($0) }
                // Suggestions are worked out live, so channels join as their
                // listings load (and core networks / market locals always).
                if LineupEngine.suggests(info, prefs: prefs, hasGuide: hasGuide, name: info.name) {
                    lineup.insert(info.id)
                }
            }
        }
        // Guide order: neighborhoods (Local, News, Sports, Entertainment…),
        // locals by their broadcast number, everything else A–Z. No channel
        // numbers: channels come and go, and the Apple TV remote can't dial.
        let rank = Dictionary(uniqueKeysWithValues: LineupCategory.allCases.enumerated().map { ($1, $0) })
        let ordered = infos.sorted { a, b in
            let ra = rank[a.category] ?? 99, rb = rank[b.category] ?? 99
            if ra != rb { return ra < rb }
            if a.category == .local {
                let na = a.virtualNumber ?? 999, nb = b.virtualNumber ?? 999
                if na != nb { return na < nb }
            }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
        var marketOf: [String: String] = [:]
        let built: [LiveTVChannel] = ordered.compactMap { info in
            let members = info.members.compactMap(member)
            guard let primary = members.first else { return nil }
            if let market = info.market { marketOf[info.id] = market }
            return LiveTVChannel(
                id: info.id, serverID: primary.serverID, itemID: primary.itemID, name: info.name,
                number: nil,
                imageURL: members.lazy.compactMap(\.imageURL).first,
                isFavorite: members.contains(where: \.isFavorite),
                tags: primary.tags, isRadio: primary.isRadio, group: primary.group, shortName: info.name
            )
        }
        let entryIndex = Dictionary(built.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lineupEntries = built.filter { lineup.contains($0.id) }
        let browseEntries = built.filter { entry in
            lineup.contains(entry.id) || entry.isFavorite || prefs.includes(market: marketOf[entry.id])
        }
        var counts: [String: Int] = [:]
        for entry in browseEntries { counts[entry.group ?? input.otherGroup, default: 0] += 1 }
        let groups = counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return LineupOutput(
            lineupIDs: lineup, entries: built, entryIndex: entryIndex,
            lineupEntries: lineupEntries, browseEntries: browseEntries, groups: groups
        )
    }
}

// MARK: - Saved channel list

/// The finished channel list (channels plus everything worked out from
/// them), saved on this Apple TV so Live TV opens straight away and then
/// refreshes in the background. Two files: a small one with what the first
/// screen needs (My Lineup, the chosen countries, favorites, recents, Live
/// Events), and the full list for search and everything else. In Caches,
/// so tvOS may clear it; Live TV then simply loads from the servers.
enum LiveTVCatalogCache {
    struct Saved: Codable {
        var version: Int
        var signature: String
        var savedAt: Date
        var channels: [LiveTVChannel]
        var catalog: ChannelCatalog.Result
        var xtreamFormats: [String: [String]]
    }

    enum Part: String {
        case first, full
    }

    static let version = 1

    private static func url(signature: String, part: Part) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A stable name per profile + accounts (String.hashValue changes per launch).
        var hash: UInt64 = 1469598103934665603
        for byte in signature.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return folder.appendingPathComponent("catalog-\(String(hash, radix: 16))-\(part.rawValue).json")
    }

    static func load(signature: String, part: Part) -> (saved: Saved, bytes: Int)? {
        guard let url = url(signature: signature, part: part), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == version, saved.signature == signature else { return nil }
        return (saved, data.count)
    }

    /// Writes both files. `firstIDs` are the entries the first screen needs.
    static func save(_ saved: Saved, firstEntryIDs: Set<String>, firstFamilyIDs: Set<String>) -> (first: Int, full: Int) {
        let encoder = JSONEncoder()
        var sizes = (first: 0, full: 0)
        if let url = url(signature: saved.signature, part: .full), let data = try? encoder.encode(saved) {
            try? data.write(to: url, options: .atomic)
            sizes.full = data.count
        }
        // The first-screen subset: those entries and families, their channels.
        var first = saved
        let entries = saved.catalog.entries.filter { firstEntryIDs.contains($0.id) }
        let families = saved.catalog.families.filter { firstFamilyIDs.contains($0.id) }
        var keep = Set<String>()
        for entry in entries { keep.formUnion(entry.members) }
        for family in families { keep.formUnion(family.feeds) }
        let familyKeys = Set(families.map { String($0.id.dropFirst("fam|".count)) })
        first.channels = saved.channels.filter { keep.contains($0.id) }
        first.catalog = ChannelCatalog.Result(
            traits: saved.catalog.traits.filter { keep.contains($0.key) },
            entries: entries,
            entryOf: saved.catalog.entryOf.filter { keep.contains($0.key) },
            families: families,
            events: saved.catalog.events.filter { familyKeys.contains($0.family) }
        )
        if let url = url(signature: saved.signature, part: .first), let data = try? encoder.encode(first) {
            try? data.write(to: url, options: .atomic)
            sizes.first = data.count
        }
        return sizes
    }
}
