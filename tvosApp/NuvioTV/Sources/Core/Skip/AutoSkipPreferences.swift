import Foundation

/// Auto-skip choices for intros (recaps included) and endings. Each show
/// remembers its own choice; shows without one use the defaults from
/// Settings → Playback. Stored in the active profile's settings, on this
/// device only.
enum AutoSkipPreferences {
    static let defaultIntroKey = "nuvio.tv.settings.playback.autoSkipIntroDefault"
    static let defaultEndingKey = "nuvio.tv.settings.playback.autoSkipEndingDefault"
    private static let perShowKey = "nuvio.tv.playback.autoSkipByShow"
    private static let maxShows = 1000

    private struct ShowChoice: Codable, Equatable {
        var intro: Bool?
        var ending: Bool?
        var updatedAt: Date
    }

    static func skipsIntro(showID: String) -> Bool {
        choice(for: showID)?.intro ?? ProfileSettings.current.bool(forKey: defaultIntroKey)
    }

    static func skipsEnding(showID: String) -> Bool {
        choice(for: showID)?.ending ?? ProfileSettings.current.bool(forKey: defaultEndingKey)
    }

    static func setSkipsIntro(_ value: Bool, showID: String) {
        update(showID: showID) { $0.intro = value }
    }

    static func setSkipsEnding(_ value: Bool, showID: String) {
        update(showID: showID) { $0.ending = value }
    }

    // MARK: - Storage

    private static func normalized(_ showID: String) -> String {
        showID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func load() -> [String: ShowChoice] {
        guard let data = ProfileSettings.current.data(forKey: perShowKey),
              let decoded = try? JSONDecoder().decode([String: ShowChoice].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ choices: [String: ShowChoice]) {
        var trimmed = choices
        if trimmed.count > maxShows {
            let oldest = trimmed.sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(trimmed.count - maxShows)
                .map(\.key)
            oldest.forEach { trimmed.removeValue(forKey: $0) }
        }
        if let data = try? JSONEncoder().encode(trimmed) {
            ProfileSettings.current.set(data, forKey: perShowKey)
        }
    }

    private static func choice(for showID: String) -> ShowChoice? {
        load()[normalized(showID)]
    }

    private static func update(showID: String, _ change: (inout ShowChoice) -> Void) {
        let key = normalized(showID)
        guard !key.isEmpty else { return }
        var choices = load()
        var choice = choices[key] ?? ShowChoice(intro: nil, ending: nil, updatedAt: Date())
        change(&choice)
        choice.updatedAt = Date()
        choices[key] = choice
        save(choices)
    }
}
