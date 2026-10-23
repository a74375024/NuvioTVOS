import SwiftUI

/// The player's mini guide: Left while watching opens it on the channel on
/// screen. Up / Down browse now & next (the picture keeps playing beside
/// it), Select switches. Left again opens the neighborhoods inside the same
/// panel: Up / Down move through them with the list following, Right or
/// Select lands on the first channel there. Back steps out one level.
struct LiveMiniGuide: View {
    @ObservedObject private var store = LiveTVStore.shared
    @FocusState private var rowFocus: String?
    @FocusState private var hoodFocus: LineupCategory?
    @State private var hoodsOpen = false
    @State private var origin: LineupCategory?
    @State private var returnRow: String?
    @State private var channels: [LiveTVChannel] = []
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private struct Hood: Identifiable {
        let category: LineupCategory
        let headerID: String
        let first: LiveTVChannel
        var count: Int
        var id: String { category.rawValue }
    }

    private enum Item: Identifiable {
        case header(String, LineupCategory, Int)
        case row(LiveTVChannel)
        var id: String {
            switch self {
            case .header(_, let category, let index): return "mh|\(index)|\(category.rawValue)"
            case .row(let channel): return channel.id
            }
        }
    }

    private var items: [Item] {
        var result: [Item] = []
        var last: LineupCategory?
        for channel in channels {
            if let category = store.category(of: channel.id), category != last {
                result.append(.header(category.genreTitle, category, result.count))
                last = category
            }
            result.append(.row(channel))
        }
        return result
    }

    private var hoods: [Hood] {
        var result: [Hood] = []
        var index: [LineupCategory: Int] = [:]
        var pending: (String, LineupCategory)?
        for item in items {
            switch item {
            case .header(_, let category, _):
                pending = (item.id, category)
            case .row(let channel):
                guard let category = store.category(of: channel.id) else { continue }
                if let at = index[category] {
                    result[at].count += 1
                } else if let header = pending, header.1 == category {
                    index[category] = result.count
                    result.append(Hood(category: category, headerID: header.0, first: channel, count: 1))
                }
                pending = nil
            }
        }
        return result
    }

    var body: some View {
        let width: CGFloat = hoodsOpen ? 1340 : 980
        LiveSidePanel(edge: .leading, width: width) {
            ScrollViewReader { scroller in
                VStack(alignment: .leading, spacing: 0) {
                    LiveSectionLabel(text: L10n.string("live_tv", fallback: "Live TV") + "  ·  " + ChannelsView.clockFormatter.string(from: now))
                        .padding(.bottom, 24)
                    HStack(alignment: .top, spacing: 0) {
                        if hoodsOpen {
                            hoodColumn(scroller: scroller)
                                .frame(width: 320)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1)
                                .padding(.horizontal, 24)
                        }
                        channelList
                            .frame(width: 780)
                            .opacity(hoodsOpen ? LiveStyle.inactive : 1)
                            .disabled(hoodsOpen)
                    }
                    Text(hoodsOpen
                         ? L10n.string("live_mini_hint_hoods", fallback: "▲▼ neighborhoods   ·   ▶ or Select: pick   ·   Back: close")
                         : L10n.string("live_mini_hint", fallback: "▲▼ browse   ·   Select: watch   ·   ◀ neighborhoods   ·   Back: close"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.top, 14)
                }
                .padding(.leading, 70)
                .padding(.top, 50)
                .padding(.bottom, 40)
                .onAppear {
                    channels = store.miniGuideChannels()
                    let target = store.watching?.id
                    DispatchQueue.main.async {
                        if let target { scroller.scrollTo(target, anchor: .center) }
                        rowFocus = target ?? channels.first?.id
                    }
                }
                .onChange(of: hoodFocus) { _, category in
                    // The list follows the neighborhood being browsed.
                    guard let category, let hood = hoods.first(where: { $0.category == category }) else { return }
                    scroller.scrollTo(hood.headerID, anchor: .top)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: hoodsOpen)
        .onReceive(ticker) { now = $0 }
        .onExitCommand {
            if hoodsOpen { closeHoods(landingOn: nil) } else { store.closeMiniGuide() }
        }
    }

    // MARK: Channel list

    private var channelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    switch item {
                    case .header(let title, _, _):
                        LiveSectionLabel(text: title)
                            .padding(.leading, 6)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    case .row(let channel):
                        row(channel)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .focusSection()
    }

    private func row(_ channel: LiveTVChannel) -> some View {
        let focused = rowFocus == channel.id
        let program = store.current(on: channel.id, at: now)
        let next = store.next(on: channel.id, at: now)
        let isWatching = store.watching?.id == channel.id
        return Button {
            store.watchFromMiniGuide(channel)
        } label: {
            HStack(spacing: 22) {
                ChannelLogoView(urls: store.logoSpec(for: channel).urls, width: 136, height: 64, focused: focused) {
                    Text(channel.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 136, height: 64)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(program?.title ?? channel.displayName)
                            .font(LiveStyle.rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isWatching {
                            HStack(spacing: 7) {
                                Circle().fill(LiveStyle.watching).frame(width: 10, height: 10)
                                Text(L10n.string("live_watching", fallback: "WATCHING"))
                                    .font(.system(size: 14, weight: .heavy))
                                    .tracking(0.8)
                                    .foregroundColor(focused ? Color(red: 0.75, green: 0.1, blue: 0.15) : LiveStyle.watching)
                            }
                        }
                    }
                    Text(detail(channel: channel, program: program, next: next))
                        .font(LiveStyle.rowDetail)
                        .opacity(0.6)
                        .lineLimit(1)
                    if let program {
                        progress(program, focused: focused)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, height: 96))
        .focused($rowFocus, equals: channel.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .left { openHoods(from: channel) }
        }
    }

    private func detail(channel: LiveTVChannel, program: LiveTVProgram?, next: LiveTVProgram?) -> String {
        var parts: [String] = []
        if let program {
            parts.append(L10n.format("live_until", fallback: "until %@", ChannelsView.clockFormatter.string(from: program.end)))
        } else {
            parts.append(channel.displayName)
        }
        if let next {
            parts.append(L10n.format("live_next_title", fallback: "Next: %@", next.title))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func progress(_ program: LiveTVProgram, focused: Bool) -> some View {
        let total = program.end.timeIntervalSince(program.start)
        let fraction = total > 0 ? min(1, max(0, now.timeIntervalSince(program.start) / total)) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(focused ? Color.black.opacity(0.15) : Color.white.opacity(0.2))
            Capsule().fill(focused ? Color.black : Color.white).frame(width: 280 * fraction)
        }
        .frame(width: 280, height: 5)
    }

    // MARK: Neighborhoods

    private func hoodColumn(scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveSectionLabel(text: L10n.string("live_neighborhoods", fallback: "Neighborhoods"))
                .padding(.leading, 6)
                .padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hoods) { hood in
                        hoodButton(hood)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .focusSection()
    }

    private func hoodButton(_ hood: Hood) -> some View {
        let focused = hoodFocus == hood.category
        return Button {
            closeHoods(landingOn: hood)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(LiveStyle.watching)
                    .frame(width: 9, height: 9)
                    .opacity(hood.category == origin && !focused ? 1 : 0)
                Text(hood.category.genreTitle)
                    .font(LiveStyle.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Text("\(hood.count)")
                    .font(LiveStyle.rowValue.monospacedDigit())
                    .opacity(0.6)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused))
        .focused($hoodFocus, equals: hood.category)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            if direction == .right { closeHoods(landingOn: hood) }
        }
    }

    private func openHoods(from channel: LiveTVChannel) {
        guard let category = store.category(of: channel.id), hoods.count > 1 else { return }
        returnRow = channel.id
        origin = category
        hoodsOpen = true
        hoodFocus = category
        DispatchQueue.main.async { if hoodsOpen { hoodFocus = category } }
    }

    /// Closes the neighborhoods: onto the first channel of `hood`, or (Back)
    /// onto the row you came from.
    private func closeHoods(landingOn hood: Hood?) {
        let target = hood?.first.id ?? returnRow
        hoodsOpen = false
        hoodFocus = nil
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !hoodsOpen, let target, rowFocus != target else { return }
                rowFocus = target
            }
        }
    }
}
