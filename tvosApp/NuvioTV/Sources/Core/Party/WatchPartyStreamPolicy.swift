import Foundation
import Darwin

enum WatchPartyStreamError: Error, Equatable {
    case invalidURL, invalidHeaders, oversizedPayload, consentRequired, notHost, wrongMedia, unsupportedSource, unavailable
}

enum WatchPartyStreamOrigin { case directHTTP, localTorrent, serverManaged }

enum WatchPartyStreamPolicy {
    static let maximumPayloadBytes = 256 * 1_024
    private static let headerToken = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    /// Mirrors Android's HTTP/LAN support; additionally parses userinfo and numeric loopback forms.
    /// This is syntax/loopback validation, not a DNS/public-address guarantee. No request is made.
    static func isShareableURL(_ value: String) -> Bool {
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let c = URLComponents(string: value), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), c.user == nil, c.password == nil,
              let rawHost = c.host, !rawHost.isEmpty, c.url != nil,
              c.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost") else { return false }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            if bytes.first == 127 || bytes.allSatisfy({ $0 == 0 }) { return false }
        }
        // A scoped IPv6 host keeps its address before the zone identifier.
        let address = String(host.split(separator: "%", maxSplits: 1).first ?? "")
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) || (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1) { return false }
            let mapped = bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255
            if mapped && (bytes[12] == 127 || bytes.suffix(4).allSatisfy({ $0 == 0 })) { return false }
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) && bytes[12] == 127 { return false }
        }
        return true
    }

    static func validate(_ value: WatchPartyStream) throws {
        guard isShareableURL(value.url) else { throw WatchPartyStreamError.invalidURL }
        guard validHeaders(value.headers), validHeaders(value.responseHeaders) else { throw WatchPartyStreamError.invalidHeaders }
        guard try JSONEncoder().encode(value).count <= maximumPayloadBytes else { throw WatchPartyStreamError.oversizedPayload }
    }

    private static func validHeaders(_ headers: [String: String]) -> Bool {
        var names: Set<String> = []
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy({ headerToken.contains($0) }),
                  names.insert(name.lowercased()).inserted,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else { return false }
        }
        return true
    }
}
