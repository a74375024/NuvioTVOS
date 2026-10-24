import Foundation
import OSLog
import AetherEngine

enum PlaybackDiagnosticSystemLogLevel: Sendable {
    case notice
    case warning
    case error
    case fault
}

struct PlaybackDiagnosticLogEntry: Identifiable, Equatable, Sendable {
    let id: UInt64
    let timestamp: Date
    let source: String
    let message: String
}

/// Recent playback diagnostics kept in memory; selected entries are also retained by unified logging.
final class PlaybackDiagnosticLogStore: @unchecked Sendable {
    static let shared = PlaybackDiagnosticLogStore()
    private static let systemLogger = Logger(subsystem: "com.pyksel.nuviotvos", category: "playback-diagnostics")

    private let lock = NSLock()
    private let maxEntries: Int
    private let maxStoredBytes: Int
    private let maxMessageBytes: Int
    private var entries: [PlaybackDiagnosticLogEntry] = []
    private var storedBytes = 0
    private var nextID: UInt64 = 1

    private static let aetherHandlerInstallation: Void = {
        EngineLog.handler = { line in
            PlaybackDiagnosticLogStore.shared.append(source: "AetherEngine", message: line)
        }
    }()
    private static let sensitiveHeaderExpression = try! NSRegularExpression(
        pattern: #"(?i)[\"']?\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|x-access-token|referer|referrer|user-agent|http[-_ ]?header[-_ ]?fields?)\b[\"']?\s*[:=]\s*[^\r\n]*"#
    )
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"']+"#
    )

    init(maxEntries: Int = 500, maxStoredBytes: Int = 256 * 1024, maxMessageBytes: Int = 4 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxStoredBytes = max(1, maxStoredBytes)
        self.maxMessageBytes = max(1, min(maxMessageBytes, maxStoredBytes))
    }

    /// Installs the engine's single host handler once, before its first load.
    static func installAetherEngineHandlerIfNeeded() {
        _ = aetherHandlerInstallation
    }

    func append(
        source: String,
        message: String,
        timestamp: Date = Date(),
        systemLogLevel: PlaybackDiagnosticSystemLogLevel? = nil
    ) {
        let safeSource = Self.truncate(source, toUTF8Bytes: 64)
        let safeMessage = Self.truncate(Self.sanitize(message), toUTF8Bytes: maxMessageBytes)
        let byteCount = safeSource.utf8.count + safeMessage.utf8.count
        guard byteCount <= maxStoredBytes else { return }

        lock.lock()

        while !entries.isEmpty,
              entries.count >= maxEntries || storedBytes + byteCount > maxStoredBytes {
            let removed = entries.removeFirst()
            storedBytes -= removed.source.utf8.count + removed.message.utf8.count
        }

        entries.append(PlaybackDiagnosticLogEntry(
            id: nextID,
            timestamp: timestamp,
            source: safeSource,
            message: safeMessage
        ))
        nextID &+= 1
        storedBytes += byteCount
        lock.unlock()

        guard let systemLogLevel else { return }
        let consoleSafeMessage = Self.truncate(Self.sanitizeURLs(safeMessage), toUTF8Bytes: maxMessageBytes)
        switch systemLogLevel {
        case .notice:
            Self.systemLogger.notice("[\(safeSource, privacy: .public)] \(consoleSafeMessage, privacy: .public)")
        case .warning:
            Self.systemLogger.warning("[\(safeSource, privacy: .public)] \(consoleSafeMessage, privacy: .public)")
        case .error:
            Self.systemLogger.error("[\(safeSource, privacy: .public)] \(consoleSafeMessage, privacy: .public)")
        case .fault:
            Self.systemLogger.fault("[\(safeSource, privacy: .public)] \(consoleSafeMessage, privacy: .public)")
        }
    }

    func snapshot() -> [PlaybackDiagnosticLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        storedBytes = 0
        lock.unlock()
    }

    private static func sanitize(_ message: String) -> String {
        let redacted = EngineLog.redacted(message)
        let range = NSRange(location: 0, length: (redacted as NSString).length)
        let sanitized = sensitiveHeaderExpression.stringByReplacingMatches(
            in: redacted,
            range: range,
            withTemplate: "$1: [redacted]"
        )

        let mutable = NSMutableString(string: sanitized)
        let urlRange = NSRange(location: 0, length: mutable.length)
        for match in urlExpression.matches(in: sanitized, range: urlRange).reversed() {
            guard let swiftRange = Range(match.range, in: sanitized) else { continue }
            var token = String(sanitized[swiftRange])
            var punctuation = ""
            while let last = token.last, ".,;:!?)]}".contains(last) {
                punctuation.insert(last, at: punctuation.startIndex)
                token.removeLast()
            }
            let replacement = safeURLLabel(token) + punctuation
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private static func sanitizeURLs(_ message: String) -> String {
        let range = NSRange(location: 0, length: (message as NSString).length)
        return urlExpression.stringByReplacingMatches(
            in: message,
            range: range,
            withTemplate: "[URL redacted]"
        )
    }

    private static func safeURLLabel(_ token: String) -> String {
        guard let components = URLComponents(string: token),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty else {
            return "[URL redacted]"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/…"
    }

    private static func truncate(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var bytes = Array(value.utf8.prefix(limit))
        while !bytes.isEmpty {
            if let completeString = String(bytes: bytes, encoding: .utf8) {
                return completeString
            }
            bytes.removeLast()
        }
        return ""
    }
}
