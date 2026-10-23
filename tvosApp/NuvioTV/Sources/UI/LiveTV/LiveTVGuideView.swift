import SwiftUI
import AetherEngine

enum LiveGuideMetrics {
    /// Extra side margin inside tvOS's own 80 pt safe area (none: the guide
    /// uses the full safe width).
    static let sideInset: CGFloat = 0
    static let channelColumn: CGFloat = 190
    static let rowHeight: CGFloat = 84
    static let rowSpacing: CGFloat = 8
    static let cellGap: CGFloat = 8
    static let heroHeight: CGFloat = 270
    static let previewWidth: CGFloat = 400
    static let windowMinutes = 180
}

/// Which entries the guide lists.
enum LiveView: Equatable {
    case lineup
    case all
    case favorites
    case recent
    case group(String)

    var title: String {
        switch self {
        case .lineup: return L10n.string("live_view_lineup", fallback: "My Lineup")
        case .all: return L10n.string("live_view_all", fallback: "All Channels")
        case .favorites: return L10n.string("live_filter_favorites", fallback: "Favorites")
        case .recent: return L10n.string("live_filter_recent", fallback: "Recent")
        case .group(let name): return name
        }
    }
}

/// What's on now, from the guide's program tags (with the channel's own
/// kind standing in when the program isn't tagged).
enum LiveNowGenre: String, CaseIterable, Identifiable {
    case sports, news, movies, kids
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sports: return L10n.string("live_now_sports", fallback: "Sports on now")
        case .news: return L10n.string("live_now_news", fallback: "News on now")
        case .movies: return L10n.string("live_now_movies", fallback: "Movies on now")
        case .kids: return L10n.string("live_now_kids", fallback: "Kids on now")
        }
    }

    var symbol: String {
        switch self {
        case .sports: return "sportscourt"
        case .news: return "newspaper"
        case .movies: return "film"
        case .kids: return "figure.and.child.holdinghands"
        }
    }

    /// The channel kind that counts when a program carries no tags.
    var category: LineupCategory {
        switch self {
        case .sports: return .sports
        case .news: return .news
        case .movies: return .movies
        case .kids: return .kids
        }
    }

    func tagged(_ program: LiveTVProgram) -> Bool {
        switch self {
        case .sports: return program.isSports
        case .news: return program.isNews
        case .movies: return program.isMovie
        case .kids: return program.isKids
        }
    }
}

/// The guide's genre filter: a kind of channel, or what's on now.
enum LiveGenre: Hashable, Identifiable {
    case channels(LineupCategory)
    case onNow(LiveNowGenre)

    var id: String {
        switch self {
        case .channels(let category): return "c:" + category.rawValue
        case .onNow(let kind): return "n:" + kind.rawValue
        }
    }

    var title: String {
        switch self {
        case .channels(let category): return category.genreTitle
        case .onNow(let kind): return kind.title
        }
    }

    var needsPrograms: Bool {
        if case .onNow = self { return true }
        return false
    }
}

extension LineupCategory {
    /// Short name for the genre filter.
    var genreTitle: String {
        switch self {
        case .local: return "Local"
        case .news: return "News"
        case .sports: return "Sports"
        case .entertainment: return "Entertainment"
        case .movies: return "Movies & Premium"
        case .kids: return "Kids & Family"
        case .music: return "Music"
        case .spanish: return "Spanish"
        case .free: return "Free Streaming"
        case .international: return "International"
        case .radio: return "Radio"
        }
    }

    var genreSymbol: String {
        switch self {
        case .local: return "antenna.radiowaves.left.and.right"
        case .news: return "newspaper"
        case .sports: return "sportscourt"
        case .entertainment: return "tv"
        case .movies: return "film"
        case .kids: return "figure.and.child.holdinghands"
        case .music: return "music.note"
        case .spanish: return "globe.americas"
        case .free: return "play.tv"
        case .international: return "globe"
        case .radio: return "radio"
        }
    }
}

/// A guide row, or the header that starts a neighborhood.
enum LiveGuideItem: Identifiable {
    case header(String, Int)
    case row(LiveGuideRow)

    var id: String {
        switch self {
        case .header(let title, let index): return "h|\(index)|" + title
        case .row(let row): return row.id
        }
    }
}

/// Rows of the guide, worked out once per change (not on every redraw).
final class LiveRowsMemo {
    var key = ""
    var rows: [LiveGuideRow] = []
}

/// A row in the guide; hidden rows (not in My Lineup) show dimmed when
/// "Show hidden channels" is on.
struct LiveGuideRow: Identifiable {
    let channel: LiveTVChannel
    let dimmed: Bool
    var id: String { channel.id }
}

/// Picks one version of a channel, or one feed of an event family.
struct LiveFeedPicker: Identifiable {
    let id = UUID()
    let title: String
    let channel: LiveTVChannel?
    let family: EventFamily?
}

/// Live TV guide for the channels on the user's Emby / Jellyfin server: My
/// Lineup (or all channels), real guide times with a now line, Live Events,
/// search, and long press for lineup, favorites and feed choice.
struct LiveTVGuideView: View {
    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var multiview = MultiviewStore.shared
    @ObservedObject private var preview = LiveTVStore.shared.previewPlayer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage("nuvio.tv.livetv.setupOffered") private var setupOffered = false
    @FocusState private var focusedCell: String?
    /// Neighborhood rail: Left from a row's first show opens it.
    @State private var railOpen = false
    @State private var railOrigin: LineupCategory?
    @State private var railReturnKey: String?
    @FocusState private var railFocus: LineupCategory?
    @State private var focusedChannel: LiveTVChannel?
    @State private var focusedProgram: LiveTVProgram?
    @State private var chosenView: LiveView?
    @State private var genre: LiveGenre?
    @State private var showingEvents = false
    @State private var showSearch = false
    /// The Filter or Options panel over the guide's right side.
    @State private var panel: LivePanelKind?
    @AppStorage(LiveTabsSetting.allChannelsKey) private var allChannelsTab = -1
    @FocusState private var barFocus: String?
    @State private var genreCounts: (channels: [LineupCategory: Int], now: [LiveNowGenre: Int])?
    @State private var rowsMemo = LiveRowsMemo()
    @State private var showSetup = false
    @State private var feedPicker: LiveFeedPicker?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var currentView: LiveView {
        chosenView ?? (store.prefs.configured || !showsAllTab ? .lineup : .all)
    }

    private var showsAllTab: Bool {
        LiveTabsSetting.showsAllChannels(allChannelsTab, configured: store.prefs.configured)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            switch store.state {
            case .loaded:
                content
            case .idle, .loading:
                statusView(symbol: "antenna.radiowaves.left.and.right", title: L10n.string("live_loading", fallback: "Loading your channels…"), message: nil, showsProgress: true, showsRetry: false)
            case .empty(let message):
                statusView(symbol: "antenna.radiowaves.left.and.right", title: L10n.string("live_none", fallback: "No live channels yet"), message: message, showsProgress: false, showsRetry: store.hasServers)
            case .failed(let message):
                statusView(symbol: "exclamationmark.triangle", title: L10n.string("live_failed", fallback: "Couldn't load Live TV"), message: message, showsProgress: false, showsRetry: true)
            }
            if ScreenTour.isMockLiveTV, !store.loadLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(store.loadLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 17, weight: .medium).monospacedDigit()).foregroundColor(.white)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(40)
                .allowsHitTesting(false)
            }
            if let toast = store.toast, !store.isWatching {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 50)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
            if let panel {
                Group {
                    switch panel {
                    case .filter:
                        filterPanel
                    case .options:
                        LiveTVOptionsPanel(
                            onSetup: {
                                closePanel()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSetup = true }
                            },
                            onClose: { closePanel() }
                        )
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        .animation(.easeOut(duration: 0.22), value: panel)
        .onChange(of: showsAllTab) { _, shows in
            // Turning the tab off while on it lands on My Lineup.
            guard !shows else { return }
            switch currentView {
            case .all, .group: chosenView = .lineup
            default: break
            }
        }
        .onAppear {
            now = Date()
            store.loadIfNeeded()
            runScreenTourHooks()
        }
        .onChange(of: previewTarget, initial: true) { _, target in
            store.requestPreview(target.isEmpty ? nil : (store.entry(id: target) ?? focusedChannel))
        }
        .onDisappear {
            store.requestPreview(nil)
        }
        .onReceive(ticker) { date in
            now = date
            store.refreshGuideIfNeeded()
        }
        .onChange(of: store.state) { _, newState in
            // Offer setup once, the first time channels load.
            guard newState == .loaded, !store.prefs.configured, !setupOffered, !ScreenTour.isActive else { return }
            setupOffered = true
            showSetup = true
        }
        .onChange(of: store.entriesRevision) { _, _ in
            // Keep the genre picker's counts current while it's open.
            if panel == .filter { genreCounts = countGenres() }
        }
        .onChange(of: genre) { _, newGenre in
            // "On now" filtering needs guide data for the whole list.
            guard newGenre?.needsPrograms == true else { return }
            store.requestGuide(baseRows.prefix(1500).map(\.channel.id))
        }
        .fullScreenCover(isPresented: $showSearch) {
            LiveTVSearchView(
                initialQuery: ScreenTour.requested == "live-demo-search" ? "sports" : "",
                onWatch: { channel, lineup in
                    showSearch = false
                    store.watch(channel, lineup: lineup)
                },
                onWatchEvent: { event in
                    showSearch = false
                    store.watchEvent(event)
                }
            )
        }
        .fullScreenCover(isPresented: $showSetup) {
            LineupSetupView { showSetup = false; chosenView = nil }
        }
        .sheet(item: $feedPicker) { picker in
            LiveFeedPickerView(picker: picker) { feedPicker = nil }
        }
    }

    /// The provider guide's progress while it builds (and its result during
    /// the screenshot tour).
    private var providerGuideLine: String? {
        for state in store.providerStates.values.sorted(by: { $0.name < $1.name }) {
            switch state.status {
            case .updating(let line):
                return line
            case .ready(let matched, let total, _, _) where ScreenTour.isActive:
                return "Provider guide: \(matched) of \(total) channels"
            case .unavailable(let message) where ScreenTour.isActive, .failed(let message) where ScreenTour.isActive:
                return "Provider guide: \(message)"
            default:
                continue
            }
        }
        return nil
    }

    private func runScreenTourHooks() {
        guard let request = ScreenTour.requested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            switch request {
            case "live-demo-search": showSearch = true
            case "live-demo-groups": panel = .filter
            case "live-demo-sources": panel = .options
            case "live-demo-events": showingEvents = true
            case "live-demo-all": chosenView = .all
            case "live-demo-setup": showSetup = true
            case "live-demo-genres":
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { genreCounts = countGenres(); panel = .filter }
            default: break
            }
        }
    }

    // MARK: Status

    private func statusView(symbol: String, title: String, message: String?, showsProgress: Bool, showsRetry: Bool) -> some View {
        VStack(spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: 70, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text(title)
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
            if let message {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            if showsProgress { ProgressView().tint(.white) }
            if showsRetry {
                Button {
                    store.loadIfNeeded(force: true)
                } label: {
                    Text(L10n.string("live_retry", fallback: "Try Again"))
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.horizontal, 30)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    // MARK: Rows

    private var windowStart: Date { LiveTVStore.windowStart(for: now) }

    /// Rows for the current view, before the genre filter.
    private var baseRows: [LiveGuideRow] {
        // "Show hidden channels" gave way to the All Channels tab setting.
        let showHidden = false
        switch currentView {
        case .lineup:
            guard showHidden else { return store.lineupEntries.map { LiveGuideRow(channel: $0, dimmed: false) } }
            // Hidden channels in their neighborhoods, between the lineup's.
            return store.browseEntries.map { LiveGuideRow(channel: $0, dimmed: !store.isInLineup($0)) }
        case .all:
            return store.browseEntries.compactMap { entry in
                let hidden = store.isHidden(entry)
                if hidden && !showHidden { return nil }
                return LiveGuideRow(channel: entry, dimmed: hidden)
            }
        case .favorites:
            return store.entries.filter(\.isFavorite).map { LiveGuideRow(channel: $0, dimmed: false) }
        case .recent:
            return store.recentChannels.map { LiveGuideRow(channel: $0, dimmed: false) }
        case .group(let name):
            return store.browseEntries.filter { store.groupName(of: $0) == name }.map { LiveGuideRow(channel: $0, dimmed: false) }
        }
    }

    private var rows: [LiveGuideRow] {
        var key = "\(currentView)|\(genre?.id ?? "")|\(store.entriesRevision)|\(store.hiddenGroups.hashValue)"
        if currentView == .recent { key += "|\(store.recentIDs.hashValue)" }
        if genre?.needsPrograms == true {
            key += "|\(store.programsRevision)|\(Int(now.timeIntervalSince1970 / 60))"
        }
        if key == rowsMemo.key { return rowsMemo.rows }
        let base = baseRows
        let value: [LiveGuideRow]
        switch genre {
        case nil:
            value = base
        case .channels(let category)?:
            value = base.filter { store.category(of: $0.channel.id) == category }
        case .onNow(let kind)?:
            value = base.filter { matchesNow($0.channel.id, kind) }
        }
        rowsMemo.key = key
        rowsMemo.rows = value
        return value
    }

    /// On now (or starting within half an hour): a program tagged with the
    /// genre, or an untagged one on a channel of that kind.
    private func matchesNow(_ id: String, _ kind: LiveNowGenre) -> Bool {
        let soon = now.addingTimeInterval(30 * 60)
        let program = (store.programs[id] ?? []).first { $0.end > now && $0.start < soon }
        if let program, program.isMovie || program.isSports || program.isNews || program.isKids {
            return kind.tagged(program)
        }
        return store.category(of: id) == kind.category
    }

    /// Counts for the genre picker, from the current view's rows.
    private func countGenres() -> (channels: [LineupCategory: Int], now: [LiveNowGenre: Int]) {
        var channels: [LineupCategory: Int] = [:]
        var current: [LiveNowGenre: Int] = [:]
        for row in baseRows {
            if let category = store.category(of: row.channel.id) { channels[category, default: 0] += 1 }
            for kind in LiveNowGenre.allCases where matchesNow(row.channel.id, kind) { current[kind, default: 0] += 1 }
        }
        return (channels, current)
    }

    private var emptyMessage: String {
        if genre != nil { return L10n.string("live_filter_empty", fallback: "Nothing on that matches this filter right now.") }
        switch currentView {
        case .lineup: return L10n.string("live_lineup_empty", fallback: "My Lineup is empty. Open Options → Edit My Lineup, or hold Select on any channel in All Channels to add it.")
        case .favorites: return L10n.string("live_favorites_empty", fallback: "No favorites yet. Hold Select on a channel and choose Add to Favorites.")
        case .recent: return L10n.string("live_recent_empty", fallback: "Channels you watch will show up here.")
        default: return L10n.string("live_filter_empty", fallback: "Nothing on that matches this filter right now.")
        }
    }

    // MARK: Layout

    private var content: some View {
        GeometryReader { proxy in
            let gridWidth = max(600, proxy.size.width - LiveGuideMetrics.sideInset * 2 - LiveGuideMetrics.channelColumn)
            let ppm = gridWidth / CGFloat(LiveGuideMetrics.windowMinutes)
            VStack(alignment: .leading, spacing: 0) {
                if showingEvents {
                    eventsHeader
                    tabBar.padding(.bottom, 16)
                    LiveEventsView(onPickFamily: { family in
                        feedPicker = LiveFeedPicker(title: family.name, channel: nil, family: family)
                    })
                } else {
                    hero.frame(width: max(0, proxy.size.width - LiveGuideMetrics.sideInset * 2), height: LiveGuideMetrics.heroHeight).clipped()
                    tabBar.padding(.bottom, 14)
                    if !store.prefs.configured {
                        setupPrompt.padding(.bottom, 14)
                    }
                    timeRuler(gridWidth: gridWidth, ppm: ppm).padding(.bottom, 8)
                    guideList(gridWidth: gridWidth, ppm: ppm)
                }
            }
            .padding(.horizontal, LiveGuideMetrics.sideInset)
            .frame(width: proxy.size.width, alignment: .leading)
            .disabled(panel != nil)
            .overlay(alignment: .topLeading) {
                if !showingEvents, !railOpen {
                    nowLine(gridWidth: gridWidth, ppm: ppm, height: proxy.size.height)
                }
            }
        }
    }

    private func guideList(gridWidth: CGFloat, ppm: CGFloat) -> some View {
        let list = rows
        let items = guideItems(list)
        return ScrollViewReader { scroller in
            ZStack(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: LiveGuideMetrics.rowSpacing) {
                        if list.isEmpty {
                            Text(emptyMessage)
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.vertical, 40)
                        }
                        ForEach(items) { item in
                            switch item {
                            case .header(let title, _):
                                neighborhoodHeader(title)
                            case .row(let row):
                                guideRow(row, list: list, gridWidth: gridWidth, ppm: ppm)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }
                .mask(Rectangle().padding(.horizontal, -60).padding(.bottom, -200))
                .disabled(railOpen)
                .overlay(Color.black.opacity(railOpen ? 0.5 : 0).allowsHitTesting(false))
                .focusSection()
                if railOpen {
                    neighborhoodRail(neighborhoods(items), list: list, ppm: ppm, scroller: scroller)
                        .padding(.leading, -16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: railOpen)
            .onChange(of: store.isWatching) { _, watching in
                guard !watching else { return }
                returnFocus(list: list, ppm: ppm, scroller: scroller)
            }
            .onChange(of: focusedCell) { old, new in
                channelColumnFocused(old: old, new: new, list: list, items: items, ppm: ppm)
            }
            .onChange(of: railFocus) { old, new in
                if let new, let hood = neighborhoods(items).first(where: { $0.category == new }) {
                    // The guide follows the rail, so you see where you'll land.
                    scroller.scrollTo(hood.headerID, anchor: .top)
                } else if old != nil, new == nil, railOpen {
                    // Focus left the rail (Left to the app menu, Up to the filters).
                    railOpen = false
                }
            }
        }
    }

    // MARK: Neighborhood rail
    //
    // Left from a row's first show focuses that row's channel cell, which
    // opens the rail on the row's neighborhood instead. Up / Down move
    // through the neighborhoods (the guide scrolls along behind it), Right or
    // Select lands on the first channel of the highlighted one, Back returns
    // to where you were. Left again goes on to the app menu. Channel cells
    // are only a way into the rail: reached any other way (Down from the
    // filters), focus moves on to the row's current show.

    struct Neighborhood: Identifiable {
        let category: LineupCategory
        let headerID: String
        let firstRow: LiveGuideRow
        var count: Int
        var id: String { category.rawValue }
    }

    /// The neighborhoods in the current view, in guide order.
    private func neighborhoods(_ items: [LiveGuideItem]) -> [Neighborhood] {
        var result: [Neighborhood] = []
        var indexOf: [LineupCategory: Int] = [:]
        var pendingHeader: String?
        for item in items {
            switch item {
            case .header:
                pendingHeader = item.id
            case .row(let row):
                guard let category = store.category(of: row.channel.id) else { continue }
                if let index = indexOf[category] {
                    result[index].count += 1
                } else if let header = pendingHeader {
                    indexOf[category] = result.count
                    result.append(Neighborhood(category: category, headerID: header, firstRow: row, count: 1))
                }
                pendingHeader = nil
            }
        }
        return result
    }

    /// The cell to focus on a channel's row: what's on now, else its first
    /// show, else its "no guide" cell.
    private func nowKey(for channel: LiveTVChannel, ppm: CGFloat) -> String {
        let programs = segments(for: channel, ppm: ppm).compactMap { part -> LiveTVProgram? in
            if case .program(let program, _, _) = part { return program }
            return nil
        }
        if let program = programs.first(where: { $0.isOn(at: Date()) }) ?? programs.first {
            return "\(channel.id)#\(program.id)"
        }
        return "\(channel.id)#none"
    }

    /// Focus moves to `key` once the grid can take it (it's disabled while
    /// the rail is open), checked again a moment later.
    private func focusGrid(_ key: String) {
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !railOpen, !store.isWatching, focusedCell != key else { return }
                focusedCell = key
            }
        }
    }

    private func channelColumnFocused(old: String?, new: String?, list: [LiveGuideRow], items: [LiveGuideItem], ppm: CGFloat) {
        guard let new, new.hasSuffix("#ch") else { return }
        let id = String(new.dropLast(3))
        guard let row = list.first(where: { $0.channel.id == id }) else { return }
        let fromRow = old.map { $0.hasPrefix(id + "#") && !$0.hasSuffix("#ch") } ?? false
        if fromRow, let old, let category = store.category(of: id),
           neighborhoods(items).contains(where: { $0.category == category }) {
            railReturnKey = old
            railOrigin = category
            railOpen = true
            railFocus = category
            DispatchQueue.main.async { if railOpen { railFocus = category } }
        } else {
            let key = fromRow ? (old ?? nowKey(for: row.channel, ppm: ppm)) : nowKey(for: row.channel, ppm: ppm)
            DispatchQueue.main.async { focusedCell = key }
        }
    }

    private func closeRail(landingOn hood: Neighborhood, ppm: CGFloat, scroller: ScrollViewProxy) {
        railOpen = false
        scroller.scrollTo(hood.headerID, anchor: .top)
        focusGrid(nowKey(for: hood.firstRow.channel, ppm: ppm))
    }

    private func cancelRail(scroller: ScrollViewProxy) {
        railOpen = false
        guard let key = railReturnKey, let hash = key.lastIndex(of: "#") else { return }
        scroller.scrollTo(String(key[..<hash]), anchor: .center)
        focusGrid(key)
    }

    private func neighborhoodRail(_ hoods: [Neighborhood], list: [LiveGuideRow], ppm: CGFloat, scroller: ScrollViewProxy) -> some View {
        let buttons = VStack(alignment: .leading, spacing: 8) {
            ForEach(hoods) { hood in
                railButton(hood, ppm: ppm, scroller: scroller)
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            LiveSectionLabel(text: L10n.string("live_jump_to", fallback: "Jump to"))
                .padding(.leading, 22)
            ViewThatFits(in: .vertical) {
                buttons
                ScrollView(.vertical, showsIndicators: false) { buttons.padding(.vertical, 6) }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 14)
        .padding(.horizontal, 12)
        .frame(width: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 8, y: 8)
        )
        .focusSection()
        .onExitCommand { cancelRail(scroller: scroller) }
    }

    private func railButton(_ hood: Neighborhood, ppm: CGFloat, scroller: ScrollViewProxy) -> some View {
        let focused = railFocus == hood.category
        return Button {
            closeRail(landingOn: hood, ppm: ppm, scroller: scroller)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(LiveStyle.watching)
                    .frame(width: 9, height: 9)
                    .opacity(hood.category == railOrigin && !focused ? 1 : 0)
                Text(hood.category.genreTitle)
                    .font(LiveStyle.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Text("\(hood.count)")
                    .font(LiveStyle.rowValue.monospacedDigit())
                    .opacity(0.6)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused))
        .focused($railFocus, equals: hood.category)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .right { closeRail(landingOn: hood, ppm: ppm, scroller: scroller) }
        }
    }

    /// Back from the player: scroll to the channel that was on screen and
    /// focus what's on it now, instead of letting focus land at the top.
    /// The player is still fading out at first, so focus is set once it's
    /// gone and checked again a moment later.
    private func returnFocus(list: [LiveGuideRow], ppm: CGFloat, scroller: ScrollViewProxy) {
        guard let id = store.lastWatchedID, let row = list.first(where: { $0.channel.id == id }) else { return }
        let key = nowKey(for: row.channel, ppm: ppm)
        scroller.scrollTo(row.id, anchor: .center)
        for delay in [0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !store.isWatching, focusedCell != key else { return }
                scroller.scrollTo(row.id, anchor: .center)
                focusedCell = key
            }
        }
    }

    /// Rows with a header where each neighborhood starts (Local, News,
    /// Sports…). Recent keeps its own order and has none.
    private func guideItems(_ list: [LiveGuideRow]) -> [LiveGuideItem] {
        guard currentView != .recent else { return list.map(LiveGuideItem.row) }
        var items: [LiveGuideItem] = []
        items.reserveCapacity(list.count + 12)
        var last: LineupCategory?
        for row in list {
            let category = store.category(of: row.channel.id)
            if let category, category != last {
                items.append(.header(category.genreTitle.uppercased(), items.count))
                last = category
            }
            items.append(.row(row))
        }
        return items
    }

    private func neighborhoodHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .heavy))
            .tracking(1.4)
            .foregroundColor(.white.opacity(0.5))
            .padding(.leading, 14)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var setupPrompt: some View {
        HStack(spacing: 20) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("live_setup_prompt_title", fallback: "Make Live TV yours"))
                    .font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Text(L10n.format("live_setup_prompt_detail", fallback: "Set up My Lineup: your local stations and the networks you watch, one entry each, instead of %d channels.", store.channels.count))
                    .font(.system(size: 20)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            SourceModeChip(title: L10n.string("live_setup_prompt_button", fallback: "Set Up My Lineup"), isSelected: true) {
                showSetup = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.08)))
        .focusSection()
    }

    // MARK: Hero

    private var heroChannel: LiveTVChannel? { focusedChannel ?? rows.first?.channel }

    /// The small label over the hero: the channel's neighborhood (the tab
    /// already says which view this is).
    private var heroNeighborhood: String {
        heroChannel.flatMap { store.category(of: $0.id)?.genreTitle } ?? currentView.title
    }

    private var heroProgram: LiveTVProgram? {
        if let focusedProgram { return focusedProgram }
        guard let channel = heroChannel else { return nil }
        return store.current(on: channel.id, at: now)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 30) {
            heroInfo
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            VStack(alignment: .trailing, spacing: 8) {
                Text(ChannelsView.clockFormatter.string(from: now))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                previewWindow
            }
            .padding(.top, 4)
        }
    }

    private var heroInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(heroNeighborhood)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                if store.isLoadingGuide { ProgressView().tint(.white).scaleEffect(0.7) }
                if let line = providerGuideLine {
                    Text(line)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                } else if case .updating(let line) = store.outsideStatus {
                    Text(line)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                } else if case .ready(let matched, let total, _) = store.outsideStatus, ScreenTour.isActive {
                    Text("Outside listings: \(matched) of \(total) channels")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                } else if case .failed(let message) = store.outsideStatus, ScreenTour.isActive {
                    Text(message).font(.system(size: 16)).foregroundColor(.red.opacity(0.8)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let channel = heroChannel {
                HStack(spacing: 12) {
                    logo(channel, size: 30)
                    Text(channel.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if channel.isFavorite { Image(systemName: "star.fill").foregroundColor(.yellow) }
                    let versions = store.versions(of: channel).count
                    if versions > 1 {
                        Text(L10n.format("live_versions", fallback: "%d feeds", versions))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            if let program = heroProgram {
                Text(program.title)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    if program.isOn(at: now) { badge(L10n.string("live_badge_live", fallback: "LIVE"), color: Color(red: 1, green: 0.3, blue: 0.3)) }
                    if program.isPremiere { badge(L10n.string("live_badge_new", fallback: "NEW"), color: .blue) }
                    Text(timeRange(program))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                    if program.fromOutsideGuide {
                        Text(L10n.string("live_outside_badge", fallback: "OUTSIDE LISTING"))
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.6)
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    }
                    if let episode = program.episodeTitle {
                        Text("· \(episode)")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                if program.isOn(at: now) {
                    progressBar(program).frame(width: 420, height: 6)
                }
                if let overview = program.overview {
                    Text(overview)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .frame(maxWidth: 1200, alignment: .leading)
                }
            } else if heroChannel != nil {
                Text(L10n.string("live_no_guide", fallback: "No guide information"))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Preview window

    /// The guide's corner preview: the focused channel's logo, then (after
    /// focus rests on it) its live picture with sound. LiveTVStore owns the
    /// stream; see "Guide preview" there.
    private var previewWindow: some View {
        let width = LiveGuideMetrics.previewWidth
        let height = width * 9 / 16
        let channel = heroChannel
        let isThisChannel = channel != nil && store.previewChannelID == channel?.id
        let showsVideo = isThisChannel && preview.hasPicture
        return ZStack {
            Color.black
            logo(channel, size: 70)
                .opacity(showsVideo ? 0 : 0.9)
            if isThisChannel, let engine = preview.engine {
                MultiviewEngineSurface(engine: engine)
                    .id(ObjectIdentifier(engine))
                    .opacity(showsVideo ? 1 : 0)
            }
            VStack {
                HStack(spacing: 8) {
                    if showsVideo {
                        Text(L10n.string("live_preview_badge", fallback: "LIVE"))
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.8)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.3, blue: 0.3)))
                    } else if isThisChannel, preview.isActive, !preview.failed {
                        ProgressView().tint(.white).scaleEffect(0.6)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: showsVideo)
        .allowsHitTesting(false)
    }

    /// What the preview should follow: the focused channel while focus is in
    /// the grid and nothing covers the guide; "" means no preview.
    private var previewTarget: String {
        if ScreenTour.requested == "live-demo-preview" { return rows.first?.channel.id ?? "" }
        guard focusedCell != nil, let channel = focusedChannel, !showingEvents, !showSearch, !showSetup,
              panel == nil, feedPicker == nil, !store.isWatching, store.overlay == nil,
              !multiview.isPresented, scenePhase == .active else { return "" }
        return channel.id
    }

    private var eventsHeader: some View {
        HStack(spacing: 14) {
            Text(L10n.string("live_events_title", fallback: "Live Events"))
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.format("live_events_count", fallback: "%d events", store.events.count))
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(ChannelsView.clockFormatter.string(from: now))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    private func logo(_ channel: LiveTVChannel?, size: CGFloat) -> some View {
        ChannelLogoView(urls: store.logoSpec(for: channel).urls, width: size * 2.2, height: size) {
            Image(systemName: "tv").font(.system(size: size * 0.5)).foregroundColor(.white.opacity(0.4))
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .heavy))
            .tracking(0.8)
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }

    private func progressBar(_ program: LiveTVProgram) -> some View {
        let total = program.end.timeIntervalSince(program.start)
        let fraction = total > 0 ? min(1, max(0, now.timeIntervalSince(program.start) / total)) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
            }
        }
    }

    private func timeRange(_ program: LiveTVProgram) -> String {
        let f = ChannelsView.clockFormatter
        return "\(f.string(from: program.start))–\(f.string(from: program.end))"
    }

    // MARK: Filters

    // MARK: Tabs

    private var tabs: [LiveTab] {
        [.lineup, .favorites, .recent, .events] + (showsAllTab ? [.all] : [])
    }

    private var currentTab: LiveTab {
        if showingEvents { return .events }
        switch currentView {
        case .lineup: return .lineup
        case .favorites: return .favorites
        case .recent: return .recent
        case .all, .group: return .all
        }
    }

    /// Moving across the tabs only highlights them; Select switches.
    private func selectTab(_ tab: LiveTab) {
        guard tab != currentTab || (tab == .all && currentView != .all) else { return }
        genre = nil
        switch tab {
        case .events:
            showingEvents = true
        case .lineup: showingEvents = false; chosenView = .lineup
        case .favorites: showingEvents = false; chosenView = .favorites
        case .recent: showingEvents = false; chosenView = .recent
        case .all: showingEvents = false; chosenView = .all
        }
    }

    /// What the filter chip says: the genre, or the provider group.
    private var filterTitle: String? {
        if showingEvents { return nil }
        if let genre { return genre.title }
        if case .group(let name) = currentView { return name }
        return nil
    }

    private func clearFilter() {
        genre = nil
        if case .group = currentView { chosenView = .all }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(tabs, id: \.self) { tab in
                LiveTabButton(title: tab.title, selected: tab == currentTab) { selectTab(tab) }
            }
            Spacer(minLength: 20)
            if !multiview.channels.isEmpty {
                SourceModeChip(
                    title: L10n.format("live_open_multiview", fallback: "Multiview (%d)", multiview.channels.count),
                    isSelected: false
                ) {
                    multiview.isPresented = true
                }
            }
            if let filterTitle {
                LiveFilterChip(title: filterTitle) { clearFilter() }
            }
            LiveIconButton(symbol: "magnifyingglass", focus: $barFocus, id: "search") { showSearch = true }
            if !showingEvents {
                LiveIconButton(symbol: "line.3.horizontal.decrease", dot: filterTitle != nil, focus: $barFocus, id: "filter") {
                    openPanel(.filter)
                }
            }
            LiveIconButton(symbol: "gearshape", focus: $barFocus, id: "options") { openPanel(.options) }
        }
        .frame(height: 60)
        .focusSection()
    }

    // MARK: Panels

    private func openPanel(_ kind: LivePanelKind) {
        if kind == .filter { genreCounts = countGenres() }
        panel = kind
    }

    /// Closes the panel and puts focus back on the icon that opened it.
    private func closePanel() {
        let opened = panel
        panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            barFocus = opened == .options ? "options" : "filter"
        }
    }

    private var filterPanel: some View {
        let counts = genreCounts ?? ([:], [:])
        let total = baseRows.count
        let isGroup: Bool = { if case .group = currentView { return true }; return false }()
        return LiveSidePanel(edge: .trailing, width: 760) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    LiveSectionLabel(text: L10n.string("live_filter", fallback: "Filter") + "  ·  " + currentTab.title)
                        .padding(.leading, 4)
                        .padding(.bottom, 10)
                    LivePanelRow(title: L10n.string("live_filter_all", fallback: "All channels"),
                                 accessory: .countChecked(total, genre == nil && !isGroup)) {
                        genre = nil
                        if isGroup { chosenView = .all }
                        closePanel()
                    }
                    panelSection(L10n.string("live_genre_now", fallback: "On now"))
                    ForEach(LiveNowGenre.allCases) { kind in
                        LivePanelRow(title: kind.title, accessory: .countChecked(counts.now[kind] ?? 0, genre == .onNow(kind)),
                                     dot: LiveStyle.watching) {
                            genre = .onNow(kind)
                            closePanel()
                        }
                    }
                    let categories = LineupCategory.allCases.filter { (counts.channels[$0] ?? 0) > 0 }
                    if !categories.isEmpty {
                        panelSection(L10n.string("live_neighborhoods", fallback: "Neighborhoods"))
                        ForEach(categories) { category in
                            LivePanelRow(title: category.genreTitle,
                                         accessory: .countChecked(counts.channels[category] ?? 0, genre == .channels(category))) {
                                genre = .channels(category)
                                closePanel()
                            }
                        }
                    }
                    if currentTab == .all, !store.groups.isEmpty {
                        panelSection(L10n.format("live_groups_count", fallback: "Provider groups (%d)", store.groups.count))
                        ForEach(store.groups) { group in
                            LivePanelRow(title: group.name, accessory: .countChecked(group.count, currentView == .group(group.name))) {
                                genre = nil
                                chosenView = .group(group.name)
                                closePanel()
                            }
                        }
                    }
                }
                .padding(.top, 50)
                .padding(.bottom, 60)
                .padding(.trailing, 70)
            }
            .focusSection()
        }
        .onExitCommand { closePanel() }
    }

    private func panelSection(_ title: String) -> some View {
        LiveSectionLabel(text: title)
            .padding(.top, 22)
            .padding(.bottom, 6)
            .padding(.leading, 4)
    }

    // MARK: Time ruler

    private func timeRuler(gridWidth: CGFloat, ppm: CGFloat) -> some View {
        let marks = stride(from: 0, to: LiveGuideMetrics.windowMinutes, by: 30).map { $0 }
        return HStack(spacing: 0) {
            Text(Self.dayFormatter.string(from: now).uppercased())
                .font(.system(size: 18, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.5))
                .frame(width: LiveGuideMetrics.channelColumn, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).offset(y: 18)
                ForEach(marks, id: \.self) { minutes in
                    Text(ChannelsView.clockFormatter.string(from: windowStart.addingTimeInterval(TimeInterval(minutes * 60))))
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.6))
                        .offset(x: CGFloat(minutes) * ppm + 6)
                }
            }
            .frame(width: gridWidth, height: 40, alignment: .leading)
            .clipped()
        }
    }

    /// Red line at the current time, drawn over the ruler and the grid.
    private func nowLine(gridWidth: CGFloat, ppm: CGFloat, height: CGFloat) -> some View {
        let minutes = now.timeIntervalSince(windowStart) / 60
        let x = LiveGuideMetrics.sideInset + LiveGuideMetrics.channelColumn + CGFloat(minutes) * ppm
        let top = LiveGuideMetrics.heroHeight + 74 + 20 + (store.prefs.configured ? 0 : 98)
        return Rectangle()
            .fill(Color(red: 1, green: 0.32, blue: 0.32))
            .frame(width: 3, height: max(0, height - top))
            .offset(x: x, y: top)
            .allowsHitTesting(false)
    }

    // MARK: Guide rows

    private enum Segment {
        case program(LiveTVProgram, width: CGFloat, startsEarlier: Bool)
        case gap(width: CGFloat)
    }

    private func segments(for channel: LiveTVChannel, ppm: CGFloat) -> [Segment] {
        let start = windowStart
        let end = start.addingTimeInterval(TimeInterval(LiveGuideMetrics.windowMinutes * 60))
        var cursor = start
        var result: [Segment] = []
        for program in store.programs[channel.id] ?? [] {
            guard program.end > cursor else { continue }
            guard program.start < end else { break }
            let from = max(program.start, cursor)
            if from > cursor {
                result.append(.gap(width: CGFloat(from.timeIntervalSince(cursor) / 60) * ppm))
            }
            let to = min(program.end, end)
            let width = CGFloat(to.timeIntervalSince(from) / 60) * ppm
            if width < 40 {
                // Too thin to read or focus: leave it as space.
                result.append(.gap(width: width))
            } else {
                result.append(.program(program, width: width, startsEarlier: program.start < start))
            }
            cursor = to
        }
        return result
    }

    private func guideRow(_ row: LiveGuideRow, list: [LiveGuideRow], gridWidth: CGFloat, ppm: CGFloat) -> some View {
        let channel = row.channel
        let parts = segments(for: channel, ppm: ppm)
        let isRowFocused = focusedChannel?.id == channel.id && focusedCell != nil
        let lineup = list.map(\.channel)
        return HStack(spacing: 0) {
            channelCell(channel, dimmed: row.dimmed, isRowFocused: isRowFocused)
                .frame(width: LiveGuideMetrics.channelColumn, height: LiveGuideMetrics.rowHeight)
            HStack(spacing: 0) {
                if parts.contains(where: { if case .program = $0 { return true }; return false }) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .gap(let width):
                            Color.clear.frame(width: width)
                        case .program(let program, let width, let earlier):
                            programCell(program, channel: channel, lineup: lineup, width: width, startsEarlier: earlier)
                        }
                    }
                } else {
                    noGuideCell(channel, lineup: lineup, width: gridWidth)
                }
            }
            .frame(width: gridWidth, height: LiveGuideMetrics.rowHeight, alignment: .leading)
            .clipped()
        }
        .opacity(row.dimmed && !isRowFocused ? 0.45 : 1)
        .onAppear { store.requestGuide([channel.id]) }
    }

    private func channelCell(_ channel: LiveTVChannel, dimmed: Bool, isRowFocused: Bool) -> some View {
        LiveChannelCell(channel: channel, spec: store.logoSpec(for: channel), focused: isRowFocused, dimmed: dimmed)
            // Focusable only as the way into the neighborhood rail.
            .focusable(!railOpen && currentView != .recent)
            .focused($focusedCell, equals: "\(channel.id)#ch")
            .focusEffectDisabledIfAvailable()
            .padding(.trailing, LiveGuideMetrics.cellGap)
    }

    private func programCell(_ program: LiveTVProgram, channel: LiveTVChannel, lineup: [LiveTVChannel], width: CGFloat, startsEarlier: Bool) -> some View {
        let key = "\(channel.id)#\(program.id)"
        let isFocused = focusedCell == key
        let isNow = program.isOn(at: now)
        let cellWidth = max(4, width - LiveGuideMetrics.cellGap)
        return Button {
            store.watch(channel, lineup: lineup)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if cellWidth >= 110 {
                    HStack(spacing: 6) {
                        if startsEarlier {
                            Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)).opacity(0.6)
                        }
                        Text(program.title)
                            .font(.system(size: 21, weight: .bold))
                            .lineLimit(1)
                    }
                    Text(program.episodeTitle ?? timeRange(program))
                        .font(.system(size: 17, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, cellWidth > 60 ? 14 : 4)
            .frame(width: cellWidth, height: LiveGuideMetrics.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(isNow ? 0.15 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? 3 : 0)
            )
            .scaleEffect(isFocused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedCell, equals: key)
        .focusEffectDisabledIfAvailable()
        .contextMenu { menu(for: channel, lineup: lineup) }
        .onChange(of: focusedCell == key) { _, focused in
            guard focused else { return }
            focusedChannel = channel
            focusedProgram = program
        }
        .padding(.trailing, LiveGuideMetrics.cellGap)
    }

    private func noGuideText(for channel: LiveTVChannel) -> String {
        switch store.guideState[channel.id] {
        case .loading, nil: return L10n.string("live_guide_loading", fallback: "Live · Loading guide…")
        case .failed: return L10n.string("live_guide_failed", fallback: "Live · Guide didn't load")
        case .loaded: return L10n.string("live_guide_none", fallback: "Live · No guide info")
        }
    }

    private func noGuideCell(_ channel: LiveTVChannel, lineup: [LiveTVChannel], width: CGFloat) -> some View {
        let key = "\(channel.id)#none"
        let isFocused = focusedCell == key
        return Button {
            store.watch(channel, lineup: lineup)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Color(red: 1, green: 0.32, blue: 0.32)).frame(width: 9, height: 9)
                Text(noGuideText(for: channel))
                    .font(.system(size: 20, weight: .semibold))
                if store.guideState[channel.id] == .loading {
                    ProgressView().scaleEffect(0.6)
                }
                Spacer()
            }
            .foregroundColor(isFocused ? .black : .white.opacity(0.75))
            .padding(.horizontal, 16)
            .frame(width: width - LiveGuideMetrics.cellGap, height: LiveGuideMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedCell, equals: key)
        .focusEffectDisabledIfAvailable()
        .contextMenu { menu(for: channel, lineup: lineup) }
        .onChange(of: focusedCell == key) { _, focused in
            guard focused else { return }
            focusedChannel = channel
            focusedProgram = nil
        }
    }

    @ViewBuilder
    private func menu(for channel: LiveTVChannel, lineup: [LiveTVChannel]) -> some View {
        Button {
            store.watch(channel, lineup: lineup)
        } label: {
            Label(L10n.string("live_watch", fallback: "Watch"), systemImage: "play.fill")
        }
        if store.isInLineup(channel) {
            Button {
                store.setInLineup(channel, false)
            } label: {
                Label(L10n.string("live_lineup_remove", fallback: "Remove from My Lineup"), systemImage: "minus.circle")
            }
        } else {
            Button {
                store.setInLineup(channel, true)
            } label: {
                Label(L10n.string("live_lineup_add", fallback: "Add to My Lineup"), systemImage: "plus.circle")
            }
        }
        if store.versions(of: channel).count > 1 {
            Button {
                feedPicker = LiveFeedPicker(title: channel.name, channel: channel, family: nil)
            } label: {
                Label(L10n.format("live_choose_feed", fallback: "Choose Feed (%d)", store.versions(of: channel).count), systemImage: "list.bullet")
            }
        }
        Button {
            store.toggleFavorite(channel)
        } label: {
            Label(
                channel.isFavorite
                    ? L10n.string("live_unfavorite", fallback: "Remove from Favorites")
                    : L10n.string("live_favorite", fallback: "Add to Favorites"),
                systemImage: channel.isFavorite ? "star.slash" : "star"
            )
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}

// MARK: - Tuning card, info banner and notices

/// Mounted at the app root next to the Channels overlay: the card shown while
/// a live channel opens (or fails), the info bar after it starts, and short
/// notices ("Switched to a backup feed") over the player.
struct LiveTVOverlay: View {
    @ObservedObject private var store = LiveTVStore.shared
    @FocusState private var buttonFocused: Bool

    var body: some View {
        ZStack {
            if let overlay = store.overlay {
                card(overlay)
                    .transition(.opacity)
                    .onAppear { DispatchQueue.main.async { buttonFocused = true } }
            } else if let banner = store.banner {
                bannerView(banner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if store.isWatching, store.overlay == nil, let note = store.playbackNote {
                // Recovery in progress: a small note, never a full screen and
                // never focusable, so the remote keeps working.
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            ProgressView().tint(.white).scaleEffect(0.8)
                            Text(note)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                    }
                    .padding(.top, 50)
                    .padding(.trailing, 60)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if store.isWatching, store.overlay == nil, let toast = store.toast {
                VStack {
                    Text(toast)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.top, 50)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.overlay)
        .animation(.easeInOut(duration: 0.25), value: store.playbackNote)
        .animation(.easeInOut(duration: 0.35), value: store.banner)
        .animation(.easeInOut(duration: 0.25), value: store.toast)
    }

    private func card(_ overlay: LiveTVStore.Overlay) -> some View {
        let channel: LiveTVChannel
        let message: String?
        switch overlay {
        case .tuning(let c): channel = c; message = nil
        case .failed(let c, let m): channel = c; message = m
        }
        let program = store.current(on: channel.id)
        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                ChannelLogoView(urls: store.logoSpec(for: channel).urls, width: 300, height: 110, alignment: .leading)
                HStack(spacing: 14) {
                    Text(channel.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Text(message == nil
                     ? L10n.string("channels_tuning", fallback: "TUNING IN")
                     : L10n.string("live_cant_play", fallback: "CAN'T PLAY THIS CHANNEL"))
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.55))
                if let program {
                    Text(program.title)
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                if let message {
                    Text(message)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: 1100, alignment: .leading)
                } else {
                    ProgressView().tint(.white).padding(.top, 6)
                }
                HStack(spacing: 20) {
                    if message != nil {
                        Button {
                            store.watch(channel)
                        } label: {
                            Text(L10n.string("live_retry", fallback: "Try Again"))
                                .font(.system(size: 26, weight: .semibold))
                                .padding(.horizontal, 24)
                        }
                    }
                    Button {
                        store.stopWatching()
                    } label: {
                        Text(L10n.string("channels_back_to_guide", fallback: "Back to Guide"))
                            .font(.system(size: 26, weight: .semibold))
                            .padding(.horizontal, 24)
                    }
                    .focused($buttonFocused)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .focusSection()
        .onExitCommand { store.stopWatching() }
    }

    private func bannerView(_ banner: LiveTVStore.Banner) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .center, spacing: 28) {
                Text("LIVE")
                    .font(.system(size: 34, weight: .heavy).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(minWidth: 110)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(banner.channel.name.uppercased())
                        .font(.system(size: 17, weight: .heavy))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                    Text(banner.now?.title ?? banner.channel.name)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let now = banner.now {
                        Text("\(ChannelsView.clockFormatter.string(from: now.start))–\(ChannelsView.clockFormatter.string(from: now.end))" + (now.episodeTitle.map { " · \($0)" } ?? ""))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 20)
                if let next = banner.next {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(L10n.string("channels_next", fallback: "NEXT") + " · " + ChannelsView.clockFormatter.string(from: next.start))
                            .font(.system(size: 17, weight: .heavy))
                            .tracking(1)
                            .foregroundColor(.white.opacity(0.55))
                        Text(next.title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 520, alignment: .trailing)
                }
                VStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                    Text(L10n.string("channels_ch", fallback: "CH")).font(.system(size: 15, weight: .heavy))
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.45)))
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
    }
}
