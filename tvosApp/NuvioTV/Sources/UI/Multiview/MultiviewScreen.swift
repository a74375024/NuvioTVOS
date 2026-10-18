import SwiftUI
import AetherEngine

/// Owns the tiles for one visit to the grid. Tiles are created on appear and
/// every engine is stopped on disappear, so nothing keeps decoding off screen.
@MainActor
final class MultiviewSession: ObservableObject {
    @Published private(set) var tiles: [MultiviewTile] = []
    let wakeLockOwnerID = UUID()
    private var nextTagNumber = 1

    func sync(with channels: [MultiviewChannel]) {
        let wanted = Set(channels.map(\.id))
        for tile in tiles where !wanted.contains(tile.id) {
            tile.stop()
        }
        var next: [MultiviewTile] = []
        for channel in channels {
            if let existing = tiles.first(where: { $0.id == channel.id }) {
                next.append(existing)
            } else {
                let tile = MultiviewTile(channel: channel)
                let hasPrimary = next.contains { $0.role == .primary }
                    || tiles.contains { $0.role == .primary && wanted.contains($0.id) }
                tile.start(tag: "tile\(nextTagNumber)", role: hasPrimary ? .secondary : .primary)
                nextTagNumber += 1
                next.append(tile)
            }
        }
        // Keep exactly one primary: promote the first tile if its owner left.
        if !next.contains(where: { $0.role == .primary }) {
            next.first?.role = .primary
        }
        tiles = next
    }

    func setAudible(id: String?) {
        for tile in tiles {
            tile.setAudible(tile.id == id)
        }
    }

    func stopAll() {
        tiles.forEach { $0.stop() }
        tiles = []
    }
}

/// Presents the grid over the whole app. Attach once at the root.
struct MultiviewPresenter: ViewModifier {
    @ObservedObject private var store = MultiviewStore.shared

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $store.isPresented) {
                MultiviewScreen()
            }
    }
}

struct MultiviewScreen: View {
    @ObservedObject private var store = MultiviewStore.shared
    @StateObject private var session = MultiviewSession()
    @FocusState private var focusedSlot: String?
    @State private var expandedID: String?
    @State private var audibleID: String?
    /// Titles, speaker badges and the focus ring fade out after a few idle
    /// seconds so they never cover a score bug or clock; any remote input
    /// brings them back.
    @State private var showsChrome = true
    @State private var chromeHideTask: Task<Void, Never>?

    private static let addSlotID = "multiview.add"
    private static let chromeIdleSeconds: Double = 4
    /// Tiles narrower than this use the compact label and add-slot styling.
    private static let compactWidth: CGFloat = 700

    private var isSpotlight: Bool { store.layout == .spotlight }

    /// The tile in the large spotlight slot: the stored pick, else the first.
    private var spotlightTileID: String? {
        if let id = store.spotlightID, session.tiles.contains(where: { $0.id == id }) {
            return id
        }
        return session.tiles.first?.id
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = computeLayout(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                ForEach(session.tiles) { tile in
                    let isExpanded = expandedID == tile.id
                    let isHidden = expandedID != nil && !isExpanded
                    let frame = isExpanded
                        ? CGRect(origin: .zero, size: proxy.size)
                        : (layout.tiles[tile.id] ?? .zero)
                    tileButton(
                        tile,
                        isExpanded: isExpanded,
                        isCompact: !isExpanded && frame.width < Self.compactWidth
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(isHidden ? 0 : 1)
                    .disabled(isHidden)
                    .zIndex(isExpanded ? 2 : 1)
                }

                if expandedID == nil, let frame = layout.addSlot {
                    addSlot(isCompact: frame.width < Self.compactWidth)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                if expandedID == nil, showsChrome, session.tiles.count > 1 {
                    layoutHint
                        .frame(width: proxy.size.width)
                        .position(x: proxy.size.width / 2, y: proxy.size.height - 34)
                        .transition(.opacity)
                        .zIndex(3)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: expandedID)
            .animation(.easeInOut(duration: 0.3), value: store.layout)
            .animation(.easeInOut(duration: 0.3), value: store.spotlightID)
            .animation(.easeInOut(duration: 0.25), value: session.tiles.map(\.id))
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            PlaybackWakeLock.acquire(ownerID: session.wakeLockOwnerID)
            session.sync(with: store.channels)
            let first = isSpotlight ? spotlightTileID : session.tiles.first?.id
            makeAudible(first)
            DispatchQueue.main.async { focusedSlot = first ?? Self.addSlotID }
            revealChrome()
        }
        .onDisappear {
            chromeHideTask?.cancel()
            session.stopAll()
            PlaybackWakeLock.release(ownerID: session.wakeLockOwnerID)
        }
        .onChange(of: store.channels) { _, channels in
            session.sync(with: channels)
            if let expandedID, !channels.contains(where: { $0.id == expandedID }) {
                self.expandedID = nil
            }
            if let audibleID, !channels.contains(where: { $0.id == audibleID }) {
                let next = isSpotlight ? spotlightTileID : channels.first?.id
                makeAudible(next)
                DispatchQueue.main.async { focusedSlot = next ?? Self.addSlotID }
            }
        }
        .onChange(of: focusedSlot) { _, slot in
            revealChrome()
            // Grid: sound follows focus. Spotlight: sound stays with the big
            // tile while you glance around. The add slot never takes sound.
            guard !isSpotlight, let slot, slot != Self.addSlotID else { return }
            makeAudible(slot)
        }
        .onPlayPauseCommand {
            revealChrome()
            guard expandedID == nil, !session.tiles.isEmpty else { return }
            toggleLayout()
        }
        .onExitCommand {
            revealChrome()
            if let expandedID {
                // Whatever you were watching full screen becomes the main game.
                if isSpotlight { store.spotlightID = expandedID }
                self.expandedID = nil
                DispatchQueue.main.async { focusedSlot = expandedID }
            } else {
                store.dismiss()
            }
        }
    }

    // MARK: - Tiles

    private func tileButton(_ tile: MultiviewTile, isExpanded: Bool, isCompact: Bool) -> some View {
        let isMain = isSpotlight && tile.id == spotlightTileID
        return Button {
            revealChrome()
            if case .failed = tile.status {
                tile.retry()
            } else if isExpanded {
                return
            } else if isSpotlight && !isMain {
                promote(tile.id)
            } else {
                expandedID = tile.id
                makeAudible(tile.id)
            }
        } label: {
            MultiviewTileView(
                tile: tile,
                isFocused: focusedSlot == tile.id && !isExpanded,
                isExpanded: isExpanded,
                isCompact: isCompact,
                showsChrome: showsChrome
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedSlot, equals: tile.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            // Fires on every press, including toward an edge with nothing
            // there, so the labels come back even when focus can't move.
            revealChrome()
            guard isExpanded else { return }
            cycleExpanded(direction)
        }
        .contextMenu {
            if !isExpanded {
                if isSpotlight && !isMain {
                    Button {
                        promote(tile.id)
                    } label: {
                        Label(L10n.string("multiview_make_main", fallback: "Make Main Game"), systemImage: "star")
                    }
                }
                Button {
                    expandedID = tile.id
                    makeAudible(tile.id)
                } label: {
                    Label(L10n.string("multiview_full_screen", fallback: "Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    toggleLayout()
                } label: {
                    if isSpotlight {
                        Label(L10n.string("multiview_grid_view", fallback: "Grid View"), systemImage: "square.grid.2x2")
                    } else {
                        Label(L10n.string("multiview_spotlight_view", fallback: "Spotlight View"), systemImage: "rectangle.leadinghalf.inset.filled")
                    }
                }
            }
            Button(role: .destructive) {
                store.remove(id: tile.id)
            } label: {
                Label(L10n.string("multiview_remove", fallback: "Remove from Multiview"), systemImage: "minus.circle")
            }
        }
    }

    private func addSlot(isCompact: Bool) -> some View {
        Button {
            store.dismiss()
        } label: {
            MultiviewAddSlotView(isFocused: focusedSlot == Self.addSlotID, isCompact: isCompact)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedSlot, equals: Self.addSlotID)
        .focusEffectDisabledIfAvailable()
        .contextMenu {
            Button(role: .destructive) {
                store.clear()
            } label: {
                Label(L10n.string("multiview_clear", fallback: "Clear Multiview"), systemImage: "trash")
            }
        }
    }

    /// A small reminder of what Play/Pause does; fades with the tile labels.
    private var layoutHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "playpause.fill")
            Text(isSpotlight
                 ? L10n.string("multiview_hint_grid", fallback: "Grid view")
                 : L10n.string("multiview_hint_spotlight", fallback: "Spotlight view"))
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    // MARK: - Actions

    private func revealChrome() {
        if !showsChrome {
            withAnimation(.easeOut(duration: 0.2)) { showsChrome = true }
        }
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.chromeIdleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { showsChrome = false }
        }
    }

    private func toggleLayout() {
        if isSpotlight {
            // Back to the grid; sound and focus stay on the main game.
            store.layout = .grid
            let main = audibleID
            DispatchQueue.main.async { focusedSlot = main ?? session.tiles.first?.id }
        } else {
            // The game you're listening to becomes the main one.
            store.spotlightID = audibleID ?? session.tiles.first?.id
            store.layout = .spotlight
            let main = spotlightTileID
            makeAudible(main)
            DispatchQueue.main.async { focusedSlot = main }
        }
    }

    /// Swaps a small tile into the spotlight. Only the sizes change, so no
    /// tile reloads; sound moves with the new main game.
    private func promote(_ id: String) {
        store.spotlightID = id
        makeAudible(id)
        DispatchQueue.main.async { focusedSlot = id }
    }

    private func makeAudible(_ id: String?) {
        audibleID = id
        session.setAudible(id: id)
    }

    /// Left / Right while a tile is full screen flips to the neighbouring tile.
    private func cycleExpanded(_ direction: MoveCommandDirection) {
        guard let expandedID,
              let index = session.tiles.firstIndex(where: { $0.id == expandedID }),
              session.tiles.count > 1 else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        default: return
        }
        let count = session.tiles.count
        let next = session.tiles[(index + step + count) % count].id
        self.expandedID = next
        makeAudible(next)
        DispatchQueue.main.async { focusedSlot = next }
    }

    // MARK: - Layout

    private struct LayoutFrames {
        var tiles: [String: CGRect] = [:]
        var addSlot: CGRect?
    }

    private func computeLayout(in size: CGSize) -> LayoutFrames {
        let hasAddSlot = session.tiles.count < MultiviewStore.maxTiles
        if isSpotlight, let mainID = spotlightTileID {
            let others = session.tiles.map(\.id).filter { $0 != mainID }
            return spotlightFrames(in: size, mainID: mainID, others: others, hasAddSlot: hasAddSlot)
        }
        let ids = session.tiles.map(\.id)
        let slots = gridSlots(in: size, count: min(ids.count + (hasAddSlot ? 1 : 0), MultiviewStore.maxTiles))
        var frames = LayoutFrames()
        for (index, id) in ids.enumerated() where index < slots.count {
            frames.tiles[id] = slots[index]
        }
        if hasAddSlot, slots.count > ids.count {
            frames.addSlot = slots.last
        }
        return frames
    }

    /// One large 16:9 tile on the left; up to three small ones stacked on the
    /// right, sized so the stack of three is exactly as tall as the big tile.
    private func spotlightFrames(in size: CGSize, mainID: String, others: [String], hasAddSlot: Bool) -> LayoutFrames {
        let gap: CGFloat = 28
        let columnSlots: CGFloat = 3
        // Solve bigWidth + smallWidth + 3 gaps == width, with
        // 3 * smallHeight + 2 gaps == bigHeight, all 16:9.
        var bigWidth = (size.width - 3 * gap + (columnSlots - 1) * gap * 16 / 9 / columnSlots)
            / (1 + 1 / columnSlots)
        var bigHeight = bigWidth * 9 / 16
        if bigHeight > size.height - 2 * gap {
            bigHeight = size.height - 2 * gap
            bigWidth = bigHeight * 16 / 9
        }
        let smallHeight = (bigHeight - (columnSlots - 1) * gap) / columnSlots
        let smallWidth = smallHeight * 16 / 9
        let totalWidth = bigWidth + gap + smallWidth
        let originX = (size.width - totalWidth) / 2
        let originY = (size.height - bigHeight) / 2

        var frames = LayoutFrames()
        frames.tiles[mainID] = CGRect(x: originX, y: originY, width: bigWidth, height: bigHeight)
        let columnX = originX + bigWidth + gap
        func slot(_ index: Int) -> CGRect {
            CGRect(
                x: columnX,
                y: originY + CGFloat(index) * (smallHeight + gap),
                width: smallWidth,
                height: smallHeight
            )
        }
        for (index, id) in others.enumerated() {
            frames.tiles[id] = slot(index)
        }
        if hasAddSlot, others.count < Int(columnSlots) {
            frames.addSlot = slot(others.count)
        }
        return frames
    }

    /// Even grid: two side by side, or 2x2 for three or four slots.
    private func gridSlots(in size: CGSize, count slots: Int) -> [CGRect] {
        let gap: CGFloat = 28
        let aspect: CGFloat = 16.0 / 9.0

        if slots <= 1 {
            return [CGRect(origin: .zero, size: size)]
        }

        let columns = 2
        let rows = slots <= 2 ? 1 : 2
        let availableWidth = size.width - gap * CGFloat(columns + 1)
        let availableHeight = size.height - gap * CGFloat(rows + 1)
        var tileWidth = availableWidth / CGFloat(columns)
        var tileHeight = tileWidth / aspect
        if tileHeight * CGFloat(rows) > availableHeight {
            tileHeight = availableHeight / CGFloat(rows)
            tileWidth = tileHeight * aspect
        }
        let gridWidth = tileWidth * CGFloat(columns) + gap * CGFloat(columns - 1)
        let gridHeight = tileHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
        let originX = (size.width - gridWidth) / 2
        let originY = (size.height - gridHeight) / 2

        return (0..<slots).map { slot in
            let column = slot % columns
            let row = slot / columns
            return CGRect(
                x: originX + CGFloat(column) * (tileWidth + gap),
                y: originY + CGFloat(row) * (tileHeight + gap),
                width: tileWidth,
                height: tileHeight
            )
        }
    }
}

private struct MultiviewTileView: View {
    @ObservedObject var tile: MultiviewTile
    let isFocused: Bool
    let isExpanded: Bool
    var isCompact: Bool = false
    let showsChrome: Bool

    var body: some View {
        let corner: CGFloat = isExpanded ? 0 : 18
        // Idle: no title bar, no lift, and only a hairline marking the focused
        // tile so it can't hide on-screen graphics.
        let ringWidth: CGFloat = isFocused ? (showsChrome ? 6 : 2) : 0
        ZStack {
            Color.black

            if let engine = tile.engine {
                MultiviewEngineSurface(engine: engine)
            }

            statusOverlay

            if showsChrome {
                VStack {
                    Spacer()
                    label
                }
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(showsChrome ? 1 : 0.55), lineWidth: ringWidth)
        }
        .scaleEffect(isFocused && showsChrome ? 1.03 : 1)
        .shadow(color: .black.opacity(isFocused && showsChrome ? 0.6 : 0), radius: 24, y: 10)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.4), value: showsChrome)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch tile.status {
        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
        case .playing:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: isCompact ? 28 : 40))
                Text(message)
                    .font(.system(size: isCompact ? 17 : 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(isCompact ? 2 : 3)
                Text(L10n.string("multiview_select_to_retry", fallback: "Press Select to retry"))
                    .font(.system(size: isCompact ? 16 : 20))
                    .foregroundColor(.white.opacity(0.7))
            }
            .foregroundColor(.white)
            .padding(isCompact ? 12 : 24)
        }
    }

    private var label: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Image(systemName: tile.isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: isCompact ? 16 : 22, weight: .semibold))
                .foregroundColor(tile.isAudible ? .white : .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.channel.title)
                    .font(.system(size: isCompact ? 18 : 26, weight: .semibold))
                    .lineLimit(1)
                if !isCompact, let subtitle = tile.channel.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(.horizontal, isCompact ? 12 : 22)
        .padding(.vertical, isCompact ? 8 : 16)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct MultiviewAddSlotView: View {
    let isFocused: Bool
    var isCompact: Bool = false

    var body: some View {
        VStack(spacing: isCompact ? 8 : 16) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: isCompact ? 32 : 54, weight: .regular))
            Text(L10n.string("multiview_add_title", fallback: "Add a Channel"))
                .font(.system(size: isCompact ? 20 : 30, weight: .semibold))
            if !isCompact {
                Text(L10n.string(
                "multiview_add_hint",
                fallback: "Open another live channel, then choose Multiview in the player controls."
            ))
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.18 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(isFocused ? 1 : 0.25), style: StrokeStyle(lineWidth: isFocused ? 6 : 2, dash: isFocused ? [] : [10, 8]))
        )
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Binds a tile's engine to its own layer host. (The app's `AetherPlayerSurface`
/// wraps the full-screen controller and shadows the engine's view of that name.)
private struct MultiviewEngineSurface: UIViewRepresentable {
    let engine: AetherEngine

    func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    func updateUIView(_ uiView: AetherPlayerView, context: Context) {}
}
