import Foundation

/// Read-only diagnostics for the Dolby Vision Profile 5 native HLS route. These values describe
/// source metadata, the selected route, and the delivered init segment; they do not measure pixels
/// or the HDMI output.
enum DolbyVisionColorDiagnostics {

    static func sourceColorFields(_ format: VideoStreamFormat?) -> String {
        "sourcePrimaries=\(format?.colorPrimaries ?? "unknown") "
            + "sourceTransfer=\(format?.transfer ?? "unknown") "
            + "sourceMatrix=\(format?.matrix ?? "unknown") "
            + "sourceRange=\(format?.range ?? "unknown")"
    }

    static func sourceFormatFields(_ format: VideoStreamFormat?) -> String {
        sourceColorFields(format)
            + " sourcePixelFormat=\(format?.pixelFormat ?? "unknown")"
            + " sourceBitDepth=\(format?.bitDepth.map { String($0) } ?? "unknown")"
    }

    /// Returns fields only for a Dolby Vision sample entry or an entry carrying a DV config box.
    /// Parsing follows moov/trak/mdia/minf/stbl/stsd and then the visual sample-entry children; it
    /// never searches arbitrary init bytes for box names.
    static func initLogFields(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty,
              let topLevel = boxes(in: bytes, start: 0, end: bytes.count),
              let moov = topLevel.first(where: { $0.type == "moov" }),
              let moovChildren = boxes(in: bytes, start: moov.payloadStart, end: moov.end)
        else { return nil }

        for trak in moovChildren where trak.type == "trak" {
            guard let trakChildren = boxes(in: bytes, start: trak.payloadStart, end: trak.end),
                  let mdia = trakChildren.first(where: { $0.type == "mdia" }),
                  let mdiaChildren = boxes(in: bytes, start: mdia.payloadStart, end: mdia.end),
                  let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
                  let handler = fourCC(in: bytes, at: hdlr.payloadStart + 8, end: hdlr.end),
                  handler == "vide",
                  let minf = mdiaChildren.first(where: { $0.type == "minf" }),
                  let minfChildren = boxes(in: bytes, start: minf.payloadStart, end: minf.end),
                  let stbl = minfChildren.first(where: { $0.type == "stbl" }),
                  let stblChildren = boxes(in: bytes, start: stbl.payloadStart, end: stbl.end),
                  let stsd = stblChildren.first(where: { $0.type == "stsd" }),
                  stsd.payloadStart + 8 <= stsd.end,
                  let entryCount = uint32(in: bytes, at: stsd.payloadStart + 4, end: stsd.end)
            else { continue }

            var cursor = stsd.payloadStart + 8 // full-box version/flags + entry_count
            var entries: [Box] = []
            for _ in 0..<entryCount {
                guard let entry = box(in: bytes, at: cursor, end: stsd.end) else { break }
                entries.append(entry)
                cursor = entry.end
            }

            for entry in entries {
                let entryTypeIsDV = ["dvh1", "dvhe", "dva1", "dvav"].contains(entry.type)
                // A visual sample entry has 78 bytes of fixed payload before child atoms.
                // Keep a known DV entry reportable even when that fixed payload is truncated.
                let childBoxes: [Box]?
                if entry.payloadStart + 78 <= entry.end {
                    childBoxes = boxes(in: bytes, start: entry.payloadStart + 78, end: entry.end)
                } else {
                    childBoxes = nil
                }
                let dvcC = childBoxes?.first(where: { $0.type == "dvcC" })
                let dvvC = childBoxes?.first(where: { $0.type == "dvvC" })
                guard entryTypeIsDV || dvcC != nil || dvvC != nil else { continue }

                let color = childBoxes.map {
                    colorFields(in: bytes, children: $0)
                } ?? (entryTypeIsDV ? "malformed" : "absent")
                let dvcFields = dvcC.map { configurationFields(in: bytes, box: $0) }
                    ?? (childBoxes == nil ? "malformed" : "absent")
                let dvvFields = dvvC.map { configurationFields(in: bytes, box: $0) }
                    ?? (childBoxes == nil ? "malformed" : "absent")
                return "sampleEntry=\(entry.type) colr=\(color) dvcC=\(dvcFields) dvvC=\(dvvFields)"
            }
        }
        return nil
    }

    private struct Box {
        let type: String
        let payloadStart: Int
        let end: Int
    }

    /// Parses one ISO BMFF box. Extended-size boxes and size-to-parent-end boxes are supported.
    /// All arithmetic is checked against the containing range before indexing.
    private static func box(in bytes: [UInt8], at offset: Int, end: Int) -> Box? {
        guard offset >= 0, end >= offset, end <= bytes.count, end - offset >= 8,
              let size32 = uint32(in: bytes, at: offset, end: end),
              let type = fourCC(in: bytes, at: offset + 4, end: end)
        else { return nil }

        let headerSize: Int
        let boxSize: Int
        if size32 == 1 {
            guard end - offset >= 16,
                  let size64 = uint64(in: bytes, at: offset + 8, end: end),
                  size64 <= UInt64(Int.max)
            else { return nil }
            headerSize = 16
            boxSize = Int(size64)
        } else if size32 == 0 {
            headerSize = 8
            boxSize = end - offset
        } else {
            headerSize = 8
            boxSize = Int(size32)
        }

        guard boxSize >= headerSize, boxSize <= end - offset else { return nil }
        return Box(type: type, payloadStart: offset + headerSize, end: offset + boxSize)
    }

    private static func boxes(in bytes: [UInt8], start: Int, end: Int) -> [Box]? {
        guard start >= 0, end >= start, end <= bytes.count else { return nil }
        var result: [Box] = []
        var cursor = start
        while cursor < end {
            guard let next = box(in: bytes, at: cursor, end: end), next.end > cursor else { return nil }
            result.append(next)
            cursor = next.end
        }
        return cursor == end ? result : nil
    }

    private static func colorFields(in bytes: [UInt8], children: [Box]) -> String {
        guard let colr = children.first(where: { $0.type == "colr" }) else { return "absent" }
        guard let type = fourCC(in: bytes, at: colr.payloadStart, end: colr.end) else { return "malformed" }
        guard type == "nclx" else { return "other(\(type))" }
        let fieldsStart = colr.payloadStart + 4
        guard let primaries = uint16(in: bytes, at: fieldsStart, end: colr.end),
              let transfer = uint16(in: bytes, at: fieldsStart + 2, end: colr.end),
              let matrix = uint16(in: bytes, at: fieldsStart + 4, end: colr.end),
              fieldsStart + 7 <= colr.end
        else { return "nclx-malformed" }
        let fullRange = (bytes[fieldsStart + 6] & 0x80) != 0
        return "nclx(primaries=\(primaries),transfer=\(transfer),matrix=\(matrix),range=\(fullRange ? "full" : "limited"))"
    }

    private static func configurationFields(in bytes: [UInt8], box: Box) -> String {
        guard let p2 = byte(in: bytes, at: box.payloadStart + 2, end: box.end),
              let p3 = byte(in: bytes, at: box.payloadStart + 3, end: box.end),
              let p4 = byte(in: bytes, at: box.payloadStart + 4, end: box.end)
        else { return "malformed" }
        let profile = p2 >> 1
        let level = ((p2 & 0x01) << 5) | (p3 >> 3)
        let rpu = (p3 >> 2) & 0x01
        let enhancementLayer = (p3 >> 1) & 0x01
        let baseLayer = p3 & 0x01
        let compatibility = p4 >> 4
        return "profile=\(profile),level=\(level),rpu=\(rpu),el=\(enhancementLayer),bl=\(baseLayer),compat=\(compatibility)"
    }

    private static func byte(in bytes: [UInt8], at offset: Int, end: Int) -> UInt8? {
        guard offset >= 0, offset < end, end <= bytes.count else { return nil }
        return bytes[offset]
    }

    private static func uint16(in bytes: [UInt8], at offset: Int, end: Int) -> UInt16? {
        guard let first = byte(in: bytes, at: offset, end: end),
              let second = byte(in: bytes, at: offset + 1, end: end)
        else { return nil }
        return (UInt16(first) << 8) | UInt16(second)
    }

    private static func uint32(in bytes: [UInt8], at offset: Int, end: Int) -> UInt32? {
        guard let first = byte(in: bytes, at: offset, end: end),
              let second = byte(in: bytes, at: offset + 1, end: end),
              let third = byte(in: bytes, at: offset + 2, end: end),
              let fourth = byte(in: bytes, at: offset + 3, end: end)
        else { return nil }
        return (UInt32(first) << 24) | (UInt32(second) << 16) | (UInt32(third) << 8) | UInt32(fourth)
    }

    private static func uint64(in bytes: [UInt8], at offset: Int, end: Int) -> UInt64? {
        guard let high = uint32(in: bytes, at: offset, end: end),
              let low = uint32(in: bytes, at: offset + 4, end: end)
        else { return nil }
        return (UInt64(high) << 32) | UInt64(low)
    }

    private static func fourCC(in bytes: [UInt8], at offset: Int, end: Int) -> String? {
        guard offset >= 0, offset + 4 <= end, end <= bytes.count else { return nil }
        let value = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
        guard let value, value.utf8.count == 4 else { return nil }
        return value
    }
}
