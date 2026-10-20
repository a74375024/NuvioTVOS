import Foundation

enum WatchPartySourceMatch: Equatable { case none, unique(index: Int), ambiguous(indices: [Int]) }

// Matching contract: PartySourceMatch.kt, NuvioMedia/NuvioTV (GPL-3.0), f7e2a78.
enum WatchPartySourceMatcher {
    static func matches(_ source: WatchPartySource, stream: NuvioStream) -> Bool {
        let hash = normalized(source.infoHash)?.lowercased()
        let candidateHash = normalized(stream.effectiveInfoHash)?.lowercased()
        if let hash, let candidateHash {
            return hash == candidateHash && (source.fileIndex == nil || stream.effectiveFileIdx == nil || source.fileIndex == stream.effectiveFileIdx)
        }
        guard let filename = normalized(source.filename), let candidate = normalized(stream.filename) else { return false }
        return filename.caseInsensitiveCompare(candidate) == .orderedSame
    }

    /// Keep discovery order and ambiguity. Never choose a URL by display name, size or title alone.
    static func resolve(_ source: WatchPartySource, streams: [NuvioStream]) -> WatchPartySourceMatch {
        let indices = streams.indices.filter {
            !streams[$0].isNotPlayable && streams[$0].unavailabilityReason == nil && matches(source, stream: streams[$0])
        }
        if indices.isEmpty { return .none }
        if indices.count == 1 { return .unique(index: indices[0]) }
        return .ambiguous(indices: indices)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
