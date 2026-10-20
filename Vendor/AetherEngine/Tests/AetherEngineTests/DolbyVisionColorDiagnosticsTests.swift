import Foundation
import Testing
@testable import AetherEngine

struct DolbyVisionColorDiagnosticsTests {

    @Test("DV5 init diagnostics report delivered nclx and dvcC fields")
    func reportsNCLXAndDoviConfig() throws {
        let nclx = makeBox("colr", fourCC("nclx") + uint16(9) + uint16(16) + uint16(9) + Data([0x80]))
        let config = makeBox("dvcC", Data([0, 0, 10, 0x55, 0]))
        let entry = makeVisualEntry("dvh1", children: nclx + config)
        let video = makeTrack(handler: "vide", entry: entry)
        let fields = try #require(DolbyVisionColorDiagnostics.initLogFields(from: makeInit(videoTrack: video)))

        #expect(fields.contains("sampleEntry=dvh1"))
        #expect(fields.contains("colr=nclx(primaries=9,transfer=16,matrix=9,range=full)"))
        #expect(fields.contains("dvcC=profile=5,level=10,rpu=1,el=0,bl=1,compat=0"))
        #expect(fields.contains("dvvC=absent"))
    }

    @Test("DV sample entry reports an absent colr explicitly")
    func reportsMissingColorBox() throws {
        let config = makeBox("dvcC", Data([0, 0, 10, 0x55, 0]))
        let entry = makeVisualEntry("dvh1", children: config)
        let video = makeTrack(handler: "vide", entry: entry)
        let fields = try #require(DolbyVisionColorDiagnostics.initLogFields(from: makeInit(videoTrack: video)))

        #expect(fields.contains("colr=absent"))
        #expect(fields.contains("dvvC=absent"))
    }

    @Test("parser handles extended-size boxes and selects the video track over audio")
    func supportsExtendedBoxesAndSelectsVideoTrack() throws {
        let audioConfig = makeBox("dvcC", Data([0, 0, 16, 0x55, 0]))
        let videoConfig = makeBox("dvcC", Data([0, 0, 10, 0x55, 0]), extended: true)
        let audio = makeTrack(handler: "soun", entry: makeVisualEntry("dvh1", children: audioConfig))
        let video = makeTrack(handler: "vide", entry: makeVisualEntry("dvh1", children: videoConfig, extended: true))
        let fields = try #require(DolbyVisionColorDiagnostics.initLogFields(
            from: makeInit(videoTrack: video, precedingTrack: audio, extendedMoov: true)))

        #expect(fields.contains("dvcC=profile=5,level=10"))
        #expect(!fields.contains("profile=8"))
    }

    @Test("malformed and truncated init boxes return safely")
    func rejectsMalformedAndTruncatedBoxes() {
        let entry = makeVisualEntry("dvh1", children: makeBox("dvcC", Data([0, 0, 10, 0x55, 0])))
        let valid = makeInit(videoTrack: makeTrack(handler: "vide", entry: entry))
        #expect(DolbyVisionColorDiagnostics.initLogFields(from: Data(valid.dropLast())) == nil)

        let malformed = Data([0, 0, 0, 7, 109, 111, 111, 118])
        #expect(DolbyVisionColorDiagnostics.initLogFields(from: malformed) == nil)
        #expect(DolbyVisionColorDiagnostics.initLogFields(from: Data([0, 1, 2])) == nil)
    }

    private func makeInit(
        videoTrack: Data,
        precedingTrack: Data? = nil,
        extendedMoov: Bool = false
    ) -> Data {
        var tracks = Data()
        if let precedingTrack { tracks.append(precedingTrack) }
        tracks.append(videoTrack)
        let moov = makeBox("moov", tracks, extended: extendedMoov)
        return makeBox("ftyp", fourCC("isom") + Data([0, 0, 0, 0]) + fourCC("isom")) + moov
    }

    private func makeTrack(handler: String, entry: Data) -> Data {
        var hdlrPayload = Data(repeating: 0, count: 8)
        hdlrPayload.append(fourCC(handler))
        var stsdPayload = Data(repeating: 0, count: 4) // version and flags
        stsdPayload.append(uint32(1))
        stsdPayload.append(entry)
        let stsd = makeBox("stsd", stsdPayload)
        let stbl = makeBox("stbl", stsd)
        let minf = makeBox("minf", stbl)
        let mdia = makeBox("mdia", makeBox("hdlr", hdlrPayload) + minf)
        return makeBox("trak", mdia)
    }

    private func makeVisualEntry(_ type: String, children: Data, extended: Bool = false) -> Data {
        makeBox(type, Data(repeating: 0, count: 78) + children, extended: extended)
    }

    private func makeBox(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
        var box = Data()
        if extended {
            box.append(uint32(1))
            box.append(fourCC(type))
            box.append(uint64(UInt64(payload.count + 16)))
        } else {
            box.append(uint32(UInt32(payload.count + 8)))
            box.append(fourCC(type))
        }
        box.append(payload)
        return box
    }

    private func fourCC(_ value: String) -> Data { Data(value.utf8) }

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func uint64(_ value: UInt64) -> Data {
        Data((0..<8).map { shift in UInt8((value >> UInt64((7 - shift) * 8)) & 0xFF) })
    }
}
