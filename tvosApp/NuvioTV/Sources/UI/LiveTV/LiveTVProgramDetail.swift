import SwiftUI

/// A future show picked in the guide.
struct LiveProgramDetail: Identifiable {
    let channel: LiveTVChannel
    let program: LiveTVProgram
    let lineup: [LiveTVChannel]
    var id: String { channel.id + "|" + program.id }
}

/// Details for a show that hasn't started: Remind Me, watch the channel
/// now, and other airings of the same show (each can be reminded too).
/// Back closes it.
struct LiveProgramDetailCard: View {
    let detail: LiveProgramDetail
    let onClose: () -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @ObservedObject private var reminders = LiveReminders.shared
    @FocusState private var focus: String?
    @State private var airings: [(channel: LiveTVChannel, program: LiveTVProgram)] = []

    private var program: LiveTVProgram { detail.program }
    private var channel: LiveTVChannel { detail.channel }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    ChannelLogoView(urls: store.logoSpec(for: channel).urls, width: 150, height: 60) {
                        Text(channel.displayName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text(L10n.string("live_badge_later", fallback: "LATER"))
                        .font(.system(size: 16, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.7), lineWidth: 2))
                }
                Text(program.title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(summaryLine)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if let overview = program.overview {
                    Text(overview)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(3)
                }
                HStack(spacing: 16) {
                    let reminded = reminders.isSet(channelID: channel.id, start: program.start)
                    pill(reminded ? L10n.string("live_reminder_set", fallback: "Reminder Set")
                                  : L10n.string("live_remind_me", fallback: "Remind Me"),
                         symbol: reminded ? "bell.fill" : "bell", id: "remind") {
                        reminders.toggle(channel: channel, program: program)
                    }
                    pill(L10n.format("live_watch_now", fallback: "Watch %@ Now", channel.name), symbol: "play.fill", id: "watch") {
                        onClose()
                        store.watch(channel, lineup: detail.lineup)
                    }
                }
                .padding(.top, 8)
                if !airings.isEmpty {
                    LiveSectionLabel(text: L10n.string("live_other_airings", fallback: "Other airings"))
                        .padding(.top, 14)
                    VStack(spacing: 6) {
                        ForEach(Array(airings.enumerated()), id: \.offset) { _, airing in
                            LivePanelRow(
                                title: airing.channel.name,
                                detail: dayAndTime(airing.program),
                                accessory: .check(reminders.isSet(channelID: airing.channel.id, start: airing.program.start))
                            ) {
                                reminders.toggle(channel: airing.channel, program: airing.program)
                            }
                        }
                    }
                }
                Text(L10n.string("live_reminder_hint", fallback: "A reminder shows over whatever you're watching when the show starts, with one click to switch."))
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 6)
            }
            .padding(44)
            .frame(width: 1100, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.black.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 12)
            )
            .focusSection()
        }
        .onExitCommand { onClose() }
        .onAppear {
            airings = store.otherAirings(of: program).filter { !($0.channel.id == channel.id && $0.program.start == program.start) }
            DispatchQueue.main.async { focus = "remind" }
        }
    }

    private var summaryLine: String {
        var parts = [channel.name, dayAndTime(program)]
        if program.isSports { parts.append(L10n.string("live_genre_sports_short", fallback: "Sports")) }
        else if program.isMovie { parts.append(L10n.string("live_genre_movie_short", fallback: "Movie")) }
        else if program.isNews { parts.append(L10n.string("live_genre_news_short", fallback: "News")) }
        if program.isLive { parts.append(L10n.string("live_badge_live_word", fallback: "Live")) }
        return parts.joined(separator: "  ·  ")
    }

    private func dayAndTime(_ program: LiveTVProgram) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(program.start) {
            day = calendar.component(.hour, from: program.start) >= 17
                ? L10n.string("live_time_tonight", fallback: "Tonight")
                : L10n.string("live_time_today", fallback: "Today")
        } else if calendar.isDateInTomorrow(program.start) {
            day = L10n.string("live_time_tomorrow", fallback: "Tomorrow")
        } else {
            day = Self.weekday.string(from: program.start)
        }
        let f = ChannelsView.clockFormatter
        return "\(day) \(f.string(from: program.start))–\(f.string(from: program.end))"
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private func pill(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        let focused = focus == id
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
            }
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 30)
            .frame(height: 70)
            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focus, equals: id)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
