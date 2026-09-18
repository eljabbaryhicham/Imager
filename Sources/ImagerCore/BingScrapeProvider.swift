import Foundation

/// A keyless, unofficial Bing Images scrape provider.
///
/// Bing's results page embeds each tile as an `<a class="iusc">` whose `m`
/// attribute holds a JSON blob (`murl`, `turl`, `t`, `purl`, `w`, `h`). This
/// is unofficial and may break if Bing changes markup or begins bot-checking.
public struct BingScrapeProvider: ImageSearchProvider {
    public let id = "bing"
    public let displayName = "Bing"
    public let requiresAPIKey = false

    private let session: URLSession

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
        var components = URLComponents(string: "https://www.bing.com/images/search")!
        let first = (page - 1) * 42 + 1
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "form", value: "HDRSC2"),
            URLQueryItem(name: "first", value: String(first)),
            URLQueryItem(name: "count", value: "42")
        ]
        guard let url = components.url else {
            throw ProviderError.server("Bing could not build its search URL.")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Bing request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            throw ProviderError.server("Bing search failed (HTTP \(http.statusCode)).")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.server("Bing returned unreadable data.")
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
                id: "bing-\(StableHash.string(raw.murl))",
                title: raw.title.isEmpty ? "Bing result" : raw.title,
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

    /// Scans `class="iusc"` anchors, decodes their `m="..."` JSON attribute.
    static func parseTiles(from html: String) -> [Tile] {
        let ns = html as NSString
        let pattern = #"<a[^>]*class="iusc"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: ns.length)

        var tiles: [Tile] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            let anchor = ns.substring(with: match.range)
            let metadata = Self.extractMetadata(from: anchor)
            guard let murl = metadata["murl"] as? String, !murl.isEmpty else { return }
            tiles.append(
                Tile(
                    murl: murl,
                    turl: metadata["turl"] as? String ?? "",
                    title: metadata["t"] as? String ?? "",
                    pageURL: metadata["purl"] as? String,
                    width: (metadata["w"] as? Double).flatMap(Int.init),
                    height: (metadata["h"] as? Double).flatMap(Int.init)
                )
            )
        }
        return tiles
    }

    /// Decodes the escaped JSON in the `m` attribute (Bing HTML-escapes quotes).
    static func extractMetadata(from anchor: String) -> [String: Any] {
        guard
            let start = anchor.range(of: "m=\""),
            let end = anchor[start.upperBound...].range(of: "\"")
        else { return [:] }
        let raw = String(anchor[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }
}
