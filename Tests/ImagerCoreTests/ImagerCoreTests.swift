import XCTest
@testable import ImagerCore

final class FilterTests: XCTestCase {
    func testQualitySmall() {
        let filters = SearchFilters(quality: .small, format: .any)
        XCTAssertTrue(filters.matches(width: 500, height: 600, urlPathExtension: "jpg", contentType: nil))
        XCTAssertFalse(filters.matches(width: 1024, height: 1024, urlPathExtension: "jpg", contentType: nil))
    }

    func testQualityMedium() {
        let filters = SearchFilters(quality: .medium, format: .any)
        XCTAssertTrue(filters.matches(width: 1280, height: 720, urlPathExtension: "png", contentType: nil))
        XCTAssertFalse(filters.matches(width: 500, height: 500, urlPathExtension: "png", contentType: nil))
        XCTAssertFalse(filters.matches(width: 3840, height: 2160, urlPathExtension: "png", contentType: nil))
    }

    func testQualityLarge() {
        let filters = SearchFilters(quality: .large, format: .any)
        XCTAssertTrue(filters.matches(width: 3840, height: 2160, urlPathExtension: "jpg", contentType: nil))
        XCTAssertFalse(filters.matches(width: 1280, height: 720, urlPathExtension: "jpg", contentType: nil))
    }

    func testFormatFromExtension() {
        XCTAssertTrue(SearchFilters(format: .jpg).matches(width: nil, height: nil, urlPathExtension: "JPEG", contentType: nil))
        XCTAssertTrue(SearchFilters(format: .png).matches(width: nil, height: nil, urlPathExtension: "png", contentType: nil))
        XCTAssertFalse(SearchFilters(format: .png).matches(width: nil, height: nil, urlPathExtension: "jpg", contentType: nil))
        XCTAssertTrue(SearchFilters(format: .webp).matches(width: nil, height: nil, urlPathExtension: "webp", contentType: nil))
    }

    func testFormatFromMIME() {
        XCTAssertTrue(SearchFilters(format: .jpg).matches(width: nil, height: nil, urlPathExtension: nil, contentType: "image/jpeg"))
        XCTAssertFalse(SearchFilters(format: .gif).matches(width: nil, height: nil, urlPathExtension: nil, contentType: "image/png"))
    }

    func testMissingDimensionsPassQuality() {
        let filters = SearchFilters(quality: .large, format: .any)
        XCTAssertTrue(filters.matches(width: nil, height: nil, urlPathExtension: "jpg", contentType: nil))
    }
}

final class ImageResultTests: XCTestCase {
    func testSuggestedFileName() {
        let result = ImageResult(
            id: "test-abc123",
            title: "Fluffy cats / playing",
            thumbnailURL: "https://example.com/t.jpg",
            fullURL: "https://example.com/photo.png?w=800",
            sourcePageURL: nil,
            width: 800,
            height: 600,
            providerID: "test",
            contentType: nil
        )
        XCTAssertEqual(result.fileExtension, "png")
        XCTAssertTrue(result.suggestedFileName.hasPrefix("Fluffy-cats-playing-"))
        XCTAssertTrue(result.suggestedFileName.hasSuffix(".png"))
    }

    func testFileExtensionFallbackToMIME() {
        let result = ImageResult(
            id: "x",
            title: "photo",
            thumbnailURL: "https://example.com/t",
            fullURL: "https://example.com/photo",
            sourcePageURL: nil,
            width: nil,
            height: nil,
            providerID: "x",
            contentType: "image/webp"
        )
        XCTAssertEqual(result.fileExtension, "webp")
    }
}

final class DuckDuckGoParsingTests: XCTestCase {
    func testExtractVQD() {
        XCTAssertEqual(DuckDuckGoProvider.extractVQD(from: #"var vqd='4-123456789'??="#), "4-123456789")
        XCTAssertEqual(DuckDuckGoProvider.extractVQD(from: #"vqd="4-987654321";"#), "4-987654321")
        XCTAssertNil(DuckDuckGoProvider.extractVQD(from: "no token here"))
    }
}

@MainActor
final class SearchHistoryTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ImagerTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testRecentSearchesMoveToFrontAndCap() throws {
        let model = try makeModel()
        for number in 1...10 {
            model.query = "Query \(number)"
            model.performSearch()
        }

        XCTAssertEqual(model.recentSearches.count, 8)
        XCTAssertEqual(model.recentSearches.first, "Query 10")
        XCTAssertFalse(model.recentSearches.contains("Query 1"))

        model.query = "query 5"
        model.performSearch()
        XCTAssertEqual(model.recentSearches.first, "query 5")
        XCTAssertEqual(model.recentSearches.count, 8)
    }

    func testSavedSearchesDeduplicatePersistAndRemove() throws {
        let model = try makeModel()
        model.saveSearch(" Cats ")
        model.saveSearch("cats")
        XCTAssertEqual(model.savedSearches, ["cats"])

        let reloaded = try makeModel(storage: modelStorage())
        XCTAssertEqual(reloaded.savedSearches, ["cats"])

        reloaded.removeSavedSearch("CATS")
        XCTAssertTrue(reloaded.savedSearches.isEmpty)
    }

    func testSearchAsYouTypePersists() throws {
        let model = try makeModel()
        model.setSearchAsYouType(false)
        XCTAssertFalse(model.searchAsYouType)

        let reloaded = try makeModel(storage: modelStorage())
        XCTAssertFalse(reloaded.searchAsYouType)
    }

    private func makeModel(storage: UserDefaults? = nil) throws -> SearchViewModel {
        SearchViewModel(providers: [], storage: try storage ?? modelStorage())
    }

    private func modelStorage() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}

final class ResultSortTests: XCTestCase {
    func testLargestSortPutsUnknownSizesLast() {
        let results = [
            makeResult(id: "unknown", title: "Unknown", width: nil, height: nil),
            makeResult(id: "small", title: "Small", width: 100, height: 100),
            makeResult(id: "large", title: "Large", width: 2000, height: 2000)
        ]
        XCTAssertEqual(ResultSortOption.largest.sort(results).map(\.id), ["large", "small", "unknown"])
    }

    func testSmallestSortPutsUnknownSizesLast() {
        let results = [
            makeResult(id: "large", title: "Large", width: 2000, height: 2000),
            makeResult(id: "unknown", title: "Unknown", width: nil, height: nil),
            makeResult(id: "small", title: "Small", width: 100, height: 100)
        ]
        XCTAssertEqual(ResultSortOption.smallest.sort(results).map(\.id), ["small", "large", "unknown"])
    }

    func testTitleSortIsCaseInsensitive() {
        let results = [
            makeResult(id: "b", title: "banana", width: nil, height: nil),
            makeResult(id: "a", title: "Apple", width: nil, height: nil),
            makeResult(id: "c", title: "cherry", width: nil, height: nil)
        ]
        XCTAssertEqual(ResultSortOption.title.sort(results).map(\.id), ["a", "b", "c"])
    }

    private func makeResult(id: String, title: String, width: Int?, height: Int?) -> ImageResult {
        ImageResult(
            id: id,
            title: title,
            thumbnailURL: "https://example.com/\(id).jpg",
            fullURL: "https://example.com/\(id).jpg",
            sourcePageURL: nil,
            width: width,
            height: height,
            providerID: "test",
            contentType: "image/jpeg"
        )
    }
}

final class ProviderLiveTests: XCTestCase {
    func testDuckDuckGoLiveSearch() async throws {
        let provider = DuckDuckGoProvider()
        let results = try await provider.search(query: "cats", filters: SearchFilters(), page: 1)
        XCTAssertFalse(results.isEmpty, "Expected live DuckDuckGo results")
        XCTAssertTrue(results.allSatisfy { $0.fullURL.hasPrefix("http") })
    }

    func testOpenverseLiveSearch() async throws {
        let provider = OpenverseProvider()
        do {
            let results = try await provider.search(query: "cats", filters: SearchFilters(), page: 1)
            XCTAssertFalse(results.isEmpty, "Expected live Openverse results")
        } catch ProviderError.server(let message) where message.contains("rate limit") {
            throw XCTSkip("Openverse anonymous rate limit reached (\(message))")
        }
    }

    func testDuckDuckGoSizeFilter() async throws {
        let provider = DuckDuckGoProvider()
        let results = try await provider.search(query: "cats", filters: SearchFilters(quality: .large, format: .any), page: 1)
        for result in results {
            if let width = result.width, let height = result.height {
                XCTAssertGreaterThan(max(width, height), 1920, "Filtered results should be large when dimensions are known")
            }
        }
    }

    func testBingLiveSmoke() async throws {
        let provider = BingScrapeProvider()
        do {
            let results = try await provider.search(query: "cats", filters: SearchFilters(), page: 1)
            XCTAssertFalse(results.isEmpty, "Expected live Bing scrape results")
        } catch {
            throw XCTSkip("Bing scrape failed in this environment (\(String(describing: error)))")
        }
    }

    func testYahooLiveSmoke() async throws {
        let provider = YahooScrapeProvider()
        do {
            let results = try await provider.search(query: "cats", filters: SearchFilters(), page: 1)
            XCTAssertFalse(results.isEmpty, "Expected live Yahoo scrape results")
        } catch {
            throw XCTSkip("Yahoo scrape failed in this environment (\(String(describing: error)))")
        }
    }

    func testPinterestLiveSmoke() async throws {
        let provider = PinterestScrapeProvider()
        do {
            let results = try await provider.search(query: "cats", filters: SearchFilters(), page: 1)
            XCTAssertFalse(results.isEmpty, "Expected live Pinterest scrape results")
        } catch {
            throw XCTSkip("Pinterest scrape failed in this environment (\(String(describing: error)))")
        }
    }

    func testGoogleSerpApiParsing() throws {
        let json = """
        {
          "images_results": [
            {
              "position": 1,
              "thumbnail": "https://example.com/thumbs/tabby.jpg",
              "title": "A tabby cat",
              "link": "https://example.com/blog/cats",
              "source": "Example",
              "original": "https://example.com/photos/tabby.jpg",
              "original_width": 800,
              "original_height": 600
            },
            {
              "position": 2,
              "thumbnail": "https://example.com/thumbs/cat.png",
              "title": "PNG cat",
              "link": "https://example.com/gallery",
              "source": "Example",
              "original": "https://example.com/cat.png",
              "original_width": 400,
              "original_height": 400
            }
          ]
        }
        """
        let results = try GoogleSerpApiProvider.results(from: Data(json.utf8), filters: SearchFilters())
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].fullURL, "https://example.com/photos/tabby.jpg")
        XCTAssertEqual(results[0].thumbnailURL, "https://example.com/thumbs/tabby.jpg")
        XCTAssertEqual(results[0].sourcePageURL, "https://example.com/blog/cats")
        XCTAssertEqual(results[0].width, 800)
        XCTAssertEqual(results[0].providerID, "google")
    }
}

final class BingParsingTests: XCTestCase {
    func testParseTilesExtractsMetadata() {
        let html = """
        <a class="iusc" m="{&quot;murl&quot;:&quot;https://cdn.example.com/img1.jpg&quot;,&quot;turl&quot;:&quot;https://cdn.example.com/thumb1.jpg&quot;,&quot;t&quot;:&quot;A gray cat&quot;,&quot;w&quot;:800,&quot;h&quot;:600}">&nbsp;</a>
        <a class="iusc" m="{&quot;murl&quot;:&quot;&quot;}">&nbsp;</a>
        """
        let tiles = BingScrapeProvider.parseTiles(from: html)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].murl, "https://cdn.example.com/img1.jpg")
        XCTAssertEqual(tiles[0].turl, "https://cdn.example.com/thumb1.jpg")
        XCTAssertEqual(tiles[0].title, "A gray cat")
        XCTAssertEqual(tiles[0].width, 800)
        XCTAssertEqual(tiles[0].height, 600)
        XCTAssertNil(tiles[0].pageURL)
    }
}

final class YahooParsingTests: XCTestCase {
    func testParseTilesExtractsTile() {
        let html = """
        <a class="li-mg media-tile" data-origurl="https://img.example.com/cat.jpg" data-referenceurl="https://site.example.com/cat.html"><img src="https://img.example.com/t_cat.jpg" data-meta="{&quot;ow&quot;:1024,&quot;oh&quot;:768}"><div class="tile-title">A photo of a cat</div></a>
        """
        let tiles = YahooScrapeProvider.parseTiles(from: html)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].murl, "https://img.example.com/cat.jpg")
        XCTAssertEqual(tiles[0].turl, "https://img.example.com/t_cat.jpg")
        XCTAssertEqual(tiles[0].pageURL, "https://site.example.com/cat.html")
        XCTAssertEqual(tiles[0].title, "A photo of a cat")
        XCTAssertEqual(tiles[0].width, 1024)
        XCTAssertEqual(tiles[0].height, 768)
    }
}

final class PinterestParsingTests: XCTestCase {
    func testParsePinsFillsFromFixture() throws {
        let json = """
        {
          "resource_response": {
            "data": {
              "results": [
                {
                  "type": "pin",
                  "id": "12345",
                  "link": "https://example.com/art",
                  "title": "Nice pin title",
                  "images": {
                    "orig": {"url": "https://img.example.com/full.jpg", "width": 1200, "height": 900},
                    "236x": {"url": "https://img.example.com/t.jpg"}
                  }
                },
                {
                  "type": "story",
                  "images": {}
                }
              ]
            }
          }
        }
        """
        let pins = PinterestScrapeProvider.parsePins(from: Data(json.utf8))
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].murl, "https://img.example.com/full.jpg")
        XCTAssertEqual(pins[0].turl, "https://img.example.com/t.jpg")
        XCTAssertEqual(pins[0].pageURL, "https://example.com/art")
        XCTAssertEqual(pins[0].title, "Nice pin title")
        XCTAssertEqual(pins[0].width, 1200)
        XCTAssertEqual(pins[0].height, 900)
    }
}

final class StableHashTests: XCTestCase {
    func testIsDeterministicAndDiscriminating() {
        XCTAssertEqual(StableHash.string("https://example.com/a.jpg"), StableHash.string("https://example.com/a.jpg"))
        XCTAssertNotEqual(StableHash.string("https://example.com/a.jpg"), StableHash.string("https://example.com/b.jpg"))
    }
}