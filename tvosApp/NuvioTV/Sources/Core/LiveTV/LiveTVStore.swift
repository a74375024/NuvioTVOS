import Foundation
import Combine
import UIKit
import os

/// Live TV from the Emby / Jellyfin servers signed in under Settings →
/// Jellyfin. Raw server channels are turned into one guide entry per real
/// channel (other versions become automatic backup feeds), numbered event
/// feeds into Live Events, and a suggested, editable My Lineup.
/// What the Live TV overlay has open over the player; the player watches
/// this (not the whole store) to hand its remote input to the overlay.
@MainActor
final class LiveOverlayState: ObservableObject {
    static let shared = LiveOverlayState()
    @Published var miniGuideOpen = false
    /// A "starting now" reminder card is up and wants the remote.
    @Published var reminderShowing = false

    var blocksPlayerInput: Bool { miniGuideOpen || reminderShowing }
}

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
        var previous: LiveTVChannel? = nil
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
    @Published private(set) var events: [LiveEvent] = [] {
        didSet {
            plainEventsMemo = nil
            eventsRevision &+= 1
            scheduleSportsRebuild(delay: 1, reason: "events")
        }
    }
    private var plainEventsMemo: [SportsEvent]?

    /// Until the first match finishes: the provider's events as plain tiles,
    /// so Live Events is never just the event channels.
    var plainSportsEvents: [SportsEvent] {
        if let plainEventsMemo { return plainEventsMemo }
        let value = events.map { event in
            SportsEvent(
                id: event.id, title: event.title, league: event.league, leagueShort: SportsMatcher.shortLeague(event.league),
                start: event.start, game: nil,
                sources: event.feeds.map { EventSource(channelID: $0, kind: .provider, spanish: event.market == "US-ES", detail: "") },
                family: event.family
            )
        }
        plainEventsMemo = value
        return value
    }
    /// Live Events: TheSportsDB games joined with guide channels and
    /// provider event feeds (see SportsMatcher).
    @Published private(set) var sportsEvents: [SportsEvent] = []
    @Published private(set) var families: [EventFamily] = []
    @Published private(set) var prefs = LineupPrefs()
    @Published private(set) var programs: [String: [LiveTVProgram]] = [:] {
        didSet {
            programsRevision &+= 1
            // Guide data no longer triggers a games rebuild; the sports
            // listings are pulled from it on their own schedule.
            guideChangedForSports()
        }
    }
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
    /// The channel before the one on screen: Right in the player goes back
    /// to it (and Right again bounces forward), like a cable LAST button.
    @Published private(set) var previousChannel: LiveTVChannel?
    private var lastDisplay: LiveTVChannel?
    /// The channel on screen when the viewer left the player, for the guide
    /// to focus when it comes back.
    private(set) var lastWatchedID: String?
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
    private static var channelLifetime: TimeInterval { ScreenTour.isMockLiveTV ? 1 : 30 * 60 }
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
    private var outsideRunning = false
    private var outsideRunningShards: Set<String> = []
    /// Each listings source's state after the last update (Guide Listings screen).
    @Published private(set) var outsideSources: [OutsideGuide.SourceState] = []
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
    /// The Live Events game on screen (set when watching from Live Events):
    /// the mini guide then lists games, and Up / Down flip between them.
    @Published private(set) var watchingEventID: String?
    /// That game, for Try Again.
    private var watchingEvent: SportsEvent?
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
    /// The feed the viewer picked from the player's Sources panel: recovery
    /// sticks with it (reconnects) and only leaves it once it's dead.
    private var manualFeedID: String?

    // Guide preview (see "Guide preview" below).
    /// Entry shown in the guide's corner preview (being opened or playing).
    @Published private(set) var previewChannelID: String?
    let previewPlayer = LiveTVPreviewPlayer()
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    /// The version the preview plays, once it's chosen.
    private var previewFeed: LiveTVChannel?
    /// The Emby stream opened for the preview (also in `openStreams`), handed
    /// to the player when that channel is picked.
    private var previewStream: LiveTVStream?
    private var lastPreviewOpen = Date.distantPast

    // Saved channel list, load timing and background rebuilds.
    /// The channels on screen came from the small first-screen file; the
    /// full list is still being read.
    private var catalogPartial = false
    /// Entries in the order the catalog built them.
    private var catalogEntries: [LiveTVEntryInfo] = []
    private var loadStartedAt = Date()
    private var rebuildGeneration = 0
    private var listingsGeneration = 0
    /// Channels a guide fetch updated while listings were being merged in the
    /// background (they're redone on top of that result).
    private var touchedListings: Set<String> = []
    /// Per entry: which version's listing it shows, so unchanged entries
    /// aren't rebuilt each time any guide data lands.
    private var entryGuideKeys: [String: String] = [:]
    private var providerSavedCache: [String: ProviderGuide.Saved] = [:]
    private var providerSavedTried: Set<String> = []
    private var outsideSavedCache: [String: OutsideGuide.Saved] = [:]
    private var outsideSavedTried: Set<String> = []
    /// Bumped when the entry lists / listings change (the guide memoizes its rows on these).
    @Published private(set) var entriesRevision = 0
    @Published private(set) var programsRevision = 0

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
            catalogPartial = false
            catalogEntries = []
            entryGuideKeys = [:]
            touchedListings = []
            providerSavedCache = [:]
            providerSavedTried = []
            outsideSavedCache = [:]
            outsideSavedTried = []
        }
        let channelsFresh = channelsLoadedAt.map { Date().timeIntervalSince($0) < Self.channelLifetime } ?? false
        if !force, channelsFresh, signature == loadedSignature, !channels.isEmpty, !catalogPartial {
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
        loadStartedAt = Date()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            // 1. The list saved on this Apple TV: on screen right away.
            if self.channels.isEmpty, !force {
                await self.loadSavedCatalog(signature: signature)
            }
            guard self.loadedSignature == signature, !Task.isCancelled else { return }
            // 2. The servers' current list, in the background when a saved
            // one is showing, once that one is older than `channelLifetime`
            // (event names change through the day).
            let fresh = self.channelsLoadedAt.map { Date().timeIntervalSince($0) < Self.channelLifetime } ?? false
            if force || !fresh || self.channels.isEmpty || self.catalogPartial {
                await self.downloadChannels(configured: configured, xtream: xtream, signature: signature)
            }
        }
    }

    /// Called at app start: reads the saved list and refreshes it in the
    /// background, so Live TV is ready by the time it's opened.
    func prewarm() {
        guard hasServers, channels.isEmpty, loadTask == nil, !ScreenTour.isActive else { return }
        logLoad("started at app launch", detail: "")
        loadIfNeeded()
    }

    // MARK: Saved channel list

    /// Puts the list saved on this Apple TV on screen: the small first-screen
    /// file, then the full one (both read off the main thread).
    private func loadSavedCatalog(signature: String) async {
        let started = Date()
        guard let first = await Task.detached(priority: .userInitiated, operation: {
            LiveTVCatalogCache.load(signature: signature, part: .first)
        }).value else {
            logLoad("no saved channel list", detail: "loading from the servers")
            return
        }
        guard loadedSignature == signature, channels.isEmpty else { return }
        xtreamFormats.merge(first.saved.xtreamFormats) { current, _ in current }
        await apply(channels: withLocalFavorites(first.saved.channels), catalog: first.saved.catalog, partial: true)
        channelsLoadedAt = first.saved.savedAt
        state = .loaded
        logLoad("first screen from saved list", detail: "\(first.saved.channels.count) channels, \(LiveTVWork.size(first.bytes)); "
                + "\(LiveTVWork.ms(since: started)) (\(LiveTVWork.ms(since: loadStartedAt)) after opening); saved \(LiveTVWork.age(first.saved.savedAt)) ago")
        await startGuides(requestRows: true)
        let fullStarted = Date()
        guard let full = await Task.detached(priority: .utility, operation: {
            LiveTVCatalogCache.load(signature: signature, part: .full)
        }).value, loadedSignature == signature, catalogPartial else { return }
        await apply(channels: withLocalFavorites(full.saved.channels), catalog: full.saved.catalog, partial: false)
        logLoad("full saved list", detail: "\(full.saved.channels.count) channels, \(LiveTVWork.size(full.bytes)); \(LiveTVWork.ms(since: fullStarted))")
        await startGuides(requestRows: false)
    }

    /// Favorites kept on this Apple TV (Xtream has no favorites API).
    private func withLocalFavorites(_ list: [LiveTVChannel]) -> [LiveTVChannel] {
        let local = Set(Self.loadList(Self.localFavoritesKey))
        var updated = list
        for index in updated.indices where updated[index].serverID.hasPrefix("xt:") {
            updated[index].isFavorite = local.contains(updated[index].id)
        }
        return updated
    }

    /// Saves the finished list (off the main thread) for the next launch.
    private func saveCatalog(signature: String) {
        guard !catalogPartial, !channels.isEmpty, !ScreenTour.isActive || ScreenTour.isMockLiveTV else { return }
        let saved = LiveTVCatalogCache.Saved(
            version: LiveTVCatalogCache.version, signature: signature, savedAt: channelsLoadedAt ?? Date(),
            channels: channels,
            catalog: ChannelCatalog.Result(traits: traits, entries: catalogEntries, entryOf: entryOf,
                                           families: allFamilies, events: allEvents),
            xtreamFormats: xtreamFormats
        )
        var firstEntries = Set(browseEntries.map(\.id))
        firstEntries.formUnion(lineupIDs)
        firstEntries.formUnion(entries.filter(\.isFavorite).map(\.id))
        firstEntries.formUnion(recentIDs.filter { entryInfo[$0] != nil })
        let firstFamilies = Set(families.map(\.id))
        let started = Date()
        Task.detached(priority: .background) {
            let sizes = LiveTVCatalogCache.save(saved, firstEntryIDs: firstEntries, firstFamilyIDs: firstFamilies)
            let detail = "first screen \(LiveTVWork.size(sizes.first)), full \(LiveTVWork.size(sizes.full)); \(LiveTVWork.ms(since: started))"
            await MainActor.run { LiveTVStore.shared.logLoad("saved channel list", detail: detail) }
        }
    }

    /// Starts the guide sources for the current list: saved listings (read
    /// off the main thread) first, then the rows on screen, then any
    /// background rebuild of the listings.
    private func startGuides(requestRows: Bool) async {
        await preloadSavedListings()
        loadProviderGuide()
        loadOutsideGuide()
        if requestRows {
            let first = visibleEntries().prefix(60).map(\.id)
            let favorites = entries.filter(\.isFavorite).prefix(40).map(\.id)
            requestGuide(Array(favorites) + recentIDs.prefix(20) + first)
        }
    }

    /// Reads saved provider / outside listings into memory off the main thread.
    private func preloadSavedListings() async {
        let profile = ProfileSettings.activeProfileScope
        let keys = xtreamClients().map { ProviderGuide.cacheKey(profile: profile, sourceID: $0.account.sourceID) }
            .filter { providerSavedCache[$0] == nil && !providerSavedTried.contains($0) }
        let signature = loadedSignature ?? "default"
        let needOutside = OutsideGuide.isEnabled && outsideSavedCache[signature] == nil && !outsideSavedTried.contains(signature)
        guard !keys.isEmpty || needOutside else { return }
        let started = Date()
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([String: ProviderGuide.Saved], OutsideGuide.Saved?) in
            var found: [String: ProviderGuide.Saved] = [:]
            for key in keys { if let saved = ProviderGuide.loadSaved(key) { found[key] = saved } }
            return (found, needOutside ? OutsideGuide.loadSaved(signature: signature) : nil)
        }.value
        for key in keys {
            providerSavedTried.insert(key)
            if let saved = loaded.0[key] { providerSavedCache[key] = saved }
        }
        if needOutside {
            outsideSavedTried.insert(signature)
            if let saved = loaded.1 { outsideSavedCache[signature] = saved }
        }
        logLoad("saved listings read", detail: "\(loaded.0.count) provider guide(s)\(loaded.1 == nil ? "" : " + outside listings"); \(LiveTVWork.ms(since: started))")
    }

    private func savedProviderGuide(_ key: String) -> ProviderGuide.Saved? {
        if let saved = providerSavedCache[key] { return saved }
        guard !providerSavedTried.contains(key) else { return nil }
        providerSavedTried.insert(key)
        let saved = ProviderGuide.loadSaved(key)
        providerSavedCache[key] = saved
        return saved
    }

    private func savedOutsideGuide(_ signature: String) -> OutsideGuide.Saved? {
        if let saved = outsideSavedCache[signature] { return saved }
        guard !outsideSavedTried.contains(signature) else { return nil }
        outsideSavedTried.insert(signature)
        let saved = OutsideGuide.loadSaved(signature: signature)
        outsideSavedCache[signature] = saved
        return saved
    }

    /// A load-timing line in the exportable log.
    func logLoad(_ event: String, detail: String) {
        LiveTVPlaybackLog.shared.add("load: " + event, session: 0, detail: detail)
        if ScreenTour.isMockLiveTV {
            loadLines.append(event + (detail.isEmpty ? "" : " — " + detail))
            if loadLines.count > 9 { loadLines.removeFirst(loadLines.count - 9) }
        }
    }

    /// The latest load lines, shown on screen in the CI mock-provider tour.
    @Published private(set) var loadLines: [String] = []

    /// CI only (`-NuvioScreenTour live-mock`): an Xtream account on the
    /// local mock provider (scripts/mock-xtream.py).
    func installMockAccount() {
        guard ScreenTour.isMockLiveTV else { return }
        let account = XtreamAccount(id: "tourmock", displayName: "Mock IPTV", serverURLString: "http://127.0.0.1:8765",
                                    username: "tour", expires: nil, maxConnections: 1, lastChannelCount: nil)
        XtreamCredentialStore.save("tour", forAccountID: account.id)
        if XtreamStore.shared.account(sourceID: account.sourceID) == nil { XtreamStore.shared.upsert(account) }
    }

    // MARK: Downloading the channel list

    private struct Fetched {
        var index: Int
        var name: String
        var channels: [LiveTVChannel] = []
        var problem: String?
        var config: JellyfinServerConfig?
        var account: XtreamAccount?
        var formats: [String]?
        var milliseconds = 0
    }

    /// Downloads every account's channel list at once, then either refreshes
    /// Live Events alone (when only event slots were renamed) or rebuilds the
    /// catalog, off the main thread, and saves the result.
    private func downloadChannels(configured: [Server], xtream: [XtreamClient], signature: String) async {
        let started = Date()
        let showing = !channels.isEmpty && !catalogPartial
        var parts = [[LiveTVChannel]](repeating: [], count: configured.count + xtream.count)
        var problems: [String] = []
        var timings: [String] = []
        await withTaskGroup(of: Fetched.self) { group in
            for (index, server) in configured.enumerated() {
                group.addTask {
                    var fetched = Fetched(index: index, name: server.config.displayName)
                    let began = Date()
                    var client = server.client
                    do {
                        if client.userID.isEmpty, let base = server.config.baseURL {
                            let resolved = try await JellyfinClient.currentUserId(
                                baseURL: base, apiKey: client.token, username: server.config.username
                            )
                            var updated = server.config
                            updated.userId = resolved
                            fetched.config = updated
                            client = LiveTVClient(serverID: client.serverID, baseURL: client.baseURL, token: client.token, userID: resolved)
                        }
                        fetched.channels = try await client.channels()
                    } catch {
                        fetched.problem = "\(server.config.displayName): \(error.localizedDescription)"
                    }
                    fetched.milliseconds = Int(Date().timeIntervalSince(began) * 1000)
                    return fetched
                }
            }
            for (offset, client) in xtream.enumerated() {
                group.addTask {
                    var fetched = Fetched(index: configured.count + offset, name: client.account.displayName)
                    let began = Date()
                    async let info = try? client.accountInfo()
                    do {
                        let list = try await client.channels()
                        fetched.channels = list
                        var updated = client.account
                        updated.lastChannelCount = list.count
                        fetched.account = updated
                    } catch {
                        fetched.problem = "\(client.account.displayName): \(error.localizedDescription)"
                    }
                    fetched.formats = (await info)?.formats
                    fetched.milliseconds = Int(Date().timeIntervalSince(began) * 1000)
                    return fetched
                }
            }
            for await fetched in group {
                parts[fetched.index] = fetched.channels
                timings.append("\(fetched.name) \(fetched.channels.count) in \(fetched.milliseconds) ms")
                if let problem = fetched.problem { problems.append(problem) }
                if let config = fetched.config { JellyfinServerStore.shared.upsert(config) }
                if let account = fetched.account {
                    XtreamStore.shared.upsert(account)
                    if let formats = fetched.formats { xtreamFormats[account.sourceID] = formats }
                }
            }
        }
        let downloaded = LiveTVWork.ms(since: started)
        let all = withLocalFavorites(parts.flatMap { $0 })
        guard loadedSignature == signature, !Task.isCancelled else { return }
        logLoad("downloaded channel lists", detail: timings.joined(separator: "; ") + " (all at once: \(downloaded))")
        if !problems.isEmpty { logLoad("some sources failed", detail: problems.joined(separator: "; ")) }
        if all.isEmpty {
            channelsLoadedAt = Date()
            if channels.isEmpty {
                state = problems.isEmpty
                    ? .empty("Your server didn't list any live channels for this account.")
                    : .failed(problems.joined(separator: "\n"))
            }
            return
        }
        let wasEmpty = channels.isEmpty
        let oldChannels = showing ? channels : []
        let oldResult: ChannelCatalog.Result? = showing
            ? ChannelCatalog.Result(traits: traits, entries: catalogEntries, entryOf: entryOf, families: allFamilies, events: allEvents)
            : nil
        let processStarted = Date()
        let work = await Task.detached(priority: showing ? .utility : .userInitiated) {
            () -> (channels: [LiveTVChannel], catalog: ChannelCatalog.Result, renamed: Int?) in
            let annotated = LiveTVWork.annotated(all)
            // Same channels, only event slots renamed: refresh Live Events
            // alone instead of classifying everything again.
            if let oldResult, let renamed = LiveTVWork.renamedEventSlots(old: oldChannels, new: annotated, traits: oldResult.traits) {
                var result = oldResult
                if !renamed.isEmpty { ChannelCatalog.refreshEvents(&result, channels: annotated, renamed: renamed) }
                return (annotated, result, renamed.count)
            }
            return (annotated, ChannelCatalog.build(annotated, stations: StationDirectory.cached()), nil)
        }.value
        guard loadedSignature == signature, !Task.isCancelled else { return }
        channelsLoadedAt = Date()
        await apply(channels: work.channels, catalog: work.catalog, partial: false)
        state = .loaded
        if let renamed = work.renamed {
            logLoad("refresh: only event names changed", detail: "\(renamed) renamed; events updated in \(LiveTVWork.ms(since: processStarted)), no full rebuild")
        } else {
            logLoad(wasEmpty ? "built channel list" : "rebuilt channel list",
                    detail: "\(work.channels.count) channels, \(entryInfo.count) entries; processed in \(LiveTVWork.ms(since: processStarted))")
        }
        if wasEmpty { logLoad("first screen", detail: "\(LiveTVWork.ms(since: loadStartedAt)) after opening (nothing saved)") }
        if showing {
            // New channels may need the provider's guide; cheap if not.
            loadProviderGuide()
            rebuildOutsidePrograms()
        } else {
            await startGuides(requestRows: wasEmpty)
        }
        saveCatalog(signature: signature)
    }

    /// Installs a freshly built catalog (raw channels, entries, events),
    /// then works out My Lineup in the background.
    private func apply(channels list: [LiveTVChannel], catalog: ChannelCatalog.Result, partial: Bool = false) async {
        installCatalog(list, catalog, partial: partial)
        await rebuildEntries()
    }

    /// The same, all on the main thread (small demo lineups).
    private func applyNow(channels list: [LiveTVChannel], catalog: ChannelCatalog.Result) {
        installCatalog(list, catalog, partial: false)
        rebuildEntriesNow()
    }

    private func installCatalog(_ list: [LiveTVChannel], _ catalog: ChannelCatalog.Result, partial: Bool) {
        channels = list
        indexByID = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        traits = catalog.traits
        entryOf = catalog.entryOf
        catalogEntries = catalog.entries
        entryInfo = Dictionary(catalog.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        allEvents = catalog.events
        allFamilies = catalog.families
        catalogPartial = partial
        applyEventFilter()
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
            await self.rebuildEntries()
        }
    }

    /// Recomputes lineup membership, numbering and the entry lists on a
    /// background thread (tens of thousands of entries on big provider
    /// lists), then installs them. The newest call wins.
    private func rebuildEntries() async {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let input = lineupInput()
        let output = await Task.detached(priority: .userInitiated) { LiveTVWork.lineup(input) }.value
        guard generation == rebuildGeneration else { return }
        install(output)
    }

    private func scheduleRebuild() {
        Task { [weak self] in await self?.rebuildEntries() }
    }

    /// The same on the main thread (small demo lineups).
    private func rebuildEntriesNow() {
        rebuildGeneration &+= 1
        install(LiveTVWork.lineup(lineupInput()))
    }

    private func lineupInput() -> LiveTVWork.LineupInput {
        var guideIDs = Set(outsideMatches.keys)
        guideIDs.formUnion(providerMatches.keys)
        for (id, list) in serverPrograms where !list.isEmpty { guideIDs.insert(id) }
        return LiveTVWork.LineupInput(
            infos: catalogEntries, channels: channels, indexByID: indexByID, prefs: prefs,
            guideIDs: guideIDs, otherGroup: Self.otherGroup
        )
    }

    private func install(_ output: LiveTVWork.LineupOutput) {
        lineupIDs = output.lineupIDs
        entries = output.entries
        entryIndex = output.entryIndex
        lineupEntries = output.lineupEntries
        browseEntries = output.browseEntries
        groups = output.groups.map { ChannelGroup(name: $0.name, count: $0.count) }
        entriesRevision &+= 1
        logoSpecs = [:]
        // Entry guides from whatever member data is already here.
        var merged = programs
        var states = guideState
        applyEntryGuides(&merged, &states, entryIDs: Array(entryInfo.keys))
        programs = merged
        guideState = states
    }

    // MARK: Channel logos

    /// Logo specs by channel id (cleared when entries are rebuilt or the
    /// iptv-org index arrives).
    private var logoSpecs: [String: ChannelLogoSpec] = [:]
    @Published private(set) var logosRevision = 0

    /// Which logos a guide row tries and how its cell reads (see ChannelLogos).
    func logoSpec(for channel: LiveTVChannel?) -> ChannelLogoSpec {
        guard let channel else { return .empty }
        if let hit = logoSpecs[channel.id] { return hit }
        IptvOrgLogos.shared.start { [weak self] in
            guard let self else { return }
            self.logoSpecs = [:]
            self.logosRevision &+= 1
        }
        let spec: ChannelLogoSpec
        if let info = entryInfo[channel.id] {
            let member = info.members.first.flatMap { self.channel(id: $0) }
            spec = ChannelLogos.spec(
                name: info.name, core: info.core, isWest: info.id.hasSuffix("~west"),
                isLocal: info.category == .local && info.callsign != nil, callsign: info.callsign,
                virtualNumber: info.virtualNumber, provider: channel.imageURL,
                epgID: member?.epgID, category: info.category)
        } else if events.contains(where: { $0.id == channel.id }) {
            spec = ChannelLogoSpec(urls: channel.imageURL.map { [$0] } ?? [], style: .named)
        } else {
            let trait = traits[channel.id]
            let isLocal = trait?.scope == "local"
            let callsign = isLocal ? ChannelCatalog.callsignCandidates(channel.displayName).first?.sign : nil
            let west = ChannelCatalog.coreKey(channel.displayName).west
            spec = ChannelLogos.spec(
                name: channel.displayName, core: trait?.core, isWest: west,
                isLocal: callsign != nil, callsign: callsign,
                virtualNumber: ChannelCatalog.virtualNumber(in: channel.displayName), provider: channel.imageURL,
                epgID: channel.epgID, category: trait?.category)
        }
        logoSpecs[channel.id] = spec
        return spec
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
        LiveTVWork.windowStart(for: date)
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
                    self.touchedListings.insert(id)
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
                touchedListings.insert(id)
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
                self.touchedListings.insert(id)
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
            var bestMember = ""
            var bestCoverage: TimeInterval = -1
            var anyLoading = false, anyLoaded = false, anyFailed = false
            for member in info.members {
                if let list = merged[member], !list.isEmpty {
                    let value = coverage(list)
                    if value > bestCoverage { best = list; bestCoverage = value; bestMember = member }
                }
                switch states[member] {
                case .loading: anyLoading = true
                case .loaded: anyLoaded = true
                case .failed: anyFailed = true
                case nil: break
                }
            }
            // Unchanged since last time (same version, same programs and tags): keep it.
            let key: String
            if let first = best.first, let last = best.last {
                let tagged = best.reduce(0) { $0 + ($1.isMovie || $1.isSports || $1.isNews || $1.isKids ? 1 : 0) }
                key = "\(bestMember)|\(best.count)|\(first.id)|\(last.id)|\(tagged)"
            } else {
                key = ""
            }
            if key.isEmpty || entryGuideKeys[id] != key || merged[id] == nil {
                entryGuideKeys[id] = key
                merged[id] = best.isEmpty ? nil : best.map { program in
                LiveTVProgram(
                    id: "\(id)|\(program.id)", channelID: id, title: program.title, episodeTitle: program.episodeTitle,
                    overview: program.overview, start: program.start, end: program.end, isMovie: program.isMovie,
                    isSports: program.isSports, isNews: program.isNews, isKids: program.isKids, isLive: program.isLive,
                    isPremiere: program.isPremiere, imageURL: program.imageURL, fromOutsideGuide: program.fromOutsideGuide
                )
                }
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
            let saved = savedProviderGuide(key)
            if let saved {
                Self.replace(&matches, &notes, prefix: "\(sourceID)|", with: saved.programs, saved.notes)
                states[sourceID] = ProviderGuide.State(name: name, status: .ready(
                    matched: saved.programs.count, total: scoped.count, guideChannels: saved.guideChannels, updated: saved.built))
            }
            // Never rebuild from the partial first-screen list.
            if !catalogPartial, force || ProviderGuide.needsRebuild(saved, channelCount: scoped.count) {
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
            if let key {
                Task.detached(priority: .background) { ProviderGuide.save(saved, key: key) }
                providerSavedCache[key] = saved
                providerSavedTried.insert(key)
            }
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
        let shardIDs = OutsideGuide.enabledShards
        // An update already running keeps going (it used to restart each time
        // the channel list refreshed, so a long one never finished), unless
        // the listings chosen changed.
        if outsideRunning, outsideRunningShards == shardIDs, OutsideGuide.isEnabled {
            if force { CrashRecorder.note("guide update requested; one is already running") }
            return
        }
        outsideTask?.cancel()
        outsideRunning = false
        guard OutsideGuide.isEnabled, !channels.isEmpty else {
            outsideMatches = [:]
            outsideStatus = .off
            rebuildOutsidePrograms()
            return
        }
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
        let saved = savedOutsideGuide(signature)
        if let saved, Set(saved.shards) == shardIDs {
            outsideMatches = saved.programs
            outsideNotes = saved.notes ?? [:]
            outsideBuiltAt = saved.built
            outsideSources = OutsideGuide.sources.compactMap { saved.sources?[$0.id] }
            outsideStatus = .ready(matched: saved.programs.count, total: snapshot.count, updated: saved.built)
            rebuildOutsidePrograms()
            scheduleLineupRefresh()
        }
        // Never rebuild from the partial first-screen list.
        guard !catalogPartial, force || OutsideGuide.needsRebuild(saved, shards: shardIDs, channelCount: snapshot.count) else { return }
        outsideStatus = .updating("Getting ready…")
        outsideRunning = true
        outsideRunningShards = shardIDs
        let reason = force ? "refresh" : (saved == nil ? "first" : "due")
        outsideTask = Task { [weak self] in
            // Give the app a moment to settle before starting background work.
            try? await Task.sleep(nanoseconds: force ? 0 : 8_000_000_000)
            // One heavy guide job at a time: the provider's own guide first.
            if let pending = self?.providerTask { await pending.value }
            guard !Task.isCancelled else { return }
            CrashRecorder.note("guide update started (\(reason)), \(snapshot.count) channels, sources: \(shardIDs.sorted().joined(separator: ", "))")
            let built = await OutsideGuide.build(for: snapshot, shards: shardIDs, previous: saved) { line in
                Task { @MainActor in
                    guard let self, case .updating = self.outsideStatus else { return }
                    self.outsideStatus = .updating(line)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.outsideRunning = false
            for line in built.log { CrashRecorder.note(line) }
            self.outsideSources = OutsideGuide.sources.compactMap { built.states[$0.id] }
            if built.programs.isEmpty, !built.problems.isEmpty {
                self.outsideStatus = self.outsideMatches.isEmpty
                    ? .failed(built.problems.joined(separator: "\n"))
                    : .ready(matched: self.outsideMatches.count, total: snapshot.count, updated: self.outsideBuiltAt)
                return
            }
            let now = Date()
            let newSaved = OutsideGuide.Saved(built: now, shards: Array(shardIDs), channelCount: snapshot.count,
                                           programs: built.programs, notes: built.notes,
                                           sources: built.states, nextCheck: built.nextCheck, targetsKey: built.targetsKey,
                                           detailVersion: OutsideGuide.detailVersion)
            Task.detached(priority: .background) { OutsideGuide.save(newSaved, signature: signature) }
            self.outsideSavedCache[signature] = newSaved
            self.outsideSavedTried.insert(signature)
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
    /// The merging runs on a background thread (thousands of channels);
    /// guide fetches that land meanwhile are redone on top of its result.
    private func rebuildOutsidePrograms() {
        listingsGeneration &+= 1
        let generation = listingsGeneration
        let server = serverPrograms
        let provider = providerMatches
        let outside = outsideMatches
        var ids = Set(outside.keys).union(provider.keys)
        for key in programs.keys where !key.hasPrefix("e|") { ids.insert(key) }
        let window = Self.windowStart()
        touchedListings = []
        Task { [weak self] in
            let merged = await Task.detached(priority: .userInitiated) {
                LiveTVWork.mergedListings(ids: ids, server: server, provider: provider, outside: outside, windowStart: window)
            }.value
            guard let self, generation == self.listingsGeneration else { return }
            var result = merged
            for id in self.touchedListings {
                let list = self.bestListing(server: self.serverListing(for: id), outside: self.outsideListing(for: id))
                result[id] = list.isEmpty ? nil : list
            }
            // Entry lists stay until applyEntryGuides decides they changed.
            for (key, value) in self.programs where key.hasPrefix("e|") { result[key] = value }
            var states = self.guideState
            self.applyEntryGuides(&result, &states, entryIDs: Array(self.entryInfo.keys))
            self.programs = result
            self.guideState = states
        }
    }

    /// Picks whichever listing covers more of the next three hours; the
    /// server's wins ties and is topped up from outside where it has gaps.
    private func bestListing(server: [LiveTVProgram]?, outside: [LiveTVProgram]?) -> [LiveTVProgram] {
        LiveTVWork.bestListing(server: server, outside: outside, windowStart: Self.windowStart())
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

    /// The kind of channel an entry (or raw channel) is: News, Sports…
    func category(of id: String) -> LineupCategory? {
        entryInfo[id]?.category ?? traits[id]?.category
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
        // Shown right away; the full lineup follows from the background rebuild.
        if included { lineupIDs.insert(channel.id) } else { lineupIDs.remove(channel.id) }
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
        scheduleRebuild()
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
        let serverTagged: Int
        let nowGenres: String
        let nowSubtitle: String
        let nowDescription: String
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
                kind: trait?.kind.rawValue ?? "", market: trait?.market ?? "", core: trait?.core ?? "", scope: trait?.scope ?? "",
                serverTagged: serverList.filter {
                    $0.end > start && $0.start < end && ($0.isMovie || $0.isSports || $0.isNews || $0.isKids)
                }.count,
                nowGenres: current.map { program in
                    [program.isSports ? "sports" : nil, program.isNews ? "news" : nil,
                     program.isMovie ? "movie" : nil, program.isKids ? "kids" : nil].compactMap { $0 }.joined(separator: " ")
                } ?? "",
                nowSubtitle: current?.episodeTitle ?? "",
                nowDescription: current?.overview.map { String($0.prefix(160)) } ?? ""
            ))
        }
        let low = Int(start.timeIntervalSince1970 / 60)
        let high = Int(end.timeIntervalSince1970 / 60)
        let total = rows.count
        return await Task.detached(priority: .userInitiated) { () -> String in
            func cell(_ value: String?) -> String {
                "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let endFormatter = DateFormatter()
            endFormatter.locale = Locale(identifier: "en_US_POSIX")
            endFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            func count(_ raw: [OutsideGuide.RawProgram]?) -> Int {
                (raw ?? []).reduce(0) { $0 + ($1.s < high && $1.s + $1.m > low ? 1 : 0) }
            }
            func tagged(_ raw: [OutsideGuide.RawProgram]?) -> Int {
                (raw ?? []).reduce(0) { $0 + ($1.s < high && $1.s + $1.m > low && $1.f & ProgramGenre.genreBits != 0 ? 1 : 0) }
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
                "kind", "market", "core_network", "scope",
                "server_genre_tagged_next_3h", "outside_genre_tagged_next_3h", "provider_guide_genre_tagged_next_3h", "now_genres",
                "now_subtitle", "now_description", "outside_listings_end"
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
                    cell(row.kind), cell(row.market), cell(row.core), cell(row.scope),
                    cell(String(row.serverTagged)), cell(String(tagged(row.outsideRaw))),
                    cell(isXtream ? String(tagged(row.providerRaw)) : ""), cell(row.nowGenres),
                    cell(row.nowSubtitle), cell(row.nowDescription.isEmpty ? "" : row.nowDescription.rxReplace("https?://\\S+", with: "")
                        .replacingOccurrences(of: "\n", with: " ")),
                    cell(row.outsideRaw.flatMap { list in list.map { $0.s + $0.m }.max() }.map { end in
                        endFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(end * 60)))
                    } ?? "")
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

    /// An entry's own versions, without the event feeds `versions(of:)` adds.
    func baseVersions(of channel: LiveTVChannel) -> [LiveTVChannel] {
        guard let info = entryInfo[channel.id] else { return [channel] }
        var list = orderedByReliability(info.members.compactMap { self.channel(id: $0) })
        if let pinned = pinnedFeeds[channel.id], let index = list.firstIndex(where: { $0.id == pinned }), index > 0 {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    /// Raw versions of an entry, best first (reliable sources moved up).
    func versions(of channel: LiveTVChannel) -> [LiveTVChannel] {
        if let info = entryInfo[channel.id] {
            var list = orderedByReliability(info.members.compactMap { self.channel(id: $0) })
            // A version the viewer pinned always goes first.
            if let pinned = pinnedFeeds[channel.id], let index = list.firstIndex(where: { $0.id == pinned }), index > 0 {
                list.insert(list.remove(at: index), at: 0)
            }
            // A game on this channel: its provider event feeds back it up.
            for feed in eventBackups(forEntry: channel.id) where !list.contains(feed) { list.append(feed) }
            return list
        }
        // A game from Live Events: its channels, then its event feeds.
        if let game = sportsEvents.first(where: { $0.id == channel.id }) {
            let list = eventCandidates(game)
            if !list.isEmpty { return list }
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
        watchingEventID = nil
        if let lineup, lineup.contains(channel) { flipList = lineup }
        else if !flipList.contains(channel) { flipList = visibleEntries().contains(channel) ? visibleEntries() : [channel] }
        surfStep = 0
        remember(channel)
        tune(channel, candidates: versions(of: channel), from: 0, followFeed: false)
    }

    /// Opens a numbered event feed for surfing: Up / Down move through the
    /// family, skipping feeds that aren't live.
    func surf(_ feed: LiveTVChannel, in family: EventFamily) {
        watchingEventID = nil
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
        watchingEventID = nil
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
        let (title, start) = ChannelCatalog.parseEvent(text, now: Date(), market: traits[feed.id]?.market)
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
        // A channel starting takes the one stream slot from the guide preview.
        // Picking the previewed channel keeps the Emby stream the preview
        // opened (no second open on the server); an Xtream preview is closed
        // a moment before the channel connects, so the provider sees it go.
        var handoff: LiveTVStream?
        var settle = delay
        if !replacing, previewChannelID != nil || previewPlayer.isActive {
            if let feed = previewFeed, list.indices.contains(startIndex), list[startIndex].id == feed.id,
               let stream = previewStream {
                handoff = stream
                previewStream = nil
            } else if previewFeed?.serverID.hasPrefix("xt:") == true, previewPlayer.isActive {
                settle = max(settle, 1)
            }
            stopPreview()
        }
        let settleDelay = settle
        let handed = handoff
        if !replacing {
            if let last = lastDisplay, last.id != display.id { previousChannel = last }
            lastDisplay = display
        }
        watching = display
        if !replacing {
            // A new channel: new log session and a fresh recovery budget.
            manualFeedID = nil
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
            try? await Task.sleep(nanoseconds: 350_000_000 + settleDelay * 1_000_000_000)
            guard generation == self.tuneGeneration else { return }
            if let handoff = handed, list.indices.contains(startIndex),
               self.openStreams.contains(where: { $0.stream.url == handoff.url }) {
                self.log("from preview", list[startIndex], detail: "kept the stream the guide preview opened")
                self.startFeed(display: display, feed: list[startIndex], url: handoff.url, index: startIndex, of: list.count,
                               followFeed: followFeed, replacing: replacing, generation: generation)
                return
            }
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
        // A feed picked in the Sources panel gets more reconnects before
        // anything else is tried.
        let allowance = (isXtream ? 2 : 1) + (played > 60 ? 1 : 0) + (manualFeedID == feed.id ? 2 : 0)
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
        if candidateIndex < candidates.count, manualFeedID == candidates[candidateIndex].id {
            manualFeedID = nil
            playbackNote = "The feed you picked stopped working. Trying another…"
        }
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

    /// Channel up / down from the player. Watching from Live Events, it
    /// moves between the live games of the same sport instead.
    func flip(by step: Int) {
        if let eventID = watchingEventID {
            // Rows (and their state) as of now, not as of when Live Events closed.
            LiveEventsModel.shared.refreshNow()
            let games = LiveEventsModel.shared.flipEvents(around: eventID)
            guard games.count > 1,
                  let index = games.firstIndex(where: { LiveEventsModel.shared.matches($0, eventID: eventID) }) else {
                flash(L10n.string("live_event_no_other_games", fallback: "No other games on right now"))
                return
            }
            let next = (index + step + games.count) % games.count
            let target = games[next]
            flash("\(next + 1) / \(games.count)  ·  " + (target.game.map(SportsNames.title) ?? target.title))
            switchToEvent(LiveEventsModel.shared.cardCurrent(target).flatMap { $0.sources.isEmpty ? nil : $0 } ?? target)
            return
        }
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

    // MARK: Later in the day
    //
    // The guide normally shows the three hours from the last half hour. When
    // the viewer moves later (Right past the last show, or Tonight ▾), rows
    // ask for listings around that start instead: worked out from the same
    // provider and outside guides (which cover many hours ahead) plus a
    // server fetch for Emby channels. Kept for one start at a time.

    @Published private(set) var laterRevision = 0
    private var laterStart: Date?
    private var laterPrograms: [String: [LiveTVProgram]] = [:]
    private var laterServer: [String: [LiveTVProgram]] = [:]
    private var laterRequested: Set<String> = []
    private var laterFetching: Set<String> = []

    /// A row's programs for the guide: the live window, or a later one.
    func guidePrograms(on id: String, viewStart: Date?) -> [LiveTVProgram] {
        guard let viewStart, viewStart != Self.windowStart() else { return programs[id] ?? [] }
        guard laterStart == viewStart else { return [] }
        return laterPrograms[id] ?? []
    }

    /// Whether a later window has anything for a row yet.
    func laterLoaded(_ id: String, viewStart: Date) -> Bool {
        laterStart == viewStart && laterRequested.contains(id) && !laterFetching.contains(where: { member in
            (entryInfo[id]?.members.prefix(2).contains(member) ?? (member == id))
        })
    }

    func requestLaterGuide(_ ids: [String], viewStart: Date) {
        if laterStart != viewStart {
            laterStart = viewStart
            laterPrograms = [:]
            laterServer = [:]
            laterRequested = []
            laterFetching = []
        }
        var fetch: [String: [String]] = [:]
        var changed = false
        for id in ids where !laterRequested.contains(id) {
            laterRequested.insert(id)
            changed = true
            let members = entryInfo[id].map { Array($0.members.prefix(2)) } ?? [id]
            for member in members {
                if laterPrograms[member] == nil { laterPrograms[member] = laterListing(member, start: viewStart) }
                if let index = indexByID[member], index < channels.count, traits[member]?.familyKey == nil,
                   !channels[index].serverID.hasPrefix("xt:"), !laterFetching.contains(member) {
                    fetch[channels[index].serverID, default: []].append(member)
                    laterFetching.insert(member)
                }
            }
            if entryInfo[id] != nil { laterPrograms[id] = laterEntryListing(id, start: viewStart) }
        }
        if changed { laterRevision &+= 1 }
        guard !fetch.isEmpty else { return }
        let clients = Dictionary(uniqueKeysWithValues: servers().map { ($0.config.id, $0.client) })
        for (serverID, members) in fetch {
            guard let client = clients[serverID] else {
                members.forEach { laterFetching.remove($0) }
                continue
            }
            for batch in stride(from: 0, to: members.count, by: Self.programBatch).map({ Array(members[$0..<min($0 + Self.programBatch, members.count)]) }) {
                let itemIDs = batch.compactMap { indexByID[$0].map { channels[$0].itemID } }
                Task { [weak self] in
                    let list = try? await client.programs(channelItemIDs: itemIDs, from: viewStart.addingTimeInterval(-1800),
                                                         to: viewStart.addingTimeInterval(Self.guideHours * 3600 + 1800))
                    guard let self, self.laterStart == viewStart else { return }
                    let grouped = Dictionary(grouping: list ?? [], by: \.channelID)
                    var entries: Set<String> = []
                    for member in batch {
                        self.laterFetching.remove(member)
                        self.laterServer[member] = (grouped[member] ?? []).sorted { $0.start < $1.start }
                        self.laterPrograms[member] = self.laterListing(member, start: viewStart)
                        if let entry = self.entryOf[member] { entries.insert(entry) }
                    }
                    for entry in entries where self.laterRequested.contains(entry) {
                        self.laterPrograms[entry] = self.laterEntryListing(entry, start: viewStart)
                    }
                    self.laterRevision &+= 1
                }
            }
        }
    }

    private func laterListing(_ id: String, start: Date) -> [LiveTVProgram] {
        let isXtream = indexByID[id].map { channels[$0].serverID.hasPrefix("xt:") } ?? false
        return LiveTVWork.listing(id: id, server: laterServer[id] ?? (isXtream ? serverPrograms[id] : nil),
                                  provider: providerMatches[id], outside: outsideMatches[id], windowStart: start)
    }

    /// An entry's later listing: its best-covered version, under the entry's id.
    private func laterEntryListing(_ id: String, start: Date) -> [LiveTVProgram] {
        guard let info = entryInfo[id] else { return [] }
        let end = start.addingTimeInterval(Self.guideHours * 3600)
        func coverage(_ list: [LiveTVProgram]) -> TimeInterval {
            list.reduce(0) { total, p in total + max(0, min(p.end, end).timeIntervalSince(max(p.start, start))) }
        }
        var best: [LiveTVProgram] = []
        var bestCoverage: TimeInterval = -1
        for member in info.members.prefix(2) {
            let list = laterPrograms[member] ?? []
            guard !list.isEmpty else { continue }
            let value = coverage(list)
            if value > bestCoverage { best = list; bestCoverage = value }
        }
        return best.map { program in
            LiveTVProgram(
                id: "\(id)|\(program.id)", channelID: id, title: program.title, episodeTitle: program.episodeTitle,
                overview: program.overview, start: program.start, end: program.end, isMovie: program.isMovie,
                isSports: program.isSports, isNews: program.isNews, isKids: program.isKids, isLive: program.isLive,
                isPremiere: program.isPremiere, imageURL: program.imageURL, fromOutsideGuide: program.fromOutsideGuide
            )
        }
    }

    /// Other upcoming airings of a show (same title) on the guide's entries.
    func otherAirings(of program: LiveTVProgram, limit: Int = 5) -> [(channel: LiveTVChannel, program: LiveTVProgram)] {
        let now = Date()
        var seen: Set<String> = [program.channelID + "|" + "\(program.start.timeIntervalSince1970)"]
        var result: [(channel: LiveTVChannel, program: LiveTVProgram)] = []
        for source in [programs, laterPrograms] {
            for (id, list) in source where id.hasPrefix("e|") {
                for other in list where other.title == program.title && other.end > now {
                    let key = id + "|" + "\(other.start.timeIntervalSince1970)"
                    guard !seen.contains(key), let channel = entry(id: id) else { continue }
                    seen.insert(key)
                    result.append((channel, other))
                }
            }
        }
        return Array(result.sorted { $0.program.start < $1.program.start }.prefix(limit))
    }

    // MARK: Sports events
    //
    // Rebuilds run off the main thread and only when an input changes:
    // provider events, the schedule, the lineup / hidden groups, the sports
    // listings, a 30-minute time bucket, the Spanish preference or the
    // schedule switch. Guide data doesn't trigger them; sports listings are
    // pulled from it after a quiet minute, at most every 10 minutes, or when
    // Live Events opens. The last result is saved and shown on next launch.

    private var sportsSinks: [AnyCancellable] = []
    private var sportsRebuildTask: Task<Void, Never>?
    private var sportsRebuildDue: Date?
    private var sportsRebuildRunning = false
    /// Launch pacing: while the first ~40 s of data pour in (schedule, guide,
    /// channel index), rebuilds run at most every 6 s instead of on every
    /// arrival. Your own changes (settings, home city) skip the wait.
    private var sportsFirstRequest: Date?
    private var sportsLastRebuild: Date?
    private static let sportsLaunchWindow: TimeInterval = 40
    private static let sportsLaunchGap: TimeInterval = 6
    private static let sportsUserReasons: Set<String> = ["setting", "home city", "my sports", "hidden"]
    private var sportsRebuildAgain: String?
    private var sportsFingerprint: String?
    private var sportsRebuildTimes: [Date] = []
    private var eventsRevision = 0
    private var sportsListings: [SportsMatcher.GuideListing] = []
    private var sportsListingsRevision = 0
    private var listingsExtractedAt: Date?
    private var listingsChangedAt: Date?
    private var listingsPendingSince: Date?
    private var listingsTask: Task<Void, Never>?
    private var listingsExtracting = false
    /// Channel entry id → indices into `sportsEvents` (for event backups).
    private var sportsBackupIndex: [String: [Int]] = [:]
    private var sportsPersistLoaded = false
    private var sportsPersistedFingerprint: String?
    /// The guide had game listings to read at least once this session (until
    /// then a result would miss local-station games, so it isn't saved).
    private var sportsListingsReady = false
    private var listingsProgramsRevision = -1
    private var sportsAbortUntil: Date?
    private var sportsChannelIndex: (key: String, index: SportsNetworkMap.ChannelIndex)?
    private var sportsChannelIndexBuiltAt: Date?
    private var lastCoverageNote = ""

    private static var sportsCacheFile: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("LiveTV", isDirectory: true).appendingPathComponent("live-events.json")
    }

    func scheduleSportsRebuild(delay: Double = 0.5, reason: String = "request") {
        SportsData.shared.loadCached()
        if sportsSinks.isEmpty {
            sportsSinks.append(SportsData.shared.$revision.dropFirst().sink { [weak self] _ in
                guard let self else { return }
                self.scheduleSportsRebuild(delay: 0.3, reason: "schedule")
                // First schedule of the session: the guide's game listings too.
                if self.listingsExtractedAt == nil {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await self?.extractSportsListings(reason: "schedule")
                    }
                }
            })
            sportsSinks.append($entriesRevision.dropFirst().sink { [weak self] _ in
                self?.scheduleSportsRebuild(delay: 3, reason: "lineup")
            })
            sportsSinks.append($hiddenGroups.dropFirst().sink { [weak self] _ in
                self?.scheduleSportsRebuild(delay: 1, reason: "hidden")
            })
            loadSavedSportsEvents()
        }
        if sportsRebuildRunning {
            sportsRebuildAgain = reason
            return
        }
        let now = Date()
        if sportsFirstRequest == nil { sportsFirstRequest = now }
        var delay = delay
        if let first = sportsFirstRequest, now.timeIntervalSince(first) < Self.sportsLaunchWindow,
           let last = sportsLastRebuild, !Self.sportsUserReasons.contains(reason) {
            let gap = Self.sportsLaunchGap - now.timeIntervalSince(last)
            if gap > delay { delay = gap }
        }
        let wait = delay
        let due = now.addingTimeInterval(wait)
        if let pending = sportsRebuildDue, pending <= due { return }
        sportsRebuildTask?.cancel()
        sportsRebuildDue = due
        sportsRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.sportsRebuildDue = nil
            self.sportsRebuildRunning = true
            await self.rebuildSportsEvents(reason: reason)
            self.sportsRebuildRunning = false
            self.sportsLastRebuild = Date()
            if let again = self.sportsRebuildAgain {
                self.sportsRebuildAgain = nil
                self.scheduleSportsRebuild(delay: 2, reason: again)
            }
        }
    }

    /// Live Events opened: fresh sports listings if they're over 10 minutes
    /// old, and a rebuild if anything changed.
    func sportsOpened() {
        let stale = listingsExtractedAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        let guideMoved = programsRevision != listingsProgramsRevision
            && (listingsExtractedAt.map { Date().timeIntervalSince($0) > 60 } ?? true)
        guard stale || guideMoved else {
            scheduleSportsRebuild(delay: 0.2, reason: "open")
            return
        }
        Task { [weak self] in
            await self?.extractSportsListings(reason: "open")
            self?.scheduleSportsRebuild(delay: 0.2, reason: "open")
        }
    }

    /// Live Events' 30-second tick: only rebuilds when the 30-minute time
    /// bucket moved on (the fingerprint skips everything else).
    func sportsTick() {
        scheduleSportsRebuild(delay: 0.5, reason: "tick")
    }

    private func guideChangedForSports() {
        let now = Date()
        listingsChangedAt = now
        if listingsPendingSince == nil { listingsPendingSince = now }
        guard listingsTask == nil else { return }
        listingsTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                let now = Date()
                let quiet = now.timeIntervalSince(self.listingsChangedAt ?? now)
                let waiting = now.timeIntervalSince(self.listingsPendingSince ?? now)
                let sinceLast = self.listingsExtractedAt.map { now.timeIntervalSince($0) } ?? .infinity
                if quiet >= 60 || (waiting >= 600 && sinceLast >= 600) {
                    self.listingsTask = nil
                    await self.extractSportsListings(reason: quiet >= 60 ? "quiet" : "deadline")
                    return
                }
            }
        }
    }

    /// Game listings from the guide: sports, local and Spanish channels in
    /// My Lineup or the browse list, titles with two sides, −5 h to +16 h.
    /// Call signs of your markets, for ranking stations: the home market
    /// (picked in Options, else the first) and the others.
    struct StationMarkets {
        var home: Set<String> = []
        var others: Set<String> = []
    }

    /// Station ranks, best first. Lower is listed first on a tile.
    enum StationRank {
        static let lineupHome = 0
        static let lineup = 1
        static let home = 2
        static let market = 3
        static let elsewhere = 4
        /// Ranks that count as "your local station".
        static func isLocal(_ rank: Int) -> Bool { rank == home || rank == market }
    }

    var homeMarketName: String? {
        prefs.homeMarket.flatMap { name in prefs.markets.first { $0.name == name }?.name } ?? prefs.markets.first?.name
    }

    func stationMarkets() -> StationMarkets {
        func bases(_ list: [String]) -> Set<String> {
            Set(list.map { ($0.split(separator: "-").first.map(String.init) ?? $0).uppercased() })
        }
        var result = StationMarkets()
        let homeName = homeMarketName
        result.home = bases(prefs.markets.first { $0.name == homeName }?.callsigns ?? [])
        result.others = bases(prefs.markets.filter { $0.name != homeName }.flatMap(\.callsigns)).subtracting(result.home)
        return result
    }

    /// Live Events' home city: the next of your markets.
    func cycleHomeMarket() {
        guard prefs.markets.count > 1 else { return }
        var updated = prefs
        let index = prefs.markets.firstIndex { $0.name == homeMarketName } ?? 0
        updated.homeMarket = prefs.markets[(index + 1) % prefs.markets.count].name
        prefs = updated
        updated.save()
        CrashRecorder.note("live events home city: \(updated.homeMarket ?? "")")
        // Station ranks are worked out when the guide's game listings are
        // read, so read them again, then rebuild.
        Task { [weak self] in
            await self?.extractSportsListings(reason: "home city")
            self?.scheduleSportsRebuild(delay: 0.3, reason: "home city")
        }
    }

    /// A station's rank: My Lineup (home first), then your home market, your
    /// other markets, anywhere else.
    nonisolated static func stationRank(_ info: LiveTVEntryInfo, markets: StationMarkets, inLineup: Bool) -> Int {
        var place = StationRank.elsewhere
        if info.category == .local || info.category == .spanish {
            let signs = (info.callsign.map { $0.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) } ?? [])
                + (RegionalNetworks.callsignInName(info.name).map { [$0] } ?? [])
            let bases = Set(signs.map { ($0.split(separator: "-").first.map(String.init) ?? $0).uppercased() })
            if !bases.isDisjoint(with: markets.home) { place = StationRank.home } else if !bases.isDisjoint(with: markets.others) { place = StationRank.market }
        }
        guard inLineup else { return place }
        return place == StationRank.home ? StationRank.lineupHome : StationRank.lineup
    }

    private func extractSportsListings(reason: String) async {
        guard !listingsExtracting, !SportsData.shared.games.isEmpty else { return }
        listingsExtracting = true
        defer { listingsExtracting = false }
        let started = Date()
        listingsPendingSince = nil
        let kinds: Set<LineupCategory> = [.sports, .local, .spanish]
        let lineup = lineupIDs
        let markets = stationMarkets()
        var subsetMap: [String: [LiveTVProgram]] = [:]
        // The saved listings beyond the guide's window (the guide keeps about
        // 14 h; games are looked for 48 h ahead). Shared arrays, not copies.
        var savedMap: [String: (outside: [OutsideGuide.RawProgram]?, provider: [OutsideGuide.RawProgram]?)] = [:]
        var metaMap: [String: (inLineup: Bool, spanish: Bool, rank: Int)] = [:]
        // Every such channel you have, not only My Lineup's: any station
        // whose guide shows the game is a way to watch it. Sports channels of
        // unknown country too (they're not in the browse list).
        var candidates = lineup.union(browseEntries.map(\.id))
        for (id, info) in entryInfo where info.market == nil && info.category == .sports && info.kind == .channel {
            candidates.insert(id)
        }
        for id in candidates {
            guard let info = entryInfo[id], kinds.contains(info.category) else { continue }
            let list = programs[id]
            // Saved listings are kept per provider channel (the entry's members).
            let outside = info.members.prefix(2).lazy.compactMap { self.outsideMatches[$0] }.first
            let provider = info.members.prefix(2).lazy.compactMap { self.providerMatches[$0] }.first
            guard list != nil || outside != nil || provider != nil else { continue }
            subsetMap[id] = list ?? []
            if outside != nil || provider != nil { savedMap[id] = (outside, provider) }
            let inLineup = lineup.contains(id)
            metaMap[id] = (inLineup, info.category == .spanish || info.market == "US-ES",
                           Self.stationRank(info, markets: markets, inLineup: inLineup))
        }
        let subset = subsetMap
        let savedListings = savedMap
        let meta = metaMap
        let mainMS = Int(Date().timeIntervalSince(started) * 1000)
        // Nothing to read yet (guide still loading): try again later.
        guard !subset.isEmpty else {
            CrashRecorder.note("sports listings (\(reason)): guide not loaded yet")
            return
        }
        listingsProgramsRevision = programsRevision
        let now = Date()
        let extracted = await Task.detached(priority: .utility) { () -> (listings: [SportsMatcher.GuideListing], ahead: Int) in
            let low = now.addingTimeInterval(-5 * 3600), high = now.addingTimeInterval(48 * 3600)
            var listings: [SportsMatcher.GuideListing] = []
            var ahead = 0
            func consider(_ id: String, _ info: (inLineup: Bool, spanish: Bool, rank: Int), title rawTitle: String, subtitle: String?,
                          overview: String?, sports: Bool, start: Date, end: Date) -> Bool {
                let title = subtitle.map { "\(rawTitle) \($0)" } ?? rawTitle
                if SportsMatcher.looksLikeGame(title) {
                    listings.append(SportsMatcher.GuideListing(entryID: id, inLineup: info.inLineup, spanish: info.spanish,
                                                               title: title, start: start, end: end, rank: info.rank))
                    return true
                }
                if let overview, overview.count > 12, sports || SportsMatcher.isGenericSportsTitle(rawTitle),
                   SportsMatcher.isGenericSportsTitle(title) {
                    // "NBA Basketball": the description names the venue
                    // ("From Chase Center in San Francisco"), or sometimes the teams.
                    var listing = SportsMatcher.GuideListing(entryID: id, inLineup: info.inLineup, spanish: info.spanish,
                                                             title: title, start: start, end: end, rank: info.rank)
                    if let place = SportsMatcher.venueOf(overview) {
                        listing.venue = place.venue
                        listing.city = place.city
                    } else {
                        listing.detail = String(overview.prefix(120))
                    }
                    listings.append(listing)
                    return true
                }
                return false
            }
            let highMinute = Int(high.timeIntervalSince1970 / 60)
            for (id, list) in subset {
                autoreleasepool {
                    guard let info = meta[id] else { return }
                    var guideEnd = low
                    for program in list where program.end > low && program.start < high {
                        if program.end > guideEnd { guideEnd = program.end }
                        _ = consider(id, info, title: program.title, subtitle: program.episodeTitle, overview: program.overview,
                                     sports: program.isSports, start: program.start, end: program.end)
                    }
                    // Then the saved listings past what the guide holds.
                    guard let saved = savedListings[id] else { return }
                    let fromMinute = Int(guideEnd.timeIntervalSince1970 / 60)
                    var seen = Set<Int>()
                    for raw in [saved.outside, saved.provider] {
                        for item in raw ?? [] where item.s >= fromMinute && item.s < highMinute && seen.insert(item.s).inserted {
                            let start = Date(timeIntervalSince1970: TimeInterval(item.s * 60))
                            let end = Date(timeIntervalSince1970: TimeInterval((item.s + item.m) * 60))
                            if consider(id, info, title: item.t, subtitle: item.st, overview: item.d, sports: item.f & 2 != 0,
                                        start: start, end: end) {
                                ahead += 1
                            }
                        }
                    }
                }
            }
            let sorted = listings.sorted { $0.start != $1.start ? $0.start < $1.start : ($0.entryID != $1.entryID ? $0.entryID < $1.entryID : $0.title < $1.title) }
            return (sorted, ahead)
        }.value
        listingsExtractedAt = Date()
        sportsListingsReady = true
        let changed = extracted.listings != sportsListings
        CrashRecorder.note("sports listings (\(reason)): \(extracted.listings.count) from \(subset.count) channels "
                           + "(\(extracted.ahead) from saved listings past the guide), "
                           + "\(Int(Date().timeIntervalSince(started) * 1000)) ms (main \(mainMS) ms)\(changed ? "" : ", unchanged")")
        guard changed else { return }
        sportsListings = extracted.listings
        sportsListingsRevision &+= 1
        scheduleSportsRebuild(delay: 0.5, reason: "listings")
    }

    private func rebuildSportsEvents(reason: String) async {
        let now = Date()
        let games = SportsData.shared.games
        let schools = SportsData.shared.schools
        let preferSpanish = prefs.countries.contains("US-ES")
        let bucket = Int(now.timeIntervalSince1970 / 1800)
        let fingerprint = [eventsRevision, SportsData.shared.revision, entriesRevision,
                           sportsListingsRevision, bucket].map { String($0) }.joined(separator: "|")
            + "|\(hiddenGroups.sorted().joined(separator: ","))|\(preferSpanish)|\(SportsData.isEnabled)|\(schools.count)"
        guard fingerprint != sportsFingerprint else { return }
        if let until = sportsAbortUntil, until > now { return }
        let available = os_proc_available_memory()
        guard available == 0 || available > 200 * 1_048_576 else {
            CrashRecorder.note("sports rebuild (\(reason)) skipped: only \(available / 1_048_576) MB free")
            return
        }
        sportsRebuildTimes = sportsRebuildTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if sportsRebuildTimes.count > 4 { CrashRecorder.note("sports rebuild: \(sportsRebuildTimes.count) in the last minute") }
        let started = Date()
        let memoryBefore = CrashRecorder.memoryMB()
        // Snapshots (copy-on-write); everything heavy runs off the main thread.
        let rawEvents = events
        let listings = sportsListings
        let lineup = lineupIDs
        let lineupEntries = lineupIDs.compactMap { entry(id: $0) }
        let browse = browseEntries
        let allEntries = entries
        let entryInfo = self.entryInfo
        let hidden = hiddenGroups
        var previousMap: [String: String] = [:]
        for event in sportsEvents { if let game = event.game { previousMap[game.id] = event.id } }
        let previousIDs = previousMap
        // Teams of the leagues being looked up (logos by name, team channels).
        let allRosters = SportsData.shared.rosters
        let rosters: [SportsMatcher.RosterLeague] = SportsData.activeLeagues.compactMap { league in
            guard let teams = allRosters[league.short], !teams.isEmpty else { return nil }
            return SportsMatcher.RosterLeague(short: league.short, group: league.group, college: league.college, teams: teams)
        }
        // Which of your channels carry which network or team: worked out once
        // per channel list, lineup or team change, not on every rebuild.
        let markets = stationMarkets()
        var lineupHasher = Hasher()
        for id in lineup.sorted() { lineupHasher.combine(id) }
        for sign in markets.home.sorted() { lineupHasher.combine(sign) }
        for sign in markets.others.sorted() { lineupHasher.combine(sign) }
        let indexKey = "\(entriesRevision)|\(lineupHasher.finalize())|\(hidden.sorted().joined(separator: ","))|"
            + rosters.map { "\($0.short):\($0.teams.count)" }.joined(separator: ",")
        // Event titles from a list saved by an older build don't say whether
        // their day was a guess: read that from the slot's raw text.
        var rawTexts: [String: String] = [:]
        for event in rawEvents where event.startGuessed == nil && event.start != nil {
            if let feed = event.feeds.first, let text = traits[feed]?.eventText { rawTexts[event.id] = text }
        }
        let savedTexts = rawTexts
        let mainMS = Int(Date().timeIntervalSince(started) * 1000)
        let channelIndex: SportsNetworkMap.ChannelIndex
        var staleIndex = false
        if let cached = sportsChannelIndex, cached.key == indexKey {
            channelIndex = cached.index
        } else if let cached = sportsChannelIndex, let built = sportsChannelIndexBuiltAt, now.timeIntervalSince(built) < 15 {
            // The channel list changes several times while it loads: reuse
            // the last index now and catch up once it settles.
            channelIndex = cached.index
            staleIndex = true
            scheduleSportsRebuild(delay: 15, reason: "channel index")
        } else {
            let indexStarted = Date()
            channelIndex = await Task.detached(priority: .utility) {
                SportsNetworkMap.channelIndex(lineup: lineup, lineupEntries: lineupEntries, browse: browse, all: allEntries,
                                              entryInfo: entryInfo, hidden: hidden, rosters: rosters, markets: markets)
            }.value
            sportsChannelIndex = (indexKey, channelIndex)
            sportsChannelIndexBuiltAt = Date()
            CrashRecorder.note("sports channel index: \(channelIndex.summary), \(Int(Date().timeIntervalSince(indexStarted) * 1000)) ms")
        }
        let result = await Task.detached(priority: .utility) { () -> (events: [SportsEvent], stats: SportsMatcher.Stats, sources: SportsNetworkMap.SourceStats)? in
            let spanishWords = "\\b(spanish|espanol|español|deportes|telemundo|univision|tudn|unimas)\\b"
            var providerEvents: [SportsMatcher.ProviderEvent] = []
            providerEvents.reserveCapacity(rawEvents.count)
            for event in rawEvents {
                autoreleasepool {
                    providerEvents.append(SportsMatcher.ProviderEvent(
                        id: event.id, title: event.title, league: event.league, start: event.start, feeds: event.feeds,
                        family: event.family, spanish: event.market == "US-ES" || RX.test(spanishWords, event.title, caseInsensitive: true),
                        guessed: event.startGuessed
                            ?? savedTexts[event.id].map { ChannelCatalog.parseEventDetailed($0, now: now, market: event.market).guessed } ?? false
                    ))
                }
            }
            let network = SportsNetworkMap.networkSources(for: games, index: channelIndex)
            guard let built = SportsMatcher.build(
                games: games, channelSources: network.sources, events: providerEvents, listings: listings,
                preferSpanish: preferSpanish, now: now, previousIDs: previousIDs, schools: schools, rosters: rosters,
                shouldStop: {
                    let free = os_proc_available_memory()
                    if free != 0, free < 150 * 1_048_576 { return "only \(free / 1_048_576) MB free" }
                    let grown = CrashRecorder.memoryMB() - memoryBefore
                    if grown > 250 { return "memory grew \(grown) MB" }
                    return nil
                }
            ) else { return nil }
            return (built.events, built.stats, network.stats)
        }.value
        let memoryAfter = CrashRecorder.memoryMB()
        guard let result else {
            // Don't retry on every tick: wait a few minutes.
            sportsAbortUntil = Date().addingTimeInterval(300)
            CrashRecorder.note("sports rebuild (\(reason)) stopped; keeping the last result, retry in 5 min")
            return
        }
        sportsAbortUntil = nil
        // With a stale channel index, the catch-up rebuild must still run.
        sportsFingerprint = staleIndex ? nil : fingerprint
        let built = markEndedByFeeds(result.events, previous: sportsEvents, rawEvents: rawEvents, now: now)
        noteSportsCoverage(built, sources: result.sources, now: now)
        CrashRecorder.note("sports rebuild (\(reason)): \(built.count) shown, \(built.filter { !$0.sources.isEmpty }.count) watchable, "
                           + "\(Int(Date().timeIntervalSince(started) * 1000)) ms (main \(mainMS) ms), memory \(memoryBefore)→\(memoryAfter) MB")
        if built != sportsEvents {
            setSportsEvents(built)
            saveSportsEvents(built, rawEvents: rawEvents)
        }
        SportsData.shared.noteWatchable(Set(built.filter { !$0.sources.isEmpty && $0.game != nil }.map(\.leagueShort)))
    }

    /// Live Events inputs and results, appended to the playback log so the
    /// matching can be replayed and tuned offline: the schedule's games,
    /// sports guide listings, provider event titles, your sports / local
    /// channels and the tiles built. One JSON object per "#J " line; no
    /// stream links (any URL in a title is removed).
    func sportsTestData() async -> String {
        let games = SportsData.shared.games
        let listings = sportsListings
        let rawEvents = events
        let tiles = sportsEvents
        let traits = self.traits
        let infos = entryInfo
        let lineup = lineupIDs
        let marketList = prefs.markets.map { ["name": $0.name, "callsigns": $0.callsigns] as [String: Any] }
        let ids = lineup.union(browseEntries.map(\.id))
        let guideSources = outsideSources
        return await Task.detached(priority: .utility) { () -> String in
            func time(_ date: Date?) -> Any { date.map { Int($0.timeIntervalSince1970) } ?? NSNull() }
            func team(_ t: SportsTeam) -> [String: Any] {
                ["id": t.id, "name": t.name, "short": t.short ?? "", "loc": t.location ?? "", "alt": t.alternates]
            }
            var objects: [[String: Any]] = [["t": "meta", "now": Int(Date().timeIntervalSince1970), "markets": marketList]]
            for source in guideSources {
                let mb: Int64 = (source.bytes ?? 0) / 1_048_576
                let file: Int = source.lastModified.map { Int($0.timeIntervalSince1970) } ?? 0
                let checked: Int = source.checkedAt.map { Int($0.timeIntervalSince1970) } ?? 0
                let horizon: Int = (source.horizonMedian ?? 0) * 60
                var object: [String: Any] = ["t": "guidesource", "id": source.id, "name": source.name, "backup": source.backup]
                object["status"] = source.status ?? -1
                object["mb"] = mb
                object["file"] = file
                object["checked"] = checked
                object["matched"] = source.matched ?? 0
                object["horizon"] = horizon
                object["stale"] = source.stale ?? false
                object["used"] = source.used ?? false
                object["extended"] = source.extended ?? 0
                object["shift"] = source.shift ?? 0
                object["shiftNote"] = source.shiftNote ?? ""
                object["problem"] = source.problem ?? ""
                object["seconds"] = source.parseSeconds ?? 0
                objects.append(object)
            }
            for game in games {
                var object: [String: Any] = ["t": "game", "id": game.id, "lg": game.leagueShort, "group": game.league, "start": time(game.start),
                                             "home": team(game.home), "away": team(game.away), "venue": game.venue ?? "",
                                             "nets": game.networks, "done": game.completed]
                if let card = game.cardKey {
                    object["card"] = card
                    object["title"] = game.title
                }
                objects.append(object)
            }
            for id in ids {
                guard let info = infos[id], [.sports, .local, .spanish].contains(info.category) else { continue }
                objects.append(["t": "entry", "id": id, "name": info.name, "cat": info.category.rawValue, "cs": info.callsign ?? "",
                                "kind": info.kind.rawValue, "core": info.core ?? "", "mk": info.market ?? "", "lu": lineup.contains(id)])
            }
            for listing in listings {
                objects.append(["t": "listing", "id": listing.entryID, "lu": listing.inLineup, "sp": listing.spanish,
                                "title": listing.title, "s": time(listing.start), "e": time(listing.end), "rank": listing.rank ?? -1,
                                "venue": listing.venue ?? "", "city": listing.city ?? "", "d": listing.detail ?? ""])
            }
            for event in rawEvents {
                objects.append(["t": "event", "id": event.id, "title": event.title, "lg": event.league, "fam": event.family,
                                "s": time(event.start), "g": event.startGuessed.map { $0 ? 1 : 0 } ?? -1, "mk": event.market ?? "",
                                "n": event.feeds.count, "raw": event.feeds.first.flatMap { traits[$0]?.eventText } ?? ""])
            }
            for tile in tiles {
                objects.append(["t": "tile", "id": tile.id, "title": tile.title, "lg": tile.league, "s": time(tile.start),
                                "game": tile.game?.id ?? "", "more": tile.moreStations ?? 0,
                                "src": tile.sources.map { ["k": $0.kind.rawValue, "r": $0.rank ?? -1, "id": $0.channelID,
                                                           "name": infos[$0.channelID]?.name ?? ""] as [String: Any] }])
            }
            var lines = ["#", "# LIVE EVENTS TEST DATA (\(games.count) games, \(listings.count) listings, \(rawEvents.count) events, \(tiles.count) tiles)"]
            lines.reserveCapacity(objects.count + 2)
            for object in objects {
                autoreleasepool {
                    guard let data = try? JSONSerialization.data(withJSONObject: object),
                          let text = String(data: data, encoding: .utf8) else { return }
                    lines.append("#J " + text.rxReplace("https?:\\\\?/\\\\?/[^\"\\s]+", with: ""))
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }.value
    }

    /// How a station shows on a tile, by rank.
    nonisolated static func stationDetail(_ rank: Int) -> String {
        if rank <= StationRank.lineup { return "In My Lineup" }
        if StationRank.isLocal(rank) { return "Your local station" }
        return "In your channels"
    }

    /// Where the next two days' games can be watched, by kind of source.
    private func noteSportsCoverage(_ events: [SportsEvent], sources: SportsNetworkMap.SourceStats, now: Date) {
        var games = 0, lineup = 0, local = 0, elsewhere = 0, team = 0, feedsOnly = 0, none = 0, folded = 0
        for event in events {
            guard let game = event.game, !game.completed, game.start > now.addingTimeInterval(-4 * 3600),
                  game.start < now.addingTimeInterval(48 * 3600) else { continue }
            games += 1
            let channels = event.channels
            if channels.contains(where: { $0.kind == .lineup }) { lineup += 1 }
            if channels.contains(where: { $0.kind == .guide && StationRank.isLocal($0.rank ?? StationRank.elsewhere) }) { local += 1 }
            if channels.contains(where: { $0.kind == .guide && ($0.rank ?? StationRank.elsewhere) == StationRank.elsewhere }) { elsewhere += 1 }
            if channels.contains(where: { $0.kind == .team }) { team += 1 }
            if channels.isEmpty { if event.feeds.isEmpty { none += 1 } else { feedsOnly += 1 } }
            folded += event.moreStations ?? 0
        }
        let summary = "\(games) games in 48 h: \(lineup) on My Lineup, \(local) on your local stations, \(elsewhere) on other stations, "
            + "\(team) on team channels, \(feedsOnly) on provider feeds only, \(none) nowhere; \(folded) more stations folded"
        guard summary != lastCoverageNote else { return }
        lastCoverageNote = summary
        CrashRecorder.note("sports coverage: " + summary + "; links: " + sources.summary)
    }

    /// A started game carried only by provider feeds is over once every one
    /// of those feeds has been renamed or cleared (they still exist, but now
    /// show something else). Games on guide or network channels keep the
    /// usual estimate, since those channels may still be running it.
    private func markEndedByFeeds(_ built: [SportsEvent], previous: [SportsEvent], rawEvents: [LiveEvent], now: Date) -> [SportsEvent] {
        guard !rawEvents.isEmpty else { return built }
        var old: [String: SportsEvent] = [:]
        for event in previous where event.game != nil { old[event.id] = event }
        guard !old.isEmpty else { return built }
        var ended = 0
        let result = built.map { event -> SportsEvent in
            guard event.game != nil, let before = old[event.id] else { return event }
            var copy = event
            if !event.feeds.isEmpty {
                copy.feedsEndedAt = nil
                return copy
            }
            if let at = before.feedsEndedAt {
                copy.feedsEndedAt = at
                return copy
            }
            guard let start = event.start, now.timeIntervalSince(start) > 45 * 60,
                  !before.feeds.isEmpty, !event.channels.contains(where: { $0.kind != .team }),
                  before.feeds.allSatisfy({ channel(id: $0.channelID) != nil }) else { return event }
            copy.feedsEndedAt = now
            ended += 1
            return copy
        }
        if ended > 0 { CrashRecorder.note("sports: \(ended) games ended (feeds moved on)") }
        return result
    }

    private func setSportsEvents(_ value: [SportsEvent]) {
        sportsEvents = value
        MySports.shared.scheduleTeamReminders(value)
        var index: [String: [Int]] = [:]
        for (position, event) in value.enumerated() {
            for source in event.sources where source.kind != .provider {
                index[source.channelID, default: []].append(position)
            }
        }
        sportsBackupIndex = index
    }

    // MARK: Saved result (shown instantly on the next launch)

    private struct SavedSportsEvents: Codable {
        var version = 1
        var savedAt: Date
        var events: [SportsEvent]
        /// Provider feed id → the matchup it was showing when saved.
        var feedKeys: [String: String]
        /// The guide's game listings, so the next launch's first rebuild
        /// still finds games on local stations.
        var listings: [SportsMatcher.GuideListing]? = nil
    }

    private func saveSportsEvents(_ value: [SportsEvent], rawEvents: [LiveEvent]) {
        let games = value.filter { $0.game != nil && !$0.sources.isEmpty }
        // Never save an empty or listing-less (weaker) result over a good one.
        guard !games.isEmpty, sportsListingsReady || sportsListings.isEmpty == false else { return }
        let fingerprint = games.map { "\($0.id):" + $0.sources.map(\.channelID).joined(separator: "+") }.joined(separator: ",")
        guard fingerprint != sportsPersistedFingerprint else { return }
        let listings = sportsListings
        sportsPersistedFingerprint = fingerprint
        let file = Self.sportsCacheFile
        Task.detached(priority: .background) {
            var titleOfFeed: [String: String] = [:]
            for event in rawEvents { for feed in event.feeds { titleOfFeed[feed] = event.title } }
            var keys: [String: String] = [:]
            for event in games {
                for source in event.feeds {
                    autoreleasepool {
                        if let title = titleOfFeed[source.channelID] { keys[source.channelID] = SportsMatcher.matchupKey(title) }
                    }
                }
            }
            let saved = SavedSportsEvents(savedAt: Date(), events: games, feedKeys: keys, listings: listings)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// Last launch's games, checked: provider feeds must still show the
    /// same matchup (event slots get renamed through the day); until the
    /// channel list has loaded, only guide and network channels are kept.
    private func loadSavedSportsEvents() {
        guard !sportsPersistLoaded else { return }
        sportsPersistLoaded = true
        let file = Self.sportsCacheFile
        let rawEvents = events
        Task { [weak self] in
            let checked = await Task.detached(priority: .utility) { () -> (events: [SportsEvent], listings: [SportsMatcher.GuideListing], age: Int, dropped: Int)? in
                guard let data = try? Data(contentsOf: file),
                      let saved = try? JSONDecoder().decode(SavedSportsEvents.self, from: data), saved.version == 1 else { return nil }
                var current: [String: String] = [:]
                for event in rawEvents {
                    autoreleasepool {
                        let key = SportsMatcher.matchupKey(event.title)
                        for feed in event.feeds { current[feed] = key }
                    }
                }
                let now = Date()
                var dropped = 0
                let events: [SportsEvent] = saved.events.compactMap { event in
                    guard event.state(at: now) != .finished else { return nil }
                    var copy = event
                    copy.sources = event.sources.filter { source in
                        guard source.kind == .provider else { return true }
                        let keep = !rawEvents.isEmpty && current[source.channelID] != nil && current[source.channelID] == saved.feedKeys[source.channelID]
                        if !keep { dropped += 1 }
                        return keep
                    }
                    return copy
                }
                let listings = (saved.listings ?? []).filter { $0.end > now && $0.start < now.addingTimeInterval(16 * 3600) }
                return (events, listings, Int(now.timeIntervalSince(saved.savedAt) / 60), dropped)
            }.value
            guard let self, let checked, SportsData.isEnabled else { return }
            if self.sportsListings.isEmpty, !checked.listings.isEmpty {
                self.sportsListings = checked.listings
                self.sportsListingsRevision &+= 1
                self.scheduleSportsRebuild(delay: 0.3, reason: "saved listings")
            }
            // Only fills in when there's no matched result yet.
            guard !self.sportsEvents.contains(where: { $0.game != nil }) else { return }
            let resolvable = checked.events.map { event -> SportsEvent in
                guard !self.browseEntries.isEmpty else { return event }
                var copy = event
                copy.sources = event.sources.filter { self.sourceChannel($0) != nil }
                return copy
            }
            let savedIDs = Set(resolvable.map(\.id))
            self.setSportsEvents(resolvable + self.sportsEvents.filter { $0.game == nil && !savedIDs.contains($0.id) })
            CrashRecorder.note("sports saved result: \(resolvable.count) games, \(checked.listings.count) listings, "
                               + "\(checked.age) min old, \(checked.dropped) stale feeds dropped")
        }
    }

    func sourceChannel(_ source: EventSource) -> LiveTVChannel? {
        source.kind == .provider ? channel(id: source.channelID) : (entry(id: source.channelID) ?? channel(id: source.channelID))
    }

    private func quality(_ channel: LiveTVChannel) -> Int { traits[channel.id]?.quality ?? 0 }

    /// Provider feeds best first: quality, then how reliable their source has been.
    private func bestFeeds(_ feeds: [LiveTVChannel]) -> [LiveTVChannel] {
        let byQuality = feeds.enumerated().sorted { a, b in
            let qa = quality(a.element), qb = quality(b.element)
            return qa != qb ? qa > qb : a.offset < b.offset
        }.map(\.element)
        return orderedByReliability(byQuality)
    }

    /// Everything that can play an event, in order: the picked source (if
    /// any) first, then My Lineup / guide channels, then provider feeds.
    func eventCandidates(_ event: SportsEvent, preferring sourceID: String? = nil) -> [LiveTVChannel] {
        var list: [LiveTVChannel] = []
        func add(_ channels: [LiveTVChannel]) {
            for channel in channels where !list.contains(where: { $0.id == channel.id }) { list.append(channel) }
        }
        if let sourceID, let source = event.sources.first(where: { $0.channelID == sourceID }), let channel = sourceChannel(source) {
            add(source.kind == .provider ? [channel] : baseVersions(of: channel))
        }
        for source in event.channels where source.kind != .team {
            if let channel = sourceChannel(source) { add(baseVersions(of: channel)) }
        }
        add(bestFeeds(event.feeds.compactMap { channel(id: $0.channelID) }))
        // A team's own channel last: likely, not certain, to carry the game.
        for source in event.channels where source.kind == .team {
            if let channel = sourceChannel(source) { add(baseVersions(of: channel)) }
        }
        return list
    }

    /// An event shown as a channel (player, banner, tuning card).
    func displayChannel(for event: SportsEvent) -> LiveTVChannel {
        let first = eventCandidates(event).first
        return LiveTVChannel(
            id: event.id, serverID: first?.serverID ?? "", itemID: first?.itemID ?? "", name: event.title,
            number: nil, imageURL: nil, isFavorite: false, group: event.league, shortName: event.title
        )
    }

    func watchSportsEvent(_ event: SportsEvent, preferring sourceID: String? = nil) {
        let candidates = eventCandidates(event, preferring: sourceID)
        guard !candidates.isEmpty else {
            flash(L10n.string("live_event_no_source", fallback: "Nothing in your channels is showing this yet"))
            return
        }
        // Starting a guide channel: watch the channel itself (the game's
        // event feeds back it up through versions(of:)).
        if let sourceID, let source = event.sources.first(where: { $0.channelID == sourceID }), source.kind != .provider,
           let entry = entry(id: source.channelID) {
            watch(entry)
            watchingEventID = event.id
            watchingEvent = event
            return
        }
        let display = displayChannel(for: event)
        flipList = [display]
        surfStep = 0
        watchingEventID = event.id
        watchingEvent = event
        tune(display, candidates: candidates, from: 0, followFeed: false)
    }

    /// Try Again on a failed tune: the game again (with all its sources), or the channel.
    func retry(_ channel: LiveTVChannel) {
        if let event = watchingEvent, event.id == watchingEventID {
            watchSportsEvent(event)
        } else {
            watch(channel)
        }
    }

    /// Another game picked in the player (event guide or Up / Down).
    func switchToEvent(_ event: SportsEvent, preferring sourceID: String? = nil) {
        closeMiniGuide()
        guard isWatching else { return }
        // Nothing to play: say so and keep the game on screen.
        guard !eventCandidates(event, preferring: sourceID).isEmpty else {
            flash(L10n.string("live_event_no_source", fallback: "Nothing in your channels is showing this yet"))
            return
        }
        playerOnScreen = false
        playerMetaID = nil
        leavePlayer?()
        watchSportsEvent(event, preferring: sourceID)
    }

    /// Feeds of a game airing now on an entry, as extra backups for it.
    private func eventBackups(forEntry id: String) -> [LiveTVChannel] {
        guard let positions = sportsBackupIndex[id] else { return [] }
        let now = Date()
        for position in positions where position < sportsEvents.count {
            let event = sportsEvents[position]
            guard let start = event.start, start < now.addingTimeInterval(15 * 60) else { continue }
            let state = event.state(at: now)
            guard state == .live || state == .mayHaveEnded || state == .upcoming else { continue }
            return bestFeeds(event.feeds.compactMap { channel(id: $0.channelID) })
        }
        return []
    }

    /// What a reminder for an upcoming event points at: its best channel.
    func reminderTarget(for event: SportsEvent) -> (channel: LiveTVChannel, program: LiveTVProgram)? {
        guard let start = event.start,
              let source = event.channels.first ?? event.feeds.first, let channel = sourceChannel(source) else { return nil }
        let program = LiveTVProgram(
            id: event.id, channelID: channel.id, title: event.title, episodeTitle: nil, overview: nil,
            start: start, end: start.addingTimeInterval(event.expectedLength), isMovie: false, isSports: true,
            isNews: false, isKids: false, isLive: true, isPremiere: false, imageURL: nil
        )
        return (channel, program)
    }

    // MARK: Mini guide and previous channel

    /// The channels the player's mini guide lists: the list Up / Down surf.
    func miniGuideChannels() -> [LiveTVChannel] {
        flipList.isEmpty ? visibleEntries() : flipList
    }

    /// Left in the live player: the mini guide over the picture.
    func openMiniGuide() {
        guard isWatching, overlay == nil else { return }
        requestGuide(miniGuideChannels().prefix(300).map(\.id))
        LiveOverlayState.shared.miniGuideOpen = true
    }

    func closeMiniGuide() {
        LiveOverlayState.shared.miniGuideOpen = false
    }

    /// A channel picked in the mini guide; the surf list stays as it was.
    func watchFromMiniGuide(_ channel: LiveTVChannel) {
        closeMiniGuide()
        guard isWatching, channel.id != watching?.id else { return }
        switchInPlayer(to: channel)
    }

    /// Right in the live player: back to the previous channel.
    func goToPreviousChannel() {
        guard isWatching, overlay == nil, let target = previousChannel, target.id != watching?.id else { return }
        flash(L10n.format("live_back_to", fallback: "Back to %@", target.name))
        switchInPlayer(to: target)
    }

    private func switchInPlayer(to target: LiveTVChannel) {
        watchingEventID = nil
        playerOnScreen = false
        playerMetaID = nil
        leavePlayer?()
        surfStep = 0
        remember(target)
        tune(target, candidates: versions(of: target), from: 0, followFeed: false)
    }

    /// Leaving the player or the tuning card.
    func stopWatching() {
        LiveOverlayState.shared.miniGuideOpen = false
        watchingEventID = nil
        watchingEvent = nil
        // The provider may take a moment to let go of the stream: the guide
        // preview waits at least `previewMinGap` before opening another.
        lastPreviewOpen = Date()
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
        // The guide puts focus back on this channel (the last one surfed to).
        switch overlay {
        case .some(.tuning(let channel)), .some(.failed(let channel, _)): lastWatchedID = watching?.id ?? channel.id
        case .none: if let watching { lastWatchedID = watching.id }
        }
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
        stopPreview()
        // Don't keep a server stream (and the provider's single slot) busy
        // while the app is in the background, unless it's playing in PiP.
        guard isWatching || !openStreams.isEmpty,
              !PictureInPictureManager.shared.isPictureInPictureActive else { return }
        leavePlayer?()
        stopWatching()
    }

    // MARK: Sources panel (player)

    /// Marks a Live TV feed in the player's Sources panel. Never a real link:
    /// Xtream links carry the password, and Emby links only exist once open.
    nonisolated static let feedScheme = "nuvio-livefeed"

    /// Every version of what's playing, for the player's Sources panel (none
    /// while surfing an event family, whose feeds are different events).
    func playingFeedSources() -> [NuvioStream] {
        guard isWatching, surfStep == 0, candidates.count > 1 else { return [] }
        return candidates.map { feed in
            var parts: [String] = []
            if let trait = traits[feed.id] {
                let label = ["", "720p", "1080p", "4K"][max(0, min(3, trait.quality))]
                if !label.isEmpty { parts.append(label) }
                if trait.isWest { parts.append("West feed") }
            }
            if let group = feed.group { parts.append(group) }
            if feed.id == pinnedFeeds[watching?.id ?? ""] { parts.append("Always starts first") }
            return NuvioStream(
                url: Self.feedToken(feed.id), name: feed.name,
                description: parts.joined(separator: " · "),
                addonName: providerName(for: feed.serverID) ?? (feed.serverID.hasPrefix("xt:") ? "Xtream" : "Emby")
            )
        }
    }

    /// How many versions the Sources panel would list (0 when it has none).
    var playingFeedCount: Int {
        guard isWatching, surfStep == 0, candidates.count > 1 else { return 0 }
        return candidates.count
    }

    nonisolated static func feedToken(_ feedID: String) -> String {
        "\(feedScheme)://" + (feedID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? feedID)
    }

    /// The Sources-panel token of the version playing now.
    var playingFeedToken: String? {
        guard isWatching, candidateIndex < candidates.count else { return nil }
        return Self.feedToken(candidates[candidateIndex].id)
    }

    /// The viewer picked a version in the Sources panel: switch to it in the
    /// open player. Recovery then sticks with it (reconnects first) and only
    /// leaves it if it stops working altogether.
    func switchToFeed(token: String) {
        guard let display = watching,
              let index = candidates.firstIndex(where: { Self.feedToken($0.id) == token }) else { return }
        if index == candidateIndex, sawFirstFrame { return }
        let feed = candidates[index]
        manualFeedID = feed.id
        reconnectsOnFeed = 0
        startupRetries[feed.id] = 0
        announceBackup = false
        playbackNote = "Switching…"
        log("you picked", feed, detail: "version \(index + 1) of \(candidates.count)")
        tune(display, candidates: candidates, from: index, followFeed: false, inPlace: true, reason: "picked in Sources")
    }

    // MARK: Guide preview
    //
    // The guide's corner preview plays a channel's first version (the one
    // Watch would start with), with sound, once focus has rested on it: 2 s
    // for Xtream, 3 s for Emby (slower to open, and it ties up a tuner).
    // It shares the one stream slot with watching: Emby opens and closes go
    // through the same one-at-a-time queue, so the app never holds two server
    // streams; a preview is closed before any channel starts, and picking the
    // previewed channel hands its open Emby stream to the player. Opens are
    // at least `previewMinGap` apart, a failed preview is never retried, and
    // nothing previews while a channel, Multiview or the background is up.

    private static let previewKey = "nuvio.tv.livetv.guidePreview"
    private static let previewMinGap: TimeInterval = 3
    /// The screenshot tour has no real streams: Apple's public HLS sample.
    private static let previewDemoURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")

    static var guidePreviewEnabled: Bool {
        get { UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: previewKey) }
    }

    /// From the guide: preview this channel after a pause, or stop (nil).
    func requestPreview(_ channel: LiveTVChannel?) {
        guard let channel, Self.guidePreviewEnabled, !isWatching, overlay == nil,
              !MultiviewStore.shared.isPresented,
              UIApplication.shared.applicationState == .active else {
            stopPreview()
            return
        }
        guard previewChannelID != channel.id else { return }
        stopPreview()
        previewGeneration &+= 1
        let generation = previewGeneration
        previewChannelID = channel.id
        let demo = ScreenTour.isActive && !hasServers
        guard let feed = demo ? channel : versions(of: channel).first else { return }
        let isXtream = demo || feed.serverID.hasPrefix("xt:")
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isXtream ? 2_000_000_000 : 3_000_000_000)
            guard let self, !Task.isCancelled, generation == self.previewGeneration else { return }
            let gap = Self.previewMinGap - Date().timeIntervalSince(self.lastPreviewOpen)
            if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
            guard !Task.isCancelled, generation == self.previewGeneration, !self.isWatching else { return }
            self.enqueueStreamWork { [weak self] in
                guard let self, generation == self.previewGeneration, !self.isWatching else { return }
                await self.openPreview(feed, demo: demo, generation: generation)
            }
        }
    }

    /// Runs inside the stream queue.
    private func openPreview(_ feed: LiveTVChannel, demo: Bool, generation: Int) async {
        lastPreviewOpen = Date()
        if demo {
            guard let url = Self.previewDemoURL else { return }
            previewFeed = feed
            previewPlayer.play(url: url)
            return
        }
        if feed.serverID.hasPrefix("xt:") {
            guard let xtream = xtreamClient(for: feed.serverID),
                  let url = xtream.streamURL(streamID: feed.itemID, formats: xtreamFormats[feed.serverID] ?? [],
                                             preferTS: Self.xtreamPrefersTS) else { return }
            previewFeed = feed
            previewPlayer.play(url: url)
            return
        }
        guard let client = client(for: feed.serverID) else { return }
        await closeAllStreams()
        guard generation == previewGeneration, !isWatching else { return }
        do {
            // Not cancellable, like any Emby open: its id is needed to close it.
            let stream = try await client.openStream(channelItemID: feed.itemID)
            openStreams.append((stream, feed.serverID))
            guard generation == previewGeneration, !isWatching else {
                await closeAllStreams()
                return
            }
            previewFeed = feed
            previewStream = stream
            previewPlayer.play(url: stream.url)
            await client.reportPlaying(stream)
        } catch {
            // Not retried: a preview never opens more than it has to.
        }
    }

    /// Stops the preview now; its Emby stream (if any) is closed in turn.
    func stopPreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        if previewChannelID != nil { previewChannelID = nil }
        previewFeed = nil
        previewPlayer.stop()
        if previewStream != nil {
            previewStream = nil
            enqueueStreamWork { [weak self] in
                await self?.closeAllStreams()
            }
        }
    }

    func meta(for channel: LiveTVChannel, now: LiveTVProgram?) -> NuvioMeta {
        meta(for: channel, feed: channel, now: now)
    }

    func meta(for channel: LiveTVChannel, feed: LiveTVChannel, now: LiveTVProgram?) -> NuvioMeta {
        let description = [now?.title, now?.episodeTitle, now?.overview].compactMap { $0 }.joined(separator: "\n")
        // The curated logo (see ChannelLogos) for the player's loading and
        // pause screens; the provider's when there's none.
        let logo = logoSpec(for: channel).urls.first ?? channel.imageURL
        return NuvioMeta(
            // "live:xt:<account>:<stream>" for Xtream, "live:jf:<server>:<item>"
            // for Emby / Jellyfin (which Multiview leaves out: one stream).
            id: feed.serverID.hasPrefix("xt:") ? "live:\(feed.serverID):\(feed.itemID)" : "live:jf:\(feed.serverID):\(feed.itemID)",
            name: channel.name,
            description: description.isEmpty ? nil : description,
            posterUrl: channel.imageURL?.absoluteString,
            backgroundUrl: now?.imageURL?.absoluteString,
            logoUrl: logo?.absoluteString,
            type: "livetv"
        )
    }

    private func showBanner(for channel: LiveTVChannel) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.watching?.id == channel.id else { return }
            self.banner = Banner(channel: channel, now: self.current(on: channel.id), next: self.next(on: channel.id),
                                 previous: self.previousChannel)
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
        scheduleRebuild()
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
        let annotated = LiveTVWork.annotated(demo)
        applyNow(channels: annotated, catalog: ChannelCatalog.build(annotated))
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
        let annotated = LiveTVWork.annotated(demo)
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
        applyNow(channels: annotated, catalog: catalog)
        if configureLineup {
            prefs.suggested = Set(entryInfo.values.filter {
                LineupEngine.suggests($0, prefs: prefs, hasGuide: entryHasGuide($0.id), name: $0.name)
            }.map(\.id))
            rebuildEntriesNow()
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
        let annotated = LiveTVWork.annotated(demo)
        applyNow(channels: annotated, catalog: ChannelCatalog.build(annotated))
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

/// Maps a game's TV networks to the viewer's channels. Pure, runs off the
/// main thread.
enum SportsNetworkMap {

    /// Short names used in TV listings for networks, as the channel is named.
    private static let networkAliases: [String: String] = [
        "nfl net": "NFL Network", "nfl netwrk": "NFL Network", "mlb net": "MLB Network", "nhl net": "NHL Network",
        "usa net": "USA Network", "usa": "USA Network", "cbssn": "CBS Sports Network", "btn": "Big Ten Network",
        "secn": "SEC Network", "accn": "ACC Network", "espnews": "ESPNews", "golf": "Golf Channel"
    ]
    private static let broadcastNetworks: Set<String> = ["ABC", "CBS", "NBC", "FOX", "CW", "TELEMUNDO", "UNIVISION", "UNIMAS"]

    /// Your channels by what they carry: "core:FS1", "net:FOX", "rsn:fd-sun",
    /// "call:KJZZ", "team:NBA|14". Built once per channel list (off the
    /// main thread) and reused by every rebuild.
    struct ChannelIndex {
        struct Item {
            let id: String
            let inLineup: Bool
            let spanish: Bool
            /// `LiveTVStore.StationRank`.
            let rank: Int
        }
        var byKey: [String: [Item]] = [:]
        var regional = 0
        var callsigns = 0
        var teamChannels = 0
        var fightChannels = 0

        var summary: String {
            "\(byKey.count) keys, \(regional) regional, \(callsigns) stations by call sign, \(teamChannels) team channels, "
                + "\(fightChannels) fight card channels"
        }
    }

    /// "core:FS1" / "net:FOX" / "rsn:…" / "call:…" for a network name in the
    /// schedule, or nil (streaming services).
    private static func networkKey(_ name: String) -> String? {
        if let sign = RegionalNetworks.stationBrand(name) { return "call:\(sign)" }
        let key = ChannelCatalog.coreKey(name).key
        if let alias = networkAliases[key] { return "core:\(alias)" }
        if let core = ChannelCatalog.coreMatch(name) { return "core:\(core.name)" }
        let word = key.replacingOccurrences(of: " ", with: "").uppercased()
        if broadcastNetworks.contains(word) { return "net:\(word)" }
        if let regional = RegionalNetworks.key(name) { return "rsn:\(regional)" }
        if let sign = RegionalNetworks.callsign(name) { return "call:\(sign)" }
        return nil
    }

    /// - Parameter all: every entry; sports channels of unknown country
    ///   ("UFC PPV Main Card") count too, though they're not in the browse
    ///   list (that only has your chosen countries').
    static func channelIndex(lineup: Set<String>, lineupEntries: [LiveTVChannel], browse: [LiveTVChannel],
                             all: [LiveTVChannel] = [],
                             entryInfo: [String: LiveTVEntryInfo], hidden: Set<String>,
                             rosters: [SportsMatcher.RosterLeague], markets: LiveTVStore.StationMarkets) -> ChannelIndex {
        var index = ChannelIndex()
        // Team channels ("NBA Miami Heat", "Atlanta Falcons", "Spectrum
        // SportsNet Lakers"): pro and soccer teams, one team named.
        var teamLists: [(short: String, index: SportsMatcher.TeamIndex)] = []
        for roster in rosters where !roster.college {
            teamLists.append((roster.short, SportsMatcher.TeamIndex(teams: roster.teams, college: false)))
        }
        var seen = Set<String>()
        for (pass, list) in [lineupEntries, browse, all].enumerated() {
          for entry in list {
            autoreleasepool {
                guard seen.insert(entry.id).inserted, let info = entryInfo[entry.id],
                      !hidden.contains(entry.group ?? "Other"), info.kind == .channel else { return }
                // From the full list, only sports channels of unknown country.
                if pass == 2, info.market != nil || info.category != .sports { return }
                let spanish = info.category == .spanish || info.market == "US-ES"
                let inLineup = lineup.contains(entry.id)
                let item = ChannelIndex.Item(id: entry.id, inLineup: inLineup, spanish: spanish,
                                             rank: LiveTVStore.stationRank(info, markets: markets, inLineup: inLineup))
                func add(_ key: String) { index.byKey[key, default: []].append(item) }
                if let core = info.core {
                    add("core:\(core)")
                    return
                }
                guard info.category == .sports || info.category == .local || info.category == .spanish else { return }
                if info.category == .local, let word = ChannelCatalog.networkWord(info.name) { add("net:\(word)") }
                if let regional = RegionalNetworks.key(info.name) {
                    add("rsn:\(regional)")
                    index.regional += 1
                }
                if info.category == .local,
                   let sign = info.callsign.flatMap({ RegionalNetworks.callsign($0) }) ?? RegionalNetworks.callsignInName(info.name) {
                    add("call:\(sign)")
                    index.callsigns += 1
                }
                // A promotion's own channel for a part of its cards ("UFC PPV
                // Main Card", "UFC PPV Prelims"): no event number in the name.
                if info.category == .sports, RX.test("^ (ppv )?(ufc|pfl|bkfc) ", SportsMatcher.normalized(info.name)),
                   let key = SportsMatcher.fightKey(info.name), key.number.isEmpty, let part = key.part {
                    add("card:\(key.org)|\(part)")
                    index.fightChannels += 1
                }
                if info.category == .sports {
                    var named: [String] = []
                    for list in teamLists {
                        if let team = list.index.single(info.name, leagueWord: list.short) { named.append("team:\(list.short)|\(team.id)") }
                    }
                    if named.count == 1, let key = named.first {
                        add(key)
                        index.teamChannels += 1
                    }
                }
            }
          }
        }
        return index
    }

    /// For each game, the channels you have airing its networks (national,
    /// regional, local station) and its teams' own channels: My Lineup
    /// first, then the rest of your channels (two at most of each). Pure, so
    /// it runs off the main thread.
    static func networkSources(for games: [SportsGame], index: ChannelIndex) -> (sources: [String: [EventSource]], stats: SourceStats) {
        var stats = SourceStats()
        guard !games.isEmpty, !index.byKey.isEmpty else { return ([:], stats) }
        var keys: [String: String?] = [:]
        func cachedKey(_ network: String) -> String? {
            if let cached = keys[network] { return cached }
            let value = networkKey(network)
            keys[network] = value
            return value
        }
        // Broadcast networks split some games by region (several NFL games
        // on FOX at 1 PM): those only count when a guide listing confirms
        // which one your station has.
        var byNetwork: [String: [Date]] = [:]
        for game in games where !game.completed {
            if let network = game.networks.first, let key = cachedKey(network), key.hasPrefix("net:") {
                byNetwork[key, default: []].append(game.start)
            }
        }
        var result: [String: [EventSource]] = [:]
        for game in games where !game.completed {
            var sources: [EventSource] = []
            /// Best first (My Lineup, home market, your markets, elsewhere);
            /// `nearby` keeps only your own markets' stations (three at most),
            /// otherwise two.
            func take(_ entries: [ChannelIndex.Item], nearby: Bool, kind: (Bool) -> EventSource.Kind, detail: (ChannelIndex.Item) -> String) {
                let ranked = entries.filter { !nearby || $0.rank <= LiveTVStore.StationRank.market }.sorted { $0.rank < $1.rank }
                for item in ranked.prefix(nearby ? 3 : 2) where !sources.contains(where: { $0.channelID == item.id }) {
                    sources.append(EventSource(channelID: item.id, kind: kind(item.inLineup), spanish: item.spanish,
                                               detail: detail(item), rank: item.rank))
                }
            }
            func stationDetail(_ item: ChannelIndex.Item) -> String {
                LiveTVStore.stationDetail(item.rank)
            }
            for network in game.networks {
                guard let key = cachedKey(network) else {
                    stats.unknown[network, default: 0] += 1
                    continue
                }
                guard let entries = index.byKey[key] else {
                    stats.missing[network, default: 0] += 1
                    continue
                }
                if key.hasPrefix("net:") {
                    // Several games on the network at once (regional coverage):
                    // only a station's guide can say which one it has.
                    if (byNetwork[key] ?? []).filter({ abs($0.timeIntervalSince(game.start)) < 90 * 60 }).count > 1 {
                        stats.split += 1
                        continue
                    }
                    // A national game: your own markets' stations.
                    take(entries, nearby: true, kind: { $0 ? .lineup : .guide }, detail: stationDetail)
                    stats.national += 1
                } else {
                    // A network or station that is the broadcast itself (ESPN,
                    // FanDuel Sun, KJZZ): wherever it is.
                    take(entries, nearby: false, kind: { $0 ? .lineup : .guide }, detail: stationDetail)
                    if key.hasPrefix("rsn:") { stats.regional += 1 } else if key.hasPrefix("call:") { stats.station += 1 } else { stats.national += 1 }
                }
            }
            for team in [game.home, game.away] {
                guard let entries = index.byKey["team:\(game.leagueShort)|\(team.id)"] else { continue }
                take(entries, nearby: false, kind: { _ in .team }, detail: { $0.inLineup ? "Team channel · In My Lineup" : "Team channel" })
                stats.team += 1
            }
            // A numbered card's part on the promotion's own channel for it.
            if let card = game.cardKey?.components(separatedBy: "|"), card.count == 3, !card[1].isEmpty,
               let entries = index.byKey["card:\(card[0])|\(card[2].isEmpty ? "main" : card[2])"] {
                take(entries, nearby: false, kind: { _ in .team }, detail: { $0.inLineup ? "Fight channel · In My Lineup" : "Fight channel" })
                stats.fightCards += 1
            }
            if !sources.isEmpty { result[game.id] = sources }
        }
        return (result, stats)
    }

    /// What the schedule's broadcaster names found among your channels.
    struct SourceStats {
        var national = 0
        var regional = 0
        var station = 0
        var team = 0
        var fightCards = 0
        var split = 0
        /// Broadcaster names that aren't a known network or station.
        var unknown: [String: Int] = [:]
        /// Known networks none of your channels carry.
        var missing: [String: Int] = [:]

        var summary: String {
            func top(_ counts: [String: Int]) -> String {
                counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12)
                    .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            }
            return "\(national) national, \(regional) regional, \(station) by call sign, \(team) team channel links, \(fightCards) fight card channel links, "
                + "\(split) regional splits waiting for the guide; not in your channels: [\(top(missing))]; unknown names: [\(top(unknown))]"
        }
    }
}

/// Regional sports networks under their many names: the schedule writes
/// "FDSN Sun" or "NBCS-BA"; channel lists write "FanDuel Sports Sun",
/// "BALLY SPORTS SUN (MIAMI) HD" or the older "FOX SPORTS SUN HD". All map
/// to one key.
enum RegionalNetworks {
    /// Regions of the FanDuel (formerly Bally, formerly FOX Sports) networks,
    /// longest first so "southeast" wins over "south".
    private static let fanDuelRegions: [(words: [String], key: String)] = [
        (["southeast", "se"], "southeast"), (["southwest", "sw"], "southwest"), (["sun"], "sun"),
        (["carolinas", "carolina"], "carolinas"),
        (["prime ticket"], "primeticket"), (["socal", "west"], "socal"), (["san diego"], "sandiego"),
        (["new orleans"], "neworleans"), (["kansas city", "kc"], "kansascity"), (["great lakes"], "greatlakes"),
        (["florida", "fl"], "florida"), (["detroit"], "detroit"), (["north"], "north"), (["ohio"], "ohio"),
        (["midwest"], "midwest"), (["oklahoma"], "oklahoma"), (["wisconsin"], "wisconsin"), (["indiana"], "indiana"),
        (["arizona"], "arizona"), (["cincinnati"], "cincinnati"),
        (["tennessee"], "south"), (["south"], "south"),
    ]

    /// Other regional networks: any of the phrases → key.
    private static let others: [(phrases: [String], key: String)] = [
        (["nbcs ba", "nbcsba", "nbc sports bay area", "nbcs bay area"], "nbcs-ba"),
        (["nbcs ca", "nbcsca", "nbc sports california", "nbcs california"], "nbcs-ca"),
        (["nbcs ph", "nbcsp", "nbc sports philadelphia", "nbcs philadelphia", "nbcs philly"], "nbcs-ph"),
        (["nbcs bos", "nbc sports boston", "nbcs boston"], "nbcs-bos"),
        (["msg2", "msg 2", "msg plus", "msg+"], "msg2"),
        (["msg sportsnet", "msg sn", "msg network", "msg"], "msg"),
        (["yes network", "yes hd", "dazn yes"], "yes"),
        (["nesn"], "nesn"), (["sny"], "sny"), (["marquee sports"], "marquee"),
        (["altitude"], "altitude"),
        (["monumental", "mnmt"], "monumental"),
        (["space city", "schn"], "spacecity"),
        (["sportsnet la", "spectrum sportsnet la", "snla"], "snla"),
        (["spectrum sportsnet", "spectrum sn"], "spectrum"),
        (["root sports", "root sports northwest"], "root"),
        (["sportsnet pittsburgh", "sportsnet pit", "att sportsnet pittsburgh", "at t sportsnet pittsburgh"], "snp"),
        (["att sportsnet rocky mountain", "at t sportsnet rocky mountain", "root sports rocky mountain"], "rockymountain"),
        (["chsn", "chicago sports network"], "chsn"),
        (["gulf coast sports", "gcsen"], "gcsen"),
        (["mlb tv"], ""),
    ]

    static func key(_ name: String) -> String? {
        let text = " " + name.lowercased().replacingOccurrences(of: "&", with: "")
            .map { $0.isLetter || $0.isNumber || $0 == "+" ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ") + " "
        return keyNormalized(text.replacingOccurrences(of: " sports net ", with: " sportsnet "))
    }

    /// `text`: lowercased words between spaces (" spectrum sportsnet ").
    private static func keyNormalized(_ text: String) -> String? {
        // Bare names as the schedule writes them.
        if text == " yes " { return "yes" }
        if text == " marquee " { return "marquee" }
        // Provider names mix the two LA networks up: the team decides.
        if text.contains(" sportsnet ") || text.contains(" spectrum ") {
            if text.contains(" dodgers ") { return "snla" }
            if text.contains(" lakers ") { return "spectrum" }
        }
        if text.contains(" fdsn ") || text.contains(" fanduel ") || text.contains(" bally ")
            || text.contains(" fox sports ") || text.contains(" fsn ") || text.contains(" fanduel sn ") {
            for region in fanDuelRegions where region.words.contains(where: { text.contains(" \($0) ") }) {
                return "fd-\(region.key)"
            }
            return nil
        }
        for item in others where item.phrases.contains(where: { text.contains(" \($0) ") }) {
            return item.key.isEmpty ? nil : item.key
        }
        return nil
    }

    private static let notCallsigns: Set<String> = [
        "WITH", "WORLD", "WEST", "WILD", "KIDS", "KING", "WHO", "WEB", "KISS", "WOW", "WAR", "WIRE", "WINE", "WORK",
        "WOMAN", "WOMEN", "WHL", "WDR", "WOR", "KBS", "WEEK", "KNOW", "WALK", "WORD", "WAVE", "WARM", "WALL", "WIND", "WISE",
    ]

    private static func group(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        guard let regex = RX.get(pattern, caseInsensitive: caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// A station's call sign written in its channel name: "(KTVU)",
    /// "(PBS WKYU)", "SALT LAKE CITY, UT KJZZ IND 14", "IND KFAA".
    static func callsignInName(_ name: String) -> String? {
        if let sign = group("\\((?:[A-Za-z]+\\s+)?([KW][A-Z]{2,3})(?:[- ](?:TV|DT|LD|CD|CA|D\\d))?\\s*\\)", in: name) { return sign }
        // After a state code: "UT KJZZ".
        if let sign = group("\\b[A-Z]{2}\\s+([KW][A-Z]{2,3})\\b", in: name) { return sign }
        if let sign = group("(?:^|[\\s:])([KW][A-Z]{2,3})(?=\\s|$|-(?:TV|DT|LD|CD))", in: name), !notCallsigns.contains(sign) { return sign }
        return nil
    }

    /// "KJZZ" from "KJZZ", "KJZZ-TV", "kjzz-dt" or "KUNP 16" (with its
    /// channel number): a station call sign.
    static func callsign(_ name: String) -> String? {
        let upper = name.uppercased().trimmingCharacters(in: .whitespaces)
        guard let range = RX.range("^[KW][A-Z]{2,3}(?=$|[- ](?:TV|DT|LD|CD|CA)$|[- ](?:TV |DT )?\\d{1,2}$)", in: upper) else { return nil }
        let sign = String(upper[range])
        // "WEST 2" is a word and a number, not a station ("KING 5" is one).
        if upper.last?.isNumber == true, sign != "KING", notCallsigns.contains(sign) { return nil }
        return sign
    }

    /// Stations the schedule names by their brand instead of a call sign.
    private static let stationBrands: [String: String] = [
        "arizonasfamilycbs5": "KPHO", "azfamilycbs5": "KPHO", "arizonasfamily3tv": "KTVK", "azfamily3tv": "KTVK",
    ]

    /// "KPHO" for "Arizona's Family CBS5".
    static func stationBrand(_ name: String) -> String? {
        stationBrands[String(name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })]
    }
}
