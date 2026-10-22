import SwiftUI

/// Live TV search: channels by name / number / group as you type, plus
/// programs on now or later (from the loaded guide and the server's search).
struct LiveTVSearchView: View {
    var initialQuery = ""
    let onWatch: (LiveTVChannel, [LiveTVChannel]) -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @State private var query = ""
    @State private var programResults: [LiveTVProgram] = []
    @State private var searchingPrograms = false

    private var channelResults: [LiveTVChannel] {
        store.searchChannels(query)
    }

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
                        Text(L10n.string("live_search_hint", fallback: "Search by channel name, number, group or show title."))
                            .foregroundColor(.secondary)
                    }
                } else {
                    let channels = channelResults
                    if !channels.isEmpty {
                        Section(L10n.format("live_search_channels", fallback: "Channels (%d)", channels.count)) {
                            ForEach(channels) { channel in
                                channelRow(channel, lineup: channels)
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
            .searchable(text: $query, prompt: L10n.string("live_search_prompt", fallback: "Channels or shows"))
            .navigationTitle(L10n.string("live_search_title", fallback: "Search Live TV"))
        }
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
                    Text(channel.displayName).font(.system(size: 26, weight: .semibold))
                    Text(subtitle(for: channel))
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if channel.isFavorite { Image(systemName: "star.fill").foregroundColor(.yellow) }
            }
        }
        .contextMenu {
            Button {
                store.addToMultiview(channel)
            } label: {
                Label(L10n.string("live_add_multiview", fallback: "Add to Multiview"), systemImage: "rectangle.split.2x2")
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
        if let group = channel.group { parts.append(group) }
        if let now = store.current(on: channel.id) { parts.append(L10n.format("live_now_playing", fallback: "Now: %@", now.title)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func programRow(_ program: LiveTVProgram) -> some View {
        if let channel = store.channel(id: program.channelID) {
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
                        Text("\(store.number(of: channel)) · \(channel.displayName) · \(Self.timeRange(program))")
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

/// Picker for the provider's channel groups, with hide / show for "All".
struct LiveTVGroupsView: View {
    let selected: String?
    let onPick: (String?) -> Void

    @ObservedObject private var store = LiveTVStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        HStack {
                            Text(L10n.string("live_all_channels", fallback: "All channels"))
                            Spacer()
                            if selected == nil { Image(systemName: "checkmark") }
                        }
                    }
                } footer: {
                    Text(L10n.string("live_groups_hint", fallback: "Hold Select on a group to hide it from All. Hidden groups can still be opened here or found with Search."))
                }
                Section(L10n.format("live_groups_count", fallback: "Groups (%d)", store.groups.count)) {
                    ForEach(store.groups) { group in
                        let hidden = store.hiddenGroups.contains(group.name)
                        Button {
                            onPick(group.name)
                        } label: {
                            HStack(spacing: 16) {
                                if hidden {
                                    Image(systemName: "eye.slash").foregroundColor(.secondary)
                                }
                                Text(group.name).foregroundColor(hidden ? .secondary : .primary)
                                Spacer()
                                Text("\(group.count)").foregroundColor(.secondary).monospacedDigit()
                                if selected == group.name { Image(systemName: "checkmark") }
                            }
                        }
                        .contextMenu {
                            Button {
                                store.setGroup(group.name, hidden: !hidden)
                            } label: {
                                Label(
                                    hidden
                                        ? L10n.string("live_group_show", fallback: "Show in All")
                                        : L10n.string("live_group_hide", fallback: "Hide from All"),
                                    systemImage: hidden ? "eye" : "eye.slash"
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("live_groups", fallback: "Groups"))
        }
    }
}
