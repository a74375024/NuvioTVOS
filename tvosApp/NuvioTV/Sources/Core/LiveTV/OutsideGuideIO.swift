import Compression
import Foundation

/// Lets the outside-guide builder step aside while video plays.
final class OutsideGuidePause: @unchecked Sendable {
    static let shared = OutsideGuidePause()
    private let lock = NSLock()
    private var reasons: Set<String> = []

    /// Pause (or resume) for a reason such as "player" or "multiview".
    func set(_ reason: String, _ paused: Bool) {
        lock.lock()
        if paused { reasons.insert(reason) } else { reasons.remove(reason) }
        lock.unlock()
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return !reasons.isEmpty
    }

    /// Blocks the (background) worker thread while playback is going on.
    func waitWhilePaused() {
        while isPaused { Thread.sleep(forTimeInterval: 0.5) }
    }
}

// MARK: - Download + gunzip

enum GuideFiles {
    static func workFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutsideGuideWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Downloads to a file (never into memory), marked as background traffic.
    static func download(_ urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.networkServiceType = .background
        request.setValue("NuvioTV/1.0 (Apple TV; personal use)", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let destination = workFolder().appendingPathComponent(UUID().uuidString + ".gz")
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// Streams a .gz file to a plain file 1 MB at a time. Plain files are
    /// passed through as they are.
    static func gunzip(_ source: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = input.readData(ofLength: 10)
        guard header.count == 10, header[0] == 0x1f, header[1] == 0x8b, header[2] == 8 else {
            return source
        }
        let flags = header[3]
        if flags & 4 != 0 {
            let lengthData = input.readData(ofLength: 2)
            if lengthData.count == 2 { _ = input.readData(ofLength: Int(lengthData[0]) | Int(lengthData[1]) << 8) }
        }
        for flag: UInt8 in [8, 16] where flags & flag != 0 {
            while let byte = input.readData(ofLength: 1).first, byte != 0 {}
        }
        if flags & 2 != 0 { _ = input.readData(ofLength: 2) }

        let destination = workFolder().appendingPathComponent(UUID().uuidString + ".xml")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let bufferSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { compression_stream_destroy(stream) }
        let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { empty.deallocate() }
        var finished = false
        while !finished {
            OutsideGuidePause.shared.waitWhilePaused()
            let chunk = input.readData(ofLength: bufferSize)
            let flags: Int32 = chunk.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(empty)
                stream.pointee.src_size = chunk.count
                repeat {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = bufferSize
                    let status = compression_stream_process(stream, flags)
                    let produced = bufferSize - stream.pointee.dst_size
                    if produced > 0 { output.write(Data(bytes: buffer, count: produced)) }
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status == COMPRESSION_STATUS_ERROR { throw CocoaError(.fileReadCorruptFile) }
                } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0
            }
            if chunk.isEmpty { finished = true }
        }
        return destination
    }
}

// MARK: - XMLTV streaming reader

/// Streams through one XMLTV file on a background thread, keeping only
/// programmes for channels that match the user's lineup.
final class XMLTVReader: NSObject, XMLParserDelegate {
    private let targets: OutsideGuide.Targets
    private let locals: Bool
    private let window: (low: Int, high: Int)

    private var channelNames: [String: [String]] = [:]
    private var currentChannel: String?
    private var keep: [String: [(id: String, how: String)]]?   // xmltv id → user channels
    private var keepNames: [String: String] = [:]
    private var found: [String: [OutsideGuide.RawProgram]] = [:]   // xmltv id → programmes

    private var programmeChannel: String?
    private var programmeStart = 0
    private var programmeEnd = 0
    private var title: String?
    private var subtitle: String?
    private var desc: String?
    private var categories: [String] = []
    private var flags = 0
    private var text = ""
    private var collecting = false
    private var counter = 0

    private init(targets: OutsideGuide.Targets, locals: Bool, window: (low: Int, high: Int)) {
        self.targets = targets
        self.locals = locals
        self.window = window
    }

    /// User channel id → its programmes from this source.
    static func read(
        source: OutsideGuide.Source,
        targets: OutsideGuide.Targets,
        window: (low: Int, high: Int)
    ) async throws -> [String: (programs: [OutsideGuide.RawProgram], note: String)] {
        let compressed = try await GuideFiles.download(source.url)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                var plain: URL?
                defer {
                    try? FileManager.default.removeItem(at: compressed)
                    if let plain, plain != compressed { try? FileManager.default.removeItem(at: plain) }
                }
                do {
                    plain = try GuideFiles.gunzip(compressed)
                    guard let plain, let stream = InputStream(url: plain) else { throw CocoaError(.fileReadUnknown) }
                    let reader = XMLTVReader(targets: targets, locals: source.locals, window: window)
                    let parser = XMLParser(stream: stream)
                    parser.delegate = reader
                    parser.shouldResolveExternalEntities = false
                    parser.parse()
                    continuation.resume(returning: reader.result())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func result() -> [String: (programs: [OutsideGuide.RawProgram], note: String)] {
        var byUser: [String: (programs: [OutsideGuide.RawProgram], note: String)] = [:]
        // A user channel matching several guide channels in one source takes
        // the one with the most listings.
        for (xmltvID, users) in keep ?? [:] {
            guard let programs = found[xmltvID], !programs.isEmpty else { continue }
            for user in users where programs.count > (byUser[user.id]?.programs.count ?? 0) {
                byUser[user.id] = (programs, "\(keepNames[xmltvID] ?? xmltvID) (\(user.how))")
            }
        }
        return byUser
    }

    // Channels come first in XMLTV; the keep list is settled at the first programme.
    private func settleKeepList() {
        guard keep == nil else { return }
        var list: [String: [(id: String, how: String)]] = [:]
        for (id, names) in channelNames {
            let matches = targets.matches(names: names, xmltvID: id, locals: locals)
            if !matches.isEmpty {
                list[id] = matches
                keepNames[id] = names.first ?? id
            }
        }
        keep = list
        channelNames = [:]
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "channel":
            currentChannel = attributes["id"]
            if let id = currentChannel { channelNames[id] = [] }
        case "display-name":
            collecting = currentChannel != nil
            text = ""
        case "programme":
            settleKeepList()
            counter += 1
            if counter % 4000 == 0 { OutsideGuidePause.shared.waitWhilePaused() }
            let id = attributes["channel"] ?? ""
            guard keep?[id] != nil,
                  let start = Self.minutes(attributes["start"]),
                  let end = Self.minutes(attributes["stop"]),
                  end > start, end > window.low, start < window.high else {
                programmeChannel = nil
                return
            }
            programmeChannel = id
            programmeStart = start
            programmeEnd = end
            title = nil; subtitle = nil; desc = nil; categories = []; flags = 0
        case "title", "sub-title", "desc", "category":
            collecting = programmeChannel != nil
            text = ""
        case "new", "premiere":
            if programmeChannel != nil { flags |= 32 }
        case "live":
            if programmeChannel != nil { flags |= 16 }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "display-name":
            if let id = currentChannel {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { channelNames[id, default: []].append(value) }
            }
        case "channel":
            currentChannel = nil
        case "title":
            if programmeChannel != nil, title == nil { title = clean(text) }
        case "sub-title":
            if programmeChannel != nil { subtitle = clean(text) }
        case "desc":
            // Descriptions only for what's on soon: they're most of the size.
            if programmeChannel != nil, programmeStart < window.low + 180 + 8 * 60, let value = clean(text) {
                desc = value.count > 200 ? String(value.prefix(199)) + "…" : value
            }
        case "category":
            if programmeChannel != nil, let value = clean(text) { categories.append(value.lowercased()) }
        case "programme":
            if let id = programmeChannel, let title {
                let joined = categories.joined(separator: " ")
                var f = flags
                if joined.contains("movie") || joined.contains("film") { f |= 1 }
                if joined.contains("sport") { f |= 2 }
                if joined.contains("news") { f |= 4 }
                if joined.contains("kids") || joined.contains("children") || joined.contains("animation") { f |= 8 }
                found[id, default: []].append(OutsideGuide.RawProgram(
                    s: programmeStart, m: max(1, programmeEnd - programmeStart),
                    t: title, st: subtitle, d: desc, f: f
                ))
            }
            programmeChannel = nil
        default:
            break
        }
        collecting = false
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        settleKeepList()
    }

    private func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "20261021200000 +0000" → minutes since 1970 (fast, no DateFormatter).
    static func minutes(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8)
        guard bytes.count >= 12 else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from..<(from + count) {
                guard i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 else { return nil }
                value = value * 10 + Int(bytes[i] - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2),
              let hour = number(8, 2), let minute = number(10, 2) else { return nil }
        // Days from civil (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        var total = days * 1440 + hour * 60 + minute
        // Offset like "+0200" / "-0500".
        if let plus = bytes.lastIndex(where: { $0 == 43 || $0 == 45 }), plus > 12, bytes.count >= plus + 5,
           let oh = number(plus + 1, 2), let om = number(plus + 3, 2) {
            let offset = oh * 60 + om
            total += bytes[plus] == 43 ? -offset : offset
        }
        return total
    }
}

// MARK: - Station directory

/// US broadcast stations (call sign → network, city, channel) from
/// Wikipedia's affiliate lists, so "NBC 5 Chicago" can be matched to WMAQ.
/// Fetched by the app about once a month.
enum StationDirectory {
    private static let networks: [(String, [String])] = [
        ("ABC", ["List of ABC television affiliates (by U.S. state)", "List of ABC television affiliates"]),
        ("CBS", ["List of CBS television affiliates (by U.S. state)", "List of CBS television affiliates"]),
        ("NBC", ["List of NBC television affiliates (by U.S. state)", "List of NBC television affiliates"]),
        ("FOX", ["List of Fox television affiliates (by U.S. state)", "List of Fox television affiliates"]),
        ("CW", ["List of The CW affiliates", "List of The CW television affiliates (by U.S. state)"]),
        ("MYNETWORKTV", ["List of MyNetworkTV affiliates (by U.S. state)", "List of MyNetworkTV affiliates"]),
        ("PBS", ["List of PBS member stations"]),
        ("TELEMUNDO", ["List of Telemundo affiliates (by U.S. state)", "List of Telemundo affiliates"]),
        ("UNIVISION", ["List of Univision affiliates", "List of Univision television affiliates"]),
        ("ION", ["List of Ion Television affiliates", "List of Ion Television affiliates (by U.S. state)"])
    ]
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OutsideGuide/stations.json")
    }

    static func load() async -> [OutsideGuide.Station] {
        var cached: [OutsideGuide.Station] = []
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([OutsideGuide.Station].self, from: data) {
            cached = saved
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < maxAge, !saved.isEmpty {
                return saved
            }
        }
        var stations: [String: OutsideGuide.Station] = [:]
        for (network, titles) in networks {
            for title in titles {
                // Space requests out; Wikipedia rate-limits bursts.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let text = await wikitext(title) else { continue }
                for station in parse(text, network: network) where stations["\(station.callsign)|\(network)"] == nil {
                    stations["\(station.callsign)|\(network)"] = station
                }
                break
            }
        }
        let list = Array(stations.values)
        guard !list.isEmpty else { return cached }
        if let url = cacheURL, let data = try? JSONEncoder().encode(list) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return list
    }

    private static func wikitext(_ title: String) async -> String? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "parse"), URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "wikitext"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "redirects", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.networkServiceType = .background
        request.setValue("NuvioTV/1.0 (Apple TV; personal use)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parse = root["parse"] as? [String: Any],
              let wikitext = parse["wikitext"] as? [String: Any] else { return nil }
        return wikitext["*"] as? String
    }

    private static let callLink = try? NSRegularExpression(
        pattern: "\\[\\[\\s*((?:[KW][A-Z]{2,3})(?:-(?:TV|DT|LD|CD|LP))?)\\s*(?:\\|[^\\]]*)?\\]\\]"
    )
    private static let anyLink = try? NSRegularExpression(pattern: "\\[\\[([^\\]|#]+)(?:\\|([^\\]]+))?\\]\\]")
    private static let channelNumber = try? NSRegularExpression(pattern: "\\b(\\d{1,2})(?:\\.\\d)?\\b")

    /// Each table row: the first call-sign link, the city linked before it
    /// (carried over from the previous row for rowspans), and the channel number.
    static func parse(_ text: String, network: String) -> [OutsideGuide.Station] {
        guard let callLink, let anyLink, let channelNumber else { return [] }
        var stations: [OutsideGuide.Station] = []
        var city = ""
        for row in text.components(separatedBy: "\n|-") {
            let ns = row as NSString
            guard let call = callLink.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { continue }
            let before = NSRange(location: 0, length: call.range.location)
            for link in anyLink.matches(in: row, range: before) {
                let target = ns.substring(with: link.range(at: 1))
                if target.contains(":") || callLink.firstMatch(in: "[[\(target)]]", range: NSRange(location: 0, length: ("[[\(target)]]" as NSString).length)) != nil {
                    continue
                }
                let label = link.range(at: 2).location != NSNotFound ? ns.substring(with: link.range(at: 2)) : target
                city = label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? label
                break
            }
            var sign = ns.substring(with: call.range(at: 1))
            if let dash = sign.firstIndex(of: "-") { sign = String(sign[..<dash]) }
            let afterStart = call.range.location + call.range.length
            let after = ns.substring(from: afterStart)
                .replacingOccurrences(of: "\\[\\[[^\\]]*\\]\\]", with: " ", options: .regularExpression)
            let afterNS = after as NSString
            let number = channelNumber.firstMatch(in: after, range: NSRange(location: 0, length: afterNS.length))
                .map { afterNS.substring(with: $0.range(at: 1)) } ?? ""
            let tokens = city.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
                .filter { $0 != "city" && $0 != "the" }
            guard !tokens.isEmpty else { continue }
            stations.append(OutsideGuide.Station(callsign: sign, network: network, cityTokens: tokens, channelNumber: number))
        }
        return stations
    }
}
