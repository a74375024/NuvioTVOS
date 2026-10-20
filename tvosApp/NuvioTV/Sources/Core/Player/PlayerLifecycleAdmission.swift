import Foundation

/// Foreground intent and asynchronous engine restoration can arrive in either order.
/// A restored engine must not reopen Party admission while the application is still inactive.
struct PlayerLifecycleAdmission {
    private(set) var foreground = true
    private(set) var awaitingEngineRestore = false
    var canResume: Bool { foreground && !awaitingEngineRestore }

    mutating func suspend(engineWillPark: Bool) {
        foreground = false
        awaitingEngineRestore = awaitingEngineRestore || engineWillPark
    }

    mutating func enterForeground() { foreground = true }
    mutating func engineDidRestore() { awaitingEngineRestore = false }
}
