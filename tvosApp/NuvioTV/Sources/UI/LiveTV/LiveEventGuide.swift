import SwiftUI

/// The player's mini guide while watching from Live Events: Left opens it on
/// the game on screen, listing the other games of that sport (live, final,
/// starting soon) with clock, score and channel. Select switches games, Right
/// lists a game's other channels and feeds, Left again opens the sports
/// column (the list follows it). Back steps out one level.
///
/// Built from Live Events' rows (no requests of its own); while it's open the
/// live scoreboard keeps refreshing at its usual pace, even though a channel
/// is playing.
struct LiveEventGuide: View {
    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var model = LiveEventsModel.shared
    @FocusState private var rowFocus: String?
    @FocusState private var sportFocus: String?
    @FocusState private var sourceFocus: String?
    @State private var rowID = ""
    @State private var sportsOpen = false
    @State private var originRow: String?
    @State private var returnRow: String?
    @State private var sourcesFor: SportsEvent?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private enum Item: Identifiable {
        case header(String)
        case game(SportsEvent)
        var id: String {
            switch self {
            case .header(let title): return "gh|" + title
            case .game(let event): return event.id
            }
        }
    }

    private var row: LiveEventsModel.Row? { model.guideRows.first { $0.id == rowID } }

    /// The row's games you can watch, under its group labels.
    private var items: [Item] {
        guard let row else { return [] }
        var result: [Item] = []
        var label: String?
        var shownLabel: String?
        for event in row.events {
            if let header = row.headers[event.id] { label = header }
            guard !event.sources.isEmpty else { continue }
            if let label, label != shownLabel {
                result.append(.header(label))
                shownLabel = label
            }
            result.append(.game(event))
        }
        return result
    }

    private var firstGameID: String? {
        for item in items { if case .game(let event) = item { return event.id } }
        return nil
    }

    var body: some View {
        let width: CGFloat = sourcesFor != nil ? 1440 : (sportsOpen ? 1360 : 1000)
        LiveSidePanel(edge: .leading, width: width) {
            ScrollViewReader { scroller in
                VStack(alignment: .leading, spacing: 0) {
                    LiveSectionLabel(text: L10n.string("live_events_title", fallback: "Live Events") + "  ·  "
                                     + (row?.title ?? "") + "  ·  " + ChannelsView.clockFormatter.string(from: now))
                        .padding(.bottom, 24)
                    HStack(alignment: .top, spacing: 0) {
                        if sportsOpen {
                            sportsColumn
                                .frame(width: 320)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            divider
                        }
                        gameList
                            .frame(width: 820)
                            .opacity(sportsOpen || sourcesFor != nil ? LiveStyle.inactive : 1)
                            .disabled(sportsOpen || sourcesFor != nil)
                        if let event = sourcesFor {
                            divider
                            sourcesColumn(event)
                                .frame(width: 420)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    Text(hint)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.top, 14)
                }
                .padding(.leading, 70)
                .padding(.top, 50)
                .padding(.bottom, 40)
                .onAppear {
                    model.refreshNow()
                    LiveScores.shared.start("guide")
                    rowID = model.guideRowID(for: store.watchingEventID) ?? ""
                    let target = currentGameID() ?? firstGameID
                    DispatchQueue.main.async {
                        if let target { scroller.scrollTo(target, anchor: .center) }
                        rowFocus = target
                    }
                }
                .onChange(of: sportFocus) { _, sport in
                    // The list follows the sport being browsed.
                    guard let sport, sportsOpen else { return }
                    rowID = sport
                    if let first = items.first { scroller.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: sportsOpen)
        .animation(.easeOut(duration: 0.2), value: sourcesFor?.id)
        .onReceive(ticker) { date in
            now = date
            model.refreshNow()
        }
        .onReceive(LiveScores.shared.$revision.dropFirst()) { _ in model.refreshNow() }
        .onDisappear { LiveScores.shared.stop("guide") }
        .onExitCommand {
            if sourcesFor != nil {
                closeSources()
            } else if sportsOpen {
                closeSports(landingOn: nil)
            } else {
                store.closeMiniGuide()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.horizontal, 24)
    }

    private var hint: String {
        if sourcesFor != nil {
            return L10n.string("live_event_guide_hint_sources", fallback: "▲▼ choose   ·   Select: watch this one   ·   Back: games")
        }
        if sportsOpen {
            return L10n.string("live_event_guide_hint_sports", fallback: "▲▼ sports   ·   ▶ or Select: pick   ·   Back: close")
        }
        return L10n.string("live_event_guide_hint",
                           fallback: "▲▼ browse games   ·   Select: switch   ·   ▶ more ways to watch   ·   ◀ sports   ·   Back: close")
    }

    private func currentGameID() -> String? {
        guard let watching = store.watchingEventID else { return nil }
        for item in items {
            if case .game(let event) = item, model.matches(event, eventID: watching) { return event.id }
        }
        return nil
    }

    // MARK: Games

    private var gameList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if items.isEmpty {
                    Text(L10n.string("live_event_guide_empty", fallback: "Nothing else on in your channels right now."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.vertical, 20)
                }
                ForEach(items) { item in
                    switch item {
                    case .header(let title):
                        LiveSectionLabel(text: title)
                            .padding(.leading, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    case .game(let event):
                        gameRow(event)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .focusSection()
    }

    private func gameRow(_ event: SportsEvent) -> some View {
        let focused = rowFocus == event.id
        let place = model.place(for: event)
        let watching = store.watchingEventID.map { model.matches(event, eventID: $0) } ?? false
        let ink: Color = focused ? .black : .white
        return Button {
            pick(event, preferring: nil)
        } label: {
            HStack(spacing: 20) {
                sides(event, place, ink: ink)
                    .frame(width: 380, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    statusLine(event, place, ink: ink)
                    Text(whereText(place))
                        .font(.system(size: 18))
                        .opacity(0.65)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if watching {
                    HStack(spacing: 7) {
                        Circle().fill(LiveStyle.watching).frame(width: 10, height: 10)
                        Text(L10n.string("live_watching", fallback: "WATCHING"))
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.8)
                            .foregroundColor(focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching)
                    }
                }
            }
            .foregroundColor(ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, height: 96))
        .focused($rowFocus, equals: event.id)
        .focusEffectDisabledIfAvailable()
        .opacity(event.state(at: now) == .finished && !focused ? 0.6 : 1)
        .onMoveCommand { direction in
            if direction == .left { openSports(from: event) }
            if direction == .right { openSources(event) }
        }
    }

    @ViewBuilder
    private func sides(_ event: SportsEvent, _ place: EventWhere, ink: Color) -> some View {
        if let top = place.top, let bottom = place.bottom, place.parts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sideLine(top, score: place.topScore, ink: ink, soccer: event.game?.isSoccer ?? true)
                sideLine(bottom, score: place.bottomScore, ink: ink, soccer: event.game?.isSoccer ?? true)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.title.isEmpty ? event.title : place.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let top = place.top, let bottom = place.bottom {
                    Text(top.name + "  vs.  " + bottom.name)
                        .font(.system(size: 17))
                        .opacity(0.7)
                        .lineLimit(1)
                } else if let subtitle = place.subtitle {
                    Text(subtitle)
                        .font(.system(size: 17))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
        }
    }

    private func sideLine(_ team: SportsTeam, score: String?, ink: Color, soccer: Bool) -> some View {
        HStack(spacing: 10) {
            TeamBadge(team: team, size: 30)
            if let rank = team.rank {
                Text("\(rank)").font(.system(size: 16, weight: .heavy)).opacity(0.55)
            }
            Text(SportsNames.short(team, soccer: soccer))
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 6)
            if let score {
                Text(score)
                    .font(.system(size: 22, weight: .heavy).monospacedDigit())
                    .fixedSize()
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func statusLine(_ event: SportsEvent, _ place: EventWhere, ink: Color) -> some View {
        let state = event.state(at: now)
        HStack(spacing: 10) {
            switch state {
            case .live:
                Text(event.live == .delayed ? L10n.string("live_event_delayed", fallback: "DELAYED")
                                            : L10n.string("live_badge_live", fallback: "LIVE"))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(event.live == .delayed ? .black : .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(event.live == .delayed ? Color(red: 0.88, green: 0.63, blue: 0) : LiveStyle.watching))
                Text(place.partLabel ?? place.clock ?? "")
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
            case .mayHaveEnded:
                Text(L10n.string("live_event_likely_over", fallback: "Likely over"))
                    .font(.system(size: 19, weight: .semibold))
            case .finished:
                Text(place.clock ?? L10n.string("live_event_ended_short", fallback: "Ended"))
                    .font(.system(size: 19, weight: .semibold))
            case .upcoming:
                if let start = event.start {
                    Text(ChannelsView.clockFormatter.string(from: start) + untilText(start))
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                }
            case .postponed:
                Text(L10n.string("live_event_postponed", fallback: "POSTPONED"))
                    .font(.system(size: 19, weight: .semibold))
            case .unknownTime:
                Text(L10n.string("live_events_no_time", fallback: "Time not listed"))
                    .font(.system(size: 19, weight: .semibold))
            }
        }
    }

    private func untilText(_ start: Date) -> String {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        guard minutes >= 0, minutes < 6 * 60 else { return "" }
        if minutes < 60 { return "  ·  " + L10n.format("live_event_in_minutes", fallback: "in %d m", max(1, minutes)) }
        return "  ·  " + L10n.format("live_event_in_hours", fallback: "in %d h", (minutes + 30) / 60)
    }

    private func whereText(_ place: EventWhere) -> String {
        let name = place.channelName ?? place.pill
        let extra = place.situation ?? (place.footer.isEmpty ? nil : place.footer)
        return [name, extra].compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// Plays a game (a fight card: the part on now).
    private func pick(_ event: SportsEvent, preferring sourceID: String?) {
        let target = model.cardCurrent(event).flatMap { $0.sources.isEmpty ? nil : $0 } ?? event
        // Already on screen (for a card: the part on now): just close.
        if sourceID == nil, let watching = store.watchingEventID, target.id == watching || event.id == watching {
            store.closeMiniGuide()
            return
        }
        store.switchToEvent(target, preferring: sourceID)
    }

    // MARK: Sports column

    private var sportsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveSectionLabel(text: L10n.string("live_sports", fallback: "Sports"))
                .padding(.leading, 6)
                .padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.guideRows) { sport in
                        sportButton(sport)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .focusSection()
    }

    private func sportButton(_ sport: LiveEventsModel.Row) -> some View {
        let focused = sportFocus == sport.id
        let watchable = sport.events.filter { !$0.sources.isEmpty }.count
        return Button {
            closeSports(landingOn: sport.id)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(LiveStyle.watching)
                    .frame(width: 9, height: 9)
                    .opacity(sport.id == originRow && !focused ? 1 : 0)
                Text(sport.title)
                    .font(LiveStyle.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if sport.live > 0 {
                    Text(L10n.format("live_events_n_live", fallback: "%d live", sport.live))
                        .font(LiveStyle.rowValue)
                        .foregroundColor(focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching)
                }
                Text("\(watchable)")
                    .font(LiveStyle.rowValue.monospacedDigit())
                    .opacity(0.6)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused))
        .focused($sportFocus, equals: sport.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .right { closeSports(landingOn: sport.id) }
        }
    }

    private func openSports(from event: SportsEvent) {
        guard model.guideRows.count > 1 else { return }
        returnRow = event.id
        originRow = rowID
        sportsOpen = true
        sportFocus = rowID
        DispatchQueue.main.async { if sportsOpen { sportFocus = rowID } }
    }

    /// Closes the sports column: onto the first game of a sport, or (Back)
    /// back to the row you came from.
    private func closeSports(landingOn sport: String?) {
        if let sport { rowID = sport } else if let originRow { rowID = originRow }
        let target = sport == nil ? returnRow : firstGameID
        sportsOpen = false
        sportFocus = nil
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !sportsOpen, let target, rowFocus != target else { return }
                rowFocus = target
            }
        }
    }

    // MARK: Other ways to watch

    private func sourcesColumn(_ event: SportsEvent) -> some View {
        let basis = model.cardCurrent(event) ?? event
        return VStack(alignment: .leading, spacing: 8) {
            LiveSectionLabel(text: event.game.map(SportsNames.title) ?? event.title)
                .padding(.leading, 6)
                .padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(basis.sources, id: \.channelID) { source in
                        if let channel = store.sourceChannel(source) {
                            sourceButton(source, channel: channel, event: basis)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .focusSection()
    }

    private func sourceButton(_ source: EventSource, channel: LiveTVChannel, event: SportsEvent) -> some View {
        let focused = sourceFocus == source.channelID
        return Button {
            sourcesFor = nil
            store.switchToEvent(event, preferring: source.channelID)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(channel.name)
                        .font(LiveStyle.rowTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if source.spanish {
                        Text("ES")
                            .font(.system(size: 14, weight: .heavy))
                            .padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder((focused ? Color.black : Color.white).opacity(0.5), lineWidth: 1.5))
                    }
                }
                if !source.detail.isEmpty {
                    Text(source.detail)
                        .font(.system(size: 17))
                        .opacity(0.6)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, height: 76))
        .focused($sourceFocus, equals: source.channelID)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .left { closeSources() }
        }
    }

    private func openSources(_ event: SportsEvent) {
        let basis = model.cardCurrent(event) ?? event
        guard !basis.sources.isEmpty else { return }
        returnRow = event.id
        sourcesFor = event
        let first = basis.sources.first?.channelID
        DispatchQueue.main.async { sourceFocus = first }
    }

    private func closeSources() {
        let target = returnRow
        sourcesFor = nil
        sourceFocus = nil
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard sourcesFor == nil, let target, rowFocus != target else { return }
                rowFocus = target
            }
        }
    }
}
