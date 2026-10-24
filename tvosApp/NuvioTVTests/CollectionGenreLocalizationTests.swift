import XCTest
@testable import NuvioTV

@MainActor
final class CollectionGenreLocalizationTests: XCTestCase {
    func testTemplateIdentityIsDecodedWithoutRequiringItForCustomCollections() throws {
        let template = try JSONDecoder().decode(NuvioCollection.self, from: Data(
            #"{"id":"c","title":"Renamed collection","templateID":"discover-genres"}"#.utf8
        ))
        XCTAssertEqual(template.templateID, "discover-genres")
        let custom = try JSONDecoder().decode(NuvioCollection.self, from: Data(
            #"{"id":"c","title":"My collection"}"#.utf8
        ))
        XCTAssertNil(custom.templateID)
    }

    func testOriginalTemplateLabelIsLocalizedWithoutChangingItsStoredTitleOrID() throws {
        let value = try destination()
        XCTAssertEqual(display(value), "sidebar_genre_comedy")
        XCTAssertEqual(value.folder.title, "Comedy")
        XCTAssertEqual(value.id.folderID, "folder")
        XCTAssertEqual(value.folder.sources.first?.filters?.withGenres, "35")
    }

    func testRenamedFolderKeepsItsExactLabel() throws {
        XCTAssertEqual(display(try destination(title: "Mis comedias favoritas")), "Mis comedias favoritas")
    }

    func testCanonicalNameInCustomCollectionIsNotTranslated() throws {
        XCTAssertEqual(display(try destination(templateID: nil)), "Comedy")
    }

    func testCanonicalNameWithDifferentGenreFiltersIsNotTranslated() throws {
        XCTAssertEqual(display(try destination(genre: "18")), "Comedy")
    }

    func testProviderCollectionWithGenreFilterKeepsItsLabel() throws {
        XCTAssertEqual(display(try destination(provider: "8")), "Comedy")
    }

    private func display(_ value: CollectionHomeDestination) -> String {
        CollectionGenreLocalization.title(for: value) { key, _ in key }
    }

    private func destination(
        title: String = "Comedy", templateID: String? = "discover-genres",
        genre: String = "35", provider: String? = nil
    ) throws -> CollectionHomeDestination {
        var filters = ["withGenres": genre]
        if let provider { filters["withWatchProviders"] = provider }
        let json: [String: Any] = [
            "id": "folder", "title": title,
            "sources": [["provider": "tmdb", "tmdbSourceType": "DISCOVER",
                         "mediaType": "movie", "filters": filters]]
        ]
        let folder = try JSONDecoder().decode(NuvioCollectionFolder.self, from:
            JSONSerialization.data(withJSONObject: json))
        return CollectionHomeDestination(
            id: CollectionHomeID(profileID: "profile", collectionID: "collection", folderID: folder.id),
            collectionTitle: "Collection",
            folder: TVCollectionFolderItem(collectionId: "collection", folder: folder, sources: folder.resolvedSources),
            templateID: templateID
        )
    }
}
