import SwiftUI

private enum ChannelGuideMetrics {
    static let pageInset: CGFloat = 49
    static let rowHeight: CGFloat = 150
    static let thumbWidth: CGFloat = 230
}

/// The Channels guide: each ready-made channel with what it starts with.
struct ChannelsView: View {
    @ObservedObject private var store = ChannelSessionStore.shared
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @FocusState private var focusedChannel: String?

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(store.channels) { channel in
                        ChannelGuideRow(
                            channel: channel,
                            preview: store.previews[channel.id],
                            isUnavailable: store.unavailable.contains(channel.id),
                            isLoading: store.isLoadingLineup,
                            isFocused: focusedChannel == channel.id
                        ) {
                            store.tune(channel.id)
                        }
                        .focused($focusedChannel, equals: channel.id)
                    }
                    footnote
                }
                .padding(.horizontal, ChannelGuideMetrics.pageInset)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
        }
        .onAppear { store.loadLineupIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(L10n.string("channels_title", fallback: "Channels"))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)
                if store.isLoadingLineup {
                    ProgressView().tint(.white)
                    Text(L10n.string("channels_loading", fallback: "Building today's lineup…"))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                Text(Self.timeFormatter.string(from: Date()))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            Text(L10n.string(
                "channels_subtitle",
                fallback: "Pick a channel and it plays nonstop. Every tune-in starts fresh."
            ))
            .font(.system(size: 24))
            .foregroundColor(.white.opacity(0.6))
        }
        .padding(.bottom, 12)
    }

    private var footnote: some View {
        Text(L10n.string(
            "channels_footnote",
            fallback: "Programs come from popular and top-rated titles. Streams use your add-ons; titles without a stream are skipped. Watching here doesn't change your Continue Watching."
        ))
        .font(.system(size: 20))
        .foregroundColor(.white.opacity(0.45))
        .padding(.top, 20)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct ChannelGuideRow: View {
    let channel: ChannelDefinition
    let preview: ChannelItem?
    let isUnavailable: Bool
    let isLoading: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 28) {
                ZStack {
                    Circle().fill(Color.white.opacity(isFocused ? 0.95 : 0.12))
                    Image(systemName: channel.symbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .white)
                }
                .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(channel.name)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        if channel.season != nil {
                            Text(L10n.string("channels_seasonal", fallback: "SEASONAL"))
                                .font(.system(size: 15, weight: .heavy))
                                .tracking(0.8)
                                .foregroundColor(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 1.0, green: 0.62, blue: 0.2)))
                        }
                    }
                    Text(channel.tagline)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(width: 560, alignment: .leading)

                Spacer(minLength: 20)

                startsWith
            }
            .padding(.horizontal, 26)
            .frame(height: ChannelGuideMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.16 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isFocused ? AppFocusOutline.color : .clear, lineWidth: isFocused ? AppFocusOutline.width : 0)
            )
            .scaleEffect(isFocused ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .disabled(isUnavailable)
        .opacity(isUnavailable ? 0.45 : 1)
    }

    @ViewBuilder
    private var startsWith: some View {
        HStack(spacing: 18) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(L10n.string("channels_starts_with", fallback: "STARTS WITH"))
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.45))
                if let preview {
                    Text(preview.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(preview.detailLine)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                } else if isUnavailable {
                    Text(L10n.string("channels_unavailable", fallback: "Unavailable right now"))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text(isLoading
                         ? L10n.string("channels_picking", fallback: "Picking…")
                         : L10n.string("channels_surprise", fallback: "A surprise"))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(width: 420, alignment: .trailing)

            CachedPosterArtwork(
                urlString: preview?.artworkURL,
                width: ChannelGuideMetrics.thumbWidth,
                height: ChannelGuideMetrics.thumbWidth * 9 / 16,
                maximumWidth: ChannelGuideMetrics.thumbWidth
            ) {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.07))
                    Image(systemName: channel.symbol)
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .frame(width: ChannelGuideMetrics.thumbWidth, height: ChannelGuideMetrics.thumbWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Full-screen card shown while tuning in and between programs. Mount once
/// above everything at the app root.
struct ChannelTransitionOverlay: View {
    @ObservedObject private var store = ChannelSessionStore.shared
    @FocusState private var buttonFocused: Bool

    var body: some View {
        if let overlay = store.overlay {
            content(for: overlay)
                .transition(.opacity)
                .onAppear { DispatchQueue.main.async { buttonFocused = true } }
        }
    }

    @ViewBuilder
    private func content(for overlay: ChannelSessionStore.Overlay) -> some View {
        let parts = Self.parts(of: overlay)
        let item = parts.item
        let kind = parts.kind
        let message = parts.message
        let channel = ChannelLineup.channel(id: parts.channelID)
        ZStack {
            Color.black.ignoresSafeArea()

            if let artwork = item?.artworkURL {
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
                HStack(spacing: 14) {
                    if let channel {
                        Image(systemName: channel.symbol)
                            .font(.system(size: 30, weight: .semibold))
                        Text(channel.name)
                            .font(.system(size: 30, weight: .bold))
                    }
                }
                .foregroundColor(.white.opacity(0.85))

                Text(kind)
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

                if let message {
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
