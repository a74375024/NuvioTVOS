import SwiftUI

private enum GuideMetrics {
    static let sideInset: CGFloat = 60
    static let channelColumn: CGFloat = 300
    static let rowHeight: CGFloat = 112
    static let rowSpacing: CGFloat = 10
    static let cellGap: CGFloat = 8
    static let minCellWidth: CGFloat = 150
    static let heroHeight: CGFloat = 420
    static let previewWidth: CGFloat = 640
}

// MARK: - Guide

/// Cable-style Channels guide: preview pane on top, a numbered channel grid
/// with a time ruler below. Programs are sized by running time; everything
/// starts from the beginning when chosen.
struct ChannelsView: View {
    @ObservedObject private var store = ChannelSessionStore.shared
    @AppStorage(SettingsKey.amoled) private var amoled = false
    // Same trailer preview the posters use, with the same settings.
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @State private var trailerActiveID: String?
    @State private var trailerReadyID: String?
    @State private var trailerFinishedID: String?
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @FocusState private var focusedCell: String?
    @State private var focusedItem: ChannelItem?
    @State private var focusedChannelID: String?
    @State private var guideStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let gridWidth = max(600, proxy.size.width - GuideMetrics.sideInset * 2 - GuideMetrics.channelColumn)
            let pointsPerMinute = gridWidth / CGFloat(ChannelSessionStore.guideWindowMinutes)
            ZStack(alignment: .top) {
                Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
                heroBackdrop
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .frame(width: max(0, proxy.size.width - GuideMetrics.sideInset * 2), height: GuideMetrics.heroHeight)
                        .clipped()
                    timeRuler(gridWidth: gridWidth, pointsPerMinute: pointsPerMinute)
                        .padding(.bottom, 10)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: GuideMetrics.rowSpacing) {
                            ForEach(store.channels) { channel in
                                guideRow(channel, gridWidth: gridWidth, pointsPerMinute: pointsPerMinute)
                            }
                        }
                        .padding(.bottom, 60)
                    }
                    // Rows scroll under the ruler, not over it; sides and
                    // bottom stay open for the focus lift.
                    .mask(Rectangle().padding(.horizontal, -60).padding(.bottom, -200))
                    .focusSection()
                }
                .padding(.horizontal, GuideMetrics.sideInset)
                .frame(width: proxy.size.width, alignment: .leading)
            }
        }
        .onAppear {
            guideStart = Date()
            store.loadLineupIfNeeded()
        }
        .onChange(of: store.isActive) { _, active in
            if !active { guideStart = Date() }
        }
        .task(id: focusedItem?.id) {
            // Like the posters: wait a moment on a program before its trailer
            // plays (capped so browsing the guide stays snappy).
            trailerActiveID = nil
            trailerReadyID = nil
            guard trailersEnabled, let id = focusedItem?.id else { return }
            let delay = Double(min(2, max(0, trailerDelay)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            trailerActiveID = id
        }
    }

    // MARK: Hero / preview pane

    private var heroItem: ChannelItem? {
        focusedItem ?? store.channels.lazy.compactMap { store.lineups[$0.id]?.first }.first
    }

    private var heroChannel: ChannelDefinition? {
        let id = focusedChannelID ?? heroItem?.channelID
        return store.channels.first { $0.id == id }
    }

    @ViewBuilder
    private var heroBackdrop: some View {
        if let url = heroItem?.backdropURL {
            CachedPosterArtwork(urlString: url, width: 1920, height: 1080, maximumWidth: 1920) { Color.clear }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(0.22)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.4), .clear], startPoint: .top, endPoint: .center))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.4), value: heroItem?.id)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text(L10n.string("channels_title", fallback: "Channels"))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                    if store.isLoadingLineup {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    }
                }

                if let channel = heroChannel {
                    HStack(spacing: 12) {
                        Text(String(store.number(of: channel.id)))
                            .font(.system(size: 24, weight: .heavy).monospacedDigit())
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                        Image(systemName: channel.symbol)
                            .font(.system(size: 24, weight: .semibold))
                        Text(channel.name)
                            .font(.system(size: 26, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }

                if let item = heroItem {
                    Text(item.title)
                        .font(.system(size: 54, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(item.detailLine)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(timingLine(for: item))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    if let overview = item.overview {
                        Text(overview)
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(3)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                } else {
                    Text(L10n.string("channels_loading", fallback: "Building today's lineup…"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

            VStack(alignment: .trailing, spacing: 10) {
                Text(Self.clockFormatter.string(from: Date()))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                previewWindow
            }
        }
        .padding(.top, 30)
    }

    /// Mounted only while browsing: never behind a playing channel.
    private var showsTrailer: Bool {
        guard trailersEnabled, focusedCell != nil, !store.isActive, store.overlay == nil,
              let item = heroItem else { return false }
        return trailerFinishedID != item.id
    }

    private var previewWindow: some View {
        let height = GuideMetrics.previewWidth * 9 / 16
        let item = heroItem
        let isPlaying = item != nil && trailerReadyID == item?.id && trailerActiveID == item?.id
        return ZStack {
            Color.black
            if let item {
                CachedPosterArtwork(
                    urlString: item.backdropURL,
                    width: GuideMetrics.previewWidth,
                    height: height,
                    maximumWidth: GuideMetrics.previewWidth
                ) { Color.black }
                .opacity(isPlaying ? 0 : 1)
            }
            if showsTrailer, let item {
                TrailerPreviewPlayer(
                    meta: item.meta,
                    isActive: trailerActiveID == item.id,
                    onPlaybackReady: {
                        guard trailerActiveID == item.id else { return }
                        trailerReadyID = item.id
                    },
                    onPlaybackFinished: {
                        trailerFinishedID = item.id
                        trailerReadyID = nil
                    }
                )
                .id(item.id)
                .transition(.opacity)
            }
            VStack {
                HStack {
                    if isPlaying {
                        Text(L10n.string("channels_trailer", fallback: "TRAILER"))
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(0.8)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(width: GuideMetrics.previewWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .animation(.easeInOut(duration: 0.32), value: isPlaying)
    }

    private func timingLine(for item: ChannelItem) -> String {
        guard let offset = startOffset(of: item) else { return "\(item.durationMinutes) min" }
        let start = guideStart.addingTimeInterval(TimeInterval(offset * 60))
        let end = start.addingTimeInterval(TimeInterval(item.durationMinutes * 60))
        let range = "\(Self.clockFormatter.string(from: start))–\(Self.clockFormatter.string(from: end))"
        let lead = offset == 0
            ? L10n.string("channels_starts_now", fallback: "Starts when you tune in")
            : L10n.string("channels_later", fallback: "Later on")
        return "\(lead) · \(range) · \(item.durationMinutes) min"
    }

    private func startOffset(of item: ChannelItem) -> Int? {
        guard let lineup = store.lineups[item.channelID],
              let index = lineup.firstIndex(of: item) else { return nil }
        return lineup.prefix(index).reduce(0) { $0 + $1.durationMinutes }
    }

    // MARK: Time ruler

    private func timeRuler(gridWidth: CGFloat, pointsPerMinute: CGFloat) -> some View {
        let calendar = Calendar.current
        let minuteNow = calendar.component(.minute, from: guideStart)
        let firstMark = minuteNow < 30 ? 30 - minuteNow : 60 - minuteNow
        let marks = stride(from: firstMark, to: ChannelSessionStore.guideWindowMinutes, by: 30).map { $0 }
        return HStack(spacing: 0) {
            Text(Self.dayFormatter.string(from: guideStart).uppercased())
                .font(.system(size: 18, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.5))
                .frame(width: GuideMetrics.channelColumn, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).offset(y: 18)
                Text(L10n.string("channels_now", fallback: "NOW"))
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundColor(Color(red: 1.0, green: 0.36, blue: 0.36))
                ForEach(marks, id: \.self) { minutes in
                    Text(Self.clockFormatter.string(from: guideStart.addingTimeInterval(TimeInterval(minutes * 60))))
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.6))
                        .offset(x: CGFloat(minutes) * pointsPerMinute)
                }
            }
            .frame(width: gridWidth, height: 40, alignment: .leading)
            .clipped()
        }
    }

    // MARK: Rows

    private func guideRow(_ channel: ChannelDefinition, gridWidth: CGFloat, pointsPerMinute: CGFloat) -> some View {
        let lineup = store.lineups[channel.id] ?? []
        let isUnavailable = store.unavailable.contains(channel.id)
        let isRowFocused = focusedChannelID == channel.id && focusedCell != nil
        return HStack(spacing: 0) {
            channelCell(channel, isRowFocused: isRowFocused)
                .frame(width: GuideMetrics.channelColumn, height: GuideMetrics.rowHeight)

            HStack(spacing: GuideMetrics.cellGap) {
                if lineup.isEmpty {
                    placeholderCell(
                        isUnavailable
                            ? L10n.string("channels_unavailable", fallback: "Unavailable right now")
                            : L10n.string("channels_picking", fallback: "Picking programs…"),
                        showsProgress: !isUnavailable
                    )
                    .frame(width: gridWidth)
                } else {
                    ForEach(laidOut(lineup, gridWidth: gridWidth, pointsPerMinute: pointsPerMinute), id: \.item.id) { cell in
                        programCell(cell.item, channel: channel, width: cell.width, isFirst: cell.isFirst)
                    }
                }
            }
            .frame(width: gridWidth, height: GuideMetrics.rowHeight, alignment: .leading)
            .clipped()
        }
    }

    private struct LaidOutCell {
        let item: ChannelItem
        let width: CGFloat
        let isFirst: Bool
    }

    /// Sizes programs by running time and keeps only what fits the window.
    private func laidOut(_ lineup: [ChannelItem], gridWidth: CGFloat, pointsPerMinute: CGFloat) -> [LaidOutCell] {
        var cells: [LaidOutCell] = []
        var x: CGFloat = 0
        for (index, item) in lineup.enumerated() {
            guard x < gridWidth - 40 else { break }
            let natural = CGFloat(item.durationMinutes) * pointsPerMinute - GuideMetrics.cellGap
            let width = min(max(natural, GuideMetrics.minCellWidth), gridWidth - x)
            cells.append(LaidOutCell(item: item, width: width, isFirst: index == 0))
            x += width + GuideMetrics.cellGap
        }
        return cells
    }

    private func channelCell(_ channel: ChannelDefinition, isRowFocused: Bool) -> some View {
        HStack(spacing: 14) {
            Text(String(store.number(of: channel.id)))
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .foregroundColor(isRowFocused ? .black : .white.opacity(0.7))
                .frame(width: 56)
            Image(systemName: channel.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isRowFocused ? .black : .white)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isRowFocused ? .black : .white)
                    .lineLimit(1)
                if channel.season != nil {
                    Text(L10n.string("channels_seasonal", fallback: "SEASONAL"))
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.6)
                        .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.15))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isRowFocused ? Color.white : Color.white.opacity(0.07))
        )
        .padding(.trailing, GuideMetrics.cellGap)
        .animation(.easeOut(duration: 0.12), value: isRowFocused)
    }

    private func programCell(_ item: ChannelItem, channel: ChannelDefinition, width: CGFloat, isFirst: Bool) -> some View {
        let isFocused = focusedCell == item.id
        return Button {
            store.tune(channel.id, startingAt: item.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isFirst {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.36, blue: 0.36))
                            .frame(width: 9, height: 9)
                    }
                    Text(item.title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                }
                Text(item.episode != nil ? item.detailLine : "\(item.detailLine) · \(item.durationMinutes) min")
                    .font(.system(size: 18, weight: .medium))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, 16)
            .frame(width: width, height: GuideMetrics.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(isFirst ? 0.13 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? 3 : 0)
            )
            .scaleEffect(isFocused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedCell, equals: item.id)
        .focusEffectDisabledIfAvailable()
        .onChange(of: focusedCell == item.id) { _, focused in
            guard focused else { return }
            focusedItem = item
            focusedChannelID = channel.id
        }
    }

    private func placeholderCell(_ text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 12) {
            if showsProgress { ProgressView().tint(.white).scaleEffect(0.7) }
            Text(text)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: GuideMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}

// MARK: - Tuning card and info banner

/// Mounted once above everything at the app root: the full-screen card shown
/// while tuning in or between programs, and the cable-style info banner
/// shown over playback when a program starts.
struct ChannelTransitionOverlay: View {
    @ObservedObject private var store = ChannelSessionStore.shared
    @FocusState private var buttonFocused: Bool

    var body: some View {
        ZStack {
            if let overlay = store.overlay {
                content(for: overlay)
                    .transition(.opacity)
                    .onAppear { DispatchQueue.main.async { buttonFocused = true } }
            } else if let banner = store.banner {
                ChannelInfoBanner(banner: banner, number: store.number(of: banner.channelID))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.overlay)
        .animation(.easeInOut(duration: 0.35), value: store.banner)
    }

    @ViewBuilder
    private func content(for overlay: ChannelSessionStore.Overlay) -> some View {
        let parts = Self.parts(of: overlay)
        let item = parts.item
        let channel = ChannelLineup.channel(id: parts.channelID)
        ZStack {
            Color.black.ignoresSafeArea()

            if let artwork = item?.backdropURL {
                CachedPosterArtwork(urlString: artwork, width: 1920, height: 1080, maximumWidth: 1920) {
                    Color.black
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(0.35)
                .ignoresSafeArea()
            }

            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                if let channel {
                    HStack(spacing: 14) {
                        Text(String(store.number(of: channel.id)))
                            .font(.system(size: 28, weight: .heavy).monospacedDigit())
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                        Image(systemName: channel.symbol)
                            .font(.system(size: 30, weight: .semibold))
                        Text(channel.name)
                            .font(.system(size: 30, weight: .bold))
                    }
                    .foregroundColor(.white.opacity(0.9))
                }

                Text(parts.kind)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.55))

                if let item {
                    Text(item.title)
                        .font(.system(size: 64, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(item.detailLine)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }

                if let message = parts.message {
                    Text(message)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: 1100, alignment: .leading)
                } else {
                    HStack(spacing: 14) {
                        ProgressView().tint(.white)
                        Text(L10n.string("channels_finding_stream", fallback: "Finding a stream…"))
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 6)
                }

                Button {
                    store.stop()
                } label: {
                    Text(L10n.string("channels_back_to_guide", fallback: "Back to Guide"))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(buttonFocused ? .black : .white)
                        .padding(.horizontal, 34)
                        .frame(height: 66)
                        .background(Capsule().fill(Color.white.opacity(buttonFocused ? 1 : 0.15)))
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($buttonFocused)
                .focusEffectDisabledIfAvailable()
                .padding(.top, 16)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .focusSection()
        .onExitCommand { store.stop() }
    }

    private static func parts(of overlay: ChannelSessionStore.Overlay) -> (channelID: String, item: ChannelItem?, kind: String, message: String?) {
        switch overlay {
        case .tuning(let channelID, let item):
            return (channelID, item, L10n.string("channels_tuning", fallback: "TUNING IN"), nil)
        case .upNext(let channelID, let item):
            return (channelID, item, L10n.string("channels_up_next", fallback: "UP NEXT"), nil)
        case .failed(let channelID, let message):
            return (channelID, nil, L10n.string("channels_off_air", fallback: "OFF THE AIR"), message)
        }
    }
}

/// The info bar cable boxes show when you land on a channel.
private struct ChannelInfoBanner: View {
    let banner: ChannelSessionStore.Banner
    let number: Int

    var body: some View {
        let channel = ChannelLineup.channel(id: banner.channelID)
        VStack {
            Spacer()
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 6) {
                    Text(String(number))
                        .font(.system(size: 34, weight: .heavy).monospacedDigit())
                    if let channel {
                        Image(systemName: channel.symbol)
                            .font(.system(size: 26, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(width: 110)

                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 90)

                VStack(alignment: .leading, spacing: 6) {
                    Text(channel?.name.uppercased() ?? "")
                        .font(.system(size: 17, weight: .heavy))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.55))
                    Text(banner.item.title)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(banner.item.detailLine) · \(banner.item.durationMinutes) min")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Spacer(minLength: 20)

                if let next = banner.next {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(L10n.string("channels_next", fallback: "NEXT"))
                            .font(.system(size: 17, weight: .heavy))
                            .tracking(1)
                            .foregroundColor(.white.opacity(0.55))
                        Text(next.title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(next.detailLine)
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 520, alignment: .trailing)
                }

                VStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                    Text(L10n.string("channels_ch", fallback: "CH"))
                        .font(.system(size: 15, weight: .heavy))
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
    }
}
