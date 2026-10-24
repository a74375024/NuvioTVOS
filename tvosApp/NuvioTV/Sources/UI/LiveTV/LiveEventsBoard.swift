import SwiftUI
import Combine

// MARK: - Names and badges

enum SportsNames {
    private static let twoWord: Set<String> = [
        "red sox", "white sox", "blue jays", "maple leafs", "red wings", "golden knights", "blue jackets",
        "trail blazers", "black hawks", "st louis", "golden state"
    ]

    /// "Rams" for "Los Angeles Rams", "Utah", "Man City".
    static func short(_ team: SportsTeam, soccer: Bool) -> String {
        if let first = team.alternates.first, first.count <= 16 { return first }
        if soccer { return team.name }
        let words = team.name.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return team.name }
        let lastTwo = words.suffix(2).joined(separator: " ")
        if twoWord.contains(lastTwo.lowercased()) { return lastTwo }
        return words.last ?? team.name
    }

    static func title(_ game: SportsGame) -> String {
        let away = short(game.away, soccer: game.isSoccer), home = short(game.home, soccer: game.isSoccer)
        return game.isSoccer ? "\(home) vs \(away)" : "\(away) at \(home)"
    }

    static func symbol(_ league: String) -> String {
        switch league {
        case "NFL", "College Football": return "football.fill"
        case "NBA", "WNBA", "College Basketball": return "basketball.fill"
        case "MLB": return "baseball.fill"
        case "NHL": return "hockey.puck.fill"
        case "Soccer", "MLS": return "soccerball"
        case "Fighting": return "figure.boxing"
        case "Motorsport": return "flag.checkered"
        case "Golf": return "figure.golf"
        case "Tennis": return "tennisball.fill"
        default: return "sportscourt.fill"
        }
    }
}

/// A team's logo, or its initials when there's none.
struct TeamBadge: View {
    let team: SportsTeam
    let size: CGFloat
    var focused = false

    var body: some View {
        ChannelLogoView(urls: team.badge.flatMap(URL.init(string:)).map { [$0] } ?? [], width: size, height: size, focused: focused) {
            ZStack {
                Circle().fill(Color.white.opacity(focused ? 0.15 : 0.12))
                Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
                Text(team.abbreviation)
                    .font(.system(size: size * 0.3, weight: .heavy))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(6)
            }
            .frame(width: size, height: size)
        }
    }
}

private func chipLabel(_ text: String, fill: Color, foreground: Color = .white, outlined: Bool = false) -> some View {
    Text(text)
        .font(.system(size: 15, weight: .heavy))
        .tracking(0.4)
        .foregroundColor(foreground)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(outlined ? 0.7 : 0), lineWidth: 2))
}

private let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
}()

private func leagueLine(_ event: SportsEvent) -> String {
    var parts: [String] = [event.leagueShort]
    if let week = event.game?.weekLabel { parts.append(week) }
    return parts.joined(separator: "  ·  ")
}

/// "On NBA League Pass · not in your channels".
private func notInChannels(_ event: SportsEvent) -> String {
    if let network = event.game?.networks.first {
        return L10n.format("live_event_on_not_yours", fallback: "On %@ · not in your channels", network)
    }
    return L10n.string("live_event_not_in_channels", fallback: "Not in your channels")
}

private let shortWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
}()

private let longWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return formatter
}()

private func dayTime(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return clock.string(from: date) }
    if calendar.isDateInTomorrow(date) { return L10n.string("live_time_tomorrow", fallback: "Tomorrow") + " " + clock.string(from: date) }
    return shortWeekday.string(from: date) + " " + clock.string(from: date)
}

/// Where a tile's game is on, worked out once per update (not per draw).
struct EventWhere: Equatable {
    var channelName: String?
    var channelDisplay: String?
    var logoURLs: [URL] = []
    var inLineup = false
    var feeds = 0
}

// MARK: - Model

/// Live Events' rows, built when their inputs change and every 30 seconds,
/// never while drawing. If the tile you're on would disappear in an update,
/// the update waits until you move or 5 seconds pass.
@MainActor
final class LiveEventsModel: ObservableObject {
    static let shared = LiveEventsModel()

    struct Row: Identifiable {
        let id: String
        let title: String
        let events: [SportsEvent]
        var families: [EventFamily] = []
        let live: Int
        var count: Int { events.count + families.count }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var hero: SportsEvent?
    @Published private(set) var now = Date()
    private(set) var places: [String: EventWhere] = [:]

    private var pending: (rows: [Row], hero: SportsEvent?, places: [String: EventWhere])?
    /// The focused tile's key: row id + "|" + event id.
    private var focusedKey: String?
    private var lastInput = Date()
    private var sinks: [AnyCancellable] = []
    private var ticker: AnyCancellable?
    private var scheduled = false
    private var builds = 0
    private var buildMS = 0

    private static let sportOrder = ["NFL", "College Football", "NBA", "WNBA", "College Basketball", "MLB", "NHL",
                                     "MLS", "Soccer", "Fighting", "Motorsport", "Golf", "Tennis"]

    func start() {
        guard ticker == nil else { return }
        CrashRecorder.liveEventsOpen = true
        let store = LiveTVStore.shared
        now = Date()
        sinks = [
            store.$sportsEvents.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$events.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$families.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() },
            store.$logosRevision.dropFirst().sink { [weak self] _ in self?.scheduleRecompute() }
        ]
        ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }
            self.now = date
            LiveTVStore.shared.sportsTick()
            self.recompute()
            if self.builds > 0 {
                CrashRecorder.note("events board: \(self.builds) row builds, \(self.buildMS) ms in 30 s")
                self.builds = 0
                self.buildMS = 0
            }
        }
        recompute()
    }

    func stop() {
        CrashRecorder.liveEventsOpen = false
        sinks = []
        ticker = nil
        pending = nil
    }

    func place(for event: SportsEvent?) -> EventWhere {
        event.flatMap { places[$0.id] } ?? EventWhere()
    }

    /// From the board: which tile is focused (its key; nil when none).
    func focusChanged(to key: String?) {
        lastInput = Date()
        let old = focusedKey
        focusedKey = key
        if pending != nil, key != old { applyPending() }
    }

    /// The latest version of a game shown (a focused copy can be older).
    func current(_ event: SportsEvent?) -> SportsEvent? {
        guard let event else { return nil }
        for row in rows { if let match = row.events.first(where: { $0.id == event.id }) { return match } }
        return event
    }

    /// Settings changed (e.g. games not in my channels).
    func refresh() { scheduleRecompute() }

    private func scheduleRecompute() {
        guard !scheduled else { return }
        scheduled = true
        // @Published sends before the value changes: read it next turn.
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.recompute()
        }
    }

    private func recompute() {
        let started = Date()
        let store = LiveTVStore.shared
        let now = self.now
        let all = store.sportsEvents.isEmpty ? store.plainSportsEvents : store.sportsEvents
        var states: [String: SportsEvent.State] = [:]
        states.reserveCapacity(all.count)
        for event in all { states[event.id] = event.state(at: now) }
        func isLive(_ event: SportsEvent) -> Bool {
            let state = states[event.id]
            return state == .live || state == .mayHaveEnded
        }
        var result: [Row] = []
        let live = all.filter { isLive($0) && !$0.sources.isEmpty }
        if !live.isEmpty {
            result.append(Row(id: "live", title: L10n.string("live_events_now", fallback: "Live now"), events: live, live: live.count))
        }
        let horizon = now.addingTimeInterval(8 * 24 * 3600)
        let showUnwatchable = SportsData.showsUnwatchable
        var bySport: [String: [SportsEvent]] = [:]
        for event in all {
            let state = states[event.id]
            guard state == .live || state == .mayHaveEnded || state == .upcoming || state == .postponed,
                  let start = event.start, start < horizon else { continue }
            if event.sources.isEmpty, !showUnwatchable { continue }
            bySport[event.league.isEmpty ? "Other" : event.league, default: []].append(event)
        }
        let sports = bySport.keys.sorted { a, b in
            let ia = Self.sportOrder.firstIndex(of: a) ?? 99, ib = Self.sportOrder.firstIndex(of: b) ?? 99
            return ia != ib ? ia < ib : a < b
        }
        for sport in sports {
            // Games you can watch by time, then the rest (dimmed) by time.
            let list = (bySport[sport] ?? []).sorted { a, b in
                if a.sources.isEmpty != b.sources.isEmpty { return !a.sources.isEmpty }
                let x = a.start ?? .distantFuture, y = b.start ?? .distantFuture
                return x != y ? x < y : a.id < b.id
            }
            let liveCount = list.filter { isLive($0) && !$0.sources.isEmpty }.count
            result.append(Row(id: "sport|\(sport)", title: sport, events: list, live: liveCount))
        }
        let untimed = all.filter { states[$0.id] == .unknownTime && !$0.sources.isEmpty }
        if !untimed.isEmpty {
            result.append(Row(id: "untimed", title: L10n.string("live_events_unknown", fallback: "Time not listed"), events: untimed, live: 0))
        }
        if !store.families.isEmpty {
            result.append(Row(id: "families", title: L10n.string("live_event_channels_title", fallback: "Event channels"),
                              events: [], families: store.families, live: 0))
        }
        // Where each shown game is on.
        var newPlaces: [String: EventWhere] = [:]
        for row in result {
            for event in row.events where newPlaces[event.id] == nil {
                var place = EventWhere()
                place.feeds = event.feeds.count
                if let source = event.channels.first, let channel = store.sourceChannel(source) {
                    place.channelName = channel.name
                    place.channelDisplay = channel.displayName
                    place.logoURLs = store.logoSpec(for: channel).urls
                    place.inLineup = source.kind == .lineup
                }
                newPlaces[event.id] = place
            }
        }
        let watchable = all.filter { !$0.sources.isEmpty }
        let newHero = watchable.first(where: isLive) ?? watchable.first { states[$0.id] == .upcoming }
        builds += 1
        buildMS += Int(Date().timeIntervalSince(started) * 1000)

        // Keep the focused tile until you move (or 5 s pass).
        if let focusedKey, contains(rows, focusedKey), !contains(result, focusedKey), Date().timeIntervalSince(lastInput) < 5 {
            pending = (result, newHero, newPlaces)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.pending != nil, Date().timeIntervalSince(self.lastInput) >= 5 else { return }
                self.applyPending()
            }
            return
        }
        pending = nil
        places = newPlaces
        rows = result
        hero = newHero
    }

    private func applyPending() {
        guard let pending else { return }
        self.pending = nil
        places = pending.places
        rows = pending.rows
        hero = pending.hero
    }

    private func contains(_ rows: [Row], _ key: String) -> Bool {
        rows.contains { row in
            key.hasPrefix(row.id + "|") && (row.events.contains { key == row.id + "|" + $0.id }
                                            || row.families.contains { key == row.id + "|" + $0.id })
        }
    }
}

// MARK: - Tile

struct LiveEventTile: View {
    let event: SportsEvent
    let place: EventWhere
    let focused: Bool
    let now: Date

    var body: some View {
        let state = event.state(at: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                chipLabel(event.leagueShort, fill: focused ? Color.black.opacity(0.75) : Color.white.opacity(0.18))
                statusChip(state)
            }
            matchup(state)
                .frame(height: 70)
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            bottomLine(state)
                .frame(height: 30, alignment: .leading)
        }
        .opacity(event.sources.isEmpty && !focused ? 0.45 : 1)
        .foregroundColor(focused ? .black : .white)
        .padding(18)
        .frame(width: 400, height: 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(focused ? Color.white : Color.white.opacity(0.09)))
        .scaleEffect(focused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private var title: String {
        if let game = event.game { return SportsNames.title(game) }
        return event.title
    }

    @ViewBuilder
    private func statusChip(_ state: SportsEvent.State) -> some View {
        switch state {
        case .live:
            chipLabel(L10n.string("live_badge_live", fallback: "LIVE"), fill: LiveStyle.watching)
        case .mayHaveEnded:
            chipLabel(L10n.string("live_event_may_have_ended", fallback: "MAY HAVE ENDED"), fill: Color.white.opacity(focused ? 0.0 : 0.12),
                      foreground: focused ? .black : .white, outlined: focused)
        case .upcoming:
            chipLabel(event.start.map { dayTime($0, now: now) } ?? "", fill: focused ? Color.black.opacity(0.08) : Color.white.opacity(0.12),
                      foreground: focused ? .black : .white)
        case .finished:
            chipLabel(L10n.string("live_event_ended", fallback: "ENDED"), fill: focused ? Color.black.opacity(0.08) : Color.white.opacity(0.12),
                      foreground: focused ? .black : .white)
        case .postponed:
            chipLabel(L10n.string("live_event_postponed", fallback: "POSTPONED"), fill: Color.orange.opacity(0.85))
        case .unknownTime:
            chipLabel(L10n.string("live_events_no_time", fallback: "Time not listed"), fill: Color.white.opacity(focused ? 0.0 : 0.12),
                      foreground: focused ? .black : .white, outlined: focused)
        }
    }

    @ViewBuilder
    private func matchup(_ state: SportsEvent.State) -> some View {
        if let game = event.game {
            let left = game.isSoccer ? game.home : game.away
            let right = game.isSoccer ? game.away : game.home
            HStack {
                TeamBadge(team: left, size: 64, focused: focused)
                Spacer()
                Text(game.isSoccer ? "vs" : "@").font(.system(size: 26, weight: .bold)).opacity(0.85)
                Spacer()
                TeamBadge(team: right, size: 64, focused: focused)
            }
        } else {
            HStack {
                Image(systemName: SportsNames.symbol(event.league))
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.black.opacity(0.08) : Color.white.opacity(0.1)))
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func bottomLine(_ state: SportsEvent.State) -> some View {
        switch state {
        case .live, .mayHaveEnded:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if let start = event.start {
                        Text(L10n.format("live_events_started", fallback: "Started %@", clock.string(from: start)))
                            .font(.system(size: 17, weight: .medium)).opacity(0.65)
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(focused ? Color.black.opacity(0.15) : Color.white.opacity(0.2))
                        GeometryReader { geo in
                            Capsule().fill(focused ? Color.black : Color.white)
                                .frame(width: geo.size.width * event.progress(at: now))
                        }
                    }
                    .frame(height: 5)
                }
                whereLine(compact: true)
            }
        case .upcoming, .unknownTime, .postponed, .finished:
            whereLine(compact: false)
        }
    }

    @ViewBuilder
    private func whereLine(compact: Bool) -> some View {
        let feeds = place.feeds
        HStack(spacing: 10) {
            if let display = place.channelDisplay {
                ChannelLogoView(urls: place.logoURLs, width: compact ? 60 : 80, height: compact ? 20 : 28,
                                focused: focused) {
                    Text(display).font(.system(size: 16, weight: .bold)).lineLimit(1)
                }
                if feeds > 0 {
                    Text(L10n.format("live_event_backup_feeds", fallback: "+ %d backup feeds", feeds))
                        .font(.system(size: compact ? 15 : 17)).opacity(0.65)
                }
            } else if feeds > 0 {
                Text(L10n.format("live_event_provider_feeds", fallback: "%d feeds from your provider", feeds))
                    .font(.system(size: compact ? 15 : 17)).opacity(0.65)
            } else {
                Text(notInChannels(event))
                    .font(.system(size: compact ? 15 : 17)).opacity(0.75)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Hero and backdrop

/// The top of Live Events: the focused game, big.
struct LiveEventsHero: View {
    /// The focused game; nil shows the model's pick (first live game).
    let focused: SportsEvent?
    let now: Date
    @ObservedObject private var model = LiveEventsModel.shared

    var body: some View {
        let event = model.current(focused) ?? model.hero
        let place = model.place(for: event)
        return VStack(alignment: .leading, spacing: 10) {
            if let event {
                HStack(spacing: 10) {
                    chipLabel(leagueLine(event),
                              fill: Color.white.opacity(0.18))
                    Spacer()
                    Text(clock.string(from: now))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                }
                HStack(spacing: 16) {
                    if let game = event.game {
                        TeamBadge(team: game.isSoccer ? game.home : game.away, size: 62)
                        TeamBadge(team: game.isSoccer ? game.away : game.home, size: 62)
                    }
                    Text(event.game.map(SportsNames.title) ?? event.title)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                statusLine(event)
                if event.state(at: now) == .live {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white).frame(width: 420 * event.progress(at: now))
                    }
                    .frame(width: 420, height: 6)
                }
                whereLine(event, place)
            } else {
                HStack {
                    Text(L10n.string("live_events_title", fallback: "Live Events"))
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(clock.string(from: now))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                }
                Text(L10n.string("live_events_empty_hero", fallback: "This week's games, and where you can watch them."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 36)
    }

    @ViewBuilder
    private func statusLine(_ event: SportsEvent) -> some View {
        let state = event.state(at: now)
        HStack(spacing: 12) {
            switch state {
            case .live:
                chipLabel(L10n.string("live_badge_live", fallback: "LIVE"), fill: LiveStyle.watching)
            case .upcoming:
                chipLabel(L10n.string("live_badge_later", fallback: "LATER"), fill: .clear, outlined: true)
            case .finished:
                chipLabel(L10n.string("live_event_ended", fallback: "ENDED"), fill: Color.white.opacity(0.18))
            case .postponed:
                chipLabel(L10n.string("live_event_postponed", fallback: "POSTPONED"), fill: Color.orange.opacity(0.85))
            case .mayHaveEnded:
                chipLabel(L10n.string("live_event_may_have_ended", fallback: "MAY HAVE ENDED"), fill: .clear, outlined: true)
            case .unknownTime:
                EmptyView()
            }
            Text(statusText(event, state))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func statusText(_ event: SportsEvent, _ state: SportsEvent.State) -> String {
        var parts: [String] = []
        switch state {
        case .live, .mayHaveEnded:
            if let start = event.start { parts.append(L10n.format("live_events_started", fallback: "Started %@", clock.string(from: start))) }
        case .upcoming:
            if let start = event.start {
                parts.append(dayTime(start, now: now))
                let minutes = Int(start.timeIntervalSince(now) / 60)
                if minutes < 180 {
                    parts.append(L10n.format("live_starts_in", fallback: "Starts in %@", minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(max(1, minutes)) m"))
                }
            }
        case .finished, .postponed, .unknownTime:
            break
        }
        if let venue = event.game?.venue { parts.append(venue) }
        return parts.joined(separator: "   ·   ")
    }

    @ViewBuilder
    private func whereLine(_ event: SportsEvent, _ place: EventWhere) -> some View {
        let feeds = place.feeds
        HStack(spacing: 14) {
            if let display = place.channelDisplay, let name = place.channelName {
                ChannelLogoView(urls: place.logoURLs, width: 80, height: 32) {
                    Text(display).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                }
                let parts: [String?] = [
                    place.inLineup
                        ? L10n.format("live_event_on_lineup", fallback: "On %@, in your lineup", name)
                        : L10n.format("live_event_on_guide", fallback: "On %@", name),
                    feeds > 0 ? L10n.format("live_event_backups_long", fallback: "%d backup feeds from your provider", feeds) : nil
                ]
                Text(parts.compactMap { $0 }.joined(separator: "   ·   "))
            } else if feeds > 0 {
                Text(L10n.format("live_event_provider_feeds", fallback: "%d feeds from your provider", feeds))
            } else {
                Text(notInChannels(event))
            }
        }
        .font(.system(size: 20))
        .foregroundColor(.white.opacity(0.7))
        .lineLimit(1)
    }
}

/// The focused game's two team logos, big and faded over a glow, behind
/// the top right of Live Events.
struct LiveEventBackdrop: View {
    let focused: SportsEvent?
    @ObservedObject private var model = LiveEventsModel.shared

    var body: some View {
        let event = model.current(focused) ?? model.hero
        return GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let game = event?.game {
                    ZStack {
                        RadialGradient(colors: [Color(red: 0.05, green: 0.2, blue: 0.55).opacity(0.85), .clear],
                                       center: .center, startRadius: 40, endRadius: geo.size.width * 0.32)
                        HStack(spacing: 40) {
                            TeamBadge(team: game.isSoccer ? game.home : game.away, size: geo.size.height * 0.3)
                            Text("VS")
                                .font(.system(size: geo.size.height * 0.08, weight: .heavy))
                                .foregroundColor(.white.opacity(0.7))
                            TeamBadge(team: game.isSoccer ? game.away : game.home, size: geo.size.height * 0.3)
                        }
                        .opacity(0.45)
                    }
                    .frame(width: geo.size.width * 0.55, height: geo.size.height * 0.48)
                    .mask(
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: UnitPoint(x: 0.35, y: 0.5))
                            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    )
                    .id(game.id)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.35), value: event?.id)
    }
}

// MARK: - Board

/// Live Events: a row of what's live, a row per sport for the week (games
/// none of your channels has dimmed at the end), events without a time,
/// and the provider's event channels. Left from a
/// row's first game opens the Sports column (like the guide's Jump to).
struct LiveEventsBoard: View {
    @Binding var focusedEvent: SportsEvent?
    let onPickFamily: (EventFamily) -> Void
    let onDetail: (SportsEvent) -> Void
    let onWhere: (SportsEvent) -> Void

    private let store = LiveTVStore.shared
    @ObservedObject private var model = LiveEventsModel.shared
    @ObservedObject private var reminders = LiveReminders.shared
    @FocusState private var focus: String?
    @State private var columnOpen = false
    @State private var columnOrigin: String?
    @State private var columnReturn: String?
    @FocusState private var columnFocus: String?
    @State private var lastFocus: String?
    @State private var lastRedirect = Date.distantPast
    @Environment(\.isEnabled) private var isEnabled

    typealias Row = LiveEventsModel.Row
    private var now: Date { model.now }

    var body: some View {
        let rows = model.rows
        return ScrollViewReader { scroller in
            ZStack(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if rows.isEmpty {
                            Text(L10n.string("live_events_none", fallback: "No upcoming events found in your channels right now."))
                                .font(.system(size: 24)).foregroundColor(.white.opacity(0.6)).padding(.vertical, 30)
                        }
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.bottom, 80)
                }
                .disabled(columnOpen)
                .overlay(Color.black.opacity(columnOpen ? 0.5 : 0).allowsHitTesting(false))
                .focusSection()
                if columnOpen {
                    sportsColumn(rows, scroller: scroller)
                        .padding(.leading, -16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: columnOpen)
            .onChange(of: focus) { old, new in
                if let new, !new.hasPrefix("h|") { lastFocus = new }
                model.focusChanged(to: new.flatMap { $0.hasPrefix("h|") ? nil : $0 })
                handleFocus(old: old, new: new, rows: rows)
            }
            .onChange(of: isEnabled) { _, enabled in
                // Back from a details card or Where to Watch: the tile again.
                guard enabled, let target = lastFocus else { return }
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if focus == nil, !columnOpen { focus = target }
                    }
                }
            }
            .onChange(of: columnFocus) { old, new in
                if let new {
                    scroller.scrollTo(new, anchor: .top)
                } else if old != nil, columnOpen {
                    columnOpen = false
                }
            }
        }
        .onAppear {
            CrashRecorder.note("events: open, \(store.sportsEvents.count) events, \(CrashRecorder.memoryMB()) MB")
            model.start()
            SportsData.shared.refreshIfNeeded()
            store.sportsOpened()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: Rows

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LiveSectionLabel(text: row.title)
                Text(rowSummary(row))
                    .font(LiveStyle.sectionFont)
                    .tracking(1.2)
                    .foregroundColor(row.live > 0 ? LiveStyle.watching : LiveStyle.sectionColor)
            }
            HStack(spacing: 20) {
                // A focus target in the margin: Left from the first tile
                // lands here and opens the Sports column.
                Color.white.opacity(0.001)
                    .frame(width: 20, height: 240)
                    .focusable(!columnOpen)
                    .focused($focus, equals: "h|\(row.id)")
                    .focusEffectDisabledIfAvailable()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(row.events) { event in
                            tileButton(event, row: row)
                        }
                        ForEach(row.families) { family in
                            familyButton(family, row: row)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 60)
                }
            }
            .padding(.leading, -40)
        }
    }

    private func rowSummary(_ row: Row) -> String {
        var parts = ["·  \(row.count)"]
        if row.live > 0, row.id != "live" { parts.append(L10n.format("live_events_n_live", fallback: "%d live", row.live)) }
        return parts.joined(separator: "  ·  ")
    }

    private func key(_ row: Row, _ id: String) -> String { "\(row.id)|\(id)" }


    private func tileButton(_ event: SportsEvent, row: Row) -> some View {
        let id = key(row, event.id)
        let isFocused = focus == id
        let upcoming = event.state(at: now) == .upcoming
        return Button {
            select(event)
        } label: {
            LiveEventTile(event: event, place: model.place(for: event), focused: isFocused, now: now)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .contextMenu {
            if !event.sources.isEmpty {
                Button {
                    onWhere(event)
                } label: {
                    Label(L10n.string("live_event_where", fallback: "Where to Watch"), systemImage: "list.bullet")
                }
            }
            if upcoming, let target = store.reminderTarget(for: event) {
                let isSet = reminders.isSet(channelID: target.channel.id, start: target.program.start)
                Button {
                    reminders.toggle(channel: target.channel, program: target.program)
                } label: {
                    Label(isSet ? L10n.string("live_reminder_remove", fallback: "Remove Reminder")
                                : L10n.string("live_remind_me", fallback: "Remind Me"),
                          systemImage: isSet ? "bell.slash" : "bell")
                }
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { focusedEvent = event }
        }
    }

    private func familyButton(_ family: EventFamily, row: Row) -> some View {
        let id = key(row, family.id)
        let isFocused = focus == id
        return Button {
            onPickFamily(family)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                chipLabel(family.league.isEmpty ? "EVENTS" : SportsMatcher.shortLeague(family.league),
                          fill: isFocused ? Color.black.opacity(0.75) : Color.white.opacity(0.18))
                Image(systemName: "rectangle.stack.fill").font(.system(size: 34)).frame(height: 70)
                Text(family.name).font(.system(size: 24, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
                Text(L10n.format("live_family_feeds", fallback: "%d feeds · Up/Down to surf", family.feeds.count))
                    .font(.system(size: 17)).opacity(0.65)
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(18)
            .frame(width: 400, height: 240, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(isFocused ? Color.white : Color.white.opacity(0.07)))
            .scaleEffect(isFocused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
    }

    private func select(_ event: SportsEvent) {
        CrashRecorder.note("events: select \(event.leagueShort) \(event.state(at: now))")
        switch event.state(at: now) {
        case .live, .mayHaveEnded, .unknownTime:
            if event.sources.isEmpty { onDetail(event) } else { store.watchSportsEvent(event) }
        case .upcoming, .postponed, .finished:
            onDetail(event)
        }
    }

    // MARK: Sports column

    /// The margin target only opens the column when reached with Left from
    /// that row's first tile; arriving any other way moves on to the row.
    private func handleFocus(old: String?, new: String?, rows: [Row]) {
        guard let new, new.hasPrefix("h|") else { return }
        let rowID = String(new.dropFirst(2))
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        let first = row.events.first.map { key(row, $0.id) } ?? row.families.first.map { key(row, $0.id) }
        if let old, old.hasPrefix(rowID + "|"), rows.count > 1 {
            CrashRecorder.note("events: sports column")
            columnReturn = old
            columnOrigin = rowID
            columnOpen = true
            columnFocus = rowID
            DispatchQueue.main.async { if columnOpen { columnFocus = rowID } }
        } else if let first {
            // Never bounce focus back and forth.
            guard Date().timeIntervalSince(lastRedirect) > 0.4 else { return }
            lastRedirect = Date()
            DispatchQueue.main.async { focus = (old?.hasPrefix(rowID + "|") == true ? old : first) }
        }
    }

    private func closeColumn(to rowID: String?, rows: [Row], scroller: ScrollViewProxy) {
        columnOpen = false
        let target: String?
        if let rowID, let row = rows.first(where: { $0.id == rowID }) {
            scroller.scrollTo(rowID, anchor: .top)
            target = row.events.first.map { key(row, $0.id) } ?? row.families.first.map { key(row, $0.id) }
        } else {
            target = columnReturn
        }
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !columnOpen, let target, focus != target else { return }
                focus = target
            }
        }
    }

    private func sportsColumn(_ rows: [Row], scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LiveSectionLabel(text: L10n.string("live_sports", fallback: "Sports"))
                .padding(.leading, 22)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        columnButton(row, rows: rows, scroller: scroller)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 14)
        .padding(.horizontal, 12)
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: 640, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: LiveStyle.panelRadius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 8, y: 8)
        )
        .focusSection()
        .onExitCommand { closeColumn(to: nil, rows: rows, scroller: scroller) }
    }

    private func columnButton(_ row: Row, rows: [Row], scroller: ScrollViewProxy) -> some View {
        let focused = columnFocus == row.id
        return Button {
            closeColumn(to: row.id, rows: rows, scroller: scroller)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(LiveStyle.watching)
                    .frame(width: 9, height: 9)
                    .opacity(row.id == columnOrigin && !focused ? 1 : 0)
                Text(row.title)
                    .font(LiveStyle.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if row.live > 0, row.id != "live" {
                    Text(L10n.format("live_events_n_live", fallback: "%d live", row.live))
                        .font(LiveStyle.rowValue)
                        .foregroundColor(focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching)
                }
                Text("\(row.count)")
                    .font(LiveStyle.rowValue.monospacedDigit())
                    .opacity(0.6)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused))
        .focused($columnFocus, equals: row.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .right { closeColumn(to: row.id, rows: rows, scroller: scroller) }
        }
    }
}

// MARK: - Where to watch

struct LiveEventWherePanel: View {
    let event: SportsEvent
    let onClose: () -> Void
    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        LiveSidePanel(edge: .trailing, width: 800) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    LiveSectionLabel(text: L10n.string("live_event_where", fallback: "Where to Watch"))
                        .padding(.leading, 4)
                    Text(event.game.map(SportsNames.title) ?? event.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .padding(.bottom, 10)
                    let english = event.channels.filter { !$0.spanish }
                    let spanish = event.sources.filter { $0.spanish }
                    let feeds = event.feeds.filter { !$0.spanish }
                    if !english.isEmpty { section(L10n.string("live_event_your_channels", fallback: "Your channels"), english) }
                    if !spanish.isEmpty { section(L10n.string("live_event_spanish", fallback: "Spanish"), spanish) }
                    if !feeds.isEmpty { section(L10n.string("live_event_provider_section", fallback: "Event feeds from your provider"), feeds) }
                    Text(L10n.string("live_event_where_hint", fallback: "Whichever you pick, the others stay as automatic backups."))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 14)
                }
                .padding(.top, 50)
                .padding(.bottom, 60)
                .padding(.trailing, 70)
            }
            .focusSection()
        }
        .onExitCommand { onClose() }
    }

    @ViewBuilder
    private func section(_ title: String, _ sources: [EventSource]) -> some View {
        LiveSectionLabel(text: title)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .padding(.leading, 4)
        ForEach(sources, id: \.channelID) { source in
            if let channel = store.sourceChannel(source) {
                LivePanelRow(title: channel.name, detail: detail(source, channel), accessory: .chevron(nil)) {
                    onClose()
                    store.watchSportsEvent(event, preferring: source.channelID)
                }
            }
        }
    }

    private func detail(_ source: EventSource, _ channel: LiveTVChannel) -> String {
        source.kind == .provider ? [source.detail, store.feedSummary(channel)].filter { !$0.isEmpty }.joined(separator: " · ") : source.detail
    }
}

// MARK: - Details for a game that hasn't started

struct LiveEventDetailCard: View {
    let event: SportsEvent
    let onClose: () -> Void
    let onWhere: () -> Void
    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var reminders = LiveReminders.shared
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    chipLabel(leagueLine(event),
                              fill: Color.white.opacity(0.18))
                    Spacer()
                }
                HStack(spacing: 18) {
                    if let game = event.game {
                        TeamBadge(team: game.isSoccer ? game.home : game.away, size: 70)
                        TeamBadge(team: game.isSoccer ? game.away : game.home, size: 70)
                    }
                    Text(event.game.map(SportsNames.title) ?? event.title)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Text(summary)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    if let target = store.reminderTarget(for: event), event.state(at: Date()) == .upcoming {
                        let isSet = reminders.isSet(channelID: target.channel.id, start: target.program.start)
                        pill(isSet ? L10n.string("live_reminder_set", fallback: "Reminder Set") : L10n.string("live_remind_me", fallback: "Remind Me"),
                             symbol: isSet ? "bell.fill" : "bell", id: "remind") {
                            reminders.toggle(channel: target.channel, program: target.program)
                        }
                    }
                    if let source = event.channels.first, let channel = store.sourceChannel(source) {
                        pill(L10n.format("live_watch_now", fallback: "Watch %@ Now", channel.name), symbol: "play.fill", id: "watch") {
                            onClose()
                            store.watchSportsEvent(event, preferring: source.channelID)
                        }
                    }
                    if !event.sources.isEmpty {
                        pill(L10n.string("live_event_where", fallback: "Where to Watch"), symbol: "list.bullet", id: "where") {
                            onWhere()
                        }
                    }
                }
                .padding(.top, 8)
                if event.sources.isEmpty {
                    Text(notInChannels(event) + ". " + L10n.string("live_event_none_yet", fallback: "If one of your channels or event feeds picks it up, it'll show here."))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(44)
            .frame(width: 1150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.black.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 12)
            )
            .focusSection()
        }
        .onExitCommand { onClose() }
        .onAppear {
            DispatchQueue.main.async {
                focus = store.reminderTarget(for: event) != nil ? "remind" : (event.channels.isEmpty ? "where" : "watch")
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let start = event.start {
            let calendar = Calendar.current
            let day: String
            if calendar.isDateInToday(start) {
                day = calendar.component(.hour, from: start) >= 17
                    ? L10n.string("live_time_tonight", fallback: "Tonight") : L10n.string("live_time_today", fallback: "Today")
            } else if calendar.isDateInTomorrow(start) {
                day = L10n.string("live_time_tomorrow", fallback: "Tomorrow")
            } else {
                day = longWeekday.string(from: start)
            }
            parts.append("\(day) \(clock.string(from: start))")
        }
        if let venue = event.game?.venue { parts.append(venue) }
        if let source = event.channels.first, let channel = store.sourceChannel(source) {
            parts.append(L10n.format("live_event_on_guide", fallback: "On %@", channel.name))
        } else if event.feeds.isEmpty, let network = event.game?.networks.first {
            parts.append(L10n.format("live_event_on_guide", fallback: "On %@", network))
        }
        if !event.feeds.isEmpty {
            parts.append(L10n.format("live_event_provider_feeds", fallback: "%d feeds from your provider", event.feeds.count))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func pill(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        let focused = focus == id
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 30)
            .frame(height: 70)
            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
