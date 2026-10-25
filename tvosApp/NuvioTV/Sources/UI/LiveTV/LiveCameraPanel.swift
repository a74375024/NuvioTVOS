import SwiftUI

/// Down while watching a race: its cameras over the bottom of the picture.
/// Quick picks first (main and Sky feeds, mixed onboard, tracker, data, the
/// podium cameras, multiviews), then every driver in team colors, followed
/// drivers first. Select switches, Play/Pause follows a driver, Back closes.
struct LiveCameraPanel: View {
    @ObservedObject private var store = LiveTVStore.shared
    /// Driver photos, numbers and official team colors (F1).
    @ObservedObject private var race = RaceData.shared
    @FocusState private var focus: String?
    @State private var followed = SpecialFeeds.followedDrivers

    private var feeds: [CameraFeed] { store.currentCameras() }

    private var quick: [CameraFeed] { feeds.filter { $0.kind != .driver } }

    private var drivers: [CameraFeed] {
        let list = feeds.filter { $0.kind == .driver }
        return list.filter { followed.contains($0.title) } + list.filter { !followed.contains($0.title) }
    }

    var body: some View {
        let quickList = quick
        let driverList = drivers
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(L10n.string("live_badge_live", fallback: "LIVE"))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(LiveStyle.watching))
                Text(store.watchingEvent?.game.map(SportsNames.title) ?? store.watchingEvent?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text(L10n.string("live_cameras_hint_panel", fallback: "Select: switch   ·   Play/Pause: follow a driver   ·   Back: close"))
                    .font(.system(size: 17, weight: .semibold))
                    .opacity(0.55)
            }
            if !quickList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(quickList) { feed in
                            quickButton(feed)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .focusSection()
            }
            if !driverList.isEmpty {
                LiveSectionLabel(text: L10n.format("live_cameras_onboard", fallback: "Onboard · %d drivers", driverList.count))
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(driverList) { feed in
                            driverButton(feed)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .focusSection()
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 70)
        .padding(.top, 34)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 660, alignment: .top)
        .background(
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.055).opacity(0.97),
                                    Color(red: 0.03, green: 0.04, blue: 0.055).opacity(0.9)],
                           startPoint: .bottom, endPoint: .top)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .onAppear {
            // Drivers, once a weekend (F1) or week (NASCAR); nothing when saved.
            let f1 = isF1
            if f1 { race.refreshIfNeeded(sessions: [], results: false) } else { race.refreshNascarIfNeeded() }
            let all = feeds
            let photos = all.filter { $0.kind == .driver && driverInfo($0, f1: f1)?.headshot != nil }.count
            CrashRecorder.note("cameras: open, \(all.count) feeds, \(all.filter { $0.kind == .driver }.count) drivers, "
                               + "\(photos) with photos (\(f1 ? "F1" : "NASCAR"))")
            let current = store.playingFeedID
            let target = feeds.first { $0.channel.id == current || $0.alternates.contains { $0.id == current } }?.id
                ?? quickList.first?.id ?? driverList.first?.id
            DispatchQueue.main.async { focus = target }
        }
        .onExitCommand { store.closeCameras() }
    }

    private var isF1: Bool { store.watchingEvent.map(SpecialFeeds.isF1) ?? false }

    /// Photo, number and color for a driver's camera.
    private func driverInfo(_ feed: CameraFeed, f1: Bool) -> RaceDriver? {
        guard feed.kind == .driver else { return nil }
        return f1 ? race.driver(named: feed.title) : race.nascarDriver(named: feed.title)
    }

    private func isOnScreen(_ feed: CameraFeed) -> Bool {
        guard let current = store.playingFeedID else { return false }
        return feed.channel.id == current || feed.alternates.contains { $0.id == current }
    }

    private func quickButton(_ feed: CameraFeed) -> some View {
        let focused = focus == feed.id
        return Button {
            store.watchCamera(feed)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(feed.title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Text(feed.detail + (isOnScreen(feed) ? "  ·  " + L10n.string("live_cameras_now", fallback: "now") : ""))
                    .font(.system(size: 15))
                    .opacity(0.65)
                    .lineLimit(1)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 16)
            .frame(minWidth: 190, alignment: .leading)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, height: 70, outlined: isOnScreen(feed)))
        .focused($focus, equals: feed.id)
        .focusEffectDisabledIfAvailable()
    }

    private func driverButton(_ feed: CameraFeed) -> some View {
        let focused = focus == feed.id
        let info = driverInfo(feed, f1: isF1)
        let color = Self.color(info?.color ?? SpecialFeeds.teamColor(feed.team)) ?? Color.white.opacity(0.4)
        let isFollowed = followed.contains(feed.title)
        // NASCAR feeds already say "No. 5"; F1 adds the number to the team.
        let detail = feed.number == nil
            ? (info.flatMap { $0.number > 0 ? "\(feed.detail) · #\($0.number)" : nil } ?? feed.detail) : feed.detail
        return Button {
            store.watchCamera(feed)
        } label: {
            HStack(spacing: 10) {
                if let info {
                    headshot(info, color: color)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 5, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.title)
                        .font(.system(size: 19, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail + (isOnScreen(feed) ? "  ·  " + L10n.string("live_cameras_now", fallback: "now") : ""))
                        .font(.system(size: 14))
                        .opacity(0.6)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isFollowed {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(red: 0.88, green: 0.63, blue: 0))
                }
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 12)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, height: 64, outlined: isOnScreen(feed)))
        .focused($focus, equals: feed.id)
        .focusEffectDisabledIfAvailable()
        .onPlayPauseCommand {
            var set = followed
            if set.contains(feed.title) { set.remove(feed.title) } else { set.insert(feed.title) }
            followed = set
            SpecialFeeds.followedDrivers = set
        }
    }

    /// The driver's photo in a circle of the team color (initials until it loads).
    private func headshot(_ driver: RaceDriver, color: Color) -> some View {
        let initials = Text(driver.code)
            .font(.system(size: 13, weight: .heavy))
            .foregroundColor(.white.opacity(0.9))
        return ZStack {
            Circle().fill(color.opacity(0.75))
            if let address = driver.headshot, let url = URL(string: address) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(color, lineWidth: 2))
    }

    /// "DC0000" → the color.
    private static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
