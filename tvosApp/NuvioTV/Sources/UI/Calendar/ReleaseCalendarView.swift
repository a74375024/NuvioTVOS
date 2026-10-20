import SwiftUI

private enum CalendarMetrics {
    static let cardWidth: CGFloat = 400
    static let cardHeight: CGFloat = 225
    static let cardGap: CGFloat = 40
    static let pageInset: CGFloat = 49
}

/// The time span the calendar is showing.
enum CalendarRange: String, CaseIterable, Identifiable {
    case next7
    case next30
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .next7: return L10n.string("calendar_range_next7", fallback: "Next 7 Days")
        case .next30: return L10n.string("calendar_range_next30", fallback: "Next 30 Days")
        case .recent: return L10n.string("calendar_range_recent", fallback: "Recently Aired")
        }
    }
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

    var next: CalendarShowFilter {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    func includes(_ event: CalendarEvent) -> Bool {
        switch self {
        case .all: return true
        case .library: return event.sources.contains(.library)
        case .watching: return event.sources.contains(.watching)
        }
    }
}

private struct CalendarSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let events: [CalendarEvent]
    /// Week rows label each card with its day; day rows don't need to.
    let showsDayOnCards: Bool
}

/// Release calendar for TV shows in the Library and shows being watched.
struct ReleaseCalendarView: View {
    @ObservedObject private var store = ReleaseCalendarStore.shared
    /// Library entries from the selected library source (Trakt, Simkl, …).
    let libraryItems: [StremioMeta]
    let onOpenShow: (String, String) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage("nuvio.tv.calendar.range") private var rangeRaw = CalendarRange.next7.rawValue
    @AppStorage("nuvio.tv.calendar.filter") private var filterRaw = CalendarShowFilter.all.rawValue
    /// Bumped when watched state changes so "new" badges refresh.
    @State private var watchedRevision = 0

    private var range: CalendarRange { CalendarRange(rawValue: rangeRaw) ?? .next7 }
    private var filter: CalendarShowFilter { CalendarShowFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    header
                    content
                }
                .padding(.horizontal, CalendarMetrics.pageInset)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
        }
        .onAppear { refresh(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            watchedRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.changedNotification)) { _ in
            refresh(force: false)
        }
    }

    private func refresh(force: Bool) {
        let extra = libraryItems
            .filter { NuvioMeta.isSeriesType($0.contentType) }
            .map { (id: $0.id, name: $0.name) }
        store.refreshIfNeeded(extraLibrary: extra, force: force)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(L10n.string("calendar_title", fallback: "Calendar"))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)
                if store.isRefreshing {
                    ProgressView()
                        .tint(.white)
                    Text(L10n.format(
                        "calendar_checking_shows",
                        fallback: "Checking %d shows…",
                        store.showCount
                    ))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 16) {
                ForEach(CalendarRange.allCases) { option in
                    SourceModeChip(
                        title: chipTitle(for: option),
                        isSelected: range == option
                    ) {
                        guard range != option else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { rangeRaw = option.rawValue }
                    }
                }
                Spacer().frame(width: 24)
                SourceModeChip(title: filter.title, isSelected: false) {
                    withAnimation(.easeInOut(duration: 0.2)) { filterRaw = filter.next.rawValue }
                }
            }
            .focusSection()
        }
    }

    private func chipTitle(for option: CalendarRange) -> String {
        guard option == .recent else { return option.title }
        let unwatched = unwatchedRecentCount
        return unwatched > 0 ? "\(option.title) · \(unwatched)" : option.title
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let sections = makeSections()
        if sections.isEmpty {
            emptyState
        } else {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(section.title)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        if let subtitle = section.subtitle {
                            Text(subtitle)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: CalendarMetrics.cardGap) {
                            ForEach(section.events) { event in
                                CalendarEventCard(
                                    event: event,
                                    showsDay: section.showsDayOnCards,
                                    isWatched: isWatched(event),
                                    isRecent: range == .recent
                                ) {
                                    onOpenShow(event.showID, event.showType)
                                }
                            }
                        }
                        // Room for the focus lift so it isn't clipped.
                        .padding(.vertical, 24)
                        .padding(.horizontal, 4)
                    }
                    .padding(.top, -24)
                }
                .focusSection()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.35))
            if store.isRefreshing && store.events.isEmpty {
                Text(L10n.string("calendar_loading", fallback: "Looking up release dates…"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
            } else if store.showCount == 0 && store.events.isEmpty {
                Text(L10n.string("calendar_empty_no_shows", fallback: "No shows to follow yet"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
                Text(L10n.string(
                    "calendar_empty_no_shows_hint",
                    fallback: "Add TV shows to your Library or start watching one, and new episodes will show up here."
                ))
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.6))
            } else {
                Text(emptyRangeMessage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
                if filter != .all {
                    Text(L10n.format(
                        "calendar_empty_filter_hint",
                        fallback: "Showing %@ only. Switch the filter to see more.",
                        filter.title
                    ))
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(.top, 40)
    }

    private var emptyRangeMessage: String {
        switch range {
        case .next7: return L10n.string("calendar_empty_next7", fallback: "Nothing airing in the next 7 days")
        case .next30: return L10n.string("calendar_empty_next30", fallback: "Nothing airing in the next 30 days")
        case .recent: return L10n.string("calendar_empty_recent", fallback: "Nothing aired in the past week")
        }
    }

    // MARK: - Grouping

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var filteredEvents: [CalendarEvent] {
        store.events.filter { filter.includes($0) }
    }

    private var recentEvents: [CalendarEvent] {
        let start = Calendar.current.date(byAdding: .day, value: -ReleaseCalendarStore.pastDays, to: today) ?? today
        let now = Date()
        return filteredEvents.filter { event in
            if event.day >= start && event.day < today { return true }
            // Aired earlier today.
            if event.day == today, let time = event.airTime, time <= now { return true }
            return false
        }
    }

    private var unwatchedRecentCount: Int {
        _ = watchedRevision
        return recentEvents.filter { !isWatched($0) }.count
    }

    private func makeSections() -> [CalendarSection] {
        _ = watchedRevision
        let calendar = Calendar.current
        switch range {
        case .recent:
            let grouped = Dictionary(grouping: recentEvents, by: \.day)
            return grouped.keys.sorted(by: >).map { day in
                CalendarSection(
                    id: "recent-\(day.timeIntervalSince1970)",
                    title: dayTitle(day),
                    subtitle: daySubtitle(day),
                    events: (grouped[day] ?? []).sorted { ($0.airTime ?? $0.day) > ($1.airTime ?? $1.day) },
                    showsDayOnCards: false
                )
            }

        case .next7:
            guard let end = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }
            let upcoming = filteredEvents.filter { $0.day >= today && $0.day < end }
            let grouped = Dictionary(grouping: upcoming, by: \.day)
            return grouped.keys.sorted().map { day in
                CalendarSection(
                    id: "day-\(day.timeIntervalSince1970)",
                    title: dayTitle(day),
                    subtitle: daySubtitle(day),
                    events: grouped[day] ?? [],
                    showsDayOnCards: false
                )
            }

        case .next30:
            guard let end = calendar.date(byAdding: .day, value: ReleaseCalendarStore.futureDays, to: today) else { return [] }
            let upcoming = filteredEvents.filter { $0.day >= today && $0.day < end }
            // Rolling 7-day blocks from today, so the first row is always a full week.
            let grouped = Dictionary(grouping: upcoming) { event -> Int in
                let days = calendar.dateComponents([.day], from: today, to: event.day).day ?? 0
                return max(0, days) / 7
            }
            return grouped.keys.sorted().map { block in
                let start = calendar.date(byAdding: .day, value: block * 7, to: today) ?? today
                let last = calendar.date(byAdding: .day, value: block * 7 + 6, to: today) ?? today
                return CalendarSection(
                    id: "week-\(block)",
                    title: block == 0
                        ? L10n.string("calendar_this_week", fallback: "This Week")
                        : L10n.string("calendar_week_of", fallback: "Week of \(Self.shortDate(start))"),
                    subtitle: "\(Self.shortDate(start)) – \(Self.shortDate(last))",
                    events: grouped[block] ?? [],
                    showsDayOnCards: true
                )
            }
        }
    }

    private func isWatched(_ event: CalendarEvent) -> Bool {
        if event.kind == .seasonDrop {
            // A drop counts as watched once its last episode is.
            return WatchedStore.containsEpisode(
                metaId: event.showID,
                season: event.season,
                episode: event.episode + event.episodeCount - 1
            )
        }
        return WatchedStore.containsEpisode(metaId: event.showID, season: event.season, episode: event.episode)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.string("date_today", fallback: "Today") }
        if calendar.isDateInTomorrow(day) { return L10n.string("calendar_tomorrow", fallback: "Tomorrow") }
        if calendar.isDateInYesterday(day) { return L10n.string("calendar_yesterday", fallback: "Yesterday") }
        return Self.weekdayFormatter.string(from: day)
    }

    private func daySubtitle(_ day: Date) -> String? {
        Self.shortDate(day)
    }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

// MARK: - Card

private struct CalendarEventCard: View {
    let event: CalendarEvent
    let showsDay: Bool
    let isWatched: Bool
    let isRecent: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    CachedPosterArtwork(
                        urlString: event.imageURL,
                        width: CalendarMetrics.cardWidth,
                        height: CalendarMetrics.cardHeight,
                        maximumWidth: CalendarMetrics.cardWidth
                    ) {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: "tv")
                                .font(.system(size: 44))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                    .frame(width: CalendarMetrics.cardWidth, height: CalendarMetrics.cardHeight)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        if let badge = badgeText {
                            Text(badge)
                                .font(.system(size: 17, weight: .heavy))
                                .tracking(0.6)
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(badgeColor))
                        }
                        Text(event.showName)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(18)

                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .shadow(radius: 6)
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: CalendarMetrics.cardWidth, height: CalendarMetrics.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? AppFocusOutline.width : 0)
                )
                .opacity(isWatched && !isFocused ? 0.6 : 1)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isFocused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 10)
            .animation(.easeOut(duration: 0.18), value: isFocused)

            VStack(alignment: .leading, spacing: 4) {
                Text(episodeLine)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(isFocused ? 1 : 0.85))
                    .lineLimit(1)
                Text(timeLine)
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(width: CalendarMetrics.cardWidth, alignment: .leading)
        }
    }

    private var episodeLine: String {
        if event.kind == .seasonDrop {
            return L10n.format(
                "calendar_season_drop",
                fallback: "Season %d · %d episodes",
                event.season,
                event.episodeCount
            )
        }
        let code = "S\(event.season) · E\(event.episode)"
        let title = event.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Placeholder titles like "Episode 5" add nothing next to the code.
        guard !title.isEmpty, !title.lowercased().hasPrefix("episode ") else { return code }
        return "\(code)  \(title)"
    }

    private var timeLine: String {
        var parts: [String] = []
        if showsDay {
            parts.append(Self.dayFormatter.string(from: event.day))
        }
        if let time = event.airTime {
            parts.append(Self.timeFormatter.string(from: time))
        }
        if parts.isEmpty {
            parts.append(isRecent
                ? L10n.string("calendar_aired", fallback: "Aired")
                : L10n.string("calendar_time_tba", fallback: "Time not announced"))
        }
        return parts.joined(separator: " · ")
    }

    private var badgeText: String? {
        if isRecent && !isWatched { return L10n.string("calendar_badge_new", fallback: "NEW") }
        if event.isSeriesPremiere { return L10n.string("calendar_badge_series_premiere", fallback: "SERIES PREMIERE") }
        if event.isSeasonPremiere { return L10n.string("calendar_badge_season_premiere", fallback: "SEASON PREMIERE") }
        if event.kind == .seasonDrop { return L10n.string("calendar_badge_full_season", fallback: "FULL SEASON") }
        return nil
    }

    private var badgeColor: Color {
        if isRecent && !isWatched { return Color(red: 0.35, green: 0.85, blue: 0.55) }
        return Color(red: 1.0, green: 0.82, blue: 0.35)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
