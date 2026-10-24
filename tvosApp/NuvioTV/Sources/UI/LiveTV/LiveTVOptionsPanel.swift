import SwiftUI

/// Settings key for the All Channels tab: -1 = automatic (shown until My
/// Lineup is set up), 0 = off, 1 = on.
enum LiveTabsSetting {
    static let allChannelsKey = "nuvio.tv.livetv.allChannelsTab"

    static func showsAllChannels(_ value: Int, configured: Bool) -> Bool {
        value == 1 || (value == -1 && !configured)
    }
}

/// Live TV options, opened from the gear by the guide's tabs: a frosted
/// panel on the right with My Lineup / Guide / Playback / Help sections.
/// Sub-pages (Countries & Languages) open inside the panel; Back steps out
/// one level. Edit My Lineup, setup and the exports keep their full screens.
struct LiveTVOptionsPanel: View {
    let onSetup: () -> Void
    let onClose: () -> Void

    private enum Page { case main, countries }

    @ObservedObject private var store = LiveTVStore.shared
    @AppStorage(LiveTabsSetting.allChannelsKey) private var allChannelsTab = -1
    @State private var page: Page = .main
    /// Countries selected when the page opened: rows stay in their section
    /// while you toggle, instead of jumping under the focus.
    @State private var countriesAtOpen: Set<String> = []
    @State private var preferTS = LiveTVStore.xtreamPrefersTS
    @State private var guidePreview = LiveTVStore.guidePreviewEnabled
    @State private var gameSchedule = SportsData.isEnabled
    @State private var showUnwatchable = SportsData.showsUnwatchable
    @ObservedObject private var schedule = SportsData.shared
    @State private var showEdit = false
    @State private var showSources = false
    @State private var showReport = false
    @State private var showLog = false

    private var updatedText: String {
        if schedule.refreshing { return L10n.string("live_schedule_updating", fallback: "Updating…") }
        guard let date = schedule.updatedAt else { return L10n.string("live_schedule_never", fallback: "Not yet") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return L10n.format("live_schedule_updated", fallback: "Updated %@", formatter.localizedString(for: date, relativeTo: Date()))
    }

    var body: some View {
        LiveSidePanel(edge: .trailing, width: 760) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    switch page {
                    case .main: mainPage
                    case .countries: countriesPage
                    }
                }
                .padding(.top, 50)
                .padding(.bottom, 60)
                .padding(.trailing, 70)
            }
            .focusSection()
        }
        .onExitCommand {
            if page != .main { page = .main } else { onClose() }
        }
        .sheet(isPresented: $showSources) { LiveTVGuideSourcesView() }
        .fullScreenCover(isPresented: $showEdit) { LineupEditView() }
        .fullScreenCover(isPresented: $showReport) { LiveTVExportView() }
        .fullScreenCover(isPresented: $showLog) { LiveTVExportView(kind: .playbackLog) }
    }

    // MARK: Main page

    @ViewBuilder
    private var mainPage: some View {
        Text(L10n.string("live_options", fallback: "Options"))
            .font(.system(size: 38, weight: .bold))
            .foregroundColor(.white)
            .padding(.bottom, 14)

        section(L10n.string("live_view_lineup", fallback: "My Lineup"))
        LivePanelRow(title: L10n.string("live_edit_lineup", fallback: "Edit My Lineup"),
                     accessory: .chevron(L10n.format("live_lineup_size", fallback: "%d channels", store.lineupEntries.count))) {
            showEdit = true
        }
        LivePanelRow(title: L10n.string("live_countries_title", fallback: "Countries & Languages"),
                     accessory: .chevron(countriesSummary)) {
            countriesAtOpen = store.prefs.countries
            page = .countries
        }
        LivePanelRow(title: store.prefs.configured
                        ? L10n.string("live_setup_again", fallback: "Set Up My Lineup Again")
                        : L10n.string("live_setup_prompt_button", fallback: "Set Up My Lineup"),
                     accessory: .chevron(nil)) {
            onSetup()
        }
        let showsAll = LiveTabsSetting.showsAllChannels(allChannelsTab, configured: store.prefs.configured)
        LivePanelRow(title: L10n.string("live_all_tab", fallback: "All Channels tab"),
                     detail: L10n.string("live_all_tab_detail", fallback: "Every channel in your countries"),
                     accessory: .toggle(showsAll)) {
            allChannelsTab = showsAll ? 0 : 1
        }

        section(L10n.string("live_guide", fallback: "Guide"))
        LivePanelRow(title: L10n.string("live_guide_preview_short", fallback: "Preview channels"),
                     detail: L10n.string("live_guide_preview_detail_short", fallback: "Rest on a channel to hear it in the corner"),
                     accessory: .toggle(guidePreview)) {
            guidePreview.toggle()
            LiveTVStore.guidePreviewEnabled = guidePreview
            if !guidePreview { store.stopPreview() }
        }
        LivePanelRow(title: L10n.string("live_guide_sources", fallback: "Guide Listings"), accessory: .chevron(nil)) {
            showSources = true
        }

        section(L10n.string("live_events_title", fallback: "Live Events"))
        LivePanelRow(title: L10n.string("live_game_schedule", fallback: "Game schedule"),
                     detail: L10n.string("live_game_schedule_detail", fallback: "Schedule, logos and TV networks"),
                     accessory: .toggle(gameSchedule)) {
            gameSchedule.toggle()
            SportsData.isEnabled = gameSchedule
            SportsData.shared.enabledChanged()
            store.scheduleSportsRebuild(delay: 0.2, reason: "setting")
        }
        if gameSchedule {
            LivePanelRow(title: L10n.string("live_schedule_refresh", fallback: "Refresh schedule"),
                         accessory: .chevron(updatedText)) {
                SportsData.shared.refreshNow()
            }
            LivePanelRow(title: L10n.string("live_show_unwatchable", fallback: "Games not in my channels"),
                         detail: L10n.string("live_show_unwatchable_detail", fallback: "Show them dimmed at the end of each row"),
                         accessory: .toggle(showUnwatchable)) {
                showUnwatchable.toggle()
                SportsData.showsUnwatchable = showUnwatchable
                LiveEventsModel.shared.refresh()
            }
        }

        if !XtreamStore.shared.accounts.isEmpty {
            section(L10n.string("live_playback", fallback: "Playback"))
            LivePanelRow(title: L10n.string("live_xtream_ts_short", fallback: "Use MPEG-TS for Xtream"),
                         detail: L10n.string("live_xtream_ts_detail_short", fallback: "Try this if Xtream channels stutter"),
                         accessory: .toggle(preferTS)) {
                preferTS.toggle()
                LiveTVStore.xtreamPrefersTS = preferTS
            }
        }

        section(L10n.string("live_help", fallback: "Help"))
        LivePanelRow(title: L10n.string("live_report_open_short", fallback: "Export Channel Report"), accessory: .chevron(nil)) {
            showReport = true
        }
        LivePanelRow(title: L10n.string("live_log_open_short", fallback: "Export Playback Log"), accessory: .chevron(nil)) {
            showLog = true
        }
    }

    private var countriesSummary: String {
        store.prefs.countries.count == 1 && store.prefs.countries.contains("US")
            ? L10n.string("live_countries_us", fallback: "US English")
            : L10n.format("live_countries_n", fallback: "%d selected", store.prefs.countries.count)
    }

    // MARK: Countries page

    @ViewBuilder
    private var countriesPage: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold))
            Text(L10n.string("live_options", fallback: "Options")).font(.system(size: 22, weight: .bold))
        }
        .foregroundColor(.white.opacity(0.55))
        Text(L10n.string("live_countries_title", fallback: "Countries & Languages"))
            .font(.system(size: 38, weight: .bold))
            .foregroundColor(.white)
        Text(L10n.string("live_countries_panel_detail", fallback: "Which channels My Lineup, All Channels and Live Events include. Everything else is still in Search."))
            .font(LiveStyle.rowDetail)
            .foregroundColor(.white.opacity(0.6))
            .padding(.bottom, 12)
        let counts = store.marketCounts()
        let selected = counts.filter { countriesAtOpen.contains($0.market) }
        let others = counts.filter { !countriesAtOpen.contains($0.market) }
        if !selected.isEmpty {
            section(L10n.string("live_countries_selected", fallback: "Selected"))
            ForEach(selected) { item in countryRow(item.market, count: item.count) }
        }
        if !others.isEmpty {
            section(L10n.string("live_countries_more", fallback: "More"))
            ForEach(others) { item in countryRow(item.market, count: item.count) }
        }
    }

    private func countryRow(_ market: String, count: Int) -> some View {
        let on = store.prefs.countries.contains(market)
        return LivePanelRow(title: LiveTVStore.marketName(market),
                            detail: L10n.format("live_country_count", fallback: "%d channels", count),
                            accessory: .check(on)) {
            var updated = store.prefs
            if on {
                // Keep at least one country.
                guard updated.countries.count > 1 else { return }
                updated.countries.remove(market)
            } else {
                updated.countries.insert(market)
            }
            store.setPrefs(updated)
        }
    }

    private func section(_ title: String) -> some View {
        LiveSectionLabel(text: title)
            .padding(.top, 22)
            .padding(.bottom, 6)
            .padding(.leading, 4)
    }
}
