import SwiftUI

/// My Sports: pick leagues (the ones found in your channels are suggested),
/// optionally favorite teams, then review. Back steps back; Back on the
/// first step closes without changes.
struct MySportsSetupView: View {
    let onDone: () -> Void

    @ObservedObject private var mySports = MySports.shared
    @ObservedObject private var schedule = SportsData.shared
    @State private var step = 0
    @State private var leagues: [String] = []
    @State private var teams: Set<String> = []
    @State private var reminders = false
    @State private var teamLeague: String?
    @State private var counts: [String: Int] = [:]
    @FocusState private var focus: String?

    private static let sports = ["Football", "Basketball", "Baseball", "Hockey", "Soccer"]
    private static let green = Color(red: 0.2, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            switch step {
            case 0: leaguesStep
            case 1: teamsStep
            default: summaryStep
            }
        }
        .onAppear(perform: load)
        .onExitCommand {
            if step > 0 { step -= 1 } else { onDone() }
        }
    }

    private func load() {
        counts = MySports.suggestionCounts(LiveTVStore.shared.events)
        let prefs = mySports.prefs
        if prefs.configured {
            leagues = prefs.leagues
        } else {
            // Suggested: leagues found in your channels (else the standard set).
            let found = SportsData.leagues.filter { (counts[$0.short] ?? 0) > 0 }.map(\.short)
            leagues = found.isEmpty ? SportsData.leagues.filter(\.standard).map(\.short) : found
        }
        teams = Set(prefs.teams)
        reminders = prefs.reminders
        CrashRecorder.note("my sports: setup open, \(leagues.count) leagues suggested")
    }

    private func header(_ step: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("my_sports_step", fallback: "MY SPORTS  ·  STEP %d OF 3", step))
                .font(.system(size: 18, weight: .heavy))
                .tracking(1.6)
                .foregroundColor(.white.opacity(0.5))
            Text(title)
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
            Text(detail)
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        let focused = focus == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(focused ? .black : .white)
                .padding(.horizontal, 40)
                .frame(height: 70)
                .background(Capsule().fill(focused ? Color.white : Color.white.opacity(primary ? 0.24 : 0.14)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    // MARK: Step 1: leagues

    private var leaguesStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            header(1, L10n.string("my_sports_leagues_title", fallback: "What do you watch?"),
                   L10n.string("my_sports_leagues_detail", fallback: "Pick the leagues you follow. Their games get logos, times and where to watch; the schedule is checked only for these. Other sports stay under More events."))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Self.sports, id: \.self) { sport in
                        let list = SportsData.leagues.filter { $0.sport == sport }
                        VStack(alignment: .leading, spacing: 12) {
                            LiveSectionLabel(text: sport)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(400), spacing: 20), count: 4), alignment: .leading, spacing: 16) {
                                ForEach(list, id: \.short) { league in
                                    leagueTile(league)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 6)
            }
            .focusSection()
            HStack(spacing: 20) {
                actionButton(L10n.string("my_sports_cancel", fallback: "Cancel"), id: "cancel") { onDone() }
                Spacer()
                actionButton(L10n.string("my_sports_next_teams", fallback: "Next: favorite teams"), id: "next1", primary: true) {
                    // Picked leagues take effect now, so their teams can load.
                    let picked = leagues
                    mySports.update { $0.leagues = picked; $0.configured = true }
                    teamLeague = picked.first
                    step = 1
                }
            }
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
    }

    private func leagueTile(_ league: SportsData.League) -> some View {
        let id = "league|\(league.short)"
        let focused = focus == id
        let on = leagues.contains(league.short)
        let count = counts[league.short] ?? 0
        return Button {
            if let index = leagues.firstIndex(of: league.short) { leagues.remove(at: index) } else { leagues.append(league.short) }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(league.name)
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(count > 0
                         ? L10n.format("my_sports_in_channels", fallback: "%d events in your channels", count)
                         : " ")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(focused ? Color(red: 0.15, green: 0.35, blue: 0.8) : Color(red: 0.5, green: 0.7, blue: 1))
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().strokeBorder(focused ? Color.black.opacity(0.4) : Color.white.opacity(0.4), lineWidth: 3)
                        .opacity(on ? 0 : 1)
                    Circle().fill(Self.green).opacity(on ? 1 : 0)
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundColor(.white).opacity(on ? 1 : 0)
                }
                .frame(width: 32, height: 32)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 22)
            .frame(width: 400, height: 96)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(focused ? Color.white : Color.white.opacity(on ? 0.14 : 0.07))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Self.green, lineWidth: on && !focused ? 3 : 0))
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    // MARK: Step 2: favorite teams

    private var pickedLeagues: [SportsData.League] {
        leagues.compactMap { short in SportsData.leagues.first { $0.short == short } }
    }

    private var teamsStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            header(2, L10n.string("my_sports_teams_title", fallback: "Any favorite teams?"),
                   L10n.string("my_sports_teams_detail", fallback: "Optional. Their games come first in Live Events."))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(pickedLeagues, id: \.short) { league in
                        let id = "tab|\(league.short)"
                        let focused = focus == id
                        let selected = teamLeague == league.short
                        Button { teamLeague = league.short } label: {
                            Text(league.name)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(focused ? .black : .white)
                                .padding(.horizontal, 26)
                                .frame(height: 52)
                                .background(Capsule().fill(focused ? Color.white : Color.white.opacity(selected ? 0.24 : 0.1)))
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focused($focus, equals: id)
                        .focusEffectDisabledIfAvailable()
                        .onChange(of: focused) { _, isFocused in if isFocused { teamLeague = league.short } }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .focusSection()
            teamGrid
            HStack(spacing: 20) {
                actionButton(L10n.string("my_sports_back", fallback: "Back"), id: "back2") { step = 0 }
                Spacer()
                actionButton(L10n.string("my_sports_next_review", fallback: "Next: review"), id: "next2", primary: true) { step = 2 }
            }
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
    }

    @ViewBuilder
    private var teamGrid: some View {
        let league = teamLeague ?? leagues.first
        let roster = league.flatMap { schedule.rosters[$0] } ?? []
        if let league, roster.isEmpty {
            HStack(spacing: 16) {
                if schedule.refreshing { ProgressView() }
                Text(schedule.refreshing
                     ? L10n.string("my_sports_teams_loading", fallback: "Loading teams…")
                     : L10n.string("my_sports_teams_none", fallback: "No teams yet: they come from this week's schedule. You can add them later in Options → My Sports."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .leading)
            .id(league)
        } else if let league {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 18), count: 6), alignment: .leading, spacing: 18) {
                    ForEach(roster, id: \.id) { team in
                        teamTile(team, league: league)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 560)
            .focusSection()
        }
    }

    private func teamTile(_ team: SportsTeam, league: String) -> some View {
        let key = MySports.teamKey(league: league, teamID: team.id)
        let id = "team|\(key)"
        let focused = focus == id
        let on = teams.contains(key)
        return Button {
            if on { teams.remove(key) } else { teams.insert(key) }
        } label: {
            VStack(spacing: 12) {
                TeamBadge(team: team, size: 84, focused: focused)
                Text(team.alternates.first ?? team.name)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(focused ? .black : .white)
            .frame(width: 250, height: 180)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(focused ? Color.white : Color.white.opacity(on ? 0.14 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Self.green, lineWidth: on && !focused ? 3 : 0))
            )
            .overlay(alignment: .topTrailing) {
                if on {
                    ZStack {
                        Circle().fill(Self.green)
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
                    }
                    .frame(width: 28, height: 28)
                    .padding(10)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    // MARK: Step 3: review

    private var teamNames: [String] {
        var names: [String] = []
        for key in teams.sorted() {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let team = schedule.rosters[parts[0]]?.first(where: { $0.id == parts[1] }) else { continue }
            names.append(team.alternates.first ?? team.name)
        }
        return names
    }

    /// Requests a day for the picked leagues (only on days Live Events opens).
    private var requestsPerDay: Int {
        pickedLeagues.reduce(0) { total, league in
            switch league.mode {
            case .month: return total + 1
            case .week: return total + 2
            case .days(let count): return total + count
            }
        } + (pickedLeagues.contains(where: \.college) ? 1 : 0)
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 30) {
            header(3, L10n.string("my_sports_review_title", fallback: "Your sports are set"),
                   L10n.string("my_sports_review_detail", fallback: "Live Events leads with your teams, then a row for each league you picked."))
            VStack(alignment: .leading, spacing: 18) {
                summaryLine(L10n.string("my_sports_leagues", fallback: "Leagues"),
                            pickedLeagues.isEmpty ? L10n.string("my_sports_none", fallback: "None") : pickedLeagues.map(\.name).joined(separator: ", "))
                summaryLine(L10n.string("my_sports_teams", fallback: "Favorite teams"),
                            teamNames.isEmpty ? L10n.string("my_sports_none", fallback: "None") : teamNames.joined(separator: ", "))
                summaryLine(L10n.string("my_sports_everything_else", fallback: "Everything else"),
                            L10n.string("my_sports_more_events", fallback: "Under More events, from your provider's event channels"))
                summaryLine(L10n.string("my_sports_checks", fallback: "Schedule checks"),
                            L10n.format("my_sports_checks_detail", fallback: "Up to %d a day, only when you open Live Events", requestsPerDay))
            }
            LivePanelRow(title: L10n.string("my_sports_reminders", fallback: "Remind me before my teams play"),
                         detail: L10n.string("my_sports_reminders_detail", fallback: "A card appears over whatever you're watching when the game starts"),
                         accessory: .toggle(reminders)) {
                reminders.toggle()
            }
            .frame(width: 900)
            .disabled(teams.isEmpty)
            .opacity(teams.isEmpty ? 0.5 : 1)
            Spacer(minLength: 0)
            HStack(spacing: 20) {
                actionButton(L10n.string("my_sports_back", fallback: "Back"), id: "back3") { step = 1 }
                Spacer()
                actionButton(L10n.string("my_sports_done", fallback: "Done"), id: "done", primary: true) {
                    let picked = leagues, favorites = Array(teams).sorted(), remind = reminders && !teams.isEmpty
                    mySports.update {
                        $0.leagues = picked
                        $0.teams = favorites
                        $0.reminders = remind
                        $0.configured = true
                        $0.prompted = true
                    }
                    CrashRecorder.note("my sports: saved \(picked.count) leagues, \(favorites.count) teams")
                    onDone()
                }
            }
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 30) {
            Text(label)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 260, alignment: .leading)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
        }
    }
}
