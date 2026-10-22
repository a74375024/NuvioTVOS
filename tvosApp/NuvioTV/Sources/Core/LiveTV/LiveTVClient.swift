import Foundation

/// One Live TV channel on an Emby / Jellyfin server.
struct LiveTVChannel: Identifiable, Hashable {
    /// `serverID|itemID`, unique across servers.
    let id: String
    let serverID: String
    let itemID: String
    let name: String
    let number: String?
    let imageURL: URL?
    var isFavorite: Bool

    static func == (lhs: LiveTVChannel, rhs: LiveTVChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One guide entry. Times come straight from the server's EPG.
struct LiveTVProgram: Identifiable, Hashable {
    let id: String
    let channelID: String
    let title: String
    let episodeTitle: String?
    let overview: String?
    let start: Date
    let end: Date
    let isMovie: Bool
    let isSports: Bool
    let isNews: Bool
    let isKids: Bool
    let isLive: Bool
    let isPremiere: Bool
    let imageURL: URL?

    var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }

    func isOn(at date: Date) -> Bool { start <= date && date < end }
}

/// A stream the server opened for a channel.
struct LiveTVStream {
    let url: URL
    /// Server-side live stream to close when we're done (tuner / connection slot).
    let liveStreamID: String?
    let playSessionID: String?
}

/// The Live TV part of the Emby / Jellyfin client API. Uses the same sign-in
/// token as the Jellyfin library integration; any user with Live TV access
/// can make these calls (no admin rights needed).
struct LiveTVClient {
    let serverID: String
    let baseURL: URL
    let token: String
    let userID: String
    var session: URLSession = .shared

    private static let deviceID = "NuvioTV-AppleTV"

    struct ClientError: LocalizedError {
        let status: Int?
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Channels

    func channels() async throws -> [LiveTVChannel] {
        let data = try await request("LiveTv/Channels", query: [
            "UserId": userID,
            "EnableFavoriteSorting": "true",
            "EnableImageTypes": "Primary",
            "ImageTypeLimit": "1",
            "EnableUserData": "true",
            "Fields": "ChannelInfo"
        ])
        struct Payload: Decodable {
            struct Item: Decodable {
                struct Tags: Decodable { let Primary: String? }
                struct UserData: Decodable { let IsFavorite: Bool? }
                let Id: String
                let Name: String?
                let Number: String?
                let ChannelNumber: String?
                let ImageTags: Tags?
                let UserData: UserData?
            }
            let Items: [Item]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.Items ?? []).map { item in
            LiveTVChannel(
                id: "\(serverID)|\(item.Id)",
                serverID: serverID,
                itemID: item.Id,
                name: item.Name?.trimmingCharacters(in: .whitespacesAndNewlines).liveNonEmpty ?? "Channel",
                number: (item.Number ?? item.ChannelNumber)?.trimmingCharacters(in: .whitespaces).liveNonEmpty,
                imageURL: item.ImageTags?.Primary.flatMap { imageURL(itemID: item.Id, tag: $0) },
                isFavorite: item.UserData?.IsFavorite ?? false
            )
        }
    }

    // MARK: Guide

    /// Programs overlapping `from...to` for the given channels (item ids).
    func programs(channelItemIDs: [String], from: Date, to: Date) async throws -> [LiveTVProgram] {
        guard !channelItemIDs.isEmpty else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let data = try await request("LiveTv/Programs", query: [
            "UserId": userID,
            "ChannelIds": channelItemIDs.joined(separator: ","),
            "MinEndDate": iso.string(from: from),
            "MaxStartDate": iso.string(from: to),
            "SortBy": "StartDate",
            "EnableTotalRecordCount": "false",
            "EnableImageTypes": "Primary,Thumb",
            "ImageTypeLimit": "1",
            "Fields": "Overview"
        ])
        struct Payload: Decodable {
            struct Item: Decodable {
                struct Tags: Decodable { let Primary: String?; let Thumb: String? }
                let Id: String
                let ChannelId: String?
                let Name: String?
                let EpisodeTitle: String?
                let Overview: String?
                let StartDate: String?
                let EndDate: String?
                let IsMovie: Bool?
                let IsSports: Bool?
                let IsNews: Bool?
                let IsKids: Bool?
                let IsLive: Bool?
                let IsPremiere: Bool?
                let ImageTags: Tags?
            }
            let Items: [Item]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.Items ?? []).compactMap { item in
            guard let channel = item.ChannelId,
                  let start = Self.date(item.StartDate),
                  let end = Self.date(item.EndDate), end > start else { return nil }
            let image: URL? = {
                if let tag = item.ImageTags?.Thumb { return imageURL(itemID: item.Id, tag: tag, type: "Thumb") }
                if let tag = item.ImageTags?.Primary { return imageURL(itemID: item.Id, tag: tag) }
                return nil
            }()
            return LiveTVProgram(
                id: "\(serverID)|\(item.Id)",
                channelID: "\(serverID)|\(channel)",
                title: item.Name?.liveNonEmpty ?? "",
                episodeTitle: item.EpisodeTitle?.liveNonEmpty,
                overview: item.Overview?.liveNonEmpty,
                start: start,
                end: end,
                isMovie: item.IsMovie ?? false,
                isSports: item.IsSports ?? false,
                isNews: item.IsNews ?? false,
                isKids: item.IsKids ?? false,
                isLive: item.IsLive ?? false,
                isPremiere: item.IsPremiere ?? false,
                imageURL: image
            )
        }
    }

    // MARK: Playback

    /// Asks the server to open the channel and returns something the player
    /// can play. Prefers the untouched stream (no server transcoding, which a
    /// non-admin account may not be allowed), then the server's HLS.
    func openStream(channelItemID: String) async throws -> LiveTVStream {
        let body: [String: Any] = [
            "UserId": userID,
            "AutoOpenLiveStream": true,
            "IsPlayback": true,
            "MaxStreamingBitrate": 120_000_000,
            "DeviceProfile": [
                "Name": "Nuvio Apple TV",
                "MaxStreamingBitrate": 120_000_000,
                "MaxStaticBitrate": 120_000_000,
                "DirectPlayProfiles": [
                    ["Type": "Video", "Container": "ts,mpegts,m2ts,mp4,m4v,mkv,mov,hls,m3u8,flv,avi,webm"]
                ],
                "TranscodingProfiles": [
                    ["Type": "Video", "Container": "ts", "Protocol": "hls", "Context": "Streaming",
                     "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3",
                     "BreakOnNonKeyFrames": true, "MinSegments": 1]
                ],
                "ContainerProfiles": [],
                "CodecProfiles": [],
                "SubtitleProfiles": [["Format": "vtt", "Method": "Hls"]]
            ]
        ]
        let data = try await request(
            "Items/\(channelItemID)/PlaybackInfo",
            query: ["UserId": userID, "AutoOpenLiveStream": "true", "IsPlayback": "true"],
            method: "POST",
            jsonBody: body
        )
        struct Payload: Decodable {
            struct Source: Decodable {
                let Id: String?
                let LiveStreamId: String?
                let SupportsDirectStream: Bool?
                let SupportsDirectPlay: Bool?
                let TranscodingUrl: String?
                let DirectStreamUrl: String?
                let Path: String?
            }
            let MediaSources: [Source]?
            let PlaySessionId: String?
            let ErrorCode: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if let code = payload.ErrorCode {
            throw ClientError(status: nil, message: Self.describe(errorCode: code))
        }
        guard let source = payload.MediaSources?.first else {
            throw ClientError(status: nil, message: "The server didn't return a stream for this channel.")
        }
        let sessionID = payload.PlaySessionId
        if let direct = source.DirectStreamUrl?.liveNonEmpty, let url = serverURL(direct) {
            return LiveTVStream(url: url, liveStreamID: source.LiveStreamId, playSessionID: sessionID)
        }
        if source.SupportsDirectStream ?? false {
            var query = [
                "Static": "true",
                "MediaSourceId": source.Id ?? channelItemID,
                "DeviceId": Self.deviceID,
                "api_key": token
            ]
            if let live = source.LiveStreamId { query["LiveStreamId"] = live }
            if let sessionID { query["PlaySessionId"] = sessionID }
            if let url = makeURL("Videos/\(channelItemID)/stream.ts", query: query) {
                return LiveTVStream(url: url, liveStreamID: source.LiveStreamId, playSessionID: sessionID)
            }
        }
        if let transcode = source.TranscodingUrl?.liveNonEmpty, let url = serverURL(transcode) {
            return LiveTVStream(url: url, liveStreamID: source.LiveStreamId, playSessionID: sessionID)
        }
        if let path = source.Path, path.lowercased().hasPrefix("http"), let url = URL(string: path) {
            return LiveTVStream(url: url, liveStreamID: source.LiveStreamId, playSessionID: sessionID)
        }
        throw ClientError(status: nil, message: "This channel can't be streamed to this device.")
    }

    /// Frees the server's tuner / provider connection.
    func closeStream(_ stream: LiveTVStream) async {
        guard let live = stream.liveStreamID else { return }
        _ = try? await request("LiveStreams/Close", query: ["LiveStreamId": live], method: "POST", jsonBody: [:])
    }

    func setFavorite(_ favorite: Bool, itemID: String) async throws {
        _ = try await request("Users/\(userID)/FavoriteItems/\(itemID)", method: favorite ? "POST" : "DELETE")
    }

    // MARK: Plumbing

    private func imageURL(itemID: String, tag: String, type: String = "Primary") -> URL? {
        makeURL("Items/\(itemID)/Images/\(type)", query: ["tag": tag, "maxHeight": "360", "api_key": token])
    }

    private func makeURL(_ path: String, query: [String: String]) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    /// Server-relative URLs ("/videos/…") joined onto the configured base,
    /// with the token added when the server left it out.
    private func serverURL(_ relative: String) -> URL? {
        if relative.lowercased().hasPrefix("http") { return URL(string: relative) }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var path = relative.hasPrefix("/") ? relative : "/" + relative
        // Some servers include their own base path ("/emby") already.
        if let basePath = URL(string: base)?.path, !basePath.isEmpty, basePath != "/",
           path.lowercased().hasPrefix(basePath.lowercased() + "/") {
            path.removeFirst(basePath.count)
        }
        guard var components = URLComponents(string: base + path) else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name.lowercased() == "api_key" }) {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = items
        return components.url
    }

    private func request(
        _ path: String,
        query: [String: String] = [:],
        method: String = "GET",
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        guard let url = makeURL(path, query: query) else {
            throw ClientError(status: nil, message: "Invalid server address")
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        let auth = "MediaBrowser Client=\"Nuvio\", Device=\"Apple TV\", DeviceId=\"\(Self.deviceID)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError(status: nil, message: "No response from the server")
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            switch http.statusCode {
            case 401: message = "Signed out of the server. Sign in again in Settings → Jellyfin."
            case 403: message = "This account doesn't have Live TV access."
            case 404: message = "This server doesn't have Live TV."
            default: message = "The server returned an error (\(http.statusCode))."
            }
            throw ClientError(status: http.statusCode, message: message)
        }
        return data
    }

    private static func describe(errorCode: String) -> String {
        switch errorCode {
        case "NoCompatibleStream": return "The server has no stream this device can play for this channel."
        case "NotAllowed": return "This account isn't allowed to watch this channel."
        case "RateLimitExceeded": return "Too many streams are open on this account right now. Close one and try again."
        default: return "The server couldn't open this channel (\(errorCode))."
        }
    }

    /// EPG dates look like "2026-10-21T20:00:00.0000000Z"; fractional digits
    /// vary by server, so they're dropped before parsing.
    static func date(_ raw: String?) -> Date? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let dot = value.firstIndex(of: ".") {
            let tail = value[dot...].drop { $0 == "." || $0.isNumber }
            value = String(value[..<dot]) + tail
        }
        if !(value.hasSuffix("Z") || value.range(of: "[+-]\\d\\d:?\\d\\d$", options: .regularExpression) != nil) {
            value += "Z"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }
}

private extension String {
    var liveNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
