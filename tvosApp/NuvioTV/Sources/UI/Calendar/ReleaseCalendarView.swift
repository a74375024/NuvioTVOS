import SwiftUI

/// An episode the Calendar asks the app to play.
struct CalendarPlayRequest {
    let showID: String
    let showType: String
    let season: Int
    let episode: Int
    let released: String?
}

private enum CalendarMetrics {
    static let panelHeight: CGFloat = 320
    static let cardWidth: CGFloat = 384
    static let cardHeight: CGFloat = 216
    static let cardGap: CGFloat = 36
    static let backdropWidth: CGFloat = 1240
}

/// Which shows feed the calendar.
enum CalendarShowFilter: String, CaseIterable {
    case all
    case library
    case watching

    var title: String {
        switch self {
        case .all: return L10n.string("calendar_filter_all", fallback: "All Shows")
        case .library: return L10n.string("calendar_filter_library", fallback: "Library")
        case .watching: return L10n.string("calendar_filter_watching", fallback: "Watching")
        }
    }

    func includes(_ event: CalendarEvent) -> Bool {
        switch self {
        case .all: return true
        case .library: return event.sources.contains(.library)
        case .watching: return event.sources.contains(.watching)
        }
    }
}

/// A show with new episodes to watch: one card per show, however many
/// episodes came out.
private struct NewShowItem: Identifiable {
    let showID: String
    let showType: String
    let showName: String
    /// The event holding the next unwatched new episode (artwork, synopsis).
    let event: CalendarEvent
    /// The next unwatched new episode, and the newest one.
    let season: Int
    let episode: Int
    let lastSeason: Int
    let lastEpisode: Int
    let newCount: Int
    let latestDay: Date
    /// How far into the next episode the viewer got (0…1), if they started it.
    let progress: Double?

    var id: String { "n|" + showID }
    var availabilityKey: String {
        ReleaseCalendarStore.availabilityKey(showID: showID, season: season, episode: episode)
    }
}

private struct UpcomingSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let events: [CalendarEvent]
}

private struct CalendarModel {
    var newItems: [NewShowItem] = []
    var sections: [UpcomingSection] = []

    var firstCardID: String? { newItems.first?.id ?? sections.first?.events.first.map { "u|" + $0.id } }
}

/// Builds the Calendar's rows from the store's events and your watched
/// history (one history read per show per build), only when one of them
/// changes or an episode's air time passes.
@MainActor
private final class CalendarScreenModel: ObservableObject {
    @Published private(set) var model = CalendarModel()
    /// When the next episode airs (it moves from Coming Up to New).
    private var nextBoundary: Date?
    private var builtDay: Date?
    private var stale = true

    func markStale() { stale = true }

    func isDue(at date: Date) -> Bool {
        if stale { return true }
        if let builtDay, Calendar.current.startOfDay(for: date) != builtDay { return true }
        return nextBoundary.map { date >= $0 } ?? false
    }

    private struct Pending {
        let event: CalendarEvent
        let season: Int
        let episode: Int
    }

    func rebuild(events allEvents: [CalendarEvent], filter: CalendarShowFilter, now: Date, reason: String) {
        let started = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let events = allEvents.filter { filter.includes($0) }

        func aired(_ event: CalendarEvent) -> Bool {
            if event.day < today { return true }
            guard event.day == today else { return false }
            // Date-only listings count as out on the day.
            return event.airTime.map { $0 <= now } ?? true
        }

        // New for You: unwatched aired episodes, grouped per show.
        var watchedByShow: [String: Set<String>] = [:]
        var pendingByShow: [String: [Pending]] = [:]
        for event in events where aired(event) {
            let numbers = event.kind == .seasonDrop
                ? Array(event.episode..<(event.episode + max(1, event.episodeCount)))
                : [event.episode]
            let watched: Set<String>
            if let known = watchedByShow[event.showID] {
                watched = known
            } else {
                watched = WatchedStore.watchedEpisodeKeys(metaId: event.showID)
                watchedByShow[event.showID] = watched
            }
            for number in numbers where !watched.contains("\(event.season):\(number)") {
                pendingByShow[event.showID, default: []].append(Pending(event: event, season: event.season, episode: number))
            }
        }
        var started_: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingStore.items() {
            guard let season = item.season, let episode = item.episode else { continue }
            let key = "\(item.meta.id):\(season):\(episode)"
            if started_[key] == nil { started_[key] = item }
        }
        var newItems: [NewShowItem] = []
        for (showID, pending) in pendingByShow {
            let ordered = pending.sorted { $0.season != $1.season ? $0.season < $1.season : $0.episode < $1.episode }
            guard let next = ordered.first, let last = ordered.last else { continue }
            var progress: Double?
            if let item = started_["\(showID):\(next.season):\(next.episode)"], item.isUpNext != true,
               item.duration > 0, item.position > 0 {
                progress = min(1, item.position / item.duration)
            }
            newItems.append(NewShowItem(
                showID: showID, showType: next.event.showType, showName: next.event.showName,
                event: next.event, season: next.season, episode: next.episode,
                lastSeason: last.season, lastEpisode: last.episode,
                newCount: ordered.count,
                latestDay: ordered.map(\.event.day).max() ?? next.event.day,
                progress: progress
            ))
        }
        newItems.sort {
            if $0.latestDay != $1.latestDay { return $0.latestDay > $1.latestDay }
            return $0.showName.localizedCaseInsensitiveCompare($1.showName) == .orderedAscending
        }

        // Coming up: this week, next week, later this month.
        let upcoming = events.filter { !aired($0) }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let nextWeekEnd = calendar.date(byAdding: .day, value: 14, to: today) ?? today
        let monthEnd = calendar.date(byAdding: .day, value: ReleaseCalendarStore.futureDays + 1, to: today) ?? today
        let lastOfWeek = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let lastOfNextWeek = calendar.date(byAdding: .day, value: 13, to: today) ?? today
        var sections: [UpcomingSection] = []
        let thisWeek = upcoming.filter { $0.day < weekEnd }
        if !thisWeek.isEmpty {
            sections.append(UpcomingSection(
                id: "week", title: L10n.string("calendar_this_week", fallback: "Coming Up This Week"),
                subtitle: "\(ReleaseCalendarView.shortDate(today)) – \(ReleaseCalendarView.shortDate(lastOfWeek))", events: thisWeek))
        }
        let nextWeek = upcoming.filter { $0.day >= weekEnd && $0.day < nextWeekEnd }
        if !nextWeek.isEmpty {
            sections.append(UpcomingSection(
                id: "next", title: L10n.string("calendar_next_week", fallback: "Next Week"),
                subtitle: "\(ReleaseCalendarView.shortDate(weekEnd)) – \(ReleaseCalendarView.shortDate(lastOfNextWeek))", events: nextWeek))
        }
        let later = upcoming.filter { $0.day >= nextWeekEnd && $0.day < monthEnd }
        if !later.isEmpty {
            sections.append(UpcomingSection(
                id: "later", title: L10n.string("calendar_later", fallback: "Later This Month"),
                subtitle: "from \(ReleaseCalendarView.shortDate(nextWeekEnd))", events: later))
        }
        model = CalendarModel(newItems: newItems, sections: sections)
        nextBoundary = upcoming.compactMap { event -> Date? in
            guard event.day == today || event.day == calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return event.airTime ?? event.day
        }.min()
        builtDay = today
        stale = false
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms >= 30 {
            CrashRecorder.note("calendar rows (\(reason)): \(events.count) events, \(newItems.count) new, \(ms) ms")
        }
    }
}

/// Release calendar for the TV shows in the Library and shows being watched:
/// what's new to watch now (one card per show, Select plays the next new
/// episode), then what's coming this week, next week and later this month.
/// A panel at the top describes whichever card has focus.
struct ReleaseCalendarView: View {
    @ObservedObject private var store = ReleaseCalendarStore.shared
    /// Library entries from the selected library source (Trakt, Simkl, …).
    let libraryItems: [StremioMeta]
    let onOpenShow: (String, String) -> Void
    let onPlayEpisode: (CalendarPlayRequest) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage("nuvio.tv.calendar.filter") private var filterRaw = CalendarShowFilter.all.rawValue
    /// The rows, built only when the data changes (not on focus moves).
    @StateObject private var screen = CalendarScreenModel()
    /// Off screen nothing is rebuilt; it catches up on return.
    @State private var isVisible = false
    @State private var now = Date()
    @FocusState private var focusedCard: String?
    /// The card the panel describes (the last one focused).
    @State private var panelCardID: String?

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var filter: CalendarShowFilter { CalendarShowFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        let model = screen.model
        let focus = panelFocus(in: model)
        ZStack(alignment: .topLeading) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            backdrop(for: focus)
            VStack(alignment: .leading, spacing: 0) {
                header
                panel(for: focus)
                    .frame(height: CalendarMetrics.panelHeight, alignment: .topLeading)
                rows(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultFocus($focusedCard, model.firstCardID)
        .onAppear {
            isVisible = true
            now = Date()
            rebuild("open")
            refresh(force: false)
        }
        .onDisappear { isVisible = false }
        .onChange(of: focusedCard) { _, card in
            if let card { panelCardID = card }
        }
        // Sources for the card you rest on, nothing else.
        .task(id: focusedNewItem(in: model)?.availabilityKey) {
            guard let item = focusedNewItem(in: model) else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await store.probeAvailability(showID: item.showID, season: item.season, episode: item.episode)
        }
        .onChange(of: filterRaw) { _, _ in rebuild("filter") }
        // @Published fires before the value changes: use the value it sends.
        .onReceive(store.$events.dropFirst()) { events in rebuild("events", events: events) }
        .onReceive(ticker) { date in
            guard isVisible else { return }
            now = date
            if screen.isDue(at: date) { rebuild("time") }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification).receive(on: RunLoop.main)) { _ in
            rebuild("watched")
        }
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification).receive(on: RunLoop.main)) { _ in
            rebuild("progress")
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.changedNotification)) { _ in
            refresh(force: false)
        }
    }

    /// Rebuilds the rows now when on screen, else when the tab comes back.
    private func rebuild(_ reason: String, events: [CalendarEvent]? = nil) {
        guard isVisible else {
            screen.markStale()
            return
        }
        screen.rebuild(events: events ?? store.events, filter: filter, now: Date(), reason: reason)
    }

    private func focusedNewItem(in model: CalendarModel) -> NewShowItem? {
        guard let id = focusedCard, id.hasPrefix("n|") else { return nil }
        return model.newItems.first { $0.id == id }
    }

    private func refresh(force: Bool) {
        let extra = libraryItems
            .filter { NuvioMeta.isSeriesType($0.contentType) }
            .map { (id: $0.id, name: $0.name) }
        store.refreshIfNeeded(extraLibrary: extra, force: force)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(L10n.string("calendar_title", fallback: "Calendar"))
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)
            if store.isRefreshing && store.lookupCount > 0 {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(L10n.format("calendar_checking_shows", fallback: "Checking %d shows…", store.lookupCount))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 20)
            HStack(spacing: 12) {
                ForEach(CalendarShowFilter.allCases, id: \.self) { option in
                    SourceModeChip(title: option.title, isSelected: filter == option) {
                        withAnimation(.easeInOut(duration: 0.2)) { filterRaw = option.rawValue }
                    }
                }
            }
            .focusSection()
        }
        .frame(height: 70)
    }

    // MARK: - Panel (the focused card)

    private enum PanelFocus {
        case new(NewShowItem)
        case upcoming(CalendarEvent)

        var imageURL: String? {
            switch self {
            case .new(let item): return item.event.imageURL
            case .upcoming(let event): return event.imageURL
            }
        }
    }

    private func panelFocus(in model: CalendarModel) -> PanelFocus? {
        let id = panelCardID ?? model.firstCardID
        if let id, id.hasPrefix("n|"), let item = model.newItems.first(where: { $0.id == id }) { return .new(item) }
        if let id, id.hasPrefix("u|") {
            for section in model.sections {
                if let event = section.events.first(where: { "u|" + $0.id == id }) { return .upcoming(event) }
            }
        }
        if let first = model.newItems.first { return .new(first) }
        if let event = model.sections.first?.events.first { return .upcoming(event) }
        return nil
    }

    /// The focused card's artwork, large and faded into the page, top right.
    @ViewBuilder
    private func backdrop(for focus: PanelFocus?) -> some View {
        if let url = focus?.imageURL {
            let height = CalendarMetrics.backdropWidth * 9 / 16
            CachedPosterArtwork(
                urlString: url,
                width: CalendarMetrics.backdropWidth,
                height: height,
                maximumWidth: CalendarMetrics.backdropWidth
            ) { Color.clear }
            .frame(width: CalendarMetrics.backdropWidth, height: height)
            .clipped()
            .mask(
                LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .leading, endPoint: .trailing)
            )
            .mask(
                LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
            )
            .opacity(0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .ignoresSafeArea()
            .id(url)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.35), value: url)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func panel(for focus: PanelFocus?) -> some View {
        switch focus {
        case .new(let item):
            panelBody(
                event: item.event, name: item.showName,
                badges: newBadges(item),
                episodeLine: episodeLine(season: item.season, episode: item.episode,
                                         title: item.event.kind == .episode ? item.event.episodeTitle : nil,
                                         extra: item.newCount > 1 ? "1 of \(item.newCount) new" : nil),
                statusLine: newStatusLine(item)
            )
        case .upcoming(let event):
            panelBody(
                event: event, name: event.showName,
                badges: upcomingBadges(event),
                episodeLine: event.kind == .seasonDrop
                    ? "Season \(event.season) · all \(event.episodeCount) episodes"
                    : episodeLine(season: event.season, episode: event.episode, title: event.episodeTitle, extra: nil),
                statusLine: upcomingStatusLine(event)
            )
        case nil:
            emptyPanel
        }
    }

    private struct Badge: Hashable {
        let text: String
        let color: Color
        let symbol: String?
    }

    private func panelBody(event: CalendarEvent, name: String, badges: [Badge], episodeLine: String, statusLine: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            showTitle(name: name, logo: event.logoURL)
            if !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges, id: \.self) { badge in
                        HStack(spacing: 6) {
                            if let symbol = badge.symbol { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
                            Text(badge.text).font(.system(size: 16, weight: .heavy)).tracking(0.6)
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(badge.color))
                    }
                }
            }
            Text(episodeLine)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(statusLine)
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            if let overview = event.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 21))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(2)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.2), value: event.id)
    }

    @ViewBuilder
    private func showTitle(name: String, logo: String?) -> some View {
        if let logo, let url = URL(string: logo) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 460, maxHeight: 96, alignment: .leading)
                } else {
                    titleText(name)
                }
            }
            .frame(height: 96, alignment: .leading)
        } else {
            titleText(name)
        }
    }

    private func titleText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 52, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: 1100, alignment: .leading)
    }

    @ViewBuilder
    private var emptyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.35))
            if store.isRefreshing && store.events.isEmpty {
                Text(L10n.string("calendar_loading", fallback: "Looking up release dates…"))
                    .font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
            } else if store.showCount == 0 && store.events.isEmpty {
                Text(L10n.string("calendar_empty_no_shows", fallback: "No shows to follow yet"))
                    .font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
                Text(L10n.string(
                    "calendar_empty_no_shows_hint",
                    fallback: "Add TV shows to your Library or start watching one, and new episodes will show up here."
                ))
                .font(.system(size: 24)).foregroundColor(.white.opacity(0.6))
            } else {
                Text(L10n.string("calendar_empty_all", fallback: "You're all caught up"))
                    .font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
                Text(filter == .all
                     ? L10n.string("calendar_empty_all_hint", fallback: "Nothing new to watch and nothing airing in the next 30 days.")
                     : L10n.format("calendar_empty_filter_hint", fallback: "Showing %@ only. Switch to All Shows to see more.", filter.title))
                .font(.system(size: 24)).foregroundColor(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }

    // MARK: - Rows

    private func rows(_ model: CalendarModel) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 34) {
                if !model.newItems.isEmpty {
                    rowSection(
                        title: L10n.string("calendar_new_for_you", fallback: "New for You"),
                        subtitle: newSubtitle(model.newItems)
                    ) {
                        ForEach(model.newItems) { item in
                            NewEpisodeCard(
                                item: item,
                                availability: store.availability[item.availabilityKey],
                                airedLine: airedLine(item.latestDay),
                                focus: $focusedCard,
                                onPlay: { play(item) },
                                onMarkWatched: { markWatched(item, caughtUp: false) },
                                onMarkCaughtUp: { markWatched(item, caughtUp: true) },
                                onOpenShow: { onOpenShow(item.showID, item.showType) }
                            )
                        }
                    }
                } else if !model.sections.isEmpty {
                    Text(L10n.string("calendar_caught_up", fallback: "You're caught up: no new episodes waiting."))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                ForEach(model.sections) { section in
                    rowSection(title: section.title, subtitle: section.subtitle) {
                        ForEach(section.events) { event in
                            UpcomingEpisodeCard(
                                event: event,
                                dayLabel: dayLabel(event),
                                detailLine: upcomingCardLine(event),
                                focus: $focusedCard,
                                onOpenShow: { onOpenShow(event.showID, event.showType) }
                            )
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }

    private func rowSection<Cards: View>(title: String, subtitle: String, @ViewBuilder cards: () -> Cards) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CalendarMetrics.cardGap) {
                    cards()
                }
                .padding(.vertical, 18)
            }
            .scrollClipDisabled()
            .padding(.top, -18)
        }
        .focusSection()
    }

    // MARK: - Actions

    private func play(_ item: NewShowItem) {
        onPlayEpisode(CalendarPlayRequest(
            showID: item.showID, showType: item.showType, season: item.season, episode: item.episode,
            released: item.event.released
        ))
    }

    /// Marks the next new episode watched, or (caught up) everything up to
    /// the newest one, the same way the show page does.
    private func markWatched(_ item: NewShowItem, caughtUp: Bool) {
        Task { @MainActor in
            guard let meta = await store.meta(for: item.showID, type: item.showType) else { return }
            if caughtUp {
                _ = WatchedStore.markWatchedUpTo(meta: meta, season: item.lastSeason, episode: item.lastEpisode)
            } else if !WatchedStore.containsEpisode(metaId: item.showID, season: item.season, episode: item.episode) {
                _ = WatchedStore.toggleEpisode(meta: meta, season: item.season, episode: item.episode)
            }
        }
    }

    // MARK: - Text

    private func episodeLine(season: Int, episode: Int, title: String?, extra: String?) -> String {
        var line = "S\(season) · E\(episode)"
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Placeholder titles like "Episode 5" add nothing next to the code.
        if !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("episode ") { line += " · \(trimmed)" }
        if let extra { line += "  (\(extra))" }
        return line
    }

    private func newSubtitle(_ items: [NewShowItem]) -> String {
        let episodes = items.reduce(0) { $0 + $1.newCount }
        if items.count == 1 { return "\(episodes) episode\(episodes == 1 ? "" : "s") to watch" }
        return "\(episodes) episodes across \(items.count) shows"
    }

    private func newBadges(_ item: NewShowItem) -> [Badge] {
        var badges: [Badge] = [Badge(
            text: item.newCount > 1 ? "\(item.newCount) NEW" : "NEW",
            color: Color(red: 0.35, green: 0.85, blue: 0.55), symbol: nil)]
        if item.season == 1 && item.episode == 1 {
            badges.append(Badge(text: "SERIES PREMIERE", color: Color(red: 1, green: 0.82, blue: 0.35), symbol: nil))
        } else if item.episode == 1 {
            badges.append(Badge(text: "SEASON PREMIERE", color: Color(red: 1, green: 0.82, blue: 0.35), symbol: nil))
        }
        switch store.availability[item.availabilityKey] {
        case .ready(let count)?: badges.append(Badge(text: "\(count) SOURCE\(count == 1 ? "" : "S")", color: .white, symbol: "checkmark"))
        case .notYet?: badges.append(Badge(text: "NO SOURCES YET", color: Color.white.opacity(0.55), symbol: "clock"))
        default: break
        }
        return badges
    }

    private func upcomingBadges(_ event: CalendarEvent) -> [Badge] {
        let gold = Color(red: 1, green: 0.82, blue: 0.35)
        if event.isSeriesPremiere { return [Badge(text: "SERIES PREMIERE", color: gold, symbol: nil)] }
        if event.isSeasonPremiere { return [Badge(text: "SEASON PREMIERE", color: gold, symbol: nil)] }
        if event.kind == .seasonDrop { return [Badge(text: "FULL SEASON", color: gold, symbol: nil)] }
        return []
    }

    private func newStatusLine(_ item: NewShowItem) -> String {
        var parts = [airedLine(item.event.day)]
        if let progress = item.progress, progress > 0.02 {
            parts.append("\(Int(((1 - progress) * 100).rounded()))% left")
        }
        switch store.availability[item.availabilityKey] {
        case .ready(let count)?: parts.append("\(count) source\(count == 1 ? "" : "s") found")
        case .notYet?: parts.append("No sources yet (new episodes can take a few hours to appear)")
        case .checking?: parts.append("Checking sources…")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private func upcomingStatusLine(_ event: CalendarEvent) -> String {
        let label = dayLabel(event, long: true)
        guard let countdown = countdown(event) else { return label }
        return "\(label) · \(countdown)"
    }

    private func upcomingCardLine(_ event: CalendarEvent) -> String {
        if event.kind == .seasonDrop { return "Season \(event.season) · \(event.episodeCount) episodes" }
        return episodeLine(season: event.season, episode: event.episode, title: event.episodeTitle, extra: nil)
    }

    /// "Out today", "Aired yesterday", "Aired Tuesday", "Aired Oct 12".
    private func airedLine(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Out today" }
        if calendar.isDateInYesterday(day) { return "Aired yesterday" }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "Aired \(Self.weekdayFormatter.string(from: day))" }
        return "Aired \(Self.shortDate(day))"
    }

    /// "Tonight · 9:00 PM", "Tomorrow · 8:00 PM", "Sat, Oct 25"; the long
    /// form spells the day out and says when a time isn't announced.
    private func dayLabel(_ event: CalendarEvent, long: Bool = false) -> String {
        let calendar = Calendar.current
        let time = event.airTime.map { Self.timeFormatter.string(from: $0) }
        let day: String
        if calendar.isDateInToday(event.day) {
            let hour = event.airTime.map { calendar.component(.hour, from: $0) } ?? 0
            day = hour >= 17 ? "Tonight" : "Today"
        } else if calendar.isDateInTomorrow(event.day) {
            day = "Tomorrow"
        } else {
            day = (long ? Self.longDayFormatter : Self.cardDayFormatter).string(from: event.day)
        }
        if let time { return "\(day) · \(time)" }
        return long ? "\(day) · time not announced" : day
    }

    private func countdown(_ event: CalendarEvent) -> String? {
        let target = event.airTime ?? event.day
        guard target > now else { return nil }
        return Self.relativeFormatter.localizedString(for: target, relativeTo: now)
    }

    static func shortDate(_ date: Date) -> String { shortDateFormatter.string(from: date) }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let cardDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let longDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Cards

/// Shared card chrome: 16:9 artwork with a bottom fade, the show name, and
/// the app's focus lift and outline.
private struct CalendarCardArtwork<Overlay: View>: View {
    let imageURL: String?
    let showName: String
    let isFocused: Bool
    @ViewBuilder let overlay: () -> Overlay

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedPosterArtwork(
                urlString: imageURL,
                width: CalendarMetrics.cardWidth,
                height: CalendarMetrics.cardHeight,
                maximumWidth: CalendarMetrics.cardWidth
            ) {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.07))
                    Image(systemName: "tv").font(.system(size: 44)).foregroundColor(.white.opacity(0.25))
                }
            }
            .frame(width: CalendarMetrics.cardWidth, height: CalendarMetrics.cardHeight)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            Text(showName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            overlay()
        }
        .frame(width: CalendarMetrics.cardWidth, height: CalendarMetrics.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? AppFocusOutline.width : 0)
        )
        .scaleEffect(isFocused ? 1.06 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 10)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// A show with new episodes: Select plays the next one; hold for more.
private struct NewEpisodeCard: View {
    let item: NewShowItem
    let availability: ReleaseCalendarStore.Availability?
    let airedLine: String
    var focus: FocusState<String?>.Binding
    let onPlay: () -> Void
    let onMarkWatched: () -> Void
    let onMarkCaughtUp: () -> Void
    let onOpenShow: () -> Void

    private var isFocused: Bool { focus.wrappedValue == item.id }

    private var episodeText: String {
        let title = item.event.kind == .episode ? item.event.episodeTitle.trimmingCharacters(in: .whitespaces) : ""
        let code = "S\(item.season) · E\(item.episode)"
        guard !title.isEmpty, !title.lowercased().hasPrefix("episode ") else { return code }
        return "\(code) · \(title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onPlay) {
                CalendarCardArtwork(imageURL: item.event.imageURL, showName: item.showName, isFocused: isFocused) {
                    ZStack {
                        // New-episode count, top left.
                        Text(item.newCount > 1 ? "\(item.newCount) NEW" : "NEW")
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(0.6)
                            .foregroundColor(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(red: 0.35, green: 0.85, blue: 0.55)))
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // Ready to watch, top right.
                        if case .ready? = availability {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white)
                                .shadow(radius: 4)
                                .padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                        // Progress through a started episode, along the bottom.
                        if let progress = item.progress, progress > 0.02 {
                            VStack(spacing: 0) {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.white.opacity(0.25))
                                    Rectangle().fill(Color.white).frame(width: CalendarMetrics.cardWidth * progress)
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                }
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused(focus, equals: item.id)
            .focusEffectDisabledIfAvailable()
            .contextMenu {
                Button(action: onPlay) {
                    Label("Play S\(item.season) · E\(item.episode)", systemImage: "play.fill")
                }
                Button(action: onMarkWatched) {
                    Label("Mark S\(item.season) · E\(item.episode) Watched", systemImage: "checkmark.circle")
                }
                if item.newCount > 1 {
                    Button(action: onMarkCaughtUp) {
                        Label("Mark All \(item.newCount) Watched", systemImage: "checkmark.circle.fill")
                    }
                }
                Button(action: onOpenShow) {
                    Label("Go to Show", systemImage: "info.circle")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(episodeText)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white.opacity(isFocused ? 1 : 0.85))
                    .lineLimit(1)
                Text(airedLine)
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: CalendarMetrics.cardWidth, alignment: .leading)
        }
    }
}

/// An episode coming up: Select opens the show.
private struct UpcomingEpisodeCard: View {
    let event: CalendarEvent
    let dayLabel: String
    let detailLine: String
    var focus: FocusState<String?>.Binding
    let onOpenShow: () -> Void

    private var cardID: String { "u|" + event.id }
    private var isFocused: Bool { focus.wrappedValue == cardID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpenShow) {
                CalendarCardArtwork(imageURL: event.imageURL, showName: event.showName, isFocused: isFocused) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dayLabel.uppercased())
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(0.6)
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                        if let badge = premiereBadge {
                            Text(badge)
                                .font(.system(size: 14, weight: .heavy))
                                .tracking(0.6)
                                .foregroundColor(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 1, green: 0.82, blue: 0.35)))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused(focus, equals: cardID)
            .focusEffectDisabledIfAvailable()
            .contextMenu {
                Button(action: onOpenShow) {
                    Label("Go to Show", systemImage: "info.circle")
                }
            }

            Text(detailLine)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white.opacity(isFocused ? 1 : 0.85))
                .lineLimit(1)
                .frame(width: CalendarMetrics.cardWidth, alignment: .leading)
        }
    }

    private var premiereBadge: String? {
        if event.isSeriesPremiere { return "SERIES PREMIERE" }
        if event.isSeasonPremiere { return "SEASON PREMIERE" }
        if event.kind == .seasonDrop { return "FULL SEASON" }
        return nil
    }
}
