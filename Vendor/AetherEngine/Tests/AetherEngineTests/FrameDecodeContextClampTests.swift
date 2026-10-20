import Foundation
import Testing
@testable import AetherEngine

/// AE#105: a still requested past the demuxer's known duration otherwise seeks far past EOF and
/// decodes a blank garbage frame that reports `image=ok`. The seek target is clamped to the last
/// safely-decodable position. This is defense-in-depth behind the BDTitleSelector decoy fix that
/// stops a mis-selected decoy title (76s demuxer, 5:23 declared) from being the scrub target at all.
struct FrameDecodeContextClampTests {

    @Test("a request within the known duration is left untouched")
    func inRangePassthrough() {
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 42.0, duration: 76.64) == 42.0)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 0.0, duration: 76.64) == 0.0)
    }

    @Test("a request far past the known duration clamps to just inside the end")
    func pastDurationClamps() {
        // The AE#105 case: demuxer duration 76.64s, host scrub asked for 611.25s.
        let clamped = FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 76.64)
        #expect(clamped < 76.64)
        #expect(clamped > 0)
    }

    @Test("an unknown duration (<= 0) disables clamping so normal sources are unaffected")
    func unknownDurationPassthrough() {
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 0) == 611.25)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 5.0, duration: -1) == 5.0)
    }

    @Test("scrubbing to the very end within tolerance is not treated as past-EOF")
    func endScrubTolerated() {
        // Rounding can put the last-frame request a hair past the reported duration; that must not clamp.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 76.7, duration: 76.64) == 76.7)
    }

    @Test("elapsed preview targets map onto the raw presentation timeline and back")
    func elapsedPreviewTimelineMapping() throws {
        let origin = FrameDecodeContext.previewPresentationOrigin(
            formatStartTime: 600_000_000, streamStartSeconds: 590)
        #expect(origin == 600)
        let mapping = try #require(FrameDecodeContext.elapsedPreviewSeek(
            requested: 650, duration: 1_000, origin: origin))
        #expect(mapping.elapsedSeconds == 650)
        #expect(mapping.rawSeekSeconds == 1_250)
        #expect(FrameDecodeContext.elapsedPreviewTime(rawSeconds: 1_250, origin: origin) == 650)

        let clamped = try #require(FrameDecodeContext.elapsedPreviewSeek(
            requested: 611.25, duration: 76, origin: origin))
        #expect(clamped.elapsedSeconds == 75)
        #expect(clamped.rawSeekSeconds == 675)
    }

    @Test("elapsed preview origin falls back safely and rejects non-finite mappings")
    func elapsedPreviewOriginAndNonFiniteInputs() {
        #expect(FrameDecodeContext.previewPresentationOrigin(
            formatStartTime: Int64.min, streamStartSeconds: -12.5) == -12.5)
        #expect(FrameDecodeContext.previewPresentationOrigin(
            formatStartTime: Int64.min, streamStartSeconds: nil) == 0)
        #expect(FrameDecodeContext.previewPresentationOrigin(
            formatStartTime: Int64.min, streamStartSeconds: .infinity) == 0)
        #expect(FrameDecodeContext.previewPresentationOrigin(
            formatStartTime: -1_500_000, streamStartSeconds: 60) == -1.5)

        #expect(FrameDecodeContext.elapsedPreviewSeek(
            requested: .nan, duration: 1_000, origin: 0) == nil)
        #expect(FrameDecodeContext.elapsedPreviewSeek(
            requested: 1, duration: 1_000, origin: .infinity) == nil)
        #expect(FrameDecodeContext.elapsedPreviewSeek(
            requested: Double.greatestFiniteMagnitude,
            duration: 0,
            origin: Double.greatestFiniteMagnitude) == nil)
        #expect(FrameDecodeContext.elapsedPreviewTime(rawSeconds: .nan, origin: 0) == nil)
    }
}
