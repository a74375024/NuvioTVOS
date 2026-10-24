import XCTest
@testable import NuvioTV

@MainActor
final class CollectionServiceIconTests: XCTestCase {
    func testLegacyNetflixWordmarkUsesProviderIconWithoutChangingStoredURL() throws {
        let url = "https://image.tmdb.org/t/p/w500/wwemzKWzjKYJFfCeiB57q3r4Bcm.png"
        let folder = try folder(url: url)
        let icon = try XCTUnwrap(CollectionServiceIcon.configured(folder: folder))
        XCTAssertEqual(icon.imageURLs.first, "https://image.tmdb.org/t/p/w500/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg")
        XCTAssertEqual(icon.imageURLs.last, url)
        XCTAssertTrue(icon.fillsCircle)
        XCTAssertEqual(folder.titleLogoUrl, url)
    }

    func testRenamingServiceDoesNotChangeBrandIdentity() throws {
        let url = "https://image.tmdb.org/t/p/w500/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg"
        XCTAssertEqual(CollectionServiceIcon.configured(folder: try folder(title: "My service", url: url)),
                       CollectionServiceIcon.configured(folder: try folder(title: "Netflix", url: url)))
    }

    func testCustomImageIsNotReplacedOrStretched() throws {
        let url = "https://example.com/custom.png"
        let icon = try XCTUnwrap(CollectionServiceIcon.configured(folder: try folder(url: url)))
        XCTAssertEqual(icon.imageURLs, [url])
        XCTAssertFalse(icon.fillsCircle)
        XCTAssertEqual(icon.backgroundRGB, 0x1F1F1F)
    }

    func testCustomTMDBImageAndLookalikeHostStayCustom() throws {
        for url in ["https://image.tmdb.org/t/p/w500/custom.png",
                    "https://image.tmdb.org.example.com/t/p/w500/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg"] {
            let icon = try XCTUnwrap(CollectionServiceIcon.configured(folder: try folder(url: url)))
            XCTAssertEqual(icon.imageURLs, [url])
            XCTAssertFalse(icon.fillsCircle)
        }
    }

    func testAmbiguousAndUnknownProviderFiltersAreNotGuessedByTitle() throws {
        for provider in ["8|9", "999999"] {
            XCTAssertNil(CollectionServiceIcon.configured(folder: try folder(provider: provider)))
        }
    }

    func testCustomEmojiRemainsAuthoritative() throws {
        XCTAssertNil(CollectionServiceIcon.configured(folder: try folder(emoji: "⭐️")))
    }

    func testPrimeVideoUsesBlueIconAndKeepsConfiguredImageAsFallback() throws {
        let original = "https://image.tmdb.org/t/p/w500/pvske1MyAoymrs5bguRfVqYiM9a.jpg"
        let icon = try XCTUnwrap(CollectionServiceIcon.configured(folder: try folder(provider: "9", url: original)))
        XCTAssertTrue(icon.imageURLs.first?.hasPrefix("https://thumb.wikimedia.org/") == true)
        XCTAssertEqual(icon.imageURLs.last, original)
        XCTAssertTrue(icon.fillsCircle)
    }

    private func folder(
        title: String = "Netflix", provider: String = "8",
        url: String = "https://image.tmdb.org/t/p/w500/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg",
        emoji: String? = nil
    ) throws -> TVCollectionFolderItem {
        var json: [String: Any] = [
            "id": "folder", "title": title, "titleLogoUrl": url, "coverImageUrl": url,
            "presentationStyle": "STREAMING_SERVICE",
            "sources": [["provider": "tmdb", "tmdbSourceType": "DISCOVER", "mediaType": "movie",
                         "filters": ["withWatchProviders": provider]]]
        ]
        if let emoji { json["coverEmoji"] = emoji }
        let folder = try JSONDecoder().decode(NuvioCollectionFolder.self, from:
            JSONSerialization.data(withJSONObject: json))
        return TVCollectionFolderItem(collectionId: "collection", folder: folder, sources: folder.resolvedSources)
    }
}
