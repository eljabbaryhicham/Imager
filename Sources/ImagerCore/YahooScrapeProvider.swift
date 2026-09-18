import Foundation

/// A keyless, unofficial Yahoo Images scrape provider.
///
/// Yahoo's image search results render thumbnails whose `href` threads the
/// hosted image through `imgurl=` and the source page through `rurl=`. The
/// `alt` text holds the titlehots. Unofficial; may break if Yahoo changes
/// markup or starts requiring cookies.
public struct YahooScrapeProvider: ImageSearchProvider {
    public let id = "yahoo"
    public let displayName = "Yahoo"
    public let requiresAPIKey = false

    private let session: URLSession

    /// Pre-fetches Yahoo's consent gate through the persistent session once.
    /// The ephemeral configuration keeps the consent cookie in the session's
    /// cookie jar, so the subsequent search request carries it automatically.
    private func establishConsentCookies() async {
        guard let url = URL(string: "https://images.search.yahoo.com") else { return }
        _ = try? await session.data(from: url)
    }

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        session = URLSession(configuration: config)
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://images.search.yahoo.com/search/images")!
        let start = (page - 1) * 21 + 1
        components.queryItems = [
            URLQueryItem(name: "p", value: query),
            URLQueryItem(name: "ei", value: "UTF-8"),
            URLQueryItem(name: "b", value: String(start))
        ]
        guard let url = components.url else {
            throw ProviderError.server("Yahoo could not build its search URL.")
        }

        // Yahoo sometimes gates image search behind a consent screen that
        // returns an HTML redirect to consent.yahoo.com. Pre-fetch the
        // consent gate once per session so the subsequent search request
        // carries the cookies Yahoo expects.
        await establishConsentCookies()

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Yahoo request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            throw ProviderError.server("Yahoo search failed (HTTP \(http.statusCode)).")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.server("Yahoo returned unreadable data.")
        }

        return Self.parseTiles(from: html).compactMap { raw in
            let accepted = filters.matches(
                width: raw.width,
                height: raw.height,
                urlPathExtension: URL(string: raw.murl)?.pathExtension,
                contentType: nil
            )
            guard accepted else { return nil }
            return ImageResult(
                id: "yahoo-\(StableHash.string(raw.murl))",
                title: raw.title.isEmpty ? "Yahoo result" : raw.title,
                thumbnailURL: raw.turl,
                fullURL: raw.murl,
                sourcePageURL: raw.pageURL,
                width: raw.width,
                height: raw.height,
                providerID: id,
                contentType: nil
            )
        }
    }

    struct Tile {
        let murl: String
        let turl: String
        let title: String
        let pageURL: String?
        let width: Int?
        let height: Int?
    }

    /// Scans Yahoo's current image-tile anchors. Each tile is an
    /// `<a class="...media-tile...">` whose `data-origurl`/`data-referenceurl`
    /// carry the hosted image and source page, whose `<img data-meta>` JSON
    /// holds `ow`/`oh` dimensions, and whose `.tile-title` paragraph holds the
    /// title.
    static func parseTiles(from html: String) -> [Tile] {
        let ns = html as NSString
        let pattern = #"<a[^>]*class="[^"]*media-tile[^"]*"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(location: 0, length: ns.length)

        var tiles: [Tile] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            let tile = ns.substring(with: match.range)

            guard
                let murl = Self.attribute(named: "data-origurl", in: tile),
                !murl.isEmpty
            else { return }
            let turl = Self.attribute(named: "src", in: tile)
                ?? Self.attribute(named: "data-origurl", in: tile) ?? ""
            let pageURL = Self.attribute(named: "data-referenceurl", in: tile)
            let title = Self.classText(class: "tile-title", in: tile)
            var width: Int?
            var height: Int?
            if let meta = Self.attribute(named: "data-meta", in: tile),
               let data = Self.decodeHTMLEntities(meta).data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                width = (dict["ow"] as? NSNumber)?.intValue
                height = (dict["oh"] as? NSNumber)?.intValue
            }
            tiles.append(
                Tile(
                    murl: Self.decodeHTMLEntities(murl),
                    turl: Self.decodeHTMLEntities(turl),
                    title: Self.decodeHTMLEntities(title),
                    pageURL: pageURL,
                    width: width,
                    height: height
                )
            )
        }
        return tiles
    }

    /// Returns the value of the first attribute with the given name in an
    /// anchor's substring (`name="..."`), or nil.
    private static func attribute(named name: String, in substring: String) -> String? {
        let ns = substring as NSString
        let pattern = name + #"="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: substring, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Returns the text content of the first element that has the given class
    /// in its `class` attribute (e.g. `.tile-title`), or "".
    private static func classText(class className: String, in substring: String) -> String {
        let ns = substring as NSString
        let pattern = "class=\"[^\"]*\(className)[^\"]*\"[^>]*>([^<]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: substring, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound
        else { return "" }
        return ns.substring(with: match.range(at: 1))
    }

    static func queryValue(named name: String, in urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value?
            .removingPercentEncoding
    }

    static func firstQueryValue(named name: String, in urlString: String) -> String? {
        queryValue(named: name, in: urlString)
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let replacements = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result
    }
}
