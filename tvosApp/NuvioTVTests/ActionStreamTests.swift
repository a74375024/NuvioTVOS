import XCTest
@testable import NuvioTV

final class ActionStreamTests: XCTestCase {
    func testActionStreamBehaviorHintsDecoding() throws {
        let notPlayable = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"notPlayable":true}"#.utf8)
        )
        XCTAssertTrue(notPlayable.isNotPlayable)
        XCTAssertEqual(notPlayable.notPlayable, true)

        let action = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"action":true}"#.utf8)
        )
        XCTAssertTrue(action.isNotPlayable)
        XCTAssertEqual(action.action, true)

        let stringBool = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"notPlayable":"true"}"#.utf8)
        )
        XCTAssertTrue(stringBool.isNotPlayable)

        let integerBool = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"action":1}"#.utf8)
        )
        XCTAssertTrue(integerBool.isNotPlayable)

        let dto = StreamAddonStreamDTO(
            url: "https://addon.example/action/request-subtitles",
            name: "Request Subtitles",
            description: "Click to download subtitles for this episode",
            behaviorHints: notPlayable
        )
        let stream = try XCTUnwrap(dto.toNuvioStream(addonName: "SubtitlesAddon"))
        XCTAssertTrue(stream.isNotPlayable)
        XCTAssertEqual(stream.notPlayable, true)
    }

    func testPlayableStreamsRetainsActionStreamsRegardlessOfFilters() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper card",
            addonName: "Addon",
            notPlayable: true
        )
        let unknownResolution = NuvioStream(
            url: "https://addon.example/movie_unknown",
            name: "Unknown Res CAM",
            description: "CAM release",
            addonName: "Addon"
        )
        let hd = NuvioStream(
            url: "https://addon.example/movie1080p",
            name: "Movie 1080p",
            description: "1080p WEB-DL",
            addonName: "Addon"
        )
        let streams = [action, unknownResolution, hd]

        let defaultPlayable = SmartPlaybackSelector.playableStreams(
            from: streams, includeDebrid: false, cachedOnly: false, preserveAddonStreams: false
        )
        XCTAssertTrue(defaultPlayable.contains(where: { $0.id == action.id }))
        XCTAssertFalse(defaultPlayable.contains(where: { $0.id == unknownResolution.id }))
        XCTAssertTrue(defaultPlayable.contains(where: { $0.id == hd.id }))

        let cachedOnly = SmartPlaybackSelector.playableStreams(
            from: streams, includeDebrid: false, cachedOnly: true, preserveAddonStreams: false
        )
        XCTAssertTrue(cachedOnly.contains(where: { $0.id == action.id }))
    }

    func testStreamPickerListBuilderPreservesActionStreamPositions() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper action",
            addonName: "Addon",
            notPlayable: true
        )
        let hd = NuvioStream(url: "https://addon.example/movie720p", name: "Movie 720p", description: "720p", addonName: "Addon")
        let fullHD = NuvioStream(url: "https://addon.example/movie1080p", name: "Movie 1080p", description: "1080p", addonName: "Addon")
        let uhd = NuvioStream(url: "https://addon.example/movie4k", name: "Movie 4K 2160p", description: "4K", addonName: "Addon")

        let topAction = [action, hd, uhd, fullHD]
        let sortedQuality = StreamPickerListBuilder.sorted(topAction, by: .quality, preserveAddonStreams: false)
        XCTAssertEqual(sortedQuality.map(\.id), [action.id, uhd.id, fullHD.id, hd.id])
        let sortedDefault = StreamPickerListBuilder.sorted(topAction, by: .default, preserveAddonStreams: false)
        XCTAssertEqual(sortedDefault.first?.id, action.id)

        let middleAction = [hd, uhd, action, fullHD]
        let sortedMiddle = StreamPickerListBuilder.sorted(middleAction, by: .quality, preserveAddonStreams: false)
        XCTAssertEqual(sortedMiddle.map(\.id), [uhd.id, fullHD.id, action.id, hd.id])
    }

    func testSmartPlaybackSelectorExcludesActionStreamsFromAutoPlay() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper card",
            addonName: "Addon",
            notPlayable: true
        )
        let fullHD = NuvioStream(url: "https://addon.example/movie1080p", name: "Movie 1080p", description: "1080p WEB-DL", addonName: "Addon")
        let uhd = NuvioStream(url: "https://addon.example/movie4k", name: "Movie 2160p", description: "4K UHD", addonName: "Addon")
        let pool = [action, fullHD, uhd]

        let best = SmartPlaybackSelector.bestStream(
            from: pool,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(best?.id, uhd.id)
        XCTAssertFalse(SmartPlaybackSelector.rankedStreams(
            from: pool,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        ).contains(where: { $0.id == action.id }))
    }

    @MainActor
    func testActionPlaybackSessionRemainsUntrackedAfterSubtitleChanges() {
        XCTAssertFalse(PlayerViewModel.shouldTrackPlayback(
            subtitle: "S01 · E02 · Episode title",
            isTrailerSession: false,
            isActionSession: true
        ))
        XCTAssertTrue(PlayerViewModel.shouldTrackPlayback(
            subtitle: "S01 · E02 · Episode title",
            isTrailerSession: false
        ))
        XCTAssertFalse(PlayerViewModel.shouldTrackPlayback(
            subtitle: PlaybackMarkers.trailerSubtitle,
            isTrailerSession: false
        ))
    }

    func testBingeGroupNeverAttachesToActionStream() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Action",
            addonName: "Addon",
            bingeGroup: "release-group-x",
            notPlayable: true
        )
        let tags = StreamQualityTags.parse(stream: action)
        XCTAssertNil(tags.bingeGroup)
        XCTAssertNil(tags.releaseFingerprint)
    }
}
