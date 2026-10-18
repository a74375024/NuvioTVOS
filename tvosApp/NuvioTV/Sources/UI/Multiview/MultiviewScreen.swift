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

    private static let addSlotID = "multiview.add"

    var body: some View {
        GeometryReader { proxy in
            let frames = slotFrames(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                ForEach(Array(session.tiles.enumerated()), id: \.element.id) { index, tile in
                    let isExpanded = expandedID == tile.id
                    let isHidden = expandedID != nil && !isExpanded
                    let frame = isExpanded
                        ? CGRect(origin: .zero, size: proxy.size)
                        : (index < frames.count ? frames[index] : .zero)
                    tileButton(tile, isExpanded: isExpanded)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(isHidden ? 0 : 1)
                        .disabled(isHidden)
                        .zIndex(isExpanded ? 2 : 1)
                }

                if expandedID == nil, session.tiles.count < MultiviewStore.maxTiles,
                   let frame = frames.last, frames.count > session.tiles.count {
                    addSlot
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: expandedID)
            .animation(.easeInOut(duration: 0.25), value: session.tiles.map(\.id))
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            PlaybackWakeLock.acquire(ownerID: session.wakeLockOwnerID)
            session.sync(with: store.channels)
            let first = session.tiles.first?.id
            audibleID = first
            session.setAudible(id: first)
            DispatchQueue.main.async { focusedSlot = first ?? Self.addSlotID }
        }
        .onDisappear {
            session.stopAll()
            PlaybackWakeLock.release(ownerID: session.wakeLockOwnerID)
        }
        .onChange(of: store.channels) { _, channels in
            session.sync(with: channels)
            if let expandedID, !channels.contains(where: { $0.id == expandedID }) {
                self.expandedID = nil
            }
            if let audibleID, !channels.contains(where: { $0.id == audibleID }) {
                makeAudible(channels.first?.id)
                DispatchQueue.main.async { focusedSlot = channels.first?.id ?? Self.addSlotID }
            }
        }
        .onChange(of: focusedSlot) { _, slot in
            // Sound follows focus; the add slot keeps whatever was playing.
            guard let slot, slot != Self.addSlotID else { return }
            makeAudible(slot)
        }
        .onExitCommand {
            if let expandedID {
                self.expandedID = nil
                DispatchQueue.main.async { focusedSlot = expandedID }
            } else {
                store.dismiss()
            }
        }
    }

    // MARK: - Tiles

    private func tileButton(_ tile: MultiviewTile, isExpanded: Bool) -> some View {
        Button {
            if case .failed = tile.status {
                tile.retry()
            } else if !isExpanded {
                expandedID = tile.id
                makeAudible(tile.id)
            }
        } label: {
            MultiviewTileView(
                tile: tile,
                isFocused: focusedSlot == tile.id && !isExpanded,
                isExpanded: isExpanded
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedSlot, equals: tile.id)
        .focusEffectDisabledIfAvailable()
        .onMoveCommand { direction in
            guard isExpanded else { return }
            cycleExpanded(direction)
        }
        .contextMenu {
            if !isExpanded {
                Button {
                    expandedID = tile.id
                    makeAudible(tile.id)
                } label: {
                    Label(L10n.string("multiview_full_screen", fallback: "Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            Button(role: .destructive) {
                store.remove(id: tile.id)
            } label: {
                Label(L10n.string("multiview_remove", fallback: "Remove from Multiview"), systemImage: "minus.circle")
            }
        }
    }

    private var addSlot: some View {
        Button {
            store.dismiss()
        } label: {
            MultiviewAddSlotView(isFocused: focusedSlot == Self.addSlotID)
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

    /// Slots include the trailing "add" slot while there is room for a tile.
    private func slotFrames(in size: CGSize) -> [CGRect] {
        let tileCount = session.tiles.count
        let slots = min(tileCount + 1, MultiviewStore.maxTiles)
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

    var body: some View {
        let corner: CGFloat = isExpanded ? 0 : 18
        ZStack {
            Color.black

            if let engine = tile.engine {
                MultiviewEngineSurface(engine: engine)
            }

            statusOverlay

            if !isExpanded || isFocused {
                VStack {
                    Spacer()
                    label
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white, lineWidth: isFocused ? 6 : 0)
        }
        .scaleEffect(isFocused ? 1.03 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 24, y: 10)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
                    .font(.system(size: 40))
                Text(message)
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(L10n.string("multiview_select_to_retry", fallback: "Press Select to retry"))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.7))
            }
            .foregroundColor(.white)
            .padding(24)
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: tile.isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(tile.isAudible ? .white : .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.channel.title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = tile.channel.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 54, weight: .regular))
            Text(L10n.string("multiview_add_title", fallback: "Add a Channel"))
                .font(.system(size: 30, weight: .semibold))
            Text(L10n.string(
                "multiview_add_hint",
                fallback: "Open another live channel, then choose Multiview in the player controls."
            ))
            .font(.system(size: 22))
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
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
