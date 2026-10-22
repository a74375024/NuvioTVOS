import SwiftUI

private enum LiveGuideMetrics {
    static let sideInset: CGFloat = 60
    static let channelColumn: CGFloat = 320
    static let rowHeight: CGFloat = 100
    static let rowSpacing: CGFloat = 10
    static let cellGap: CGFloat = 8
    static let heroHeight: CGFloat = 400
    static let artWidth: CGFloat = 560
    static let windowMinutes = 180
}

private enum LiveFilter: String, CaseIterable, Identifiable {
    case all, favorites, sports, news, movies, kids
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.string("live_filter_all", fallback: "All")
        case .favorites: return L10n.string("live_filter_favorites", fallback: "Favorites")
        case .sports: return L10n.string("live_filter_sports", fallback: "Sports")
        case .news: return L10n.string("live_filter_news", fallback: "News")
        case .movies: return L10n.string("live_filter_movies", fallback: "Movies")
        case .kids: return L10n.string("live_filter_kids", fallback: "Kids")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .sports: return "sportscourt"
        case .news: return "newspaper"
        case .movies: return "film"
        case .kids: return "teddybear"
        }
    }
}

/// Live TV guide for the channels on the user's Emby / Jellyfin server: real
/// guide times, a now line, favorites first, Select to watch, long press for
/// Multiview and favorites.
struct LiveTVGuideView: View {
    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var multiview = MultiviewStore.shared
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @FocusState private var focusedCell: String?
    @State private var focusedChannel: LiveTVChannel?
    @State private var focusedProgram: LiveTVProgram?
    @State private var filter: LiveFilter = .all
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            switch store.state {
            case .loaded:
                guide
            case .idle, .loading:
                statusView(symbol: "antenna.radiowaves.left.and.right", title: L10n.string("live_loading", fallback: "Loading your channels…"), message: nil, showsProgress: true, showsRetry: false)
            case .empty(let message):
                statusView(symbol: "antenna.radiowaves.left.and.right", title: L10n.string("live_none", fallback: "No live channels yet"), message: message, showsProgress: false, showsRetry: store.hasServers)
            case .failed(let message):
                statusView(symbol: "exclamationmark.triangle", title: L10n.string("live_failed", fallback: "Couldn't load Live TV"), message: message, showsProgress: false, showsRetry: true)
            }
            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 50)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        .onAppear {
            now = Date()
            store.loadIfNeeded()
        }
        .onReceive(ticker) { date in
            now = date
            store.refreshGuideIfNeeded()
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

    // MARK: Guide

    private var windowStart: Date { LiveTVStore.windowStart(for: now) }

    private var visibleChannels: [LiveTVChannel] {
        guard filter != .all else { return store.channels }
        return store.channels.filter { channel in
            if filter == .favorites { return channel.isFavorite }
            let list = store.programs[channel.id] ?? []
            return list.contains { program in
                switch filter {
                case .sports: return program.isSports
                case .news: return program.isNews
                case .movies: return program.isMovie
                case .kids: return program.isKids
                case .all, .favorites: return true
                }
            }
        }
    }

    private var guide: some View {
        GeometryReader { proxy in
            let gridWidth = max(600, proxy.size.width - LiveGuideMetrics.sideInset * 2 - LiveGuideMetrics.channelColumn)
            let ppm = gridWidth / CGFloat(LiveGuideMetrics.windowMinutes)
            let channels = visibleChannels
            VStack(alignment: .leading, spacing: 0) {
                hero.frame(height: LiveGuideMetrics.heroHeight)
                filterBar.padding(.bottom, 14)
                timeRuler(gridWidth: gridWidth, ppm: ppm).padding(.bottom, 8)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: LiveGuideMetrics.rowSpacing) {
                        if channels.isEmpty {
                            Text(L10n.string("live_filter_empty", fallback: "Nothing on that matches this filter right now."))
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.vertical, 40)
                        }
                        ForEach(channels) { channel in
                            row(channel, gridWidth: gridWidth, ppm: ppm)
                        }
                    }
                    .padding(.bottom, 60)
                }
                .focusSection()
            }
            .padding(.horizontal, LiveGuideMetrics.sideInset)
            .overlay(alignment: .topLeading) {
                nowLine(gridWidth: gridWidth, ppm: ppm, height: proxy.size.height)
            }
        }
    }

    // MARK: Hero

    private var heroChannel: LiveTVChannel? { focusedChannel ?? store.channels.first }

    private var heroProgram: LiveTVProgram? {
        if let focusedProgram { return focusedProgram }
        guard let channel = heroChannel else { return nil }
        return store.current(on: channel.id, at: now)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text(L10n.string("nav_live_tv", fallback: "Live TV"))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                    if store.isLoadingGuide { ProgressView().tint(.white).scaleEffect(0.7) }
                }
                if let channel = heroChannel {
                    HStack(spacing: 12) {
                        Text(store.number(of: channel))
                            .font(.system(size: 24, weight: .heavy).monospacedDigit())
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                        Text(channel.name)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if channel.isFavorite {
                            Image(systemName: "star.fill").foregroundColor(.yellow)
                        }
                    }
                }
                if let program = heroProgram {
                    Text(program.title)
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        if program.isOn(at: now) { badge(L10n.string("live_badge_live", fallback: "LIVE"), color: Color(red: 1, green: 0.3, blue: 0.3)) }
                        if program.isPremiere { badge(L10n.string("live_badge_new", fallback: "NEW"), color: .blue) }
                        Text(timeRange(program))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
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
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(3)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                } else if heroChannel != nil {
                    Text(L10n.string("live_no_guide", fallback: "No guide information"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 10) {
                Text(ChannelsView.clockFormatter.string(from: now))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                heroArt
            }
        }
        .padding(.top, 30)
    }

    private var heroArt: some View {
        let height = LiveGuideMetrics.artWidth * 9 / 16
        return ZStack {
            Color.white.opacity(0.06)
            if let image = heroProgram?.imageURL {
                CachedPosterArtwork(urlString: image.absoluteString, width: LiveGuideMetrics.artWidth, height: height, maximumWidth: LiveGuideMetrics.artWidth) {
                    logo(heroChannel, size: 160)
                }
            } else {
                logo(heroChannel, size: 160)
            }
        }
        .frame(width: LiveGuideMetrics.artWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    @ViewBuilder
    private func logo(_ channel: LiveTVChannel?, size: CGFloat) -> some View {
        if let url = channel?.imageURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv").font(.system(size: size * 0.4)).foregroundColor(.white.opacity(0.4))
                }
            }
            .frame(width: size * 1.6, height: size)
        } else {
            Image(systemName: "tv").font(.system(size: size * 0.4)).foregroundColor(.white.opacity(0.4))
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

    private var filterBar: some View {
        HStack(spacing: 14) {
            ForEach(LiveFilter.allCases) { option in
                SourceModeChip(title: option.title, isSelected: filter == option) {
                    filter = option
                }
            }
            Spacer()
            if !multiview.channels.isEmpty {
                SourceModeChip(
                    title: L10n.format("live_open_multiview", fallback: "Multiview (%d)", multiview.channels.count),
                    isSelected: false
                ) {
                    multiview.isPresented = true
                }
            }
        }
        .frame(height: 60)
        .focusSection()
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
        let top = LiveGuideMetrics.heroHeight + 74 + 20
        return Rectangle()
            .fill(Color(red: 1, green: 0.32, blue: 0.32))
            .frame(width: 3, height: max(0, height - top))
            .offset(x: x, y: top)
            .allowsHitTesting(false)
    }

    // MARK: Rows

    private enum Segment {
        case program(LiveTVProgram, width: CGFloat, startsEarlier: Bool)
        case gap(width: CGFloat)
    }

    private func segments(for channel: LiveTVChannel, gridWidth: CGFloat, ppm: CGFloat) -> [Segment] {
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
            result.append(.program(program, width: width, startsEarlier: program.start < start))
            cursor = to
        }
        return result
    }

    private func row(_ channel: LiveTVChannel, gridWidth: CGFloat, ppm: CGFloat) -> some View {
        let parts = segments(for: channel, gridWidth: gridWidth, ppm: ppm)
        let isRowFocused = focusedChannel?.id == channel.id && focusedCell != nil
        return HStack(spacing: 0) {
            channelCell(channel, isRowFocused: isRowFocused)
                .frame(width: LiveGuideMetrics.channelColumn, height: LiveGuideMetrics.rowHeight)
            HStack(spacing: 0) {
                if parts.contains(where: { if case .program = $0 { return true }; return false }) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .gap(let width):
                            Color.clear.frame(width: width)
                        case .program(let program, let width, let earlier):
                            programCell(program, channel: channel, width: width, startsEarlier: earlier)
                        }
                    }
                } else {
                    noGuideCell(channel, width: gridWidth)
                }
            }
            .frame(width: gridWidth, height: LiveGuideMetrics.rowHeight, alignment: .leading)
            .clipped()
        }
    }

    private func channelCell(_ channel: LiveTVChannel, isRowFocused: Bool) -> some View {
        HStack(spacing: 12) {
            Text(store.number(of: channel))
                .font(.system(size: 20, weight: .heavy).monospacedDigit())
                .foregroundColor(isRowFocused ? .black : .white.opacity(0.7))
                .frame(width: 58)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            logo(channel, size: 44)
                .frame(width: 72)
            Text(channel.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(isRowFocused ? .black : .white)
                .lineLimit(2)
            Spacer(minLength: 0)
            if channel.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isRowFocused ? .orange : .yellow)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isRowFocused ? Color.white : Color.white.opacity(0.07))
        )
        .padding(.trailing, LiveGuideMetrics.cellGap)
        .animation(.easeOut(duration: 0.12), value: isRowFocused)
    }

    private func programCell(_ program: LiveTVProgram, channel: LiveTVChannel, width: CGFloat, startsEarlier: Bool) -> some View {
        let key = "\(channel.id)#\(program.id)"
        let isFocused = focusedCell == key
        let isNow = program.isOn(at: now)
        let cellWidth = max(4, width - LiveGuideMetrics.cellGap)
        return Button {
            store.watch(channel)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
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
        .contextMenu { menu(for: channel) }
        .onChange(of: focusedCell == key) { _, focused in
            guard focused else { return }
            focusedChannel = channel
            focusedProgram = program
        }
        .padding(.trailing, LiveGuideMetrics.cellGap)
    }

    private func noGuideCell(_ channel: LiveTVChannel, width: CGFloat) -> some View {
        let key = "\(channel.id)#none"
        let isFocused = focusedCell == key
        return Button {
            store.watch(channel)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Color(red: 1, green: 0.32, blue: 0.32)).frame(width: 9, height: 9)
                Text(L10n.string("live_no_guide_cell", fallback: "Live · No guide information"))
                    .font(.system(size: 20, weight: .semibold))
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
        .contextMenu { menu(for: channel) }
        .onChange(of: focusedCell == key) { _, focused in
            guard focused else { return }
            focusedChannel = channel
            focusedProgram = nil
        }
    }

    @ViewBuilder
    private func menu(for channel: LiveTVChannel) -> some View {
        Button {
            store.watch(channel)
        } label: {
            Label(L10n.string("live_watch", fallback: "Watch"), systemImage: "play.fill")
        }
        Button {
            store.addToMultiview(channel)
        } label: {
            Label(L10n.string("live_add_multiview", fallback: "Add to Multiview"), systemImage: "rectangle.split.2x2")
        }
        if !multiview.channels.isEmpty {
            Button {
                multiview.isPresented = true
            } label: {
                Label(L10n.format("live_open_multiview", fallback: "Multiview (%d)", multiview.channels.count), systemImage: "rectangle.split.2x2.fill")
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

// MARK: - Tuning card and info banner

/// Mounted at the app root next to the Channels overlay: the card shown while
/// a live channel opens (or fails), and the info bar after it starts.
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
        }
        .animation(.easeInOut(duration: 0.3), value: store.overlay)
        .animation(.easeInOut(duration: 0.35), value: store.banner)
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
                HStack(spacing: 14) {
                    Text(store.number(of: channel))
                        .font(.system(size: 28, weight: .heavy).monospacedDigit())
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    Text(channel.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
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
                Text(store.number(of: banner.channel))
                    .font(.system(size: 34, weight: .heavy).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(minWidth: 110)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(banner.channel.name.uppercased())
                        .font(.system(size: 17, weight: .heavy))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.55))
                    Text(banner.now?.title ?? L10n.string("live_no_guide", fallback: "No guide information"))
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
