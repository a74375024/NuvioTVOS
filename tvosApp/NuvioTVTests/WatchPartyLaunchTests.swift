import XCTest
@testable import NuvioTV

final class WatchPartyLaunchTests: XCTestCase {
    func testDetailsMovieCreatesRoomMediaWithoutPlaybackSource() throws {
        let meta = NuvioMeta(id: "tmdb:42", name: "Movie", imdbId: "tt42", type: "movie")
        let media = try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: nil)
        XCTAssertEqual(media.metaID, "tt42")
        XCTAssertEqual(media.metaType, "movie")
        XCTAssertNil(media.season)
        XCTAssertNil(media.episode)
        XCTAssertNil(media.source)
    }

    func testDetailsSeriesRequiresExplicitEpisodeAndKeepsSeasonZero() throws {
        let meta = NuvioMeta(id: "tt55", name: "Series", type: "series")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: nil))
        let episode = NuvioVideo(id: "tt55:0:1", title: "Special", season: 0, episode: 1)
        let media = try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: episode)
        XCTAssertEqual(media.key, "series|tt55|0|1")
        XCTAssertEqual(media.videoID, episode.id)
        XCTAssertNil(media.source)
    }

    func testDetailsRejectsEpisodeForMovie() {
        let meta = NuvioMeta(id: "tt12", name: "Movie", type: "movie")
        let episode = NuvioVideo(id: "tt12:1:1", title: "Not an episode", season: 1, episode: 1)
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: episode))
    }

    func testPlaybackKeepsRoomIDWhenKnownAliasMatches() throws {
        let meta = NuvioMeta(id: "tmdb:42", name: "Movie", imdbId: "tt42", type: "movie")
        let room = WatchPartyMedia(type: "movie", metaID: "tmdb:42", metaType: "movie")
        let selected = try WatchPartyLaunchPolicy.mediaForPlayback(meta, episode: nil, room: room)
        XCTAssertEqual(selected.metaID, "tmdb:42")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(selected, room: room))
    }

    func testPlaybackNormalizesAlternateSeriesTypeAndEpisode() throws {
        let meta = NuvioMeta(id: "tt55", name: "Show", type: "tv")
        let episode = NuvioVideo(id: "tt55:2:3", title: "Episode", season: 2, episode: 3)
        let room = WatchPartyMedia(type: "series", metaID: "tt55", metaType: "series",
                                   season: 2, episode: 3)
        let selected = try WatchPartyLaunchPolicy.mediaForPlayback(meta, episode: episode, room: room)
        XCTAssertEqual(selected.metaType, "series")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(selected, room: room))
    }

    func testPlaybackDoesNotAdoptUnknownRoomID() throws {
        let meta = NuvioMeta(id: "tmdb:42", name: "Same title", imdbId: "tt42", type: "movie")
        let room = WatchPartyMedia(type: "movie", metaID: "tt999", metaType: "movie")
        let selected = try WatchPartyLaunchPolicy.mediaForPlayback(meta, episode: nil, room: room)
        XCTAssertEqual(selected.metaID, "tt42")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(selected, room: room))
    }

    func testMovieOwnSelectionMatchesRoomWithoutComparingReceivedURLs() throws {
        let room = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie", title: "Host title")
        let own = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "MOVIE", title: "Localized title")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testDifferentTitleWithSameDisplayNameIsRejected() {
        let room = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie", title: "Same name")
        let own = WatchPartyMedia(type: "movie", metaID: "tt2", metaType: "movie", title: "Same name")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testDifferentEpisodeOfSameSeriesIsRejected() {
        let room = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 1, episode: 2)
        let own = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 1, episode: 3)
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testSeriesWithoutResolvedEpisodeCannotLaunch() {
        let own = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(own))
    }

    func testSpecialsHaveExplicitSeasonZeroAndPositiveEpisode() {
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validate(
            WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 0, episode: 1)))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(
            WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 0, episode: 0)))
    }

    func testLiveAndMalformedIdentityCannotBecomePartyPlayback() {
        for media in [WatchPartyMedia(type: "live", metaID: "live1", metaType: "live"),
                      WatchPartyMedia(type: "movie", metaID: "movie|fake||", metaType: "movie"),
                      WatchPartyMedia(type: "movie", metaID: "", metaType: "movie")] {
            XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(media))
        }
    }
}
