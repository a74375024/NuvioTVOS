import Foundation
import Combine
import UIKit

/// Live TV from the Emby / Jellyfin servers signed in under Settings →
/// Jellyfin. Raw server channels are turned into one guide entry per real
/// channel (other versions become automatic backup feeds), numbered event
/// feeds into Live Events, and a suggested, editable My Lineup.
@MainActor
final class LiveTVStore: ObservableObject {
    static let shared = LiveTVStore()

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: Self.playerStatusNotification, object: nil, queue: .main) { [weak self] note in
            let metaID = note.object as? String
            let status = note.userInfo?["status"] as? String ?? ""
            let message = note.userInfo?["message"] as? String
            Task { @MainActor in self?.playerStatusChanged(metaID: metaID, status: status, message: message) }
        })
        observers.append(center.addObserver(forName: Self.firstFrameNotification, object: nil, queue: .main) { [weak self] note in
            let metaID = note.object as? String
            Task { @MainActor in self?.playerStarted(metaID: metaID) }
        })
    }

    /// Posted by the player (object: meta id) for Live TV streams.
    nonisolated static let playerStatusNotification = Notification.Name("nuvio.livetv.playerStatus")
    nonisolated static let firstFrameNotification = Notification.Name("nuvio.livetv.firstFrame")
    /// Asks the player showing `from` to switch to another stream in place.
    nonisolated static let replaceStreamNotification = Notification.Name("nuvio.livetv.replaceStream")

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
        /// Rebuilding in the background; any saved listings stay in use.
        case updating(String)
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

    /// Raw server channels (every variant and event feed).
    @Published private(set) var channels: [LiveTVChannel] = []
    /// One per real channel, in guide order (lineup numbers first).
    @Published private(set) var entries: [LiveTVChannel] = []
    /// My Lineup, in lineup-number order.
    @Published private(set) var lineupEntries: [LiveTVChannel] = []
    /// Entries from the chosen countries (plus favorites and My Lineup): what
    /// All Channels, groups and Show hidden list. Search covers everything.
    @Published private(set) var browseEntries: [LiveTVChannel] = []
    @Published private(set) var events: [LiveEvent] = []
    @Published private(set) var families: [EventFamily] = []
    @Published private(set) var prefs = LineupPrefs()
    @Published private(set) var programs: [String: [LiveTVProgram]] = [:]
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingGuide = false
    /// Where each channel's guide stands, so a row can say "loading" vs "none".
    @Published private(set) var guideState: [String: GuideState] = [:]
    /// Provider groups with entry counts, largest first.
    @Published private(set) var groups: [ChannelGroup] = []
    @Published private(set) var hiddenGroups: Set<String> = []
    @Published private(set) var recentIDs: [String] = []
    @Published private(set) var outsideStatus: OutsideStatus = .off
    @Published private(set) var watching: LiveTVChannel?
    @Published private(set) var overlay: Overlay?
    @Published private(set) var banner: Banner?
    @Published private(set) var lineupBuild: String?
    /// Short confirmation shown over the guide or player.
    @Published var toast: String?

    var isWatching: Bool { watching != nil }

    /// Wired by the app root, which owns the player.
    var present: ((LiveTVChannel, URL, NuvioMeta, String) -> Void)?
    var leavePlayer: (() -> Void)?

    static let guideHours = 3.0
    /// Event feeds rename themselves through the day, so the channel list is
    /// re-read this often while Live TV is open.
    private static let channelLifetime: TimeInterval = 30 * 60
    private static let programBatch = 25
    private static let guideConcurrency = 4
    private static let otherGroup = "Other"
    private static let firstFrameTimeout: UInt64 = 25

    private(set) var entryInfo: [String: LiveTVEntryInfo] = [:]
    /// Every event and family found; `events` / `families` hold the chosen countries'.
    private var allEvents: [LiveEvent] = []
    private var allFamilies: [EventFamily] = []
    private var lineupRefreshTask: Task<Void, Never>?
    private(set) var traits: [String: ChannelTraits] = [:]
    private var entryOf: [String: String] = [:]
    private var entryIndex: [String: Int] = [:]
    private var lineupNumbers: [String: Int] = [:]
    private(set) var lineupIDs: Set<String> = []
    private var loadedSignature: String?
    private var channelsLoadedAt: Date?
    private var guideLoadedAt: Date?
    private var guideWindowStart: Date?
    private var loadTask: Task<Void, Never>?
    private var tuneGeneration = 0
    private var streamWork: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Streams currently open on the server (at most one in practice).
    private var openStreams: [(stream: LiveTVStream, serverID: String)] = []
    private var indexByID: [String: Int] = [:]
    /// What the server's guide returned, before outside listings are merged in.
    private var serverPrograms: [String: [LiveTVProgram]] = [:]
    /// Outside listings for each server channel that has any.
    private var outsideMatches: [String: [OutsideGuide.RawProgram]] = [:]
    private var outsideBuiltAt: Date?
    private var outsideNotes: [String: String] = [:]
    private var outsideTask: Task<Void, Never>?
    /// The Xtream providers' own full guides (xmltv.php), per channel id.
    private var providerMatches: [String: [OutsideGuide.RawProgram]] = [:]
    private var providerNotes: [String: String] = [:]
    private var providerTask: Task<Void, Never>?
    /// Provider guide status per Xtream account (source id), for Guide Listings.
    @Published private(set) var providerStates: [String: ProviderGuide.State] = [:]
    private var guideWindowByChannel: [String: Date] = [:]
    private var pendingGuide: [String] = []
    private var pendingGuideSet: Set<String> = []
    /// Rows asked for recently, re-requested when the guide window moves on.
    private var recentlyRequested: [String] = []
    private var guideFlushTask: Task<Void, Never>?
    private var activeGuideFetches = 0
    /// What Up / Down flips through: the list the channel was picked from.
    private var flipList: [LiveTVChannel] = []
    // Failover state for what's playing.
    private var candidates: [LiveTVChannel] = []
    private var candidateIndex = 0
    private var playingMetaID: String?
    private var sawFirstFrame = false
    private var surfStep = 0
    /// Whether a Live TV player is up (so recovery can swap streams in it),
    /// and the meta id it's showing.
    private var playerOnScreen = false
    private var playerMetaID: String?
    private var session = 0
    private var tuneStartedAt = Date()
    private var feedPresentedAt: Date?
    private var feedFirstFrameAt: Date?
    private var stallStartedAt: Date?
    private var stallTask: Task<Void, Never>?
    private var reconnectsOnFeed = 0
    private var recoveries: [Date] = []
    private var startupRetryFeed: String?
    private var startupRetries: [String: Int] = [:]
    private var startupErrorTask: Task<Void, Never>?
    private var stallCause = ""
    private var announceBackup = false
    /// Small note over the player while recovering ("Reconnecting…").
    @Published private(set) var playbackNote: String?

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

    private func xtreamClients() -> [XtreamClient] {
        XtreamStore.shared.accounts.compactMap { account in
            let password = XtreamCredentialStore.password(forAccountID: account.id)
            guard account.serverURL != nil, !password.isEmpty else { return nil }
            return XtreamClient(account: account, password: password)
        }
    }

    private func xtreamClient(for serverID: String) -> XtreamClient? {
        xtreamClients().first { $0.account.sourceID == serverID }
    }

    /// Output formats each Xtream account allows (learned when channels load).
    private var xtreamFormats: [String: [String]] = [:]

    var hasServers: Bool { !JellyfinServerStore.shared.servers.isEmpty || !XtreamStore.shared.accounts.isEmpty }

    private var currentSignature: String {
        ProfileSettings.activeProfileScope + "|" + JellyfinServerStore.shared.servers.map(\.id).joined(separator: ",")
            + "|" + XtreamStore.shared.accounts.map(\.id).joined(separator: ",")
    }

    // MARK: Loading

    func loadIfNeeded(force: Bool = false) {
        let signature = currentSignature
        if signature != loadedSignature {
            channels = []
            entries = []
            lineupEntries = []
            events = []
            families = []
            allEvents = []
            allFamilies = []
            browseEntries = []
            indexByID = [:]
            entryInfo = [:]
            entryOf = [:]
            traits = [:]
            pendingGuide = []
            pendingGuideSet = []
            programs = [:]
            serverPrograms = [:]
            outsideMatches = [:]
            outsideStatus = .off
            providerTask?.cancel()
            providerTask = nil
            providerMatches = [:]
            providerNotes = [:]
            providerStates = [:]
            guideState = [:]
            guideWindowByChannel = [:]
            channelsLoadedAt = nil
            guideLoadedAt = nil
            state = .idle
            hiddenGroups = Self.loadSet(Self.hiddenGroupsKey)
            recentIDs = Self.loadList(Self.recentKey)
            prefs = LineupPrefs.load()
            ProviderGuide.countries = prefs.guideCountries
        }
        let channelsFresh = channelsLoadedAt.map { Date().timeIntervalSince($0) < Self.channelLifetime } ?? false
        if !force, channelsFresh, signature == loadedSignature, !channels.isEmpty {
            refreshGuideIfNeeded()
            return
        }
        guard loadTask == nil else { return }
        loadedSignature = signature
        let configured = servers()
        let xtream = xtreamClients()
        guard !configured.isEmpty || !xtream.isEmpty else {
            state = .empty(hasServers
                ? "Sign in again in Settings → Integrations (Jellyfin or Xtream)."
                : "Add an Xtream account or your Emby / Jellyfin server in Settings → Integrations to see live channels here.")
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
            for client in xtream {
                do {
                    if let info = try? await client.accountInfo() {
                        self.xtreamFormats[client.account.sourceID] = info.formats
                    }
                    let list = try await client.channels()
                    all += list
                    var updated = client.account
                    updated.lastChannelCount = list.count
                    XtreamStore.shared.upsert(updated)
                } catch {
                    problems.append("\(client.account.displayName): \(error.localizedDescription)")
                }
            }
            // Favorites kept on this Apple TV (Xtream has no favorites API).
            let localFavorites = Set(Self.loadList(Self.localFavoritesKey))
            for index in all.indices where localFavorites.contains(all[index].id) { all[index].isFavorite = true }
            guard !Task.isCancelled else { return }
            if all.isEmpty {
                self.channelsLoadedAt = Date()
                if self.channels.isEmpty {
                    self.state = problems.isEmpty
                        ? .empty("Your server didn't list any live channels for this account.")
                        : .failed(problems.joined(separator: "\n"))
                }
                return
            }
            let isFirstLoad = self.channels.isEmpty
            let annotated = Self.annotated(all)
            let catalog = await Task.detached(priority: .userInitiated) {
                ChannelCatalog.build(annotated, stations: StationDirectory.cached())
            }.value
            guard !Task.isCancelled else { return }
            self.channelsLoadedAt = Date()
            self.apply(channels: annotated, catalog: catalog)
            self.state = .loaded
            if isFirstLoad {
                self.loadProviderGuide()
                self.loadOutsideGuide()
                let first = self.visibleEntries().prefix(60).map(\.id)
                let favorites = self.entries.filter(\.isFavorite).prefix(40).map(\.id)
                self.requestGuide(Array(favorites) + self.recentIDs.prefix(20) + first)
            } else {
                // New channels may need the provider's guide; cheap if not.
                self.loadProviderGuide()
                self.rebuildOutsidePrograms()
            }
        }
    }

    /// Installs a freshly built catalog: raw channels, entries, events.
    private func apply(channels list: [LiveTVChannel], catalog: ChannelCatalog.Result) {
        channels = list
        indexByID = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        traits = catalog.traits
        entryOf = catalog.entryOf
        entryInfo = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        allEvents = catalog.events
        allFamilies = catalog.families
        applyEventFilter()
        rebuildEntries()
    }

    /// Live Events for the chosen countries (events with no known country stay).
    private func applyEventFilter() {
        let countries = prefs.guideCountries
        func keep(_ market: String?) -> Bool {
            guard let market else { return true }
            return countries.contains(market.components(separatedBy: "-").first ?? market)
        }
        events = allEvents.filter { keep($0.market) }
        families = allFamilies.filter { keep($0.market) }
    }

    /// Re-works My Lineup shortly after guide data lands (several sources can
    /// finish close together), so suggestions follow what has listings.
    private func scheduleLineupRefresh() {
        guard prefs.configured else { return }
        lineupRefreshTask?.cancel()
        lineupRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.rebuildEntries()
        }
    }

    /// Recomputes lineup membership, numbering and the entry list.
    private func rebuildEntries() {
        let infos = Array(entryInfo.values)
        var lineup = Set<String>()
        for info in infos {
            let favorite = info.members.contains { indexByID[$0].map { channels[$0].isFavorite } ?? false }
            if prefs.removed.contains(info.id) { continue }
            if favorite || prefs.added.contains(info.id) {
                lineup.insert(info.id)
            } else if prefs.configured,
                      LineupEngine.suggests(info, prefs: prefs, hasGuide: entryHasGuide(info.id), name: info.name) {
                // Suggestions are worked out live, so channels join as their
                // listings load (and core networks / market locals always).
                lineup.insert(info.id)
            }
        }
        lineupIDs = lineup
        lineupNumbers = LineupEngine.numbers(for: infos.filter { lineup.contains($0.id) })
        // Everything else gets numbers after the lineup, by category.
        var allNumbers = lineupNumbers
        let rest = infos.filter { !lineup.contains($0.id) }
        var next = (lineupNumbers.values.max() ?? 0) / 1000 * 1000 + 5000
        for category in LineupCategory.allCases {
            for info in rest.filter({ $0.category == category }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                allNumbers[info.id] = next
                next += 1
            }
        }
        let built: [LiveTVChannel] = infos.compactMap { info in
            let members = info.members.compactMap { indexByID[$0].map { channels[$0] } }
            guard let primary = members.first else { return nil }
            return LiveTVChannel(
                id: info.id, serverID: primary.serverID, itemID: primary.itemID, name: info.name,
                number: allNumbers[info.id].map(String.init),
                imageURL: members.lazy.compactMap(\.imageURL).first,
                isFavorite: members.contains(where: \.isFavorite),
                tags: primary.tags, isRadio: primary.isRadio, group: primary.group, shortName: info.name
            )
        }.sorted { (Int($0.number ?? "") ?? Int.max) < (Int($1.number ?? "") ?? Int.max) }
        entries = built
        entryIndex = Dictionary(built.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        lineupEntries = built.filter { lineup.contains($0.id) }
        browseEntries = built.filter { entry in
            lineup.contains(entry.id) || entry.isFavorite || prefs.includes(market: entryInfo[entry.id]?.market)
        }
        var counts: [String: Int] = [:]
        for entry in browseEntries { counts[entry.group ?? Self.otherGroup, default: 0] += 1 }
        groups = counts.map { ChannelGroup(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Entry guides from whatever member data is already here.
        var merged = programs
        var states = guideState
        applyEntryGuides(&merged, &states, entryIDs: Array(entryInfo.keys))
        programs = merged
        guideState = states
    }

    /// The entries the guide starts with: My Lineup once set up, else all.
    func visibleEntries() -> [LiveTVChannel] {
        prefs.configured ? lineupEntries : browseEntries.filter { !isHidden($0) }
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
    /// the rows looked at recently are fetched again for the new window; the
    /// channel list (event names) is re-read every half hour.
    func refreshGuideIfNeeded() {
        if let loaded = channelsLoadedAt, Date().timeIntervalSince(loaded) > Self.channelLifetime, loadTask == nil, !isWatching {
            loadIfNeeded()
        }
        let start = Self.windowStart()
        guard guideWindowStart != start else { return }
        guideWindowStart = start
        rebuildOutsidePrograms()
        requestGuide(recentlyRequested)
    }

    // MARK: Server guide

    /// Queues guide fetches for entries or channels (by id). Rows call this as
    /// they come on screen, so the part of the guide being looked at fills in
    /// first. An entry asks for its first two versions.
    func requestGuide(_ ids: [String]) {
        let start = Self.windowStart()
        if guideWindowStart == nil { guideWindowStart = start }
        var raw: [String] = []
        for id in ids {
            if let info = entryInfo[id] { raw += info.members.prefix(2) } else { raw.append(id) }
        }
        for id in raw where indexByID[id] != nil {
            if traits[id]?.familyKey != nil { continue }     // event feeds: names, not guides
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
            if serverID.hasPrefix("xt:") {
                if let client = xtreamClient(for: serverID) {
                    fetchXtreamGuide(batch, client: client)
                } else {
                    batch.forEach { guideState[$0] = .failed }
                }
                continue
            }
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
                    merged[id] = self.bestListing(server: self.serverListing(for: id), outside: self.outsideListing(for: id))
                    states[id] = .loaded
                    self.guideWindowByChannel[id] = start
                }
            } else {
                ids.forEach { states[$0] = .failed }
            }
            self.applyEntryGuides(&merged, &states, entryIDs: Array(Set(ids.compactMap { self.entryOf[$0] })))
            self.programs = merged
            self.guideState = states
            self.guideLoadedAt = Date()
            self.startGuideFetches()
        }
    }

    /// Xtream guides come per channel ("short EPG"), a few at a time.
    /// Channels the provider's full guide already covers skip the request.
    private func fetchXtreamGuide(_ allIDs: [String], client: XtreamClient) {
        let start = Self.windowStart()
        let covered = allIDs.filter { providerCovers($0, from: start) }
        if !covered.isEmpty {
            var merged = programs
            var states = guideState
            for id in covered {
                merged[id] = bestListing(server: serverListing(for: id), outside: outsideListing(for: id))
                states[id] = .loaded
                guideWindowByChannel[id] = start
            }
            applyEntryGuides(&merged, &states, entryIDs: Array(Set(covered.compactMap { entryOf[$0] })))
            programs = merged
            guideState = states
        }
        let ids = allIDs.filter { !covered.contains($0) }
        guard !ids.isEmpty else { return }
        let items = ids.compactMap { id in indexByID[id].map { (id, channels[$0].itemID) } }
        var states = guideState
        ids.forEach { states[$0] = .loading }
        guideState = states
        activeGuideFetches += 1
        isLoadingGuide = true
        Task { [weak self] in
            var results: [String: [LiveTVProgram]] = [:]
            await withTaskGroup(of: (String, [LiveTVProgram]).self) { group in
                var iterator = items.makeIterator()
                for _ in 0..<6 {
                    guard let (id, stream) = iterator.next() else { break }
                    group.addTask { (id, await client.shortEPG(streamID: stream, channelID: id)) }
                }
                while let (id, list) = await group.next() {
                    results[id] = list
                    if let (nextID, stream) = iterator.next() {
                        group.addTask { (nextID, await client.shortEPG(streamID: stream, channelID: nextID)) }
                    }
                }
            }
            guard let self else { return }
            self.activeGuideFetches -= 1
            var merged = self.programs
            var states = self.guideState
            for id in ids {
                let server = (results[id] ?? []).sorted { $0.start < $1.start }
                self.serverPrograms[id] = server
                merged[id] = self.bestListing(server: self.serverListing(for: id), outside: self.outsideListing(for: id))
                states[id] = .loaded
                self.guideWindowByChannel[id] = start
            }
            self.applyEntryGuides(&merged, &states, entryIDs: Array(Set(ids.compactMap { self.entryOf[$0] })))
            self.programs = merged
            self.guideState = states
            self.guideLoadedAt = Date()
            self.startGuideFetches()
        }
    }

    /// An entry's guide is the best of its versions' guides.
    private func applyEntryGuides(_ merged: inout [String: [LiveTVProgram]], _ states: inout [String: GuideState], entryIDs: [String]) {
        let start = Self.windowStart()
        let end = start.addingTimeInterval(Self.guideHours * 3600)
        func coverage(_ list: [LiveTVProgram]) -> TimeInterval {
            list.reduce(0) { total, p in total + max(0, min(p.end, end).timeIntervalSince(max(p.start, start))) }
        }
        for id in entryIDs {
            guard let info = entryInfo[id] else { continue }
            var best: [LiveTVProgram] = []
            var bestCoverage: TimeInterval = -1
            var anyLoading = false, anyLoaded = false, anyFailed = false
            for member in info.members {
                if let list = merged[member], !list.isEmpty {
                    let value = coverage(list)
                    if value > bestCoverage { best = list; bestCoverage = value }
                }
                switch states[member] {
                case .loading: anyLoading = true
                case .loaded: anyLoaded = true
                case .failed: anyFailed = true
                case nil: break
                }
            }
            merged[id] = best.isEmpty ? nil : best.map { program in
                LiveTVProgram(
                    id: "\(id)|\(program.id)", channelID: id, title: program.title, episodeTitle: program.episodeTitle,
                    overview: program.overview, start: program.start, end: program.end, isMovie: program.isMovie,
                    isSports: program.isSports, isNews: program.isNews, isKids: program.isKids, isLive: program.isLive,
                    isPremiere: program.isPremiere, imageURL: program.imageURL, fromOutsideGuide: program.fromOutsideGuide
                )
            }
            if !best.isEmpty || anyLoaded {
                states[id] = .loaded
            } else if anyLoading {
                states[id] = .loading
            } else if anyFailed {
                states[id] = .failed
            }
        }
    }

    // MARK: Provider guide (Xtream xmltv.php)

    /// Uses each Xtream account's saved full guide right away, then rebuilds
    /// the old ones (or all, with `force`) in the background. Only channels
    /// with a guide id from a selected country take part.
    func loadProviderGuide(force: Bool = false) {
        if !force, providerTask != nil { return }
        providerTask?.cancel()
        providerTask = nil
        let accounts = xtreamClients()
        guard !accounts.isEmpty, !channels.isEmpty else {
            if !providerMatches.isEmpty || !providerStates.isEmpty {
                providerMatches = [:]
                providerNotes = [:]
                providerStates = [:]
                rebuildOutsidePrograms()
            }
            return
        }
        let profile = ProfileSettings.activeProfileScope
        var jobs: [(sourceID: String, name: String, url: URL, channels: [LiveTVChannel], key: String)] = []
        var matches = providerMatches
        var notes = providerNotes
        var states = providerStates
        for client in accounts {
            let sourceID = client.account.sourceID
            let name = client.account.displayName
            let scoped = channels.filter {
                $0.serverID == sourceID && traits[$0.id]?.familyKey == nil && ProviderGuide.inScope($0)
            }
            guard !scoped.isEmpty, let url = client.guideURL() else {
                states[sourceID] = ProviderGuide.State(name: name, status: .unavailable(
                    "None of this provider's channels in your countries have a guide id."))
                continue
            }
            let key = ProviderGuide.cacheKey(profile: profile, sourceID: sourceID)
            let saved = ProviderGuide.loadSaved(key)
            if let saved {
                Self.replace(&matches, &notes, prefix: "\(sourceID)|", with: saved.programs, saved.notes)
                states[sourceID] = ProviderGuide.State(name: name, status: .ready(
                    matched: saved.programs.count, total: scoped.count, guideChannels: saved.guideChannels, updated: saved.built))
            }
            if force || ProviderGuide.needsRebuild(saved, channelCount: scoped.count) {
                jobs.append((sourceID, name, url, scoped, key))
                if saved == nil {
                    states[sourceID] = ProviderGuide.State(name: name, status: .updating("Waiting to start…"))
                }
            }
        }
        providerMatches = matches
        providerNotes = notes
        providerStates = states
        rebuildOutsidePrograms()
        scheduleLineupRefresh()
        guard !jobs.isEmpty else { return }
        providerTask = Task { [weak self] in
            // Let the guide's first screen load before background work.
            try? await Task.sleep(nanoseconds: force ? 0 : 4_000_000_000)
            for job in jobs {
                guard !Task.isCancelled else { break }
                await self?.runProviderBuild(sourceID: job.sourceID, name: job.name, url: job.url,
                                             channels: job.channels, key: job.key)
            }
            if !Task.isCancelled { self?.providerTask = nil }
        }
    }

    /// Builds one provider's guide and installs it (also used by the demo).
    private func runProviderBuild(sourceID: String, name: String, url: URL, channels scoped: [LiveTVChannel], key: String?) async {
        let previous = providerStates[sourceID]?.status
        providerStates[sourceID] = ProviderGuide.State(name: name, status: .updating("Starting…"))
        let outcome = await ProviderGuide.build(url: url, channels: scoped) { line in
            Task { @MainActor [weak self] in
                guard let self, case .updating = self.providerStates[sourceID]?.status else { return }
                self.providerStates[sourceID] = ProviderGuide.State(name: name, status: .updating(line))
            }
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .built(let saved):
            if let key { ProviderGuide.save(saved, key: key) }
            var matches = providerMatches
            var notes = providerNotes
            Self.replace(&matches, &notes, prefix: "\(sourceID)|", with: saved.programs, saved.notes)
            providerMatches = matches
            providerNotes = notes
            providerStates[sourceID] = ProviderGuide.State(name: name, status: .ready(
                matched: saved.programs.count, total: scoped.count, guideChannels: saved.guideChannels, updated: saved.built))
            rebuildOutsidePrograms()
            scheduleLineupRefresh()
        case .unavailable(let message):
            providerStates[sourceID] = ProviderGuide.State(name: name, status: .unavailable(message))
        case .failed(let message):
            // Keep using a saved guide if there is one.
            if let previous, case .ready = previous {
                providerStates[sourceID] = ProviderGuide.State(name: name, status: previous)
                flash("Couldn't update \(name)'s guide: \(message)")
            } else {
                providerStates[sourceID] = ProviderGuide.State(name: name, status: .failed(message))
            }
        }
    }

    /// Swaps one provider's listings (channel ids starting with `prefix`).
    private static func replace(
        _ matches: inout [String: [OutsideGuide.RawProgram]], _ notes: inout [String: String],
        prefix: String, with programs: [String: [OutsideGuide.RawProgram]], _ newNotes: [String: String]
    ) {
        matches = matches.filter { !$0.key.hasPrefix(prefix) }
        notes = notes.filter { !$0.key.hasPrefix(prefix) }
        matches.merge(programs) { _, new in new }
        notes.merge(newNotes) { _, new in new }
    }

    private func providerListing(for id: String) -> [LiveTVProgram]? {
        guard let match = providerMatches[id] else { return nil }
        let start = Self.windowStart().addingTimeInterval(-3600)
        return OutsideGuide.programs(match, channelID: id, from: start, to: start.addingTimeInterval(14 * 3600),
                                     idPrefix: "pg", outside: false)
    }

    /// The provider's own listing for a channel: its full guide first, the
    /// per-channel short guide filling any gaps (Emby: the server guide).
    private func serverListing(for id: String) -> [LiveTVProgram] {
        let short = serverPrograms[id] ?? []
        guard let full = providerListing(for: id), !full.isEmpty else { return short }
        return bestListing(server: full, outside: short)
    }

    /// Whether the provider's full guide has something in the guide window.
    private func providerCovers(_ id: String, from start: Date) -> Bool {
        guard let raw = providerMatches[id] else { return false }
        let low = Int(start.timeIntervalSince1970 / 60)
        let high = low + Int(Self.guideHours * 60)
        return raw.contains { $0.s < high && $0.s + $0.m > low }
    }

    // MARK: Outside listings

    /// Uses saved outside listings right away, then (if they're old, or
    /// `force`) rebuilds them in the background on this Apple TV.
    func loadOutsideGuide(force: Bool = false) {
        outsideTask?.cancel()
        guard OutsideGuide.isEnabled, !channels.isEmpty else {
            outsideMatches = [:]
            outsideStatus = .off
            rebuildOutsidePrograms()
            return
        }
        let shardIDs = OutsideGuide.enabledShards
        let signature = loadedSignature ?? "default"
        // Event feeds are named per event; listings don't apply to them. Only
        // the chosen countries' channels (or ones of unknown country) take part.
        let countries = prefs.guideCountries
        let snapshot = channels.filter { channel in
            guard let trait = traits[channel.id], trait.familyKey == nil,
                  trait.kind != .placeholder, trait.kind != .separator else { return false }
            guard let market = trait.market else { return true }
            return countries.contains(market.components(separatedBy: "-").first ?? market)
        }
        let saved = OutsideGuide.loadSaved(signature: signature)
        if let saved, Set(saved.shards) == shardIDs {
            outsideMatches = saved.programs
            outsideNotes = saved.notes ?? [:]
            outsideBuiltAt = saved.built
            outsideStatus = .ready(matched: saved.programs.count, total: snapshot.count, updated: saved.built)
            rebuildOutsidePrograms()
            scheduleLineupRefresh()
        }
        guard force || OutsideGuide.needsRebuild(saved, shards: shardIDs, channelCount: snapshot.count) else { return }
        outsideStatus = .updating("Getting ready…")
        outsideTask = Task { [weak self] in
            // Give the app a moment to settle before starting background work.
            try? await Task.sleep(nanoseconds: force ? 0 : 8_000_000_000)
            // One heavy guide job at a time: the provider's own guide first.
            if let pending = self?.providerTask { await pending.value }
            guard !Task.isCancelled else { return }
            let built = await OutsideGuide.build(for: snapshot, shards: shardIDs) { line in
                Task { @MainActor in
                    guard let self, case .updating = self.outsideStatus else { return }
                    self.outsideStatus = .updating(line)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if built.programs.isEmpty, !built.problems.isEmpty {
                self.outsideStatus = self.outsideMatches.isEmpty
                    ? .failed(built.problems.joined(separator: "\n"))
                    : .ready(matched: self.outsideMatches.count, total: snapshot.count, updated: self.outsideBuiltAt)
                return
            }
            let now = Date()
            OutsideGuide.save(
                OutsideGuide.Saved(built: now, shards: Array(shardIDs), channelCount: snapshot.count,
                                   programs: built.programs, notes: built.notes),
                signature: signature
            )
            self.outsideMatches = built.programs
            self.outsideNotes = built.notes
            self.outsideBuiltAt = now
            self.outsideStatus = .ready(matched: built.programs.count, total: snapshot.count, updated: now)
            self.rebuildOutsidePrograms()
            self.scheduleLineupRefresh()
        }
    }

    private func outsideListing(for id: String) -> [LiveTVProgram]? {
        guard let match = outsideMatches[id] else { return nil }
        let start = Self.windowStart().addingTimeInterval(-3600)
        return OutsideGuide.programs(match, channelID: id, from: start, to: start.addingTimeInterval(14 * 3600))
    }

    /// Re-merges every channel's listing (after outside data loads or the
    /// window moves on), then the entries built from them.
    private func rebuildOutsidePrograms() {
        var merged = programs.filter { !$0.key.hasPrefix("e|") }
        let ids = Set(outsideMatches.keys).union(providerMatches.keys).union(merged.keys)
        for id in ids {
            merged[id] = bestListing(server: serverListing(for: id), outside: outsideListing(for: id))
        }
        merged = merged.filter { !$0.value.isEmpty }
        var states = guideState
        applyEntryGuides(&merged, &states, entryIDs: Array(entryInfo.keys))
        programs = merged
        guideState = states
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

    /// Whether any version of an entry has guide data (server or outside).
    func entryHasGuide(_ id: String) -> Bool {
        guard let info = entryInfo[id] else { return !(programs[id] ?? []).isEmpty }
        return info.members.contains {
            outsideMatches[$0] != nil || providerMatches[$0] != nil || !(serverPrograms[$0] ?? []).isEmpty
        }
    }

    // MARK: My Lineup

    func entry(id: String) -> LiveTVChannel? {
        entryIndex[id].map { entries[$0] }
    }

    func isInLineup(_ channel: LiveTVChannel) -> Bool {
        lineupIDs.contains(channel.id)
    }

    func setInLineup(_ channel: LiveTVChannel, _ included: Bool) {
        var updated = prefs
        if included {
            updated.removed.remove(channel.id)
            // Suggestions change as listings load; a hand-added channel stays.
            updated.added.insert(channel.id)
        } else {
            updated.added.remove(channel.id)
            updated.removed.insert(channel.id)
        }
        setPrefs(updated)
        flash(included ? "Added \(channel.name) to My Lineup" : "Removed \(channel.name) from My Lineup")
    }

    func setShowHidden(_ show: Bool) {
        var updated = prefs
        updated.showHidden = show
        setPrefs(updated)
    }

    func setPrefs(_ updated: LineupPrefs) {
        let countriesChanged = updated.countries != prefs.countries
        prefs = updated
        updated.save()
        if countriesChanged {
            applyEventFilter()
            ProviderGuide.countries = updated.guideCountries
            loadProviderGuide(force: true)
        }
        rebuildEntries()
    }

    /// Channels per country / language, for the country picker: US English
    /// and US Spanish first, then the rest by size.
    struct MarketCount: Identifiable {
        let market: String
        let count: Int
        var id: String { market }
    }

    func marketCounts() -> [MarketCount] {
        var counts: [String: Int] = [:]
        for info in entryInfo.values where info.kind == .channel {
            if let market = info.market { counts[market, default: 0] += 1 }
        }
        let rank: [String: Int] = ["US": 0, "US-ES": 1]
        return counts.map { MarketCount(market: $0.key, count: $0.value) }.sorted {
            let a = rank[$0.market] ?? 2, b = rank[$1.market] ?? 2
            return a != b ? a < b : $0.count > $1.count
        }
    }

    /// "US (English)", "US (Spanish)", "Mexico", "ASIA"…
    nonisolated static func marketName(_ code: String) -> String {
        switch code {
        case "US": return "United States (English)"
        case "US-ES": return "United States (Spanish)"
        case "UK": return "United Kingdom"
        case "ASIA": return "Asia"
        case "AFR": return "Africa"
        case "EXYU": return "Ex-Yugoslavia"
        case "LA": return "Latin America"
        case "KU": return "Kurdish"
        default:
            return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
        }
    }

    /// Category counts for the setup screen: (in the suggested lineup, total).
    func categoryCounts(for draft: LineupPrefs) -> [LineupCategory: (Int, Int)] {
        var result: [LineupCategory: (Int, Int)] = [:]
        var everything = draft
        everything.categories = Set(LineupCategory.allCases)
        for info in entryInfo.values {
            var counts = result[info.category] ?? (0, 0)
            counts.1 += 1
            if LineupEngine.suggests(info, prefs: everything, hasGuide: entryHasGuide(info.id), name: info.name) {
                counts.0 += 1
            }
            result[info.category] = counts
        }
        return result
    }

    /// Builds the suggested lineup: checks which channels have guide data
    /// (server and outside), then applies the market and category choices.
    func buildLineup(_ draft: LineupPrefs) async {
        lineupBuild = "Checking which channels have listings…"
        if draft.countries != prefs.countries {
            // Apply the country choice first so the check covers the right channels.
            var early = prefs
            early.countries = draft.countries
            setPrefs(early)
        }
        await checkAllGuides(timeout: 120) { [weak self] done, total in
            self?.lineupBuild = "Checking listings: \(done) of \(total) channels…"
        }
        var updated = draft
        updated.suggested = Set(entryInfo.values.filter { info in
            LineupEngine.suggests(info, prefs: draft, hasGuide: entryHasGuide(info.id), name: info.name)
        }.map(\.id))
        updated.configured = true
        updated.builtAt = Date()
        setPrefs(updated)
        lineupBuild = nil
    }

    // MARK: Channel report

    /// Fetches per-channel guides for the report, waiting up to `timeout`.
    /// Only each entry's main version is asked, lineup first, skipping event
    /// feeds and channels the provider's full guide already covers, and at
    /// most `limit` of them: asking a big provider for tens of thousands of
    /// per-channel guides takes ages and hammers it. `progress` gets
    /// "checked / total".
    func checkAllGuides(timeout: TimeInterval = 120, limit: Int = 2500, progress: @escaping (Int, Int) -> Void) async {
        let start = Self.windowStart()
        var seen = Set<String>()
        var ids: [String] = []
        for entry in lineupEntries + browseEntries {
            guard ids.count < limit else { break }
            guard let member = entryInfo[entry.id]?.members.first ?? (indexByID[entry.id] != nil ? entry.id : nil),
                  traits[member]?.familyKey == nil, !providerCovers(member, from: start),
                  seen.insert(member).inserted else { continue }
            ids.append(member)
        }
        await checkGuides(ids: ids, timeout: timeout, progress: progress)
    }

    private func checkGuides(ids: [String], timeout: TimeInterval, progress: @escaping (Int, Int) -> Void) async {
        requestGuide(ids)
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let done = ids.reduce(0) { $0 + (guideState[$1] == .loaded || guideState[$1] == .failed ? 1 : 0) }
            progress(done, ids.count)
            if pendingGuide.isEmpty, activeGuideFetches == 0 { break }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// One report row's data, gathered on the main actor.
    private struct ReportRow {
        let channel: LiveTVChannel
        let hidden: Bool
        let serverState: String
        let serverCount: Int
        let nowTitle: String
        let nowSource: String
        let entryName: String
        let inLineup: Bool
        let category: String
        let family: String
        let eventText: String
        let provider: String
        let outsideNote: String
        let outsideRaw: [OutsideGuide.RawProgram]?
        let providerGuide: String
        let providerRaw: [OutsideGuide.RawProgram]?
        let kind: String
        let market: String
        let core: String
        let scope: String
    }

    /// One row per channel: what it is, what the server's guide has, and
    /// how outside listings matched (or didn't). No stream links or tokens.
    /// The data is gathered here; the name analysis and text run off the
    /// main thread (big provider lists have tens of thousands of channels).
    func channelReportCSV(progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async -> String {
        let now = Date()
        let start = Self.windowStart()
        let end = start.addingTimeInterval(Self.guideHours * 3600)
        var names: [String: String] = [:]
        var rows: [ReportRow] = []
        rows.reserveCapacity(channels.count)
        for channel in channels {
            let serverList = serverPrograms[channel.id] ?? []
            let serverState: String
            switch guideState[channel.id] {
            case .loaded: serverState = serverList.isEmpty ? "none" : "yes"
            case .failed: serverState = "failed"
            case .loading: serverState = "loading"
            case nil: serverState = "not checked"
            }
            let trait = traits[channel.id]
            let entryID = entryOf[channel.id]
            let isXtream = channel.serverID.hasPrefix("xt:")
            let current = self.current(on: channel.id, at: now)
            let source: String = current.map { program in
                if program.fromOutsideGuide { return "outside" }
                if program.id.hasPrefix("pg|") || program.id.contains("|pg|") { return "provider guide" }
                return isXtream ? "provider short guide" : "server"
            } ?? ""
            let providerGuide: String
            if !isXtream {
                providerGuide = ""
            } else if let note = providerNotes[channel.id] {
                providerGuide = note
            } else if trait?.familyKey != nil {
                providerGuide = "event feed"
            } else if channel.epgID?.isEmpty ?? true {
                providerGuide = "no guide id"
            } else if !ProviderGuide.inScope(channel) {
                providerGuide = "country not selected"
            } else {
                switch providerStates[channel.serverID]?.status {
                case .ready: providerGuide = "not in provider guide"
                case .updating: providerGuide = "provider guide loading"
                case .unavailable(let message), .failed(let message): providerGuide = "provider guide: \(message)"
                case nil: providerGuide = "provider guide not loaded"
                }
            }
            if names[channel.serverID] == nil { names[channel.serverID] = providerName(for: channel.serverID) ?? "" }
            rows.append(ReportRow(
                channel: channel, hidden: isHidden(channel), serverState: serverState,
                serverCount: serverList.filter { $0.end > start && $0.start < end }.count,
                nowTitle: current?.title ?? "", nowSource: source,
                entryName: entryID.flatMap { entryInfo[$0]?.name } ?? "",
                inLineup: entryID.map { lineupIDs.contains($0) } ?? false,
                category: trait?.category.rawValue ?? "", family: trait?.familyKey ?? "", eventText: trait?.eventText ?? "",
                provider: names[channel.serverID] ?? "",
                outsideNote: outsideNotes[channel.id] ?? (outsideMatches[channel.id] == nil ? "no match" : "matched"),
                outsideRaw: outsideMatches[channel.id],
                providerGuide: providerGuide, providerRaw: isXtream ? providerMatches[channel.id] : nil,
                kind: trait?.kind.rawValue ?? "", market: trait?.market ?? "", core: trait?.core ?? "", scope: trait?.scope ?? ""
            ))
        }
        let low = Int(start.timeIntervalSince1970 / 60)
        let high = Int(end.timeIntervalSince1970 / 60)
        let total = rows.count
        return await Task.detached(priority: .userInitiated) { () -> String in
            func cell(_ value: String?) -> String {
                "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            func count(_ raw: [OutsideGuide.RawProgram]?) -> Int {
                (raw ?? []).reduce(0) { $0 + ($1.s < high && $1.s + $1.m > low ? 1 : 0) }
            }
            var stationsByNetwork: [String: [OutsideGuide.Station]] = [:]
            if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let data = try? Data(contentsOf: base.appendingPathComponent("OutsideGuide/stations.json")),
               let stations = try? JSONDecoder().decode([OutsideGuide.Station].self, from: data) {
                stationsByNetwork = Dictionary(grouping: stations, by: \.network)
            }
            var lines = [[
                "number", "name", "group", "tags", "hidden_group", "favorite",
                "callsign_in_name", "station_lookup", "match_key",
                "server_guide", "server_programs_next_3h", "outside_listing", "outside_programs_next_3h",
                "now_title", "now_source", "entry", "category", "in_my_lineup", "event_family", "event_text",
                "provider", "country", "guide_id", "provider_guide", "provider_guide_programs_next_3h",
                "kind", "market", "core_network", "scope"
            ].joined(separator: ",")]
            lines.reserveCapacity(total + 1)
            for (index, row) in rows.enumerated() {
                let channel = row.channel
                let isLocal = (channel.group ?? "").lowercased().contains("local")
                let signs = OutsideGuide.callsigns(in: channel.name, strongContext: isLocal)
                let station = signs.isEmpty ? OutsideGuide.stationCallsign(for: channel.name, stations: stationsByNetwork) : nil
                let isXtream = channel.serverID.hasPrefix("xt:")
                lines.append([
                    cell(channel.number ?? ""), cell(channel.name), cell(channel.group ?? ""),
                    cell(channel.tags.joined(separator: " | ")), cell(row.hidden ? "yes" : ""),
                    cell(channel.isFavorite ? "yes" : ""), cell(signs.joined(separator: " ")), cell(station ?? ""),
                    cell(OutsideGuide.normalize(channel.displayName)), cell(row.serverState), cell(String(row.serverCount)),
                    cell(row.outsideNote), cell(String(count(row.outsideRaw))), cell(row.nowTitle), cell(row.nowSource),
                    cell(row.entryName), cell(row.category), cell(row.inLineup ? "yes" : ""),
                    cell(row.family), cell(row.eventText),
                    cell(row.provider), cell(ProviderGuide.countryPrefix(of: channel.group) ?? ""),
                    cell(channel.epgID ?? ""), cell(row.providerGuide), cell(isXtream ? String(count(row.providerRaw)) : ""),
                    cell(row.kind), cell(row.market), cell(row.core), cell(row.scope)
                ].joined(separator: ","))
                if index % 2000 == 1999 {
                    let done = index + 1
                    await MainActor.run { progress(done, total) }
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }.value
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

    /// A raw server channel.
    func channel(id: String) -> LiveTVChannel? {
        indexByID[id].map { channels[$0] }
    }

    /// An entry, an event, or a raw channel by id.
    func anyChannel(id: String) -> LiveTVChannel? {
        if let entry = entry(id: id) { return entry }
        if let event = events.first(where: { $0.id == id }) { return eventChannel(event) }
        return channel(id: id)
    }

    /// Raw versions of an entry, best first (reliable sources moved up).
    func versions(of channel: LiveTVChannel) -> [LiveTVChannel] {
        if let info = entryInfo[channel.id] {
            var list = orderedByReliability(info.members.compactMap { self.channel(id: $0) })
            // A version the viewer pinned always goes first.
            if let pinned = pinnedFeeds[channel.id], let index = list.firstIndex(where: { $0.id == pinned }), index > 0 {
                list.insert(list.remove(at: index), at: 0)
            }
            return list
        }
        if let event = events.first(where: { $0.id == channel.id }) {
            let feeds = event.feeds.compactMap { self.channel(id: $0) }
            // Xtream feeds first, server feeds as backup.
            return orderedByReliability(feeds.filter { $0.serverID.hasPrefix("xt:") })
                + orderedByReliability(feeds.filter { !$0.serverID.hasPrefix("xt:") })
        }
        return [channel]
    }

    // MARK: Xtream stream format

    private static let preferTSKey = "nuvio.tv.livetv.xtreamPreferTS"

    /// Use MPEG-TS instead of HLS for Xtream streams when the provider allows.
    static var xtreamPrefersTS: Bool {
        get { UserDefaults.standard.bool(forKey: preferTSKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferTSKey) }
    }

    // MARK: Pinned versions

    private static let pinnedFeedsKey = "nuvio.tv.livetv.pinnedFeeds"

    /// Entry id → the version (raw channel id) to always start with.
    private(set) var pinnedFeeds: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: LiveTVStore.pinnedFeedsKey) as? [String: String]) ?? [:]
    }()

    func pinnedFeed(for channel: LiveTVChannel) -> String? { pinnedFeeds[channel.id] }

    /// Always start `channel` with `feed` (nil: back to automatic order).
    func pin(_ feed: LiveTVChannel?, for channel: LiveTVChannel) {
        pinnedFeeds[channel.id] = feed?.id
        UserDefaults.standard.set(pinnedFeeds, forKey: Self.pinnedFeedsKey)
        objectWillChange.send()
        flash(feed == nil ? "\(channel.name) picks its best version automatically" : "\(channel.name) will start with this version")
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

    /// Entries matching by number, name or group, best matches first. Lineup
    /// channels rank above hidden ones.
    func searchChannels(_ text: String, limit: Int = 80) -> [LiveTVChannel] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var scored: [(LiveTVChannel, Int)] = []
        for channel in entries {
            let name = channel.name.lowercased()
            var score = 0
            if let number = channel.number?.lowercased() {
                if number == query { score = 100 } else if number.hasPrefix(query), lineupIDs.contains(channel.id) { score = 60 }
            }
            if name == query { score = max(score, 95) }
            else if name.hasPrefix(query) { score = max(score, 80) }
            else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { score = max(score, 70) }
            else if name.contains(query) { score = max(score, 50) }
            else if let callsign = entryInfo[channel.id]?.callsign?.lowercased(), callsign.hasPrefix(query) { score = max(score, 75) }
            else if channel.group?.lowercased().contains(query) == true { score = max(score, 20) }
            if score > 0 {
                if channel.isFavorite { score += 5 }
                if lineupIDs.contains(channel.id) { score += 10 }
                if isHidden(channel) { score -= 15 }
                scored.append((channel, score))
            }
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
            .prefix(limit)
            .map(\.0)
    }

    /// Live events whose title or league matches.
    func searchEvents(_ text: String) -> [LiveEvent] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }
        return events.filter { $0.title.lowercased().contains(query) || $0.league.lowercased().contains(query) }
    }

    /// Programs on now or later whose title matches: the loaded guide first,
    /// then whatever the server's own search finds.
    func searchPrograms(_ text: String) async -> [LiveTVProgram] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let needle = query.lowercased()
        let now = Date()
        var found: [String: LiveTVProgram] = [:]
        for (id, list) in programs where id.hasPrefix("e|") {
            for program in list where program.end > now && program.title.lowercased().contains(needle) {
                found[program.id] = program
            }
        }
        for server in servers() {
            for program in await server.client.searchPrograms(query) {
                guard let entryID = entryOf[program.channelID], entryInfo[entryID] != nil else { continue }
                found[program.id] = LiveTVProgram(
                    id: program.id, channelID: entryID, title: program.title, episodeTitle: program.episodeTitle,
                    overview: program.overview, start: program.start, end: program.end, isMovie: program.isMovie,
                    isSports: program.isSports, isNews: program.isNews, isKids: program.isKids, isLive: program.isLive,
                    isPremiere: program.isPremiere, imageURL: program.imageURL
                )
            }
        }
        return found.values.sorted { $0.start != $1.start ? $0.start < $1.start : $0.title < $1.title }
    }

    // MARK: Saved lists

    private static let hiddenGroupsKey = "nuvio.tv.livetv.hiddenGroups"
    private static let recentKey = "nuvio.tv.livetv.recentChannels"
    private static let reliabilityKey = "nuvio.tv.livetv.sourceReliability"
    private static let localFavoritesKey = "nuvio.tv.livetv.localFavorites"

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

    var recentChannels: [LiveTVChannel] { recentIDs.compactMap(anyChannel(id:)) }

    // MARK: Source reliability

    /// Successes / failures per source marker ("(A)", "US:"…), so feeds from
    /// sources that work move ahead of ones that don't.
    private var reliability: [String: [Int]] = {
        (UserDefaults.standard.dictionary(forKey: "nuvio.tv.livetv.sourceReliability") as? [String: [Int]]) ?? [:]
    }()

    private func record(_ channel: LiveTVChannel, worked: Bool) {
        let tag = traits[channel.id]?.sourceTag ?? ""
        var counts = reliability[tag] ?? [0, 0]
        counts[worked ? 0 : 1] += 1
        reliability[tag] = counts
        UserDefaults.standard.set(reliability, forKey: Self.reliabilityKey)
    }

    private func orderedByReliability(_ list: [LiveTVChannel]) -> [LiveTVChannel] {
        func score(_ channel: LiveTVChannel) -> Double {
            let counts = reliability[traits[channel.id]?.sourceTag ?? ""] ?? [0, 0]
            return Double(counts[0] + 1) / Double(counts[0] + counts[1] + 2)
        }
        // Keep the catalog's order unless a source is clearly worse.
        return list.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            if abs(sa - sb) > 0.25 { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Watching

    /// Watches an entry, event or raw channel. `lineup` is the list it was
    /// picked from, which Up / Down then flips through.
    ///
    /// Emby Live TV is held to ONE open stream at a time: every open first
    /// closes whatever is open, opens run strictly one after another, and a
    /// tune that's been superseded (fast Up / Down) never opens anything. If a
    /// version won't open, or fails before showing a picture, the next version
    /// of the same channel is tried automatically.
    func watch(_ channel: LiveTVChannel, lineup: [LiveTVChannel]? = nil) {
        if let lineup, lineup.contains(channel) { flipList = lineup }
        else if !flipList.contains(channel) { flipList = visibleEntries().contains(channel) ? visibleEntries() : [channel] }
        surfStep = 0
        remember(channel)
        tune(channel, candidates: versions(of: channel), from: 0, followFeed: false)
    }

    /// Opens a numbered event feed for surfing: Up / Down move through the
    /// family, skipping feeds that aren't live.
    func surf(_ feed: LiveTVChannel, in family: EventFamily) {
        flipList = family.feeds.compactMap { channel(id: $0) }
        surfStep = 1
        tune(feed, candidates: surfCandidates(from: feed, step: 1), from: 0, followFeed: true)
    }

    private func surfCandidates(from feed: LiveTVChannel, step: Int) -> [LiveTVChannel] {
        guard let start = flipList.firstIndex(of: feed) else { return [feed] }
        return (0..<min(8, flipList.count)).map { flipList[(start + $0 * step + flipList.count * 8) % flipList.count] }
    }

    /// Watches a channel starting with a specific version (Choose Feed); the
    /// other versions stay as backups.
    func watch(_ channel: LiveTVChannel, preferring feed: LiveTVChannel) {
        var list = versions(of: channel)
        list.removeAll { $0 == feed }
        list.insert(feed, at: 0)
        if !flipList.contains(channel) { flipList = visibleEntries().contains(channel) ? visibleEntries() : [channel] }
        surfStep = 0
        remember(channel)
        tune(channel, candidates: list, from: 0, followFeed: false)
    }

    /// "FHD · source (A) · US Sports" for the feed picker.
    func feedSummary(_ feed: LiveTVChannel) -> String {
        var parts: [String] = []
        if let trait = traits[feed.id] {
            parts.append(["SD", "HD", "FHD", "4K"][max(0, min(3, trait.quality))])
            if trait.isWest { parts.append("West feed") }
        }
        if let provider = providerName(for: feed.serverID) { parts.append(provider) }
        if let group = feed.group { parts.append(group) }
        return parts.joined(separator: " · ")
    }

    /// The event a numbered feed carries, or that none is listed.
    func feedEventLine(_ feed: LiveTVChannel) -> String {
        guard let text = traits[feed.id]?.eventText, !ChannelCatalog.isPlaceholder(text) else {
            return "No event listed"
        }
        let (title, start) = ChannelCatalog.parseEvent(text, now: Date())
        guard let start else { return title }
        return "\(title) · \(ChannelsView.clockFormatter.string(from: start))"
    }

    func providerName(for serverID: String) -> String? {
        if serverID.hasPrefix("xt:") { return XtreamStore.shared.account(sourceID: serverID)?.displayName }
        return JellyfinServerStore.shared.servers.first { $0.id == serverID }?.displayName
    }

    func watchEvent(_ event: LiveEvent) {
        let display = eventChannel(event)
        flipList = [display]
        surfStep = 0
        remember(display)
        tune(display, candidates: versions(of: display), from: 0, followFeed: false)
    }

    /// An event shown as a channel (for the player, banner and tuning card).
    func eventChannel(_ event: LiveEvent) -> LiveTVChannel {
        let first = event.feeds.first.flatMap { channel(id: $0) }
        return LiveTVChannel(
            id: event.id, serverID: first?.serverID ?? "", itemID: first?.itemID ?? "", name: event.title,
            number: nil, imageURL: first?.imageURL, isFavorite: false, group: event.league, shortName: event.title
        )
    }

    // MARK: Playback & recovery
    //
    // Live TV alone decides how a stream recovers; the player only reports
    // its status. Starting: up to `startupTimeout` for a picture. A quick
    // failure on an Xtream feed is retried once after a pause (a provider's
    // connection limit usually means the previous stream hasn't let go
    // yet); otherwise the next version is tried. Playing: a stall shows a
    // small "Buffering" note after a moment, and only a stall that lasts
    // `stallTimeout`, an error or the stream ending triggers recovery:
    // reconnect the same feed first (twice for a feed that has played a
    // while), then the next version, all inside the open player. At most
    // `maxRecoveries` actions per `recoveryWindow`, then it stops and says so.

    private static let startupTimeout: UInt64 = 20
    private static let stallNoteDelay: UInt64 = 3
    private static let stallTimeout: UInt64 = 10
    private static let maxRecoveries = 6
    private static let recoveryWindow: TimeInterval = 180
    private static let xtreamRetryDelay: UInt64 = 2
    /// Engine errors / "ended" during playback: time to get over it alone.
    private static let errorGrace: UInt64 = 6
    private static let startupErrorGrace: UInt64 = 3
    private static let xtreamStartRetries = 2

    private func tune(_ display: LiveTVChannel, candidates list: [LiveTVChannel], from startIndex: Int,
                      followFeed: Bool, inPlace: Bool = false, reason: String? = nil, delay: UInt64 = 0) {
        bannerTask?.cancel()
        watchdogTask?.cancel()
        stallTask?.cancel()
        startupErrorTask?.cancel()
        stallStartedAt = nil
        banner = nil
        tuneGeneration &+= 1
        let generation = tuneGeneration
        let replacing = inPlace && playerOnScreen
        watching = display
        if !replacing {
            // A new channel: new log session and a fresh recovery budget.
            session = LiveTVPlaybackLog.shared.newSession()
            recoveries = []
            reconnectsOnFeed = 0
            startupRetryFeed = nil
            startupRetries = [:]
            playbackNote = nil
            var detail = "\(list.count) version(s)"
            if let first = list.first, first.serverID.hasPrefix("xt:"),
               let limit = XtreamStore.shared.account(sourceID: first.serverID)?.maxConnections {
                detail += "; provider allows \(limit) stream(s) at once"
            }
            if let reason { detail += "; \(reason)" }
            log("tune", list.indices.contains(startIndex) ? list[startIndex] : nil, detail: detail)
        }
        overlay = replacing ? nil : .tuning(display)
        candidates = list
        sawFirstFrame = false
        // Events from the stream being replaced don't count any more.
        playingMetaID = nil
        feedPresentedAt = nil
        feedFirstFrameAt = nil
        enqueueStreamWork { [weak self] in
            guard let self else { return }
            // Let a burst of channel flips settle on the last one (plus any
            // requested pause before a retry).
            try? await Task.sleep(nanoseconds: 350_000_000 + delay * 1_000_000_000)
            guard generation == self.tuneGeneration else { return }
            await self.closeAllStreams()
            var index = startIndex
            var lastError = "This channel couldn't be opened right now."
            while index < list.count {
                guard generation == self.tuneGeneration else { return }
                let raw = list[index]
                if raw.serverID.hasPrefix("xt:") {
                    // Xtream streams are direct links: nothing to open or close
                    // on a server, the player connects straight away.
                    guard let xtream = self.xtreamClient(for: raw.serverID),
                          let url = xtream.streamURL(streamID: raw.itemID, formats: self.xtreamFormats[raw.serverID] ?? [],
                                                     preferTS: Self.xtreamPrefersTS) else {
                        lastError = "Sign in to this Xtream account again in Settings → Integrations."
                        self.log("can't open", raw, detail: lastError)
                        index += 1
                        continue
                    }
                    guard generation == self.tuneGeneration else { return }
                    self.startFeed(display: display, feed: raw, url: url, index: index, of: list.count,
                                   followFeed: followFeed, replacing: replacing, generation: generation)
                    return
                }
                guard let client = self.client(for: raw.serverID) else {
                    lastError = "Sign in to this server again in Settings → Jellyfin."
                    self.log("can't open", raw, detail: lastError)
                    index += 1
                    continue
                }
                do {
                    // Not cancellable on purpose: once the server opens a stream
                    // we must learn its id so it can be closed.
                    let opened = Date()
                    let stream = try await client.openStream(channelItemID: raw.itemID)
                    self.openStreams.append((stream, raw.serverID))
                    guard generation == self.tuneGeneration else {
                        await self.closeAllStreams()
                        return
                    }
                    self.log("server opened stream", raw, detail: "in \(Int(Date().timeIntervalSince(opened) * 1000)) ms"
                             + (stream.isTranscode ? "; transcoding" : "; direct"))
                    self.startFeed(display: display, feed: raw, url: stream.url, index: index, of: list.count,
                                   followFeed: followFeed, replacing: replacing, generation: generation)
                    await client.reportPlaying(stream)
                    return
                } catch {
                    self.record(raw, worked: false)
                    lastError = error.localizedDescription
                    self.log("open failed", raw, detail: lastError)
                    index += 1
                }
            }
            guard generation == self.tuneGeneration else { return }
            let message = list.count > 1
                ? (followFeed ? "None of the next feeds are live right now." : "None of this channel's \(list.count) versions could be opened right now. \(lastError)")
                : lastError
            self.giveUp(display, message: message)
        }
    }

    /// Hands one version to the player: swapped into the open player when
    /// recovering, otherwise a fresh player.
    private func startFeed(display: LiveTVChannel, feed raw: LiveTVChannel, url: URL, index: Int, of count: Int,
                           followFeed: Bool, replacing: Bool, generation: Int) {
        let shown = followFeed ? raw : display
        watching = shown
        candidateIndex = index
        overlay = nil
        let now = current(on: shown.id)
        let meta = self.meta(for: shown, feed: raw, now: now)
        if replacing, playerOnScreen, let from = playerMetaID {
            NotificationCenter.default.post(name: Self.replaceStreamNotification, object: nil, userInfo: [
                "from": from, "url": url, "meta": meta, "subtitle": now?.title ?? ""
            ])
        } else {
            present?(shown, url, meta, now?.title ?? "")
            playerOnScreen = true
            showBanner(for: shown)
        }
        playerMetaID = meta.id
        playingMetaID = meta.id
        feedPresentedAt = Date()
        let format = url.pathExtension.isEmpty ? "stream" : url.pathExtension.uppercased()
        log(replacing ? "swapped in player" : "play", raw, detail: "version \(index + 1) of \(count); \(format)")
        armFirstFrameWatchdog(generation)
    }

    /// No picture after a while counts as a failed start.
    private func armFirstFrameWatchdog(_ generation: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupTimeout * 1_000_000_000)
            guard let self, !Task.isCancelled, generation == self.tuneGeneration, !self.sawFirstFrame else { return }
            self.startupFailed(reason: "no picture after \(Self.startupTimeout)s")
        }
    }

    /// Posted by the player for Live TV streams on every status change.
    nonisolated static func postPlayerStatus(metaID: String, status: PlayerStatus, hasPicture: Bool) {
        var info: [String: Any] = ["hasPicture": hasPicture]
        switch status {
        case .idle: info["status"] = "idle"
        case .buffering: info["status"] = "buffering"
        case .playing: info["status"] = "playing"
        case .paused: info["status"] = "paused"
        case .ended: info["status"] = "ended"
        case .error(let message):
            info["status"] = "error"
            info["message"] = message
        }
        NotificationCenter.default.post(name: playerStatusNotification, object: metaID, userInfo: info)
    }

    private func playerStarted(metaID: String?) {
        guard let metaID, metaID == playingMetaID, !sawFirstFrame else { return }
        sawFirstFrame = true
        watchdogTask?.cancel()
        feedFirstFrameAt = Date()
        let elapsed = feedPresentedAt.map { "\(Int(Date().timeIntervalSince($0) * 1000)) ms after the link" } ?? ""
        log("picture", detail: elapsed + "; \(Int(Date().timeIntervalSince(tuneStartedAt) * 1000)) ms since tuning")
        playbackNote = nil
        if announceBackup {
            announceBackup = false
            flash("Playing a backup feed (\(candidateIndex + 1) of \(candidates.count))")
        }
        if candidateIndex < candidates.count { record(candidates[candidateIndex], worked: true) }
    }

    private func playerStatusChanged(metaID: String?, status: String, message: String?) {
        guard let metaID, metaID == playingMetaID, isWatching else { return }
        switch status {
        case "playing":
            // Playing is a picture even if the first-frame signal was missed.
            if !sawFirstFrame {
                startupErrorTask?.cancel()
                playerStarted(metaID: metaID)
            }
            guard let began = stallStartedAt else { return }
            stallStartedAt = nil
            stallTask?.cancel()
            playbackNote = nil
            log("recovered by itself", detail: String(format: "%.1fs after %@", Date().timeIntervalSince(began), stallCause))
        case "buffering":
            // Before the first picture this is just the start; startup has its own timer.
            guard sawFirstFrame else { return }
            beginTrouble(cause: "stall", grace: Self.stallTimeout)
        case "error":
            // Never show or keep a stream link (Xtream links carry the password).
            let text = (message ?? "playback error")
                .rxReplace("[a-z][a-z0-9+.-]*://\\S+", with: "the stream", caseInsensitive: true)
            log("player error", detail: text)
            if sawFirstFrame {
                beginTrouble(cause: "error: \(text)", grace: Self.errorGrace)
            } else {
                scheduleStartupFailure(reason: "error: \(text)")
            }
        case "ended":
            log("stream ended")
            if sawFirstFrame {
                beginTrouble(cause: "the stream ended", grace: Self.errorGrace)
            } else {
                scheduleStartupFailure(reason: "ended before a picture")
            }
        default:
            break
        }
    }

    /// Something's wrong with a playing stream (a stall, an error the engine
    /// reported, the stream "ending"). Engines often get over these by
    /// themselves, so wait `grace` seconds; only if it hasn't started
    /// playing again by then does recovery step in.
    private func beginTrouble(cause: String, grace: UInt64) {
        if stallStartedAt != nil {
            // Already waiting: keep the earlier deadline, note the latest cause.
            stallCause = cause
            return
        }
        stallStartedAt = Date()
        stallCause = cause
        if cause == "stall" { log("stall") }
        let generation = tuneGeneration
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            let note = min(Self.stallNoteDelay, grace)
            try? await Task.sleep(nanoseconds: note * 1_000_000_000)
            guard let self, !Task.isCancelled, generation == self.tuneGeneration, self.stallStartedAt != nil else { return }
            self.playbackNote = "Buffering…"
            if grace > note { try? await Task.sleep(nanoseconds: (grace - note) * 1_000_000_000) }
            guard !Task.isCancelled, generation == self.tuneGeneration, self.stallStartedAt != nil else { return }
            self.recover(reason: "\(self.stallCause), not recovered after \(grace)s")
        }
    }

    /// An error before the first picture: give the engine a moment too.
    private func scheduleStartupFailure(reason: String) {
        let generation = tuneGeneration
        startupErrorTask?.cancel()
        startupErrorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupErrorGrace * 1_000_000_000)
            guard let self, !Task.isCancelled, generation == self.tuneGeneration, !self.sawFirstFrame else { return }
            self.startupFailed(reason: reason)
        }
    }

    /// A version that never showed a picture.
    private func startupFailed(reason: String) {
        guard let display = watching, candidateIndex < candidates.count else { return }
        watchdogTask?.cancel()
        startupErrorTask?.cancel()
        let feed = candidates[candidateIndex]
        log("start failed", feed, detail: reason)
        // Xtream: retry the same feed (twice) before any backup. A failed start
        // is often the provider's connection limit while the previous stream
        // lets go, or a slow first segment.
        let retries = startupRetries[feed.id] ?? 0
        if feed.serverID.hasPrefix("xt:"), retries < Self.xtreamStartRetries {
            startupRetries[feed.id] = retries + 1
            guard allowRecovery() else {
                giveUp(display, message: "This channel keeps failing to start. Try another version from Choose Feed, or try again later.")
                return
            }
            playbackNote = "Retrying…"
            log("retry", feed, detail: "same feed in \(Self.xtreamRetryDelay)s (attempt \(retries + 1) of \(Self.xtreamStartRetries))")
            tune(display, candidates: candidates, from: candidateIndex, followFeed: surfStep != 0,
                 inPlace: true, reason: reason, delay: Self.xtreamRetryDelay)
            return
        }
        record(feed, worked: false)
        moveToNext(display, reason: reason)
    }

    /// A playing stream that didn't get over a stall / error by itself:
    /// reconnect the same feed (a few times), then move to the next version.
    private func recover(reason: String) {
        guard let display = watching, candidateIndex < candidates.count else { return }
        stallTask?.cancel()
        stallStartedAt = nil
        let feed = candidates[candidateIndex]
        let played = feedFirstFrameAt.map { Date().timeIntervalSince($0) } ?? 0
        // A healthy run earns a fresh set of reconnects.
        if played > 120 { reconnectsOnFeed = 0 }
        // Xtream links are cheap to reopen and usually come straight back.
        let isXtream = feed.serverID.hasPrefix("xt:")
        let allowance = (isXtream ? 2 : 1) + (played > 60 ? 1 : 0)
        if reconnectsOnFeed < allowance {
            guard allowRecovery() else {
                giveUp(display, message: "This channel keeps dropping. Try another version from Choose Feed, or try again later.")
                return
            }
            reconnectsOnFeed += 1
            playbackNote = "Reconnecting…"
            log("reconnect", feed, detail: "\(reason); attempt \(reconnectsOnFeed) of \(allowance); played \(Int(played))s")
            tune(display, candidates: candidates, from: candidateIndex, followFeed: surfStep != 0,
                 inPlace: true, reason: reason, delay: isXtream ? 1 : 0)
        } else {
            record(feed, worked: false)
            moveToNext(display, reason: reason)
        }
    }

    private func moveToNext(_ display: LiveTVChannel, reason: String) {
        let next = candidateIndex + 1
        guard next < candidates.count else {
            giveUp(display, message: candidates.count > 1
                ? "None of this channel's \(candidates.count) versions are working right now."
                : "This channel stopped working. \(reason.prefix(1).uppercased() + reason.dropFirst()).")
            return
        }
        guard allowRecovery() else {
            giveUp(display, message: "This channel keeps failing. Try another version from Choose Feed, or try again later.")
            return
        }
        reconnectsOnFeed = 0
        announceBackup = surfStep == 0
        playbackNote = surfStep != 0 ? "Skipping to the next feed…" : "Switching to a backup feed…"
        log("switch", candidates[next], detail: "to version \(next + 1) of \(candidates.count); \(reason)")
        tune(display, candidates: candidates, from: next, followFeed: surfStep != 0, inPlace: true, reason: reason)
    }

    /// Counts one automatic recovery; false once there have been too many.
    private func allowRecovery() -> Bool {
        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < Self.recoveryWindow }
        guard recoveries.count < Self.maxRecoveries else { return false }
        recoveries.append(now)
        return true
    }

    /// Stops trying: closes the player and shows the "can't play" card.
    private func giveUp(_ display: LiveTVChannel, message: String) {
        log("gave up", detail: message)
        tuneGeneration &+= 1
        watchdogTask?.cancel()
        stallTask?.cancel()
        stallStartedAt = nil
        playbackNote = nil
        playingMetaID = nil
        if playerOnScreen {
            playerOnScreen = false
            playerMetaID = nil
            leavePlayer?()
        }
        watching = display
        overlay = .failed(display, message)
        enqueueStreamWork { [weak self] in
            await self?.closeAllStreams()
        }
    }

    private func log(_ event: String, _ feed: LiveTVChannel? = nil, detail: String = "") {
        let feed = feed ?? (candidateIndex < candidates.count ? candidates[candidateIndex] : nil)
        LiveTVPlaybackLog.shared.add(
            event, session: session, channel: watching?.name ?? "", feed: feed?.name ?? "",
            provider: feed.flatMap { providerName(for: $0.serverID) } ?? "", detail: detail
        )
    }

    /// Channel up / down from the player.
    func flip(by step: Int) {
        let list = flipList.isEmpty ? visibleEntries() : flipList
        guard let current = watching, let index = list.firstIndex(of: current), list.count > 1 else { return }
        let target = list[(index + step + list.count) % list.count]
        playerOnScreen = false
        playerMetaID = nil
        leavePlayer?()
        if surfStep != 0 {
            surfStep = step
            tune(target, candidates: surfCandidates(from: target, step: step), from: 0, followFeed: true)
        } else {
            remember(target)
            tune(target, candidates: versions(of: target), from: 0, followFeed: false)
        }
    }

    /// Leaving the player or the tuning card.
    func stopWatching() {
        if isWatching {
            let watched = feedFirstFrameAt.map { "watched \(Int(Date().timeIntervalSince($0)))s" } ?? "before a picture"
            log("stop", detail: watched)
        }
        tuneGeneration &+= 1
        bannerTask?.cancel()
        watchdogTask?.cancel()
        stallTask?.cancel()
        stallStartedAt = nil
        playbackNote = nil
        watching = nil
        overlay = nil
        banner = nil
        playingMetaID = nil
        playerMetaID = nil
        playerOnScreen = false
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
        meta(for: channel, feed: channel, now: now)
    }

    func meta(for channel: LiveTVChannel, feed: LiveTVChannel, now: LiveTVProgram?) -> NuvioMeta {
        let description = [now?.title, now?.episodeTitle, now?.overview].compactMap { $0 }.joined(separator: "\n")
        return NuvioMeta(
            // "live:xt:<account>:<stream>" for Xtream, "live:jf:<server>:<item>"
            // for Emby / Jellyfin (which Multiview leaves out: one stream).
            id: feed.serverID.hasPrefix("xt:") ? "live:\(feed.serverID):\(feed.itemID)" : "live:jf:\(feed.serverID):\(feed.itemID)",
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
        // An entry's favorite lives on its main version.
        let target = entryInfo[channel.id].flatMap { $0.members.first }.flatMap { self.channel(id: $0) } ?? channel
        guard let index = indexByID[target.id] else { return }
        let favorite = !channel.isFavorite
        channels[index].isFavorite = favorite
        if !favorite, let info = entryInfo[channel.id] {
            for member in info.members { if let i = indexByID[member] { channels[i].isFavorite = false } }
        }
        rebuildEntries()
        flash(favorite ? "Added \(channel.name) to Favorites" : "Removed \(channel.name) from Favorites")
        if target.serverID.hasPrefix("xt:") {
            var local = Set(Self.loadList(Self.localFavoritesKey))
            if favorite { local.insert(target.id) } else { local.remove(target.id) }
            Self.save(Array(local), key: Self.localFavoritesKey)
            return
        }
        Task { [weak self] in
            do {
                try await self?.client(for: target.serverID)?.setFavorite(favorite, itemID: target.itemID)
            } catch {
                self?.flash(error.localizedDescription)
            }
        }
    }

    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Screenshot tour

    /// Sample lineup with real channel names, filled only by outside listings
    /// built on this device (`-NuvioScreenTour live-demo-outside`): an
    /// end-to-end check of download, unzip, parse and matching in CI.
    func loadOutsideDemo() {
        let names = [
            "US: NBC 4 New York (WNBC)", "US LOCALS: FOX 32 Chicago", "US LOCALS: ABC 7 Los Angeles",
            "US LOCALS: CBS 2 Chicago", "US: ESPN", "US: CNN", "US: HGTV", "US: Cartoon Network",
            "US: HBO East", "US: Discovery Channel", "(US) (Prime) KAGS", "USA: WITI (FOX)"
        ]
        let demo = names.enumerated().map { index, name in
            LiveTVChannel(id: "demo|o\(index)", serverID: "demo", itemID: "o\(index)", name: name,
                          number: String(index + 2), imageURL: nil, isFavorite: false)
        }
        loadedSignature = currentSignature
        channelsLoadedAt = Date()
        let annotated = Self.annotated(demo)
        apply(channels: annotated, catalog: ChannelCatalog.build(annotated))
        programs = [:]
        serverPrograms = [:]
        guideState = Dictionary(uniqueKeysWithValues: demo.map { ($0.id, GuideState.loaded) })
        state = .loaded
        loadOutsideGuide(force: true)
    }

    /// Sample lineup for the CI screenshot tour (`-NuvioScreenTour live-demo…`):
    /// realistic IPTV-style names (variants, locals from two markets, FAST,
    /// international, numbered event feeds) so the catalog, My Lineup and
    /// Live Events can be checked without a real server.
    func loadDemo(configureLineup: Bool = true) {
        let now = Date()
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        func stamp(_ offsetHours: Double) -> String {
            let date = now.addingTimeInterval(offsetHours * 3600)
            let c = eastern.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return String(format: "(%04d %02d %02d %02d:%02d:00)", c.year ?? 2026, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        }
        var names: [(String, String)] = [
            ("US NBC 11 (KNTV) San Francisco (S)", "US Locals & Regional"),
            ("US NBC 11 (KNTV) San Francisco (A)", "US Locals & Regional"),
            ("US abc 7 (KGO) San Francisco (H)", "US Locals & Regional"),
            ("US Fox 2 (KTVU) San Francisco (S)", "US Locals & Regional"),
            ("US FOX KTVU (A)", "United States"),
            ("US CBS KPIX (A)", "United States"),
            ("US PBS 9 (KQED) San Francisco (D)", "US Locals & Regional"),
            ("US NBC 4 (WNBC) New York (H)", "US Locals & Regional"),
            ("US abc 7 (WABC) New York (S)", "US Locals & Regional"),
            ("US: ESPN", "United States"), ("US ESPN (S)", "United States"), ("US: ESPN FHD", "United States"),
            ("US: CNN", "United States"), ("US CNN (A)", "United States"),
            ("US: HGTV", "USA Premium"), ("US: Food Network", "USA Premium"),
            ("US HBO East (A)", "US Movies"), ("US: Cartoon Network", "USA Premium"),
            ("US NBC Sports Bay Area (S)", "US Sports"), ("US: MTV", "USA Premium"),
            ("(PLUTO USA) Pluto TV Movies", "United States"), ("(US) (RK) The Bernie Mac Show", "US Roku & Free TV"),
            ("(PLUTO UK) Antiques Road Trip", "United States"), ("MEX: Canal 5", "Mexico")
        ]
        let events = [
            ("Basketball: Lakers vs. Celtics", -0.5), ("Hockey: Sharks at Kings", 1.0), ("Football: Good Morning Football", -1.0),
            ("ESPN+: Stanford vs. Cal", 2.5), ("Soccer: LAFC vs. Galaxy", 4.0), ("UFC Fight Night: Prelims", 6.0)
        ]
        for index in 1...18 {
            if index <= events.count {
                let event = events[index - 1]
                names.append((String(format: "US (ESPN+ %03d) | %@ %@", index, event.0, stamp(event.1)), "ESPN Plus"))
            } else {
                names.append((String(format: "US (ESPN+ %03d) |  (2098 12 31 08:00:00)", index), "ESPN Plus"))
            }
        }
        for index in 0..<16 { names.append((String(format: "ESPN PLUS %02d:", index), "ESPN Plus")) }
        names.append(("NBA 01: Warriors vs Lakers \(stamp(0.25))", "NBA"))
        for index in 2...6 { names.append(("NBA \(String(format: "%02d", index)): No Games Scheduled", "NBA")) }

        let demo = names.enumerated().map { index, item in
            LiveTVChannel(id: "demo|\(index)", serverID: "demo", itemID: "\(index)", name: item.0,
                          number: String(index + 2), imageURL: nil, isFavorite: false, tags: [item.1])
        }
        let shows = ["Evening News", "Late Edition", "SportsCenter", "House Hunters", "Diners, Drive-Ins and Dives",
                     "Casablanca", "Teen Titans Go!", "Warriors Pregame", "Ridiculousness", "The Office"]
        let start = Self.windowStart().addingTimeInterval(-20 * 60)
        var demoPrograms: [String: [LiveTVProgram]] = [:]
        for (index, channel) in demo.enumerated() where index < 22 {
            var cursor = start
            demoPrograms[channel.id] = (0..<5).map { offset in
                let length = TimeInterval((offset % 2 == 0 ? 60 : 30) * 60)
                let end = cursor.addingTimeInterval(length)
                defer { cursor = end }
                return LiveTVProgram(
                    id: "demo|\(index)|\(offset)", channelID: channel.id, title: shows[(index + offset) % shows.count],
                    episodeTitle: nil, overview: "Sample listing used for the automated screenshot tour.",
                    start: cursor, end: end, isMovie: false, isSports: index == 9 || index == 18, isNews: index == 12,
                    isKids: index == 17, isLive: false, isPremiere: offset == 0, imageURL: nil, fromOutsideGuide: index % 3 == 0
                )
            }
        }
        loadedSignature = currentSignature
        channelsLoadedAt = Date()
        guideLoadedAt = Date()
        guideWindowStart = Self.windowStart()
        let annotated = Self.annotated(demo)
        let catalog = ChannelCatalog.build(annotated)
        serverPrograms = demoPrograms
        programs = demoPrograms
        guideState = Dictionary(uniqueKeysWithValues: demo.map { ($0.id, GuideState.loaded) })
        demo.forEach { guideWindowByChannel[$0.id] = Self.windowStart() }
        if configureLineup {
            var demoPrefs = LineupPrefs()
            demoPrefs.markets = [MarketChoice(name: "San Francisco–Oakland–San Jose", template: nil,
                                              callsigns: ["KNTV", "KGO", "KTVU", "KPIX", "KQED"])]
            demoPrefs.configured = true
            prefs = demoPrefs
        } else {
            prefs = LineupPrefs()
        }
        apply(channels: annotated, catalog: catalog)
        if configureLineup {
            prefs.suggested = Set(entryInfo.values.filter {
                LineupEngine.suggests($0, prefs: prefs, hasGuide: entryHasGuide($0.id), name: $0.name)
            }.map(\.id))
            rebuildEntries()
        }
        state = .loaded
    }

    /// Xtream-style channels whose listings come only from a provider guide
    /// file built on this device (`-NuvioScreenTour live-demo-provider`):
    /// an end-to-end check of the xmltv.php path (exact guide ids, two
    /// streams sharing one id, case differences, a channel from another
    /// country left out, one without a guide id).
    func loadProviderDemo() {
        let source = "xt:demo"
        let items: [(name: String, group: String, epg: String?)] = [
            ("US: ABC 7 (KGO) SAN FRANCISCO ᴴᴰ", "US| ABC ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "KGO.us"),
            ("US: ABC 7 (KGO) SAN FRANCISCO (S)", "US| ABC ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "KGO.us"),
            ("US: FOX 2 (KTVU) SAN FRANCISCO ᴿᴬᵂ", "US| FOX ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "KTVU.us"),
            ("US: ESPN ᴴᴰ", "US| SPORT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "ESPN.us"),
            ("US: CNN ᴴᴰ", "US| NEWS ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "cnn.us"),
            ("US: HGTV ᴴᴰ", "US| ENTERTAINMENT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "HGTV.us"),
            ("US: FOOD NETWORK ᴴᴰ", "US| ENTERTAINMENT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "FoodNetwork.us"),
            ("US: TCM ᴴᴰ", "US| MOVIES ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "TCM.us"),
            ("US: CARTOON NETWORK ᴴᴰ", "US| KIDS ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", nil),
            ("UK: BBC ONE ᴴᴰ", "UK| GENERAL ᴴᴰ/ᴿᴬᵂ", "BBCOne.uk")
        ]
        let demo: [LiveTVChannel] = items.enumerated().map { index, item in
            var channel = LiveTVChannel(id: "\(source)|\(100 + index)", serverID: source, itemID: String(100 + index),
                                        name: item.name, number: String(index + 1), imageURL: nil, isFavorite: false,
                                        tags: [item.group])
            channel.epgID = item.epg
            return channel
        }
        loadedSignature = currentSignature
        channelsLoadedAt = Date()
        let annotated = Self.annotated(demo)
        apply(channels: annotated, catalog: ChannelCatalog.build(annotated))
        programs = [:]
        serverPrograms = [:]
        guideState = Dictionary(uniqueKeysWithValues: demo.map { ($0.id, GuideState.loaded) })
        state = .loaded
        let file = ProviderGuide.writeDemoFile(
            channels: [("KGO.us", "ABC 7 San Francisco"), ("KTVU.us", "FOX 2 Bay Area"), ("ESPN.us", "ESPN"),
                       ("CNN.us", "CNN"), ("HGTV.us", "HGTV"), ("FoodNetwork.us", "Food Network"),
                       ("BBCOne.uk", "BBC One"), ("NotYours.us", "Some Other Channel")],
            titles: ["Provider: ABC7 News", "Provider: SportsCenter", "Provider: CNN Newsroom", "Provider: House Hunters",
                     "Provider: Chopped", "Provider: World News Tonight", "Provider: Jeopardy!"]
        )
        guard let file else {
            providerStates[source] = ProviderGuide.State(name: "Demo provider", status: .failed("Couldn't write the demo guide."))
            return
        }
        let scoped = annotated.filter { traits[$0.id]?.familyKey == nil && ProviderGuide.inScope($0) }
        providerTask = Task { [weak self] in
            await self?.runProviderBuild(sourceID: source, name: "Demo provider", url: file, channels: scoped, key: nil)
            self?.providerTask = nil
        }
    }
}
