import Foundation

/// A keyless, unofficial Pinterest scrape provider (best-effort).
///
/// Pinterest's search page is a JavaScript shell with no server-rendered
/// pins, so this provider calls Pinterest's own internal `BaseSearchResource`
/// web API (the same unauthenticated JSON endpoint the site's frontend uses)
/// and parses the returned pin list. The `x-pinterest-pws-handler` request
/// header is required or Pinterest answers `403 Invalid Resource Request`.
/// Parse/network failures degrade to empty results instead of errors. It may
/// legitimately return few or no results, and it may stop working if
/// Pinterest changes the endpoint. Keep DuckDuckGo as the fallback for
/// reliable results.
public struct PinterestScrapeProvider: ImageSearchProvider {
    public let id = "pinterest"
    public let displayName = "Pinterest"
    public let requiresAPIKey = false

    private let baseURL = "https://www.pinterest.com"
    private let session: URLSession

    public init() {
        session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Accept-Language": "en-US,en;q=0.9",
            "X-Requested-With": "XMLHttpRequest",
            "x-pinterest-pws-handler": "www/index.js"
        ]
        return URLSession(configuration: config)
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        guard let url = queryURL(for: query) else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return []
        }

        return Self.parsePins(from: data).compactMap { raw in
            let accepted = filters.matches(
                width: raw.width,
                height: raw.height,
                urlPathExtension: URL(string: raw.murl)?.pathExtension,
                contentType: nil
            )
            guard accepted else { return nil }
            return ImageResult(
                id: "pinterest-\(StableHash.string(raw.murl))",
                title: raw.title.isEmpty ? "Pinterest result" : raw.title,
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

    /// Builds the internal `BaseSearchResource` URL Pinterest's own web app
    /// uses for unauthenticated pin search. The `x-pinterest-pws-handler`
    /// header (set on the session) is required; otherwise Pinterest responds
    /// with `403 Invalid Resource Request`.
    private func queryURL(for query: String) -> URL? {
        let dataString = Self.requestData(for: query)
        let sourceURL = "/search/pins/?q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
        var components = URLComponents(string: "\(baseURL)/resource/BaseSearchResource/get/")!
        components.queryItems = [
            URLQueryItem(name: "source_url", value: sourceURL),
            URLQueryItem(name: "data", value: dataString),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]
        return components.url
    }

    private static func requestData(for query: String) -> String {
        let options: [String: Any] = [
            "query": query,
            "scope": "pins",
            "page_size": 25
        ]
        let payload: [String: Any] = [
            "options": options,
            "context": [:]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    struct Pin {
        let murl: String
        let turl: String
        let title: String
        let pageURL: String?
        let width: Int?
        let height: Int?
    }

    /// Parses the `resource_response.data.results[]` array from Pinterest's
    /// internal API. Each pin's `images.orig` holds the full-size image, the
    /// `images.236x` (or `170x`) variant is the thumbnail, and `link` (or the
    /// canonical pin URL) is the source page.
    static func parsePins(from data: Data) -> [Pin] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resource = root["resource_response"] as? [String: Any],
            let payload = resource["data"] as? [String: Any],
            let results = payload["results"] as? [[String: Any]]
        else { return [] }

        var pins: [Pin] = []
        for pin in results {
            guard pin["type"] as? String == "pin" else { continue }
            guard
                let images = pin["images"] as? [String: Any],
                let original = images["orig"] as? [String: Any],
                let murl = original["url"] as? String,
                !murl.isEmpty
            else { continue }

            let turl = Self.variantURL(from: images, sizes: ["236x", "474x", "orig"]) ?? ""
            let title = Self.pinTitle(pin)
            let pageURL: String?
            if let link = pin["link"] as? String, !link.isEmpty {
                pageURL = link
            } else if let id = pin["id"] as? String {
                pageURL = "https://www.pinterest.com/pin/\(id)/"
            } else {
                pageURL = nil
            }

            pins.append(
                Pin(
                    murl: murl,
                    turl: turl,
                    title: title,
                    pageURL: pageURL,
                    width: (original["width"] as? NSNumber)?.intValue,
                    height: (original["height"] as? NSNumber)?.intValue
                )
            )
        }
        return pins
    }

    private static func variantURL(from images: [String: Any], sizes: [String]) -> String? {
        for size in sizes {
            if let variant = images[size] as? [String: Any],
               let url = variant["url"] as? String,
               !url.isEmpty {
                return url
            }
        }
        return nil
    }

    private static func pinTitle(_ pin: [String: Any]) -> String {
        let candidates = ["title", "grid_title", "auto_alt_text", "seo_alt_text"]
        for key in candidates {
            if let value = pin[key] as? String, !value.isEmpty {
                return Self.decodeHTMLEntities(value)
            }
        }
        return ""
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
