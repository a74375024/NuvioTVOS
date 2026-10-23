import SwiftUI

/// A channel logo from a list of candidates (first that loads wins), sized
/// to fit `width`×`height`. Dark logos sit on a light plate; on a focused
/// (white) row every other logo sits on a dark plate so white logos don't
/// vanish. Shows `fallback` when nothing loads.
struct ChannelLogoView<Fallback: View>: View {
    let urls: [URL]
    let width: CGFloat
    let height: CGFloat
    var focused = false
    @ViewBuilder var fallback: () -> Fallback

    @State private var logo: ChannelLogoLoader.Logo?
    @State private var settled = false
    @State private var loadedFor: [URL] = []

    var body: some View {
        content
            .frame(width: width, height: height)
            .task(id: urls) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        let current = loadedFor == urls ? logo : ChannelLogoLoader.shared.cached(urls).logo
        if let current {
            let plate: Color? = current.isDark ? Color.white.opacity(0.88) : (focused ? Color.black.opacity(0.88) : nil)
            let inset: CGFloat = plate == nil ? 0 : max(5, height * 0.12)
            Image(uiImage: current.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(.horizontal, inset * 1.4)
                .padding(.vertical, inset)
                .frame(maxWidth: width, maxHeight: height)
                .background(
                    Group {
                        if let plate {
                            RoundedRectangle(cornerRadius: min(12, height * 0.2), style: .continuous).fill(plate)
                        }
                    }
                )
        } else if failed {
            fallback()
        } else {
            Color.clear
        }
    }

    private var failed: Bool {
        if loadedFor == urls { return settled && logo == nil }
        let cached = ChannelLogoLoader.shared.cached(urls)
        return cached.settled && cached.logo == nil
    }

    private func load() async {
        let wanted = urls
        let cached = ChannelLogoLoader.shared.cached(wanted)
        if cached.settled {
            logo = cached.logo
            settled = true
            loadedFor = wanted
            return
        }
        let result = await ChannelLogoLoader.shared.load(wanted)
        guard !Task.isCancelled, wanted == urls else { return }
        logo = result
        settled = true
        loadedFor = wanted
    }
}

extension ChannelLogoView where Fallback == EmptyView {
    init(urls: [URL], width: CGFloat, height: CGFloat, focused: Bool = false) {
        self.init(urls: urls, width: width, height: height, focused: focused, fallback: { EmptyView() })
    }
}

/// The guide's channel column cell: a curated national logo on its own, a
/// local's logo with call sign and "FOX 2", or a logo next to the name. The
/// name shows whenever no logo loads.
struct LiveChannelCell: View {
    let channel: LiveTVChannel
    let spec: ChannelLogoSpec
    let focused: Bool
    let dimmed: Bool

    private var primary: Color { focused ? .black : .white }
    private var secondary: Color { focused ? .black.opacity(0.6) : .white.opacity(0.55) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(focused ? Color.white : Color.white.opacity(0.07))
            content
                .padding(.horizontal, 12)
            corner
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    @ViewBuilder
    private var content: some View {
        switch spec.style {
        case .logoOnly:
            ChannelLogoView(urls: spec.urls, width: LiveGuideMetrics.channelColumn - LiveGuideMetrics.cellGap - 40,
                            height: LiveGuideMetrics.rowHeight - 30, focused: focused) {
                nameBlock
            }
        case .local(let callsign, let line):
            HStack(spacing: 10) {
                if !spec.urls.isEmpty {
                    ChannelLogoView(urls: spec.urls, width: 58, height: 36, focused: focused)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(callsign)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
        case .named:
            NamedChannelContent(channel: channel, spec: spec, primary: primary, secondary: secondary, focused: focused)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(channel.displayName)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if let subtitle = spec.subtitle {
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Favorite star / hidden eye at the top right, WEST at the bottom right.
    private var corner: some View {
        VStack {
            HStack {
                Spacer()
                if dimmed {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondary)
                } else if channel.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(focused ? .orange : .yellow)
                }
            }
            Spacer()
            if spec.isWest {
                HStack {
                    Spacer()
                    Text("WEST")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: focused ? 0.25 : 0.32)))
                }
            }
        }
        .padding(7)
    }
}

/// Logo (when one loads) beside the channel name; the name with its
/// neighborhood under it when none does.
private struct NamedChannelContent: View {
    let channel: LiveTVChannel
    let spec: ChannelLogoSpec
    let primary: Color
    let secondary: Color
    let focused: Bool

    @State private var hasLogo = true

    var body: some View {
        HStack(spacing: 10) {
            if !spec.urls.isEmpty, hasLogo {
                ChannelLogoView(urls: spec.urls, width: 58, height: 36, focused: focused) {
                    Color.clear.onAppear { hasLogo = false }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if spec.urls.isEmpty || !hasLogo, let subtitle = spec.subtitle {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: spec.urls) { _, _ in hasLogo = true }
    }
}
