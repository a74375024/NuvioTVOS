import Foundation

/// Launch hook for the automated screenshot tour (CI simulator only).
/// `-NuvioScreenTour channels | live | live-demo… | calendar | library | search | settings | home | details:<id>:<type>`
/// skips sign-in as a guest and opens that screen. Without the launch
/// argument this does nothing.
enum ScreenTour {
    static let requested: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-NuvioScreenTour"), index + 1 < args.count else { return nil }
        let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }()

    static var isActive: Bool { requested != nil }

    /// Live TV against the local mock Xtream provider the CI job runs
    /// (scripts/mock-xtream.py): the real load path, not demo data.
    static var isMockLiveTV: Bool { requested == "live-mock" }

    enum Destination {
        case tab(TVTab)
        case details(id: String, type: String)
    }

    static var destination: Destination? {
        guard let requested else { return nil }
        let parts = requested.split(separator: ":").map(String.init)
        switch parts.first?.lowercased() {
        case "channels": return .tab(.channels)
        case "calendar": return .tab(.calendar)
        case "live", "live-demo", "live-demo-search", "live-demo-groups", "live-demo-sources", "live-demo-outside", "live-demo-events", "live-demo-all", "live-demo-setup", "live-demo-provider", "live-demo-preview", "live-demo-genres", "live-mock": return .tab(.live)
        case "library": return .tab(.library)
        case "search": return .tab(.search)
        case "settings": return .tab(.settings)
        case "home": return .tab(.home)
        case "details" where parts.count >= 3: return .details(id: parts[1], type: parts[2])
        default: return nil
        }
    }
}
