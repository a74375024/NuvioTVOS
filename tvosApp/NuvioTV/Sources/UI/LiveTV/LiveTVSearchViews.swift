import SwiftUI

/// Live TV search: channels by name / number / call sign as you type, live
/// events, plus programs on now or later (loaded guide and the server's search).
struct LiveTVSearchView: View {
    var initialQuery = ""
    let onWatch: (LiveTVChannel, [LiveTVChannel]) -> Void
    var onWatchEvent: (LiveEvent) -> Void = { _ in }

    @ObservedObject private var store = LiveTVStore.shared
    @State private var query = ""
    @State private var programResults: [LiveTVProgram] = []
    @State private var searchingPrograms = false

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !store.recentChannels.isEmpty {
                        Section(L10n.string("live_filter_recent", fallback: "Recent")) {
                            ForEach(store.recentChannels.prefix(12)) { channel in
                                channelRow(channel, lineup: store.recentChannels)
                            }
                        }
                    } else {
                        Text(L10n.string("live_search_hint", fallback: "Search by channel name, number, call sign, team or show."))
                            .foregroundColor(.secondary)
                    }
                } else {
                    let channels = store.searchChannels(query)
                    let events = store.searchEvents(query)
                    if !channels.isEmpty {
                        Section(L10n.format("live_search_channels", fallback: "Channels (%d)", channels.count)) {
                            ForEach(channels) { channel in
                                channelRow(channel, lineup: channels)
                            }
                        }
                    }
                    if !events.isEmpty {
                        Section(L10n.format("live_search_events", fallback: "Live Events (%d)", events.count)) {
                            ForEach(events.prefix(40)) { event in
                                Button {
                                    onWatchEvent(event)
                                } label: {
                                    LiveEventRowLabel(event: event)
                                }
                            }
                        }
                    }
                    Section {
                        if programResults.isEmpty {
                            Text(searchingPrograms
                                 ? L10n.string("live_search_programs_loading", fallback: "Searching the guide…")
                                 : L10n.string("live_search_programs_none", fallback: "No shows found in the guide"))
                                .foregroundColor(.secondary)
                        }
                        ForEach(programResults.prefix(60)) { program in
                            programRow(program)
                        }
                    } header: {
                        Text(L10n.string("live_search_programs", fallback: "Shows on now & later"))
                    }
                }
            }
            .searchable(text: $query, prompt: L10n.string("live_search_prompt", fallback: "Channels, teams or shows"))
            .navigationTitle(L10n.string("live_search_title", fallback: "Search Live TV"))
        }
        // Full-screen and opaque, so the guide doesn't show through.
        .background(Color.black.ignoresSafeArea())
        .onAppear { if query.isEmpty, !initialQuery.isEmpty { query = initialQuery } }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else {
                programResults = []
                return
            }
            searchingPrograms = true
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let found = await store.searchPrograms(text)
            guard !Task.isCancelled else { return }
            programResults = found
            searchingPrograms = false
        }
    }

    private func channelRow(_ channel: LiveTVChannel, lineup: [LiveTVChannel]) -> some View {
        Button {
            onWatch(channel, lineup)
        } label: {
            HStack(spacing: 20) {
                Text(store.number(of: channel))
                    .font(.system(size: 24, weight: .heavy).monospacedDigit())
                    .frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(.system(size: 26, weight: .semibold))
                    Text(subtitle(for: channel))
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if store.isInLineup(channel) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.secondary)
                }
                if channel.isFavorite { Image(systemName: "star.fill").foregroundColor(.yellow) }
            }
        }
        .contextMenu {
            Button {
                store.setInLineup(channel, !store.isInLineup(channel))
            } label: {
                Label(
                    store.isInLineup(channel)
                        ? L10n.string("live_lineup_remove", fallback: "Remove from My Lineup")
                        : L10n.string("live_lineup_add", fallback: "Add to My Lineup"),
                    systemImage: store.isInLineup(channel) ? "minus.circle" : "plus.circle"
                )
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
        .onAppear { store.requestGuide([channel.id]) }
    }

    private func subtitle(for channel: LiveTVChannel) -> String {
        var parts: [String] = []
        if store.isInLineup(channel) { parts.append(L10n.string("live_view_lineup", fallback: "My Lineup")) }
        else if let group = channel.group { parts.append(group) }
        let versions = store.versions(of: channel).count
        if versions > 1 { parts.append(L10n.format("live_versions", fallback: "%d feeds", versions)) }
        if let now = store.current(on: channel.id) { parts.append(L10n.format("live_now_playing", fallback: "Now: %@", now.title)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func programRow(_ program: LiveTVProgram) -> some View {
        if let channel = store.entry(id: program.channelID) {
            Button {
                onWatch(channel, [channel])
            } label: {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            if program.isOn(at: Date()) {
                                Text(L10n.string("live_badge_live", fallback: "LIVE"))
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.red))
                            }
                            Text(program.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                        }
                        Text("\(store.number(of: channel)) · \(channel.name) · \(Self.timeRange(program))")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
    }

    private static func timeRange(_ program: LiveTVProgram) -> String {
        let f = ChannelsView.clockFormatter
        let day = Calendar.current.isDateInToday(program.start) ? "" : (Self.dayFormatter.string(from: program.start) + " ")
        return "\(day)\(f.string(from: program.start))–\(f.string(from: program.end))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
}

/// Picks what the guide lists: My Lineup, All Channels, Favorites, Recent,
/// or one of the provider's groups (hold Select to hide a group from All).
struct LiveTVViewPicker: View {
    let current: LiveView
    let onPick: (LiveView) -> Void

    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(.lineup, count: store.lineupEntries.count, symbol: "sparkles.tv")
                    option(.all, count: store.entries.count, symbol: "square.grid.3x3")
                    option(.favorites, count: store.entries.filter(\.isFavorite).count, symbol: "star")
                    option(.recent, count: store.recentChannels.count, symbol: "clock")
                }
                Section {
                    ForEach(store.groups) { group in
                        let hidden = store.hiddenGroups.contains(group.name)
                        Button {
                            onPick(.group(group.name))
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: hidden ? "eye.slash" : "folder")
                                    .foregroundColor(.secondary)
                                    .frame(width: 34)
                                Text(group.name).foregroundColor(hidden ? .secondary : .primary)
                                Spacer()
                                Text("\(group.count)").foregroundColor(.secondary).monospacedDigit()
                                if current == .group(group.name) { Image(systemName: "checkmark") }
                            }
                        }
                        .contextMenu {
                            Button {
                                store.setGroup(group.name, hidden: !hidden)
                            } label: {
                                Label(
                                    hidden
                                        ? L10n.string("live_group_show", fallback: "Show in All Channels")
                                        : L10n.string("live_group_hide", fallback: "Hide from All Channels"),
                                    systemImage: hidden ? "eye" : "eye.slash"
                                )
                            }
                        }
                    }
                } header: {
                    Text(L10n.format("live_groups_count", fallback: "Provider groups (%d)", store.groups.count))
                } footer: {
                    Text(L10n.string("live_groups_hint", fallback: "Hold Select on a group to hide it from All Channels. Hidden groups can still be opened here or found with Search."))
                }
            }
            .navigationTitle(L10n.string("live_view_title", fallback: "Show"))
        }
    }

    private func option(_ view: LiveView, count: Int, symbol: String) -> some View {
        Button {
            onPick(view)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).foregroundColor(.secondary).frame(width: 34)
                Text(view.title)
                Spacer()
                Text("\(count)").foregroundColor(.secondary).monospacedDigit()
                if current == view { Image(systemName: "checkmark") }
            }
        }
    }
}

/// Where guide listings come from: the server, plus free outside listings
/// matched to channels the server has no (or a thin) guide for.
struct LiveTVGuideSourcesView: View {
    @ObservedObject private var store = LiveTVStore.shared
    @State private var showReport = false
    @State private var enabled = OutsideGuide.isEnabled
    @State private var shards = OutsideGuide.enabledShards

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("live_outside_toggle", fallback: "Fill in missing listings"))
                            Text(L10n.string("live_outside_toggle_detail", fallback: "Uses free TV listings for channels your server has no guide for"))
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: enabled) { _, value in
                        OutsideGuide.isEnabled = value
                        store.loadOutsideGuide()
                    }
                } footer: {
                    Text(statusText).font(.system(size: 20))
                }

                if enabled {
                    Section(L10n.string("live_outside_sources", fallback: "Listings to use")) {
                        ForEach(OutsideGuide.shards) { shard in
                            Toggle(isOn: Binding(
                                get: { shards.contains(shard.id) },
                                set: { on in
                                    if on { shards.insert(shard.id) } else { shards.remove(shard.id) }
                                    OutsideGuide.enabledShards = shards
                                    store.loadOutsideGuide()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shard.title)
                                    Text(shard.detail)
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button(L10n.string("live_outside_refresh", fallback: "Refresh listings now")) {
                            store.loadOutsideGuide(force: true)
                        }
                        Button(L10n.string("live_report_open", fallback: "Export channel report…")) {
                            showReport = true
                        }
                    } footer: {
                        Text(L10n.string("live_outside_footer", fallback: "Your Apple TV downloads free public guides (epgshare01, i.mjh.nz) about once a day while Nuvio is open, keeps only your channels, merges duplicates across sources and saves the result. Channels are matched by call sign (like WNBC), by network and city (\"NBC 5 Chicago\"), or by name. Your server's own guide is used whenever it covers more."))
                            .font(.system(size: 20))
                    }
                }
            }
            .navigationTitle(L10n.string("live_guide_sources", fallback: "Guide Listings"))
        }
        .fullScreenCover(isPresented: $showReport) {
            LiveTVExportView()
        }
    }

    private var statusText: String {
        switch store.outsideStatus {
        case .off:
            return L10n.string("live_outside_off", fallback: "Only your server's guide is used.")
        case .loading:
            return L10n.string("live_outside_loading", fallback: "Loading outside listings…")
        case .updating(let line):
            return line + " " + L10n.string("live_outside_updating_note", fallback: "(runs in the background and pauses while you watch)")
        case .failed(let message):
            return L10n.format("live_outside_failed", fallback: "Couldn't load outside listings: %@", message)
        case .ready(let matched, let total, let updated):
            var text = L10n.format("live_outside_ready", fallback: "Matched %d of %d channels.", matched, total)
            if let updated {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                text += " " + L10n.format("live_outside_updated", fallback: "Listings updated %@.", f.localizedString(for: updated, relativeTo: Date()))
            }
            return text
        }
    }
}

/// Exports the channel report as a CSV over the local network (QR code +
/// address), for diagnosing guide matching on another device.
@MainActor
final class LiveTVExportModel: ObservableObject {
    @Published var message = ""
    @Published var url: URL?
    @Published var qrImage: UIImage?
    @Published var working = false
    private let server = PlaybackDiagnosticExportServer()

    func start() {
        guard !working else { return }
        working = true
        url = nil
        qrImage = nil
        message = L10n.string("live_report_checking", fallback: "Checking your server's guide for every channel…")
        Task {
            await LiveTVStore.shared.checkAllGuides { [weak self] done, total in
                self?.message = L10n.format("live_report_progress", fallback: "Checking guides: %d of %d channels…", done, total)
            }
            let csv = LiveTVStore.shared.channelReportCSV()
            message = L10n.string("live_report_starting", fallback: "Starting the download link…")
            server.start(
                report: Data(csv.utf8),
                contentType: "text/csv; charset=utf-8",
                filename: "nuvio-live-tv-channels.csv",
                maximumBytes: 16 * 1024 * 1024,
                lifetime: 600
            ) { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready(let url):
                        self.url = url
                        self.qrImage = QRCode.image(from: url.absoluteString)
                        self.message = L10n.string("live_report_ready", fallback: "Open this address on a phone or computer on the same Wi-Fi to download the report. The link stops working after 10 minutes.")
                        self.working = false
                    case .failed:
                        self.message = L10n.string("live_report_failed", fallback: "Couldn't start the download link. Make sure the Apple TV is on Wi-Fi or Ethernet and allowed to use the local network.")
                        self.working = false
                    case .stopped:
                        self.url = nil
                        self.qrImage = nil
                        self.working = false
                    case .starting:
                        break
                    }
                }
            }
        }
    }

    func stop() {
        server.stop()
        url = nil
        qrImage = nil
    }
}

struct LiveTVExportView: View {
    @StateObject private var model = LiveTVExportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(L10n.string("live_report_title", fallback: "Channel Report"))
                .font(.largeTitle.bold())
            Text(L10n.string("live_report_detail", fallback: "A spreadsheet (CSV) of every Live TV channel: number, name, group, the call sign or station detected, whether your server has guide data, which outside listing matched and how, and what's on now. Stream links, passwords and tokens are not included."))
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
            if !model.message.isEmpty {
                HStack(spacing: 14) {
                    if model.working { ProgressView() }
                    Text(model.message).font(.system(size: 24))
                }
            }
            if let url = model.url {
                HStack(spacing: 36) {
                    if let image = model.qrImage {
                        Image(uiImage: image)
                            .interpolation(.none).resizable().scaledToFit()
                            .frame(width: 260, height: 260).padding(12).background(.white)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text(url.absoluteString).font(.system(size: 22, design: .monospaced))
                        Button(L10n.string("live_report_stop", fallback: "Stop Sharing")) { model.stop() }
                    }
                }
            }
            HStack(spacing: 24) {
                if model.url == nil {
                    Button(model.working
                           ? L10n.string("live_report_working", fallback: "Preparing…")
                           : L10n.string("live_report_create", fallback: "Create Report")) {
                        model.start()
                    }
                    .disabled(model.working)
                }
                Button(L10n.string("live_report_done", fallback: "Done")) {
                    model.stop()
                    dismiss()
                }
            }
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .onDisappear { model.stop() }
    }
}
