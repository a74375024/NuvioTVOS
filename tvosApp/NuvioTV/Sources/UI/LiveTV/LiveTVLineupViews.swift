import SwiftUI

// MARK: - Options

/// Live TV options: My Lineup, hidden channels, guide listings, report.
struct LiveTVOptionsView: View {
    let onSetup: () -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @State private var showEdit = false
    @State private var showSources = false
    @State private var showReport = false
    @State private var showLog = false
    @State private var showCountries = false
    @State private var preferTS = LiveTVStore.xtreamPrefersTS

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showEdit = true
                    } label: {
                        row("slider.horizontal.3", L10n.string("live_edit_lineup", fallback: "Edit My Lineup"),
                            L10n.format("live_lineup_size", fallback: "%d channels", store.lineupEntries.count))
                    }
                    Toggle(isOn: Binding(get: { store.prefs.showHidden }, set: { store.setShowHidden($0) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("live_show_hidden", fallback: "Show hidden channels"))
                            Text(L10n.string("live_show_hidden_detail", fallback: "List channels outside My Lineup too, dimmed"))
                                .font(.system(size: 20)).foregroundColor(.secondary)
                        }
                    }
                    Button { showCountries = true } label: {
                        row("globe", L10n.string("live_countries_title", fallback: "Countries & Languages"),
                            store.prefs.countries.count == 1 && store.prefs.countries.contains("US")
                                ? L10n.string("live_countries_us", fallback: "US English")
                                : L10n.format("live_countries_n", fallback: "%d selected", store.prefs.countries.count))
                    }
                    Button(action: onSetup) {
                        row("sparkles.tv", store.prefs.configured
                            ? L10n.string("live_setup_again", fallback: "Set Up My Lineup Again")
                            : L10n.string("live_setup_prompt_button", fallback: "Set Up My Lineup"), nil)
                    }
                } header: {
                    Text(L10n.string("live_view_lineup", fallback: "My Lineup"))
                }
                Section {
                    Button { showSources = true } label: {
                        row("list.bullet.rectangle", L10n.string("live_guide_sources", fallback: "Guide Listings"), nil)
                    }
                    Button { showReport = true } label: {
                        row("square.and.arrow.up", L10n.string("live_report_open", fallback: "Export Channel Report…"), nil)
                    }
                    Button { showLog = true } label: {
                        row("waveform.path.ecg", L10n.string("live_log_open", fallback: "Export Playback Log…"), nil)
                    }
                } header: {
                    Text(L10n.string("live_guide", fallback: "Guide"))
                }
                if !XtreamStore.shared.accounts.isEmpty {
                    Section {
                        Toggle(isOn: $preferTS) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.string("live_xtream_ts", fallback: "Xtream: use MPEG-TS instead of HLS"))
                                Text(L10n.string("live_xtream_ts_detail", fallback: "Try this if Xtream channels stutter. Applies to the next channel you open; the playback log shows which format played."))
                                    .font(.system(size: 20)).foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: preferTS) { _, value in LiveTVStore.xtreamPrefersTS = value }
                    } header: {
                        Text(L10n.string("live_playback", fallback: "Playback"))
                    }
                }
            }
            .navigationTitle(L10n.string("live_options", fallback: "Options"))
        }
        .sheet(isPresented: $showSources) { LiveTVGuideSourcesView() }
        .fullScreenCover(isPresented: $showEdit) { LineupEditView() }
        .fullScreenCover(isPresented: $showReport) { LiveTVExportView() }
        .fullScreenCover(isPresented: $showLog) { LiveTVExportView(kind: .playbackLog) }
        .sheet(isPresented: $showCountries) { LineupCountriesView() }
    }

    private func row(_ symbol: String, _ title: String, _ value: String?) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).foregroundColor(.secondary).frame(width: 34)
            Text(title)
            Spacer()
            if let value { Text(value).foregroundColor(.secondary) }
        }
    }
}

// MARK: - Countries & languages

/// Which countries / languages My Lineup, All Channels, Live Events and the
/// provider guide cover. US English is on by default.
struct CountryToggles: View {
    @Binding var selection: Set<String>
    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        let counts = store.marketCounts()
        Section {
            ForEach(counts) { item in
                Toggle(isOn: Binding(
                    get: { selection.contains(item.market) },
                    set: { on in
                        if on { selection.insert(item.market) } else { selection.remove(item.market) }
                    }
                )) {
                    HStack {
                        Text(LiveTVStore.marketName(item.market))
                        Spacer()
                        Text(L10n.format("live_country_count", fallback: "%d channels", item.count))
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text(L10n.string("live_countries_header", fallback: "Countries & languages"))
        } footer: {
            Text(L10n.string("live_countries_footer", fallback: "Channels from the countries you pick join My Lineup, All Channels and Live Events. Everything else is still in Search."))
        }
    }
}

/// Options → Countries & Languages.
struct LineupCountriesView: View {
    @ObservedObject private var store = LiveTVStore.shared
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                CountryToggles(selection: $selection)
            }
            .navigationTitle(L10n.string("live_countries_title", fallback: "Countries & Languages"))
        }
        .onAppear { selection = store.prefs.countries }
        .onChange(of: selection) { _, value in
            guard value != store.prefs.countries else { return }
            var updated = store.prefs
            updated.countries = value
            store.setPrefs(updated)
        }
    }
}

// MARK: - Setup

/// First-run (and re-run) setup for My Lineup: market, categories, build.
struct LineupSetupView: View {
    let onDone: () -> Void

    private enum Step { case market, categories, building, summary }

    @ObservedObject private var store = LiveTVStore.shared
    @State private var step: Step = .market
    @State private var markets: [MarketDirectory.Market] = []
    @State private var suggested: [MarketDirectory.Market] = []
    @State private var loadingMarkets = true
    @State private var selected: [String] = []
    @State private var query = ""
    @State private var draft = LineupPrefs()
    @State private var resolving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch step {
            case .market: marketStep
            case .categories: categoriesStep
            case .building: buildingStep
            case .summary: summaryStep
            }
        }
        .task {
            draft = store.prefs
            selected = draft.markets.map(\.name)
            let list = await MarketDirectory.markets()
            markets = list
            let localNames = store.channels.filter { ($0.group ?? "").lowercased().contains("local") || ChannelCatalog.bareCallsign($0.name) != nil }.map(\.name)
            suggested = MarketDirectory.suggested(from: list, channelNames: localNames.isEmpty ? store.channels.map(\.name) : localNames)
            loadingMarkets = false
            if ScreenTour.requested == "live-demo-setup", selected.isEmpty, let first = suggested.first ?? list.first {
                selected = [first.name]
            }
        }
    }

    // Step 1: where do you watch?

    private var filteredMarkets: [MarketDirectory.Market] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return markets }
        return markets.filter { $0.name.lowercased().contains(text) }
    }

    private var marketStep: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 22) {
                stepLabel(1)
                Text(L10n.string("live_setup_market_title", fallback: "Where do you watch?"))
                    .font(.system(size: 52, weight: .bold)).foregroundColor(.white)
                Text(L10n.string("live_setup_market_detail", fallback: "Pick your TV market to keep its local stations (ABC, CBS, NBC, FOX, PBS…) in My Lineup. Other cities' locals stay out of the way. You can pick more than one."))
                    .font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
                if !selected.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(selected, id: \.self) { name in
                            Label(name, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 20) {
                    Button {
                        Task { await continueFromMarkets() }
                    } label: {
                        HStack {
                            if resolving { ProgressView() }
                            Text(selected.isEmpty
                                 ? L10n.string("live_setup_skip_locals", fallback: "Skip Local Stations")
                                 : L10n.string("live_setup_continue", fallback: "Continue"))
                        }
                        .font(.system(size: 26, weight: .semibold)).padding(.horizontal, 24)
                    }
                    .disabled(resolving)
                    Button(L10n.string("live_setup_cancel", fallback: "Not Now")) { onDone() }
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            .frame(width: 620, alignment: .leading)
            .padding(.vertical, 80)

            NavigationStack {
                List {
                    if loadingMarkets {
                        HStack { ProgressView(); Text(L10n.string("live_setup_loading_markets", fallback: "Loading TV markets…")) }
                    }
                    if query.isEmpty, !suggested.isEmpty {
                        Section(L10n.string("live_setup_suggested", fallback: "Suggested from your channels")) {
                            ForEach(suggested) { marketRow($0) }
                        }
                    }
                    Section(L10n.format("live_setup_all_markets", fallback: "All markets (%d)", filteredMarkets.count)) {
                        ForEach(filteredMarkets) { marketRow($0) }
                    }
                }
                .searchable(text: $query, prompt: L10n.string("live_setup_search_markets", fallback: "City or market"))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 80)
    }

    private func marketRow(_ market: MarketDirectory.Market) -> some View {
        Button {
            if let index = selected.firstIndex(of: market.name) { selected.remove(at: index) } else { selected.append(market.name) }
        } label: {
            HStack {
                Text(market.name)
                Spacer()
                if selected.contains(market.name) { Image(systemName: "checkmark") }
            }
        }
    }

    private func continueFromMarkets() async {
        resolving = true
        var choices: [MarketChoice] = []
        for name in selected {
            if let existing = draft.markets.first(where: { $0.name == name }), !existing.callsigns.isEmpty {
                choices.append(existing)
                continue
            }
            let market = markets.first { $0.name == name } ?? MarketDirectory.Market(name: name, template: nil)
            let signs = await MarketDirectory.callsigns(for: market)
            choices.append(MarketChoice(name: name, template: market.template, callsigns: signs))
        }
        draft.markets = choices
        resolving = false
        step = .categories
    }

    // Step 2: what goes in?

    private var categoriesStep: some View {
        let counts = store.categoryCounts(for: draft)
        return HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 22) {
                stepLabel(2)
                Text(L10n.string("live_setup_categories_title", fallback: "What do you want in My Lineup?"))
                    .font(.system(size: 52, weight: .bold)).foregroundColor(.white)
                Text(L10n.string("live_setup_categories_detail", fallback: "Each channel appears once, however many copies your providers have; the extra copies become automatic backups. Everything you leave out stays available under All Channels and Search."))
                    .font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
                Spacer()
                HStack(spacing: 20) {
                    Button(L10n.string("live_setup_build", fallback: "Build My Lineup")) {
                        step = .building
                        Task {
                            await store.buildLineup(draft)
                            step = .summary
                        }
                    }
                    .font(.system(size: 26, weight: .semibold))
                    Button(L10n.string("live_setup_back", fallback: "Back")) { step = .market }
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            .frame(width: 620, alignment: .leading)
            .padding(.vertical, 80)

            List {
                CountryToggles(selection: $draft.countries)
                Section {
                    ForEach(LineupCategory.allCases) { category in
                        Toggle(isOn: Binding(
                            get: { draft.categories.contains(category) },
                            set: { on in
                                if on { draft.categories.insert(category) } else { draft.categories.remove(category) }
                            }
                        )) {
                            HStack(spacing: 16) {
                                Image(systemName: category.symbol).foregroundColor(.secondary).frame(width: 34)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(category.title)
                                    Text(category.detail).font(.system(size: 19)).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let count = counts[category] {
                                    Text(category == .local
                                         ? L10n.format("live_setup_count_local", fallback: "%d stations", count.0)
                                         : L10n.format("live_setup_count", fallback: "%d of %d", count.0, count.1))
                                        .foregroundColor(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle(isOn: $draft.requireGuide) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("live_setup_require_guide", fallback: "Only channels with a guide"))
                            Text(L10n.string("live_setup_require_guide_detail", fallback: "Leaves out channels nobody publishes listings for (local stations and your area's sports channels are always included)"))
                                .font(.system(size: 19)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 80)
    }

    // Step 3: building

    private var buildingStep: some View {
        VStack(spacing: 26) {
            ProgressView().scaleEffect(1.6)
            Text(L10n.string("live_setup_building", fallback: "Building My Lineup…"))
                .font(.system(size: 44, weight: .bold)).foregroundColor(.white)
            Text(store.lineupBuild ?? "")
                .font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
        }
    }

    // Step 4: summary

    private var summaryStep: some View {
        let byCategory = Dictionary(grouping: store.lineupEntries) { store.entryInfo[$0.id]?.category ?? .entertainment }
        return VStack(alignment: .leading, spacing: 26) {
            Text(L10n.string("live_setup_done_title", fallback: "My Lineup is ready"))
                .font(.system(size: 56, weight: .bold)).foregroundColor(.white)
            Text(L10n.format("live_setup_done_detail", fallback: "%d channels, down from %d. Hold Select on any channel to add or remove it; Options → Edit My Lineup changes the rest.", store.lineupEntries.count, store.channels.count))
                .font(.system(size: 26)).foregroundColor(.white.opacity(0.75))
            HStack(spacing: 18) {
                ForEach(LineupCategory.allCases) { category in
                    if let list = byCategory[category], !list.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: category.symbol).font(.system(size: 30))
                            Text("\(list.count)").font(.system(size: 34, weight: .bold)).monospacedDigit()
                            Text(category.title).font(.system(size: 16)).multilineTextAlignment(.center).lineLimit(2)
                        }
                        .foregroundColor(.white)
                        .frame(width: 150, height: 150)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                    }
                }
            }
            Button(L10n.string("live_setup_finish", fallback: "Start Watching")) { onDone() }
                .font(.system(size: 28, weight: .semibold))
                .padding(.top, 20)
        }
        .padding(110)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func stepLabel(_ number: Int) -> some View {
        Text(L10n.format("live_setup_step", fallback: "STEP %d OF 2", number))
            .font(.system(size: 18, weight: .heavy)).tracking(1.2).foregroundColor(.white.opacity(0.5))
    }
}

// MARK: - Edit

/// Changes to My Lineup after setup: what was added or removed by hand, and
/// rebuilding the suggestions.
struct LineupEditView: View {
    @ObservedObject private var store = LiveTVStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var rebuilding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(L10n.string("live_edit_markets", fallback: "TV market"))
                        Spacer()
                        Text(store.prefs.markets.map(\.name).joined(separator: ", ").isEmpty
                             ? L10n.string("live_edit_no_market", fallback: "None")
                             : store.prefs.markets.map(\.name).joined(separator: ", "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    HStack {
                        Text(L10n.string("live_edit_included", fallback: "Included"))
                        Spacer()
                        Text(LineupCategory.allCases.filter { store.prefs.categories.contains($0) }.map(\.title).joined(separator: ", "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    Button {
                        rebuilding = true
                        Task {
                            await store.buildLineup(store.prefs)
                            rebuilding = false
                        }
                    } label: {
                        HStack {
                            Text(L10n.string("live_edit_rebuild", fallback: "Refresh Suggestions"))
                            Spacer()
                            if rebuilding { ProgressView(); Text(store.lineupBuild ?? "").foregroundColor(.secondary) }
                        }
                    }
                    .disabled(rebuilding)
                } footer: {
                    Text(L10n.string("live_edit_rebuild_detail", fallback: "Re-checks which channels have listings and picks up new channels. Your own additions and removals are kept. Use Options → Set Up My Lineup Again to change the market or categories."))
                }
                Section(L10n.format("live_edit_added", fallback: "Added by you (%d)", store.prefs.added.count)) {
                    ForEach(store.entries.filter { store.prefs.added.contains($0.id) }) { channel in
                        Button {
                            store.setInLineup(channel, false)
                        } label: {
                            HStack {
                                Text(channel.name)
                                Spacer()
                                Image(systemName: "minus.circle").foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(L10n.format("live_edit_removed", fallback: "Removed by you (%d)", store.prefs.removed.count)) {
                    ForEach(store.entries.filter { store.prefs.removed.contains($0.id) }) { channel in
                        Button {
                            store.setInLineup(channel, true)
                        } label: {
                            HStack {
                                Text(channel.name)
                                Spacer()
                                Image(systemName: "arrow.uturn.backward.circle").foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(L10n.format("live_edit_lineup", fallback: "My Lineup (%d)", store.lineupEntries.count)) {
                    ForEach(store.lineupEntries) { channel in
                        Button {
                            store.setInLineup(channel, false)
                        } label: {
                            HStack {
                                Text(store.number(of: channel)).monospacedDigit().foregroundColor(.secondary).frame(width: 90, alignment: .leading)
                                Text(channel.name)
                                Spacer()
                                Image(systemName: "minus.circle").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("live_edit_lineup_title", fallback: "Edit My Lineup"))
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Feed picker

/// The versions of one channel (or the feeds of an event family) to choose
/// from. Picking one plays it; the rest remain backups.
struct LiveFeedPickerView: View {
    let picker: LiveFeedPicker
    let onClose: () -> Void

    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        NavigationStack {
            List {
                if let channel = picker.channel {
                    Section {
                        ForEach(Array(store.versions(of: channel).enumerated()), id: \.element.id) { index, feed in
                            Button {
                                onClose()
                                store.watch(channel, preferring: feed)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(feed.name)
                                        Spacer()
                                        if store.pinnedFeed(for: channel) == feed.id {
                                            Text(L10n.string("live_feed_pinned", fallback: "Always first")).foregroundColor(.secondary)
                                        } else if index == 0 {
                                            Text(L10n.string("live_feed_main", fallback: "Main")).foregroundColor(.secondary)
                                        }
                                    }
                                    Text(store.feedSummary(feed)).font(.system(size: 19)).foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(L10n.string("live_feed_watch_header", fallback: "Watch with"))
                    } footer: {
                        Text(L10n.string("live_feed_footer", fallback: "If a feed stops working, it's reconnected first; if it still doesn't play, the next one takes over."))
                    }

                    Section {
                        pinRow(title: L10n.string("live_feed_auto", fallback: "Automatic (the version that works best)"),
                               selected: store.pinnedFeed(for: channel) == nil) {
                            store.pin(nil, for: channel)
                        }
                        ForEach(store.versions(of: channel)) { feed in
                            pinRow(title: feed.name, detail: store.feedSummary(feed),
                                   selected: store.pinnedFeed(for: channel) == feed.id) {
                                store.pin(feed, for: channel)
                            }
                        }
                    } header: {
                        Text(L10n.string("live_feed_pin_header", fallback: "Always start with"))
                    } footer: {
                        Text(L10n.string("live_feed_pin_footer", fallback: "The chosen version is tried first every time; the others stay as backups."))
                    }
                } else if let family = picker.family {
                    Section {
                        ForEach(family.feeds.compactMap { store.channel(id: $0) }) { feed in
                            Button {
                                onClose()
                                store.surf(feed, in: family)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feed.name).lineLimit(1)
                                    Text(store.feedEventLine(feed)).font(.system(size: 19)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                    } footer: {
                        Text(L10n.string("live_family_footer", fallback: "While watching, Up / Down move through these feeds and skip ones that aren't live."))
                    }
                }
            }
            .navigationTitle(picker.title)
        }
    }

    private func pinRow(title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 19)).foregroundColor(.secondary).lineLimit(1) }
                }
            }
        }
    }
}

// MARK: - Live Events

/// Events parsed from event-feed names across all providers: live now,
/// starting soon, later, by sport, plus the numbered event channels.
struct LiveEventsView: View {
    var onPickFamily: (EventFamily) -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @State private var league: String?
    @State private var now = Date()
    @State private var feedPicker: LiveFeedPicker?
    @FocusState private var focused: String?

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var leagues: [String] {
        let counts = Dictionary(grouping: store.events, by: \.league).mapValues(\.count)
        return counts.keys.sorted { counts[$0, default: 0] > counts[$1, default: 0] }
    }

    private var filtered: [LiveEvent] {
        store.events.filter { event in
            guard league == nil || event.league == league else { return false }
            guard let start = event.start else { return true }
            return now < start.addingTimeInterval(event.expectedLength)
        }
    }

    private var sections: [(String, [LiveEvent])] {
        let calendar = Calendar.current
        var live: [LiveEvent] = [], soon: [LiveEvent] = [], today: [LiveEvent] = [], later: [LiveEvent] = [], unknown: [LiveEvent] = []
        for event in filtered {
            guard let start = event.start else { unknown.append(event); continue }
            if event.isLive(at: now) { live.append(event) }
            else if start.timeIntervalSince(now) < 3 * 3600 { soon.append(event) }
            else if calendar.isDateInToday(start) { today.append(event) }
            else { later.append(event) }
        }
        return [
            (L10n.string("live_events_now", fallback: "Live now"), live),
            (L10n.string("live_events_soon", fallback: "Starting soon"), soon),
            (L10n.string("live_events_today", fallback: "Later today"), today),
            (L10n.string("live_events_later", fallback: "Coming up"), later),
            (L10n.string("live_events_unknown", fallback: "Time not listed"), unknown)
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SourceModeChip(title: L10n.string("live_filter_all", fallback: "All"), isSelected: league == nil) { league = nil }
                    ForEach(leagues, id: \.self) { name in
                        SourceModeChip(title: name, isSelected: league == name) { league = name }
                    }
                }
                .padding(.vertical, 8)
            }
            .focusSection()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if sections.isEmpty {
                        Text(L10n.string("live_events_none", fallback: "No upcoming events found in your channels' names right now."))
                            .font(.system(size: 24)).foregroundColor(.white.opacity(0.6)).padding(.vertical, 30)
                    }
                    ForEach(sections, id: \.0) { section in
                        Text(section.0.uppercased())
                            .font(.system(size: 18, weight: .heavy)).tracking(1)
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 16)
                        ForEach(section.1) { event in
                            eventButton(event)
                        }
                    }
                    let families = store.families.filter { league == nil || $0.league == league }
                    if !families.isEmpty {
                        Text(L10n.string("live_event_channels", fallback: "EVENT CHANNELS"))
                            .font(.system(size: 18, weight: .heavy)).tracking(1)
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 24)
                        ForEach(families) { family in
                            familyButton(family)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .focusSection()
        }
        .onReceive(ticker) { now = $0 }
        .sheet(item: $feedPicker) { picker in
            LiveFeedPickerView(picker: picker) { feedPicker = nil }
        }
    }

    private func eventButton(_ event: LiveEvent) -> some View {
        let isFocused = focused == event.id
        return Button {
            store.watchEvent(event)
        } label: {
            LiveEventRowLabel(event: event, now: now)
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isFocused ? Color.white : Color.white.opacity(event.isLive(at: now) ? 0.14 : 0.07)))
                .scaleEffect(isFocused ? 1.01 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused, equals: event.id)
        .focusEffectDisabledIfAvailable()
        .contextMenu {
            if event.feeds.count > 1 {
                Button {
                    feedPicker = LiveFeedPicker(title: event.title, channel: store.eventChannel(event), family: nil)
                } label: {
                    Label(L10n.format("live_choose_feed", fallback: "Choose Feed (%d)", event.feeds.count), systemImage: "list.bullet")
                }
            }
        }
    }

    private func familyButton(_ family: EventFamily) -> some View {
        let isFocused = focused == family.id
        return Button {
            feedPicker = LiveFeedPicker(title: family.name, channel: nil, family: family)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "rectangle.stack").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 4) {
                    Text(family.name).font(.system(size: 24, weight: .bold))
                    Text(family.hasNames
                         ? L10n.format("live_family_named", fallback: "%d feeds · events are listed above", family.feeds.count)
                         : L10n.format("live_family_numbered", fallback: "%d numbered feeds · open one and use Up / Down to find the game", family.feeds.count))
                        .font(.system(size: 19)).opacity(0.7)
                }
                Spacer()
                Text(family.league).font(.system(size: 18, weight: .semibold)).opacity(0.6)
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isFocused ? Color.white : Color.white.opacity(0.06)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused, equals: family.id)
        .focusEffectDisabledIfAvailable()
    }
}

/// League, title, time and feed count for one event.
struct LiveEventRowLabel: View {
    let event: LiveEvent
    var now = Date()

    var body: some View {
        HStack(spacing: 18) {
            Text(event.league.uppercased())
                .font(.system(size: 15, weight: .heavy)).tracking(0.6)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(lineWidth: 1).opacity(0.4))
                .frame(minWidth: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 24, weight: .bold)).lineLimit(1)
                Text(timeText).font(.system(size: 19, weight: .medium)).opacity(0.75)
            }
            Spacer()
            if event.isLive(at: now) {
                Text(L10n.string("live_badge_live", fallback: "LIVE"))
                    .font(.system(size: 15, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.3, blue: 0.3)))
            }
            if event.feeds.count > 1 {
                Text(L10n.format("live_versions", fallback: "%d feeds", event.feeds.count))
                    .font(.system(size: 16, weight: .bold)).opacity(0.6)
            }
        }
    }

    private var timeText: String {
        guard let start = event.start else { return L10n.string("live_events_no_time", fallback: "Time not listed") }
        let time = ChannelsView.clockFormatter.string(from: start)
        if event.isLive(at: now) { return L10n.format("live_events_started", fallback: "Started %@", time) }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return L10n.format("live_events_today_at", fallback: "Today %@", time) }
        if calendar.isDateInTomorrow(start) { return L10n.format("live_events_tomorrow_at", fallback: "Tomorrow %@", time) }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return "\(day.string(from: start)) \(time)"
    }
}
