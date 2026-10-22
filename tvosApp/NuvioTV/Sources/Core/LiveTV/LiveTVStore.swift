import Foundation
import Combine
import UIKit

/// Live TV from the Emby / Jellyfin servers signed in under Settings →
/// Jellyfin: channel list, a few hours of real guide data, and tuning (with
/// cable-style channel up / down from the player).
@MainActor
final class LiveTVStore: ObservableObject {
    static let shared = LiveTVStore()

    private var backgroundObserver: NSObjectProtocol?

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidEnterBackground() }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// No server configured, or none of them has Live TV for this account.
        case empty(String)
        case failed(String)
    }

    enum Overlay: Equatable {
        case tuning(LiveTVChannel)
        case failed(LiveTVChannel, String)
    }

    enum OutsideStatus: Equatable {
        case off
        case loading
        case ready(matched: Int, total: Int, updated: Date?)
        case failed(String)
    }

    enum GuideState: Equatable {
        case loading
        case loaded
        case failed
    }

    struct ChannelGroup: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct Banner: Equatable {
        let channel: LiveTVChannel
        let now: LiveTVProgram?
        let next: LiveTVProgram?
        let token = UUID()
    }

    @Published private(set) var channels: [LiveTVChannel] = []
    @Published private(set) var programs: [String: [LiveTVProgram]] = [:]
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingGuide = false
    /// Where each channel's guide stands, so a row can say "loading" vs "none".
    @Published private(set) var guideState: [String: GuideState] = [:]
    /// Provider groups with channel counts, largest first.
    @Published private(set) var groups: [ChannelGroup] = []
    @Published private(set) var hiddenGroups: Set<String> = []
    @Published private(set) var recentIDs: [String] = []
    @Published private(set) var outsideStatus: OutsideStatus = .off
    @Published private(set) var watching: LiveTVChannel?
    @Published private(set) var overlay: Overlay?
    @Published private(set) var banner: Banner?
    /// Short confirmation shown in the guide ("Added to Multiview").
    @Published var toast: String?

    var isWatching: Bool { watching != nil }

    /// Wired by the app root, which owns the player.
    var present: ((LiveTVChannel, URL, NuvioMeta, String) -> Void)?
    var leavePlayer: (() -> Void)?

    static let guideHours = 3.0
    private static let guideLifetime: TimeInterval = 20 * 60
    private static let channelLifetime: TimeInterval = 6 * 60 * 60
    private static let programBatch = 25
    private static let guideConcurrency = 4
    private static let otherGroup = "Other"

    private var loadedSignature: String?
    private var channelsLoadedAt: Date?
    private var guideLoadedAt: Date?
    private var guideWindowStart: Date?
    private var loadTask: Task<Void, Never>?
    private var guideTask: Task<Void, Never>?
    private var tuneGeneration = 0
    private var streamWork: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Streams currently open on the server (at most one in practice).
    private var openStreams: [(stream: LiveTVStream, serverID: String)] = []
    private var indexByID: [String: Int] = [:]
    /// What the server's guide returned, before outside listings are merged in.
    private var serverPrograms: [String: [LiveTVProgram]] = [:]
    /// Outside-listing channel matched to each server channel.
    private var outsideMatches: [String: OutsideGuide.Channel] = [:]
    private var outsideTask: Task<Void, Never>?
    private var guideWindowByChannel: [String: Date] = [:]
    private var pendingGuide: [String] = []
    private var pendingGuideSet: Set<String> = []
    /// Rows asked for recently, re-requested when the guide window moves on.
    private var recentlyRequested: [String] = []
    private var guideFlushTask: Task<Void, Never>?
    private var activeGuideFetches = 0
    /// What Up / Down flips through: the list the channel was picked from.
    private var flipList: [LiveTVChannel] = []

    // MARK: Servers

    private struct Server {
        let config: JellyfinServerConfig
        let client: LiveTVClient
    }

    private func servers() -> [Server] {
        JellyfinServerStore.shared.servers.compactMap { config in
            guard let base = config.baseURL else { return nil }
            let token = JellyfinCredentialStore.token(forServerID: config.id)
            guard !token.isEmpty else { return nil }
            return Server(config: config, client: LiveTVClient(serverID: config.id, baseURL: base, token: token, userID: config.userId))
        }
    }

    private func client(for serverID: String) -> LiveTVClient? {
        servers().first { $0.config.id == serverID }?.client
    }

    var hasServers: Bool { !JellyfinServerStore.shared.servers.isEmpty }

    // MARK: Loading

    func loadIfNeeded(force: Bool = false) {
        let signature = ProfileSettings.activeProfileScope + "|" + JellyfinServerStore.shared.servers.map(\.id).joined(separator: ",")
        if signature != loadedSignature {
            channels = []
            indexByID = [:]
            pendingGuide = []
            pendingGuideSet = []
            programs = [:]
            serverPrograms = [:]
            outsideMatches = [:]
            outsideStatus = .off
            guideState = [:]
            guideWindowByChannel = [:]
            channelsLoadedAt = nil
            guideLoadedAt = nil
            state = .idle
            hiddenGroups = Self.loadSet(Self.hiddenGroupsKey)
            recentIDs = Self.loadList(Self.recentKey)
        }
        let channelsFresh = channelsLoadedAt.map { Date().timeIntervalSince($0) < Self.channelLifetime } ?? false
        if !force, channelsFresh, signature == loadedSignature, !channels.isEmpty {
            refreshGuideIfNeeded()
            return
        }
        guard loadTask == nil else { return }
        loadedSignature = signature
        let configured = servers()
        guard !configured.isEmpty else {
            state = .empty(hasServers
                ? "Sign in to your server again in Settings → Jellyfin."
                : "Add your Emby or Jellyfin server in Settings → Jellyfin (server address, username and password) to see its live channels here.")
            return
        }
        if channels.isEmpty { state = .loading }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            var all: [LiveTVChannel] = []
            var problems: [String] = []
            for server in configured {
                var client = server.client
                do {
                    if client.userID.isEmpty, let base = server.config.baseURL {
                        let resolved = try await JellyfinClient.currentUserId(
                            baseURL: base, apiKey: client.token, username: server.config.username
                        )
                        var updated = server.config
                        updated.userId = resolved
                        JellyfinServerStore.shared.upsert(updated)
                        client = LiveTVClient(serverID: client.serverID, baseURL: client.baseURL, token: client.token, userID: resolved)
                    }
                    all += try await client.channels()
                } catch {
                    problems.append("\(server.config.displayName): \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            self.setChannels(Self.annotated(all))
            self.channelsLoadedAt = Date()
            if all.isEmpty {
                self.state = problems.isEmpty
                    ? .empty("Your server didn't list any live channels for this account.")
                    : .failed(problems.joined(separator: "\n"))
            } else {
                self.state = .loaded
                self.guideLoadedAt = nil
                // Favorites, recents and the top of the list first.
                self.loadOutsideGuide()
                let favorites = self.channels.filter(\.isFavorite).prefix(60).map(\.id)
                self.requestGuide(Array(favorites) + self.recentIDs.prefix(20) + self.channels.prefix(80).map(\.id))
            }
        }
    }

    /// Favorites first, then by channel number (numeric where possible), then name.
    private static func ordered(_ channels: [LiveTVChannel]) -> [LiveTVChannel] {
        channels.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            switch (a.number.flatMap(Double.init), b.number.flatMap(Double.init)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The guide grid starts at the last half hour.
    static func windowStart(for date: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return calendar.date(from: components) ?? date
    }

    /// Called on a timer by the guide: when the half-hour window moves on,
    /// the rows looked at recently are fetched again for the new window.
    func refreshGuideIfNeeded() {
        let start = Self.windowStart()
        guard guideWindowStart != start else { return }
        guideWindowStart = start
        rebuildOutsidePrograms()
        requestGuide(recentlyRequested)
    }

    /// Queues guide fetches for channels (by id). Rows call this as they come
    /// on screen, so the part of the guide being looked at fills in first.
    func requestGuide(_ ids: [String]) {
        let start = Self.windowStart()
        if guideWindowStart == nil { guideWindowStart = start }
        for id in ids where indexByID[id] != nil {
            if guideState[id] == .loading || pendingGuideSet.contains(id) { continue }
            if guideState[id] == .loaded, guideWindowByChannel[id] == start { continue }
            pendingGuide.append(id)
            pendingGuideSet.insert(id)
        }
        recentlyRequested.removeAll { ids.contains($0) }
        recentlyRequested.append(contentsOf: ids)
        if recentlyRequested.count > 300 { recentlyRequested.removeFirst(recentlyRequested.count - 300) }
        scheduleGuideFlush()
    }

    private func scheduleGuideFlush() {
        guard guideFlushTask == nil, !pendingGuide.isEmpty else { return }
        guideFlushTask = Task { [weak self] in
            // Let a burst of rows appearing coalesce into full batches.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            self.guideFlushTask = nil
            self.startGuideFetches()
        }
    }

    private func startGuideFetches() {
        let clients = Dictionary(uniqueKeysWithValues: servers().map { ($0.config.id, $0.client) })
        while activeGuideFetches < Self.guideConcurrency, !pendingGuide.isEmpty {
            // One batch from one server, most recently requested first.
            guard let lastID = pendingGuide.last, let lastIndex = indexByID[lastID], lastIndex < channels.count else {
                if let dropped = pendingGuide.popLast() { pendingGuideSet.remove(dropped) }
                continue
            }
            let serverID = channels[lastIndex].serverID
            var batch: [String] = []
            var index = pendingGuide.count - 1
            while index >= 0, batch.count < Self.programBatch {
                let id = pendingGuide[index]
                if let i = indexByID[id], i < channels.count, channels[i].serverID == serverID {
                    batch.append(id)
                    pendingGuide.remove(at: index)
                    pendingGuideSet.remove(id)
                }
                index -= 1
            }
            guard !batch.isEmpty else { break }
            guard let client = clients[serverID] else {
                batch.forEach { guideState[$0] = .failed }
                continue
            }
            fetchGuide(batch, client: client)
        }
        isLoadingGuide = activeGuideFetches > 0
    }

    private func fetchGuide(_ ids: [String], client: LiveTVClient) {
        let start = Self.windowStart()
        let end = start.addingTimeInterval(Self.guideHours * 3600 + 1800)
        let itemIDs = ids.compactMap { indexByID[$0].map { channels[$0].itemID } }
        var states = guideState
        ids.forEach { states[$0] = .loading }
        guideState = states
        activeGuideFetches += 1
        isLoadingGuide = true
        Task { [weak self] in
            var result = try? await client.programs(channelItemIDs: itemIDs, from: start, to: end)
            if result == nil {
                // One retry: big lineups can make the server slow to answer.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                result = try? await client.programs(channelItemIDs: itemIDs, from: start, to: end)
            }
            guard let self else { return }
            self.activeGuideFetches -= 1
            var merged = self.programs
            var states = self.guideState
            if let list = result {
                let grouped = Dictionary(grouping: list, by: \.channelID)
                for id in ids {
                    let server = (grouped[id] ?? []).sorted { $0.start < $1.start }
                    self.serverPrograms[id] = server
                    merged[id] = self.bestListing(server: server, outside: self.outsideListing(for: id))
                    states[id] = .loaded
                    self.guideWindowByChannel[id] = start
                }
            } else {
                ids.forEach { states[$0] = .failed }
            }
            self.programs = merged
            self.guideState = states
            self.guideLoadedAt = Date()
            self.startGuideFetches()
        }
    }

    // MARK: Outside listings

    /// Downloads (or reads cached) free outside listings and matches them to
    /// this server's channels; channels the server has no guide for get them.
    func loadOutsideGuide(force: Bool = false) {
        outsideTask?.cancel()
        guard OutsideGuide.isEnabled, !channels.isEmpty else {
            outsideMatches = [:]
            outsideStatus = .off
            rebuildOutsidePrograms()
            return
        }
        let shardIDs = OutsideGuide.enabledShards
        let snapshot = channels
        outsideStatus = .loading
        outsideTask = Task { [weak self] in
            let loaded = await OutsideGuide.load(shardIDs: shardIDs, force: force)
            let matches = await Task.detached(priority: .utility) {
                OutsideGuide.match(snapshot, guide: loaded.channels, stations: loaded.stations)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.outsideMatches = matches.mapValues { loaded.channels[$0] }
            if loaded.channels.isEmpty, !loaded.problems.isEmpty {
                self.outsideStatus = .failed(loaded.problems.joined(separator: "\n"))
            } else {
                self.outsideStatus = .ready(matched: matches.count, total: snapshot.count, updated: loaded.generated)
            }
            self.rebuildOutsidePrograms()
        }
    }

    private func outsideListing(for id: String) -> [LiveTVProgram]? {
        guard let match = outsideMatches[id] else { return nil }
        let start = Self.windowStart().addingTimeInterval(-3600)
        return OutsideGuide.programs(match, channelID: id, from: start, to: start.addingTimeInterval(14 * 3600))
    }

    /// Re-merges every channel's listing (after outside data loads or the
    /// window moves on).
    private func rebuildOutsidePrograms() {
        var merged = programs
        let ids = Set(outsideMatches.keys).union(merged.keys)
        for id in ids {
            merged[id] = bestListing(server: serverPrograms[id], outside: outsideListing(for: id))
        }
        programs = merged.filter { !$0.value.isEmpty }
    }

    /// Picks whichever listing covers more of the next three hours; the
    /// server's wins ties and is topped up from outside where it has gaps.
    private func bestListing(server: [LiveTVProgram]?, outside: [LiveTVProgram]?) -> [LiveTVProgram] {
        let server = server ?? []
        guard let outside, !outside.isEmpty else { return server }
        guard !server.isEmpty else { return outside }
        let start = Self.windowStart()
        let end = start.addingTimeInterval(Self.guideHours * 3600)
        func coverage(_ list: [LiveTVProgram]) -> TimeInterval {
            list.reduce(0) { total, p in total + max(0, min(p.end, end).timeIntervalSince(max(p.start, start))) }
        }
        let outsideWins = coverage(outside) > coverage(server) + 15 * 60
        let primary = outsideWins ? outside : server
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

    // MARK: Guide helpers

    func current(on channelID: String, at date: Date = Date()) -> LiveTVProgram? {
        programs[channelID]?.first { $0.isOn(at: date) }
    }

    func next(on channelID: String, at date: Date = Date()) -> LiveTVProgram? {
        programs[channelID]?.first { $0.start >= date }
    }

    func number(of channel: LiveTVChannel) -> String {
        if let number = channel.number { return number }
        return String((indexByID[channel.id] ?? 0) + 1)
    }

    func channel(id: String) -> LiveTVChannel? {
        indexByID[id].map { channels[$0] }
    }

    private func setChannels(_ list: [LiveTVChannel]) {
        channels = Self.ordered(list)
        indexByID = Dictionary(channels.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for channel in channels { counts[channel.group ?? Self.otherGroup, default: 0] += 1 }
        groups = counts.map { ChannelGroup(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Groups

    /// Works out each channel's group: the server's first tag when it has
    /// tags, otherwise an IPTV-style name prefix ("US: …", "UK | …", "[CA] …").
    /// Prefixes shared by fewer than three channels aren't treated as groups.
    private static func annotated(_ list: [LiveTVChannel]) -> [LiveTVChannel] {
        let pattern = try? NSRegularExpression(pattern: "^\\s*(?:\\[([^\\]]{1,24})\\]|\\(([^)]{1,24})\\)|([^:|\\[\\(]{1,24}?)\\s*[:|])\\s*(.+)$")
        var parsed: [(prefix: String?, rest: String)] = []
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

    func isHidden(_ channel: LiveTVChannel) -> Bool {
        hiddenGroups.contains(channel.group ?? Self.otherGroup)
    }

    func groupName(of channel: LiveTVChannel) -> String { channel.group ?? Self.otherGroup }

    func setGroup(_ name: String, hidden: Bool) {
        if hidden { hiddenGroups.insert(name) } else { hiddenGroups.remove(name) }
        Self.save(Array(hiddenGroups), key: Self.hiddenGroupsKey)
    }

    // MARK: Search

    /// Channels matching by number, name or group, best matches first.
    func searchChannels(_ text: String, limit: Int = 80) -> [LiveTVChannel] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var scored: [(LiveTVChannel, Int)] = []
        for channel in channels {
            let name = channel.displayName.lowercased()
            let full = channel.name.lowercased()
            var score = 0
            if let number = channel.number?.lowercased() {
                if number == query { score = 100 } else if number.hasPrefix(query) { score = 60 }
            }
            if name == query { score = max(score, 95) }
            else if name.hasPrefix(query) { score = max(score, 80) }
            else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { score = max(score, 70) }
            else if full.contains(query) { score = max(score, 50) }
            else if channel.group?.lowercased().contains(query) == true { score = max(score, 20) }
            if score > 0 {
                if channel.isFavorite { score += 5 }
                if isHidden(channel) { score -= 15 }
                scored.append((channel, score))
            }
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending }
            .prefix(limit)
            .map(\.0)
    }

    /// Programs on now or later whose title matches: the loaded guide first,
    /// then whatever the server's own search finds.
    func searchPrograms(_ text: String) async -> [LiveTVProgram] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let needle = query.lowercased()
        let now = Date()
        var found: [String: LiveTVProgram] = [:]
        for list in programs.values {
            for program in list where program.end > now && program.title.lowercased().contains(needle) {
                found[program.id] = program
            }
        }
        for server in servers() {
            for program in await server.client.searchPrograms(query) where indexByID[program.channelID] != nil {
                found[program.id] = program
            }
        }
        return found.values.sorted { $0.start != $1.start ? $0.start < $1.start : $0.title < $1.title }
    }

    // MARK: Saved lists

    private static let hiddenGroupsKey = "nuvio.tv.livetv.hiddenGroups"
    private static let recentKey = "nuvio.tv.livetv.recentChannels"

    private static func loadList(_ key: String) -> [String] {
        guard let data = ProfileSettings.current.data(forKey: key),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private static func loadSet(_ key: String) -> Set<String> { Set(loadList(key)) }

    private static func save(_ list: [String], key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        ProfileSettings.current.set(data, forKey: key)
    }

    private func remember(_ channel: LiveTVChannel) {
        var list = recentIDs.filter { $0 != channel.id }
        list.insert(channel.id, at: 0)
        if list.count > 30 { list.removeLast(list.count - 30) }
        recentIDs = list
        Self.save(list, key: Self.recentKey)
    }

    var recentChannels: [LiveTVChannel] { recentIDs.compactMap(channel(id:)) }

    // MARK: Watching

    /// Watches a channel. `lineup` is the list it was picked from, which
    /// Up / Down then flips through (a group, favorites, search results…).
    ///
    /// Emby Live TV is held to ONE open stream at a time: every open first
    /// closes whatever is open, opens run strictly one after another, and a
    /// tune that's been superseded (fast Up / Down) never opens anything.
    func watch(_ channel: LiveTVChannel, lineup: [LiveTVChannel]? = nil) {
        if let lineup, lineup.contains(channel) { flipList = lineup }
        else if !flipList.contains(channel) { flipList = channels.filter { !isHidden($0) || $0 == channel } }
        remember(channel)
        bannerTask?.cancel()
        banner = nil
        tuneGeneration &+= 1
        let generation = tuneGeneration
        watching = channel
        overlay = .tuning(channel)
        enqueueStreamWork { [weak self] in
            guard let self else { return }
            // Let a burst of channel flips settle on the last one.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard generation == self.tuneGeneration else { return }
            await self.closeAllStreams()
            guard generation == self.tuneGeneration else { return }
            guard let client = self.client(for: channel.serverID) else {
                self.overlay = .failed(channel, "Sign in to this server again in Settings → Jellyfin.")
                return
            }
            do {
                // Not cancellable on purpose: once the server opens a stream we
                // must learn its id so it can be closed.
                let stream = try await client.openStream(channelItemID: channel.itemID)
                self.openStreams.append((stream, channel.serverID))
                guard generation == self.tuneGeneration, self.watching?.id == channel.id else {
                    await self.closeAllStreams()
                    return
                }
                let now = self.current(on: channel.id)
                self.overlay = nil
                self.present?(channel, stream.url, self.meta(for: channel, now: now), now?.title ?? "")
                self.showBanner(for: channel)
                await client.reportPlaying(stream)
            } catch {
                guard generation == self.tuneGeneration, self.watching?.id == channel.id else { return }
                self.overlay = .failed(channel, error.localizedDescription)
            }
        }
    }

    /// Channel up / down from the player.
    func flip(by step: Int) {
        let list = flipList.isEmpty ? channels : flipList
        guard let current = watching, let index = list.firstIndex(of: current), list.count > 1 else { return }
        let target = list[(index + step + list.count) % list.count]
        leavePlayer?()
        watch(target)
    }

    /// Leaving the player or the tuning card.
    func stopWatching() {
        tuneGeneration &+= 1
        bannerTask?.cancel()
        watching = nil
        overlay = nil
        banner = nil
        enqueueStreamWork { [weak self] in
            await self?.closeAllStreams()
        }
    }

    /// Runs stream opens / closes strictly one at a time, in order.
    private func enqueueStreamWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = streamWork
        streamWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Closes every stream this app opened on the server.
    private func closeAllStreams() async {
        let open = openStreams
        openStreams.removeAll()
        for entry in open {
            await client(for: entry.serverID)?.closeStream(entry.stream)
        }
    }

    private func appDidEnterBackground() {
        // Don't keep a server stream (and the provider's single slot) busy
        // while the app is in the background, unless it's playing in PiP.
        guard isWatching || !openStreams.isEmpty,
              !PictureInPictureManager.shared.isPictureInPictureActive else { return }
        leavePlayer?()
        stopWatching()
    }

    func meta(for channel: LiveTVChannel, now: LiveTVProgram?) -> NuvioMeta {
        let description = [now?.title, now?.episodeTitle, now?.overview].compactMap { $0 }.joined(separator: "\n")
        return NuvioMeta(
            id: "live:jf:\(channel.serverID):\(channel.itemID)",
            name: channel.name,
            description: description.isEmpty ? nil : description,
            posterUrl: channel.imageURL?.absoluteString,
            backgroundUrl: now?.imageURL?.absoluteString,
            logoUrl: channel.imageURL?.absoluteString,
            type: "livetv"
        )
    }

    private func showBanner(for channel: LiveTVChannel) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.watching?.id == channel.id else { return }
            self.banner = Banner(channel: channel, now: self.current(on: channel.id), next: self.next(on: channel.id))
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    // MARK: Favorites

    func toggleFavorite(_ channel: LiveTVChannel) {
        guard let index = channels.firstIndex(of: channel) else { return }
        let favorite = !channel.isFavorite
        var updated = channels
        updated[index].isFavorite = favorite
        setChannels(updated)
        Task { [weak self] in
            do {
                try await self?.client(for: channel.serverID)?.setFavorite(favorite, itemID: channel.itemID)
            } catch {
                self?.flash(error.localizedDescription)
            }
        }
    }

    private func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Screenshot tour

    /// Sample guide for the CI screenshot tour (`-NuvioScreenTour live-demo`),
    /// so the layout can be checked without a real server.
    func loadDemo() {
        let names = ["US: News 24", "US: Sports Central", "US: Movie Classics", "UK: Kids Zone", "UK: Nature HD", "UK: Comedy Hits", "US LOCALS: KXYZ 7", "MUSIC | Music Live"]
        let shows: [[(String, Int, String)]] = [
            [("Evening News", 60, "news"), ("World Tonight", 30, "news"), ("Late Edition", 60, "news"), ("Overnight", 60, "news")],
            [("NFL Football: Seattle at Denver", 190, "sports"), ("Postgame", 30, "sports")],
            [("Casablanca", 105, "movie"), ("The Third Man", 95, "movie")],
            [("Cartoon Block", 30, "kids"), ("Science Kids", 30, "kids"), ("Puzzle Time", 30, "kids"), ("Story Hour", 60, "kids"), ("Bedtime Tales", 60, "kids")],
            [("Planet Oceans", 60, ""), ("Wild Mountains", 60, ""), ("Desert Life", 60, ""), ("Night Sky", 60, "")],
            [("Stand-Up Tonight", 45, ""), ("Sketch Hour", 60, ""), ("Late Laughs", 60, ""), ("Reruns", 60, "")],
            [("Local Weather", 15, "news"), ("City Council Live", 75, "news"), ("Community Spotlight", 30, ""), ("Late News", 30, "news"), ("Overnight", 60, "")],
            [("Concert Series", 120, ""), ("Top 20 Countdown", 90, "")]
        ]
        let start = Self.windowStart().addingTimeInterval(-20 * 60)
        var demoChannels: [LiveTVChannel] = []
        var demoPrograms: [String: [LiveTVProgram]] = [:]
        for (index, name) in names.enumerated() {
            let channel = LiveTVChannel(id: "demo|\(index)", serverID: "demo", itemID: "\(index)", name: name, number: String(index + 2), imageURL: nil, isFavorite: index == 1)
            demoChannels.append(channel)
            var cursor = start
            demoPrograms[channel.id] = shows[index].enumerated().map { offset, show in
                let end = cursor.addingTimeInterval(TimeInterval(show.1 * 60))
                defer { cursor = end }
                return LiveTVProgram(
                    id: "demo|\(index)|\(offset)", channelID: channel.id, title: show.0,
                    episodeTitle: offset == 1 ? "Episode \(offset + 3)" : nil,
                    overview: "Sample listing used for the automated screenshot tour.",
                    start: cursor, end: end,
                    isMovie: show.2 == "movie", isSports: show.2 == "sports", isNews: show.2 == "news", isKids: show.2 == "kids",
                    isLive: show.2 == "sports", isPremiere: offset == 0 && index % 3 == 0, imageURL: nil,
                    fromOutsideGuide: index == 1
                )
            }
        }
        loadedSignature = ProfileSettings.activeProfileScope + "|" + JellyfinServerStore.shared.servers.map(\.id).joined(separator: ",")
        channelsLoadedAt = Date()
        guideLoadedAt = Date()
        guideWindowStart = Self.windowStart()
        setChannels(Self.annotated(demoChannels))
        programs = demoPrograms
        guideState = Dictionary(uniqueKeysWithValues: demoChannels.map { ($0.id, GuideState.loaded) })
        demoChannels.forEach { guideWindowByChannel[$0.id] = Self.windowStart() }
        state = .loaded
    }
}
