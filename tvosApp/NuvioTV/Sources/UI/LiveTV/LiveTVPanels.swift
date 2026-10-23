import SwiftUI

// MARK: - Shared look for Live TV panels
//
// One set of pieces for every Live TV surface that sits over the guide or
// the picture: the Filter and Options panels, the neighborhood rail, the
// player's mini guide. Same type scale, same white focus pill, same frosted
// panel, so the guide and the player read as one system.

enum LiveStyle {
    static let sectionFont = Font.system(size: 16, weight: .heavy)
    static let sectionTracking: CGFloat = 2.4
    static let sectionColor = Color.white.opacity(0.55)
    static let rowTitle = Font.system(size: 25, weight: .bold)
    static let rowDetail = Font.system(size: 19, weight: .medium)
    static let rowValue = Font.system(size: 19, weight: .semibold)
    static let rowRadius: CGFloat = 16
    static let panelRadius: CGFloat = 26
    static let rowHeight: CGFloat = 64
    static let watching = Color(red: 1, green: 0.32, blue: 0.32)
    /// The column (or list) without focus fades to this.
    static let inactive: Double = 0.45
}

/// "NEIGHBORHOODS", "ON NOW"… small spaced caps above a group of rows.
struct LiveSectionLabel: View {
    let text: String
    var dimmed = false

    var body: some View {
        Text(text.uppercased())
            .font(LiveStyle.sectionFont)
            .tracking(LiveStyle.sectionTracking)
            .foregroundColor(LiveStyle.sectionColor)
            .opacity(dimmed ? LiveStyle.inactive : 1)
            .lineLimit(1)
    }
}

/// White pill with black text when focused, plain otherwise. Labels use the
/// inherited foreground color (with opacity for secondary text) so they flip
/// with the pill. The caller passes focus in (from its own @FocusState),
/// the same pattern as the rest of the app's tvOS buttons.
struct LivePillButtonStyle: ButtonStyle {
    let focused: Bool
    var height: CGFloat? = LiveStyle.rowHeight
    var radius: CGFloat = LiveStyle.rowRadius
    /// Outline shown while unfocused (e.g. the neighborhood being browsed).
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(focused ? .black : .white)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(focused ? Color.white : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(outlined && !focused ? 0.35 : 0), lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// What sits at the right end of a panel row.
enum LivePanelAccessory: Equatable {
    case none
    case chevron(String?)          // optional value before the chevron
    case toggle(Bool)
    case check(Bool)
    case count(Int)
    case countChecked(Int, Bool)
}

/// One row of a Live TV panel: title, optional line under it, accessory.
struct LivePanelRow: View {
    let title: String
    var detail: String? = nil
    var accessory: LivePanelAccessory = .none
    var dot: Color? = nil
    var outlined = false
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let dot {
                    Circle().fill(dot).frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LiveStyle.rowTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let detail {
                        Text(detail)
                            .font(LiveStyle.rowDetail)
                            .opacity(0.6)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 10)
                accessoryView
            }
            .padding(.horizontal, 24)
            .padding(.vertical, detail == nil ? 0 : 12)
        }
        .buttonStyle(LivePillButtonStyle(focused: focused, outlined: outlined))
        .focused($focused)
        .focusEffectDisabledIfAvailable()
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron(let value):
            HStack(spacing: 12) {
                if let value {
                    Text(value).font(LiveStyle.rowValue).opacity(0.6).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold)).opacity(0.6)
            }
        case .toggle(let on):
            LiveToggleKnob(on: on)
        case .check(let on):
            Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).opacity(on ? 1 : 0)
        case .count(let count):
            Text("\(count)").font(LiveStyle.rowValue.monospacedDigit()).opacity(0.6)
        case .countChecked(let count, let on):
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).opacity(on ? 1 : 0)
                Text("\(count)").font(LiveStyle.rowValue.monospacedDigit()).opacity(0.6)
            }
        }
    }
}

/// An on/off switch drawn to match the panels (green when on).
struct LiveToggleKnob: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color.gray.opacity(0.45))
            Circle().fill(Color.white).padding(4)
        }
        .frame(width: 66, height: 38)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// A frosted panel along one edge of the screen, fading softly into what's
/// behind it on the open side.
struct LiveSidePanel<Content: View>: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { Spacer(minLength: 0) }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.regularMaterial)
                    .overlay(Color.black.opacity(0.55))
                    .mask(
                        LinearGradient(
                            stops: edge == .trailing
                                ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.16), .init(color: .black, location: 1)]
                                : [.init(color: .black, location: 0), .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .ignoresSafeArea()
                content()
                    .padding(edge == .trailing ? .leading : .trailing, width * 0.12)
            }
            .frame(width: width)
            if edge == .leading { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Guide tabs and icons

/// The guide's tabs. All Channels shows only when its setting is on.
enum LiveTab: Hashable {
    case lineup, favorites, recent, events, all

    var title: String {
        switch self {
        case .lineup: return L10n.string("live_view_lineup", fallback: "My Lineup")
        case .favorites: return L10n.string("live_filter_favorites", fallback: "Favorites")
        case .recent: return L10n.string("live_filter_recent", fallback: "Recent")
        case .events: return L10n.string("live_events_chip", fallback: "Live Events")
        case .all: return L10n.string("live_view_all", fallback: "All Channels")
        }
    }
}

/// Which panel is open over the guide.
enum LivePanelKind: Equatable {
    case filter, options
}

/// A tab: white pill while focused (moving across only highlights), white
/// text with an underline when it's the tab you're on.
struct LiveTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(focused ? .black : (selected ? .white : .white.opacity(0.55)))
                    .lineLimit(1)
                Capsule()
                    .fill(Color.white)
                    .frame(height: 5)
                    .opacity(selected && !focused ? 1 : 0)
            }
            .fixedSize()
            .padding(.horizontal, 22)
            .padding(.top, 9)
            .background(
                Capsule().fill(focused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A round icon button by the tabs (Search, Filter, Options). Focus is
/// bound to the guide's own state so it can put focus back on the icon
/// after a panel closes.
struct LiveIconButton: View {
    let symbol: String
    var dot = false
    let focus: FocusState<String?>.Binding
    let id: String
    let action: () -> Void

    var body: some View {
        let focused = focus.wrappedValue == id
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(focused ? .black : .white.opacity(0.9))
                .frame(width: 60, height: 60)
                .background(Circle().fill(focused ? Color.white : Color.white.opacity(0.12)))
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle().fill(LiveStyle.watching).frame(width: 13, height: 13).offset(x: -3, y: 3)
                    }
                }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// The active filter by the icons: "● Sports on now  ✕"; Select clears it.
struct LiveFilterChip: View {
    let title: String
    let onClear: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 10) {
                Circle().fill(LiveStyle.watching).frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 20)
            .frame(height: 50)
            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
