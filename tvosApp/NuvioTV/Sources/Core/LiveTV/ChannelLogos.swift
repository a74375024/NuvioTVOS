import Foundation
import ImageIO
import UIKit

// MARK: - What a guide row shows for its channel

/// Which logos to try for a channel, best first, and how its cell reads.
/// National channels whose logo is curated show the logo alone; locals show
/// a logo with the call sign and "FOX 2"; anything else shows a logo (when
/// one loads) next to its name.
struct ChannelLogoSpec: Equatable {
    enum Style: Equatable {
        /// Curated logo, shown alone (name only if it fails to load).
        case logoOnly
        /// A local station: logo, call sign, network and number.
        case local(callsign: String, line: String)
        /// Logo (if any) next to the channel's name.
        case named
    }

    var urls: [URL]
    var style: Style
    var isWest = false
    /// Second line under a name with no logo ("News").
    var subtitle: String?

    static let empty = ChannelLogoSpec(urls: [], style: .named)
}

enum ChannelLogos {
    /// Logos for a guide row. `core`/`callsign`/`network` come from the
    /// catalog; `provider` is the logo the provider gave.
    static func spec(name: String, core: String?, isWest: Bool, isLocal: Bool, callsign: String?,
                     virtualNumber: Int?, provider: URL?, epgID: String?, category: LineupCategory?) -> ChannelLogoSpec {
        let base = ChannelLogoTable.base
        func url(_ file: String) -> URL? { URL(string: base + file) }
        let subtitle = category?.genreTitle

        if isLocal, let callsign {
            let network = ChannelCatalog.networkWord(name)
            var urls: [URL] = []
            // The network's own logo first (consistent and made for dark
            // backgrounds), then the station's, then the provider's.
            if let network, let file = ChannelLogoTable.networks[network], let link = url(file) { urls.append(link) }
            let stations = ChannelLogoTable.stations[callsign.lowercased()] ?? [:]
            if let file = network.flatMap({ stations[$0] }) ?? (stations.count == 1 ? stations.values.first : nil),
               let link = url(file) { urls.append(link) }
            if let provider { urls.append(provider) }
            let networkName = network.map(displayNetwork) ?? ""
            let line = [networkName, virtualNumber.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            return ChannelLogoSpec(urls: urls, style: .local(callsign: callsign.uppercased(), line: line),
                                   isWest: false, subtitle: subtitle)
        }

        if let core, let file = ChannelLogoTable.core[core], let link = url(file) {
            var urls = [link]
            if let provider { urls.append(provider) }
            return ChannelLogoSpec(urls: urls, style: .logoOnly, isWest: isWest, subtitle: subtitle)
        }

        var urls: [URL] = []
        // A local with no call sign ("FOX 5 San Diego"): its network's logo.
        if category == .local, let network = ChannelCatalog.networkWord(name),
           let file = ChannelLogoTable.networks[network], let link = url(file) { urls.append(link) }
        if let provider { urls.append(provider) }
        if let outside = IptvOrgLogos.shared.url(epgID: epgID, name: name) { urls.append(outside) }
        return ChannelLogoSpec(urls: urls, style: .named, isWest: isWest, subtitle: subtitle)
    }

    private static func displayNetwork(_ word: String) -> String {
        switch word {
        case "MYTV": return "MyNetworkTV"
        case "TELEMUNDO": return "Telemundo"
        case "UNIVISION": return "Univision"
        case "UNIMAS": return "UniMás"
        case "INDEPENDENT": return "Ind."
        default: return word
        }
    }
}

// MARK: - Loading

/// Downloads channel logos once, trims their empty edges, and notes whether
/// they're dark (dark logos get a light plate so they show on the guide's
/// near-black background). Kept in memory and in Caches/ChannelLogos.
final class ChannelLogoLoader: @unchecked Sendable {
    static let shared = ChannelLogoLoader()

    final class Logo {
        let image: UIImage
        let isDark: Bool
        init(image: UIImage, isDark: Bool) {
            self.image = image
            self.isDark = isDark
        }
    }

    private let memory = NSCache<NSURL, Logo>()
    private let lock = NSLock()
    private var failed = Set<URL>()
    private var inFlight: [URL: Task<Logo?, Never>] = [:]
    private let folder: URL
    private let session: URLSession

    private init() {
        memory.countLimit = 400
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = caches.appendingPathComponent("ChannelLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// What can be shown right now without waiting: the first logo in
    /// `urls` that is in memory, skipping ones known to fail. `nil` with
    /// `settled` true means every logo failed.
    func cached(_ urls: [URL]) -> (logo: Logo?, settled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        for url in urls {
            if let hit = memory.object(forKey: url as NSURL) { return (hit, true) }
            if !failed.contains(url) { return (nil, false) }
        }
        return (nil, true)
    }

    /// The first of `urls` that loads.
    func load(_ urls: [URL]) async -> Logo? {
        for url in urls {
            if Task.isCancelled { return nil }
            if let logo = await load(url) { return logo }
        }
        return nil
    }

    private func load(_ url: URL) async -> Logo? {
        let task: Task<Logo?, Never>
        lock.lock()
        if let hit = memory.object(forKey: url as NSURL) { lock.unlock(); return hit }
        if failed.contains(url) { lock.unlock(); return nil }
        if let running = inFlight[url] {
            task = running
        } else {
            task = Task.detached(priority: .utility) { [weak self] in
                await self?.fetch(url)
            }
            inFlight[url] = task
        }
        lock.unlock()
        let logo = await task.value
        lock.lock()
        inFlight[url] = nil
        if let logo { memory.setObject(logo, forKey: url as NSURL) } else { failed.insert(url) }
        lock.unlock()
        return logo
    }

    private func fetch(_ url: URL) async -> Logo? {
        let key = Self.hash(url.absoluteString)
        for (suffix, dark) in [("l", false), ("d", true)] {
            let file = folder.appendingPathComponent("\(key)-\(suffix).png")
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return Logo(image: image, isDark: dark)
            }
        }
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let processed = Self.process(data) else { return nil }
            if let png = processed.image.pngData() {
                let file = folder.appendingPathComponent("\(key)-\(processed.isDark ? "d" : "l").png")
                try? png.write(to: file, options: .atomic)
            }
            return processed
        } catch {
            return nil
        }
    }

    /// Scales the logo down, trims transparent edges and measures it.
    static func process(_ data: Data) -> Logo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = thumb.width, height = thumb.height
        guard width >= 16, height >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        var opaque = 0, dark = 0
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let i = row + x * 4
                let alpha = Int(pixels[i + 3])
                guard alpha > 16 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                guard alpha > 128 else { continue }
                opaque += 1
                // Un-premultiply roughly; "dark" = no bright channel.
                let brightest = max(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) * 255 / alpha
                if brightest < 80 { dark += 1 }
            }
        }
        guard maxX >= minX, maxY >= minY, opaque > 0 else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let trimmed = thumb.cropping(to: crop) else { return nil }
        let isDark = Double(dark) / Double(opaque) > 0.5
        return Logo(image: UIImage(cgImage: trimmed), isDark: isDark)
    }

    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }
}

// MARK: - iptv-org fallback

/// Logos from the public-domain iptv-org channel database, for national
/// channels with no curated logo and no provider logo. The two CSV files are
/// downloaded at most once a week; only US channels with PNG or JPEG logos
/// are kept, by guide id ("CNN.us") and by name.
final class IptvOrgLogos: @unchecked Sendable {
    static let shared = IptvOrgLogos()

    struct Saved: Codable {
        var fetched: Date
        var byID: [String: String]
        var byName: [String: String]
    }

    private let lock = NSLock()
    private var byID: [String: String] = [:]
    private var byName: [String: String] = [:]
    private var started = false
    private let file: URL
    private static let base = "https://cdn.jsdelivr.net/gh/iptv-org/database@master/data/"
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("iptv-org-logos.json")
    }

    func url(epgID: String?, name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let epgID, let hit = byID[epgID.lowercased()] { return URL(string: hit) }
        let key = ChannelCatalog.coreKey(name).key
        guard !key.isEmpty, let hit = byName[key] else { return nil }
        return URL(string: hit)
    }

    /// Loads the saved index and refreshes it when it's a week old. Calls
    /// `changed` (on the main actor) when new data is in.
    func start(changed: @escaping @MainActor () -> Void) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            var age = TimeInterval.infinity
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
                install(saved)
                age = Date().timeIntervalSince(saved.fetched)
                await changed()
            }
            guard age > Self.maxAge else { return }
            if let fresh = await download() {
                install(fresh)
                if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: file, options: .atomic) }
                await changed()
            }
        }
    }

    private func install(_ saved: Saved) {
        lock.lock()
        byID = saved.byID
        byName = saved.byName
        lock.unlock()
    }

    private func download() async -> Saved? {
        guard let channelsURL = URL(string: Self.base + "channels.csv"),
              let logosURL = URL(string: Self.base + "logos.csv") else { return nil }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        func text(_ url: URL) async -> String? {
            guard let result = try? await session.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: result.0, encoding: .utf8)
        }
        guard let channelText = await text(channelsURL), let logoText = await text(logosURL) else { return nil }
        return Self.build(channels: channelText, logos: logoText)
    }

    static func build(channels: String, logos: String) -> Saved? {
        let channelRows = CSV.rows(channels)
        let logoRows = CSV.rows(logos)
        guard let channelHead = channelRows.first, let logoHead = logoRows.first else { return nil }
        func column(_ head: [String], _ name: String) -> Int? { head.firstIndex(of: name) }
        guard let idCol = column(channelHead, "id"), let nameCol = column(channelHead, "name"),
              let countryCol = column(channelHead, "country"),
              let logoChannel = column(logoHead, "channel"), let urlCol = column(logoHead, "url") else { return nil }
        let altCol = column(channelHead, "alt_names")
        let closedCol = column(channelHead, "closed")
        let feedCol = column(logoHead, "feed")
        let formatCol = column(logoHead, "format")
        let inUseCol = column(logoHead, "in_use")

        // Best logo per channel: the channel's own (no feed) first.
        var logoOf: [String: (url: String, main: Bool)] = [:]
        for row in logoRows.dropFirst() where row.count > max(logoChannel, urlCol) {
            if let inUseCol, inUseCol < row.count, row[inUseCol].uppercased() == "FALSE" { continue }
            let url = row[urlCol]
            let format = formatCol.flatMap { $0 < row.count ? row[$0].uppercased() : nil } ?? ""
            let lower = url.lowercased()
            let isRaster = format == "PNG" || format == "JPEG" || format == "JPG"
                || ((lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")) && format.isEmpty)
            guard isRaster, lower.hasPrefix("https://") else { continue }
            let main = feedCol.map { $0 >= row.count || row[$0].isEmpty } ?? true
            let id = row[logoChannel]
            if let existing = logoOf[id], existing.main || !main { continue }
            logoOf[id] = (url, main)
        }

        var byID: [String: String] = [:]
        var byName: [String: String] = [:]
        for row in channelRows.dropFirst() where row.count > max(idCol, nameCol, countryCol) {
            guard row[countryCol] == "US" else { continue }
            if let closedCol, closedCol < row.count, !row[closedCol].isEmpty { continue }
            let id = row[idCol]
            guard let logo = logoOf[id]?.url else { continue }
            byID[id.lowercased()] = logo
            var names = [row[nameCol]]
            if let altCol, altCol < row.count, !row[altCol].isEmpty {
                names += row[altCol].split(separator: ";").map(String.init)
            }
            for name in names {
                let key = ChannelCatalog.coreKey(name).key
                if !key.isEmpty, byName[key] == nil { byName[key] = logo }
            }
        }
        guard !byID.isEmpty else { return nil }
        return Saved(fetched: Date(), byID: byID, byName: byName)
    }
}

/// A small CSV reader (quoted fields, doubled quotes, CRLF).
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let scalar = pending { pending = nil; return scalar }
            return iterator.next()
        }
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = iterator.next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            case "\r": continue
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
