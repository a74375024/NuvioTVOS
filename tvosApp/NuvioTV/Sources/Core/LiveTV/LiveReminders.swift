import Foundation
import Combine

/// "Remind Me" on a future show: when it starts, a card appears in the
/// corner over whatever is on screen (the guide, the player, anywhere in the
/// app) with one click to watch. Kept on this Apple TV only; tvOS can't show
/// alerts for an app that isn't open.
struct LiveReminder: Codable, Identifiable, Equatable {
    let channelID: String
    let channelName: String
    let title: String
    let start: Date
    let end: Date

    var id: String { "\(channelID)|\(Int(start.timeIntervalSince1970))" }
}

@MainActor
final class LiveReminders: ObservableObject {
    static let shared = LiveReminders()

    @Published private(set) var items: [LiveReminder] = []
    /// The reminder whose card is showing.
    @Published private(set) var due: LiveReminder? {
        didSet { LiveOverlayState.shared.reminderShowing = due != nil }
    }

    private static let key = "nuvio.tv.livetv.reminders"
    private var timer: AnyCancellable?
    private var dismissTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LiveReminder].self, from: data) {
            items = saved.filter { $0.end > Date() }
        }
    }

    func isSet(channelID: String, start: Date) -> Bool {
        items.contains { $0.channelID == channelID && abs($0.start.timeIntervalSince(start)) < 60 }
    }

    func toggle(channel: LiveTVChannel, program: LiveTVProgram) {
        if let index = items.firstIndex(where: { $0.channelID == channel.id && abs($0.start.timeIntervalSince(program.start)) < 60 }) {
            items.remove(at: index)
        } else {
            items.append(LiveReminder(channelID: channel.id, channelName: channel.name, title: program.title,
                                      start: program.start, end: program.end))
            items.sort { $0.start < $1.start }
        }
        save()
    }

    /// Checks every 15 seconds while the app runs.
    func startChecking() {
        guard timer == nil else { return }
        check()
        timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.check()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        due = nil
    }

    private func check() {
        let now = Date()
        let before = items.count
        items.removeAll { $0.end <= now }
        guard due == nil, let index = items.firstIndex(where: { $0.start <= now.addingTimeInterval(30) }) else {
            if items.count != before { save() }
            return
        }
        due = items.remove(at: index)
        save()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.due = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
