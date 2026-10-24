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

    func testDetailsMoviePreservesArtworkWithoutChangingCanonicalIdentity() throws {
        let meta = NuvioMeta(id: "tmdb:42", name: "Movie", description: "Synopsis",
                             posterUrl: "https://art.example.test/poster.jpg",
                             backgroundUrl: "https://art.example.test/backdrop.jpg",
                             logoUrl: "https://art.example.test/logo.png",
                             imdbId: "tt42", type: "movie")
        let media = try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: nil)
        XCTAssertEqual(media.key, "movie|tt42||")
        XCTAssertEqual(media.description, meta.description)
        XCTAssertEqual(media.poster, meta.posterUrl)
        XCTAssertEqual(media.background, meta.backgroundUrl)
        XCTAssertEqual(media.logo, meta.logoUrl)
        XCTAssertNil(media.source, "Artwork must not introduce a shared playback source")
    }

    func testDetailsEpisodeKeepsSeriesArtworkAndExactEpisode() throws {
        let meta = NuvioMeta(id: "tt55", name: "Show",
                             backgroundUrl: "https://art.example.test/show.jpg", type: "series")
        let episode = NuvioVideo(id: "tt55:0:1", title: "Special", season: 0, episode: 1)
        let media = try WatchPartyLaunchPolicy.mediaForDetails(meta, episode: episode)
        XCTAssertEqual(media.key, "series|tt55|0|1")
        XCTAssertEqual(media.videoID, episode.id)
        XCTAssertEqual(media.background, meta.backgroundUrl)
        XCTAssertNil(media.source)
    }

    func testDetailsArtworkFallbackFillsOnlyMissingPresentationFields() {
        let room = WatchPartyMedia(type: "movie", metaID: "tt42", metaType: "movie",
                                   title: "Server title", poster: "https://art.example.test/server.jpg",
                                   background: "  ", logo: nil)
        let local = WatchPartyMedia(type: "movie", metaID: "tt42", metaType: "movie",
                                    title: "Local title", poster: "https://art.example.test/local.jpg",
                                    background: " https://art.example.test/backdrop.jpg ",
                                    logo: "https://art.example.test/logo.png")
        let result = WatchPartyDetailsPresentationPolicy.artwork(for: room, fallback: local)
        XCTAssertEqual(result.poster, room.poster, "Server artwork takes priority")
        XCTAssertEqual(result.background, "https://art.example.test/backdrop.jpg")
        XCTAssertEqual(result.logo, local.logo)
        XCTAssertEqual(result.key, room.key)
        XCTAssertEqual(result.title, room.title, "Local artwork must not replace room identity or title")
        XCTAssertEqual(result.source, room.source)
    }

    func testDetailsArtworkDoesNotCrossMovieOrEpisodeIdentity() {
        let movie = WatchPartyMedia(type: "movie", metaID: "tt42", metaType: "movie")
        let otherMovie = WatchPartyMedia(type: "movie", metaID: "tt99", metaType: "movie",
                                         background: "https://art.example.test/other.jpg")
        XCTAssertNil(WatchPartyDetailsPresentationPolicy.artwork(for: movie, fallback: otherMovie).background)
        let episode = WatchPartyMedia(type: "series", metaID: "tt55", metaType: "series",
                                     season: 1, episode: 2)
        let otherEpisode = WatchPartyMedia(type: "series", metaID: "tt55", metaType: "series",
                                          season: 1, episode: 3, background: "https://art.example.test/next.jpg")
        XCTAssertNil(WatchPartyDetailsPresentationPolicy.artwork(for: episode, fallback: otherEpisode).background)
    }

    func testDetailsReturnRetainsOriginalTitleWithinTheSameMembership() {
        let request = WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                               userID: "user", profileID: "profile", epoch: UUID())
        let membership = UUID()
        let origin = detailsContext(request: request, membership: membership, mediaKey: "movie|tt42||")
        let changedMedia = detailsContext(request: request, membership: membership, mediaKey: "movie|tt99||")
        XCTAssertTrue(WatchPartyDetailsPresentationPolicy.sameMembership(origin, changedMedia),
                      "Ending the same membership may return to the original Details title")
    }

    func testDetailsReturnRejectsSameRoomAndMemberAfterRejoin() {
        let request = WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                               userID: "user", profileID: "profile", epoch: UUID())
        let origin = detailsContext(request: request, membership: UUID())
        let rejoined = detailsContext(request: request, membership: UUID())
        XCTAssertFalse(WatchPartyDetailsPresentationPolicy.sameMembership(origin, rejoined))
    }

    func testDetailsReturnRejectsChangedEnvironmentAndEpoch() {
        let epoch = UUID(), membership = UUID()
        let request = WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                               userID: "user", profileID: "profile", epoch: epoch)
        let origin = detailsContext(request: request, membership: membership)
        for replacement in [
            WatchPartyRequestContext(backendIdentity: "https://other.example.test",
                                     userID: "user", profileID: "profile", epoch: epoch),
            WatchPartyRequestContext(backendIdentity: request.backendIdentity,
                                     userID: "another-user", profileID: "profile", epoch: epoch),
            WatchPartyRequestContext(backendIdentity: request.backendIdentity,
                                     userID: "user", profileID: "another-profile", epoch: epoch),
            WatchPartyRequestContext(backendIdentity: request.backendIdentity,
                                     userID: "user", profileID: "profile", epoch: UUID())
        ] {
            XCTAssertFalse(WatchPartyDetailsPresentationPolicy.sameMembership(
                origin, detailsContext(request: replacement, membership: membership)))
        }
    }

    func testDetailsReturnRejectsAnotherRoomOrMember() {
        let request = WatchPartyRequestContext(backendIdentity: "https://party.example.test",
                                               userID: "user", profileID: "profile", epoch: UUID())
        let membership = UUID()
        let origin = detailsContext(request: request, membership: membership)
        XCTAssertFalse(WatchPartyDetailsPresentationPolicy.sameMembership(
            origin, detailsContext(request: request, membership: membership, roomID: "other-room")))
        XCTAssertFalse(WatchPartyDetailsPresentationPolicy.sameMembership(
            origin, detailsContext(request: request, membership: membership, memberID: "other-member")))
    }

    private func detailsContext(request: WatchPartyRequestContext, membership: UUID,
                                roomID: String = "room", memberID: String = "member",
                                mediaKey: String = "movie|tt42||") -> WatchPartyPlaybackContext {
        WatchPartyPlaybackContext(request: request, membershipID: membership, roomID: roomID,
                                  memberID: memberID, mediaKey: mediaKey)
    }

}
