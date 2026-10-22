import Foundation
import Security

/// One Xtream Codes account (Settings → Integrations → Xtream). The password
/// lives in Keychain (`XtreamCredentialStore`), never in this config.
struct XtreamAccount: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    /// e.g. "http://provider.example:8080" — scheme and port included.
    var serverURLString: String
    var username: String
    var expires: Date?
    var maxConnections: Int?
    var lastChannelCount: Int?

    var serverURL: URL? {
        var text = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        return URL(string: text)
    }

    /// Live TV channels from this account use this as their server id.
    var sourceID: String { "xt:\(id)" }
}

/// Xtream accounts for the active profile.
@MainActor
final class XtreamStore: ObservableObject {
    static let shared = XtreamStore()
    private static let key = "nuvio.tv.settings.integrations.xtreamAccounts"

    @Published private(set) var accounts: [XtreamAccount] = []

    private init() { accounts = Self.load() }

    func reload() { accounts = Self.load() }

    func account(sourceID: String) -> XtreamAccount? {
        accounts.first { $0.sourceID == sourceID }
    }

    func upsert(_ account: XtreamAccount) {
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account } else { updated.append(account) }
        persist(updated)
    }

    func remove(_ id: String) {
        persist(accounts.filter { $0.id != id })
        XtreamCredentialStore.remove(forAccountID: id)
    }

    private func persist(_ list: [XtreamAccount]) {
        accounts = list
        guard let data = try? JSONEncoder().encode(list) else { return }
        ProfileSettings.current.set(data, forKey: Self.key)
    }

    private static func load() -> [XtreamAccount] {
        guard let data = ProfileSettings.current.data(forKey: key),
              let list = try? JSONDecoder().decode([XtreamAccount].self, from: data) else { return [] }
        return list
    }
}

/// Device-local Xtream passwords (Keychain), one per account per profile.
enum XtreamCredentialStore {
    private static let service = "com.nuvio.tv.xtream"

    static func password(forAccountID id: String, profileScope: String = ProfileSettings.activeProfileScope) -> String {
        var query = baseQuery(id, profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ password: String, forAccountID id: String, profileScope: String = ProfileSettings.activeProfileScope) {
        let data = Data(password.utf8)
        var add = baseQuery(id, profileScope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(baseQuery(id, profileScope) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func remove(forAccountID id: String, profileScope: String = ProfileSettings.activeProfileScope) {
        SecItemDelete(baseQuery(id, profileScope) as CFDictionary)
    }

    private static func baseQuery(_ id: String, _ profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(id).\(profileScope)"
        ]
    }
}

/// The parts of the Xtream Codes player API that Live TV needs: account
/// check, live categories and streams, short EPG, and stream URLs.
struct XtreamClient {
    let account: XtreamAccount
    let password: String
    var session: URLSession = .shared

    struct AccountInfo {
        let status: String
        let expires: Date?
        let maxConnections: Int?
        let activeConnections: Int?
        let formats: [String]
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Account

    func accountInfo() async throws -> AccountInfo {
        let data = try await get([:])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["user_info"] as? [String: Any] else {
            throw ClientError(message: "The server didn't answer like an Xtream provider. Check the address (including the port).")
        }
        let auth = Self.int(user["auth"]) ?? 0
        guard auth == 1 else { throw ClientError(message: "Wrong username or password.") }
        let status = (user["status"] as? String) ?? "Active"
        let expires = Self.int(user["exp_date"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        let formats = (user["allowed_output_formats"] as? [String]) ?? []
        return AccountInfo(
            status: status, expires: expires, maxConnections: Self.int(user["max_connections"]),
            activeConnections: Self.int(user["active_cons"]), formats: formats
        )
    }

    // MARK: Channels

    func channels() async throws -> [LiveTVChannel] {
        async let categoriesData = get(["action": "get_live_categories"])
        async let streamsData = get(["action": "get_live_streams"])
        var categoryNames: [String: String] = [:]
        if let list = try? JSONSerialization.jsonObject(with: try await categoriesData) as? [[String: Any]] {
            for item in list {
                if let id = Self.string(item["category_id"]), let name = item["category_name"] as? String {
                    categoryNames[id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        guard let list = try JSONSerialization.jsonObject(with: try await streamsData) as? [[String: Any]] else {
            throw ClientError(message: "The provider didn't return a channel list.")
        }
        return list.compactMap { item in
            guard let streamID = Self.string(item["stream_id"]),
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let category = Self.string(item["category_id"]).flatMap { categoryNames[$0] }
            let icon = (item["stream_icon"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            var channel = LiveTVChannel(
                id: "\(account.sourceID)|\(streamID)", serverID: account.sourceID, itemID: streamID, name: name,
                number: Self.string(item["num"]), imageURL: icon, isFavorite: false,
                tags: category.map { [$0] } ?? []
            )
            channel.epgID = (item["epg_channel_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return channel
        }
    }

    // MARK: Guide

    /// The provider's own guide for one channel (titles are base64).
    func shortEPG(streamID: String, channelID: String, limit: Int = 10) async -> [LiveTVProgram] {
        guard let data = try? await get(["action": "get_short_epg", "stream_id": streamID, "limit": String(limit)]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["epg_listings"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let start = Self.int(item["start_timestamp"]).map({ Date(timeIntervalSince1970: TimeInterval($0)) }),
                  let end = Self.int(item["stop_timestamp"]).map({ Date(timeIntervalSince1970: TimeInterval($0)) }),
                  end > start else { return nil }
            let title = Self.decode(item["title"]) ?? ""
            guard !title.isEmpty else { return nil }
            let description = Self.decode(item["description"])
            return LiveTVProgram(
                id: "\(channelID)|\(Int(start.timeIntervalSince1970))", channelID: channelID, title: title,
                episodeTitle: nil, overview: description, start: start, end: end,
                isMovie: false, isSports: false, isNews: false, isKids: false, isLive: false, isPremiere: false,
                imageURL: nil
            )
        }
    }

    // MARK: Playback

    /// Direct stream URL. HLS when the provider allows it (plays best on
    /// Apple TV), otherwise MPEG-TS.
    func streamURL(streamID: String, formats: [String] = []) -> URL? {
        guard let base = account.serverURL else { return nil }
        let ext = formats.isEmpty || formats.contains("m3u8") ? "m3u8" : "ts"
        let user = account.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account.username
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? password
        return URL(string: "\(base.absoluteString)/live/\(user)/\(pass)/\(streamID).\(ext)")
    }

    // MARK: Plumbing

    private func get(_ query: [String: String]) async throws -> Data {
        guard let base = account.serverURL,
              var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false) else {
            throw ClientError(message: "Invalid server address")
        }
        components.queryItems = [
            URLQueryItem(name: "username", value: account.username),
            URLQueryItem(name: "password", value: password)
        ] + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw ClientError(message: "Invalid server address") }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("Mozilla/5.0 (Apple TV) NuvioTV", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError(message: "No response from the provider") }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError(message: http.statusCode == 401 || http.statusCode == 403
                ? "The provider refused the sign-in (\(http.statusCode))."
                : "The provider returned an error (\(http.statusCode)).")
        }
        return data
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func decode(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
