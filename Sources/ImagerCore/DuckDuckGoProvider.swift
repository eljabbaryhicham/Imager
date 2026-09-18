import Foundation

public struct DuckDuckGoProvider: ImageSearchProvider {
    public let id = "duckduckgo"
    public let displayName = "DuckDuckGo"
    public let requiresAPIKey = false

    private let vqdCache = TokenCache()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: config)
    }()

    public init() {}

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        let token = try await vqdToken(for: query)
        let pageSize = 100
        let offset = (page - 1) * pageSize

        var components = URLComponents(string: "https://duckduckgo.com/i.js")!
        components.queryItems = [
            URLQueryItem(name: "l", value: "us-en"),
            URLQueryItem(name: "o", value: "json"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vqd", value: token),
            URLQueryItem(name: "f", value: ",m"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "s", value: String(offset))
        ]
        guard let url = components.url else {
            throw ProviderError.server("Could not build search URL.")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.server("DuckDuckGo search failed (HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode)).")
        }

        guard let json = try? JSONDecoder().decode(VQDResponse.self, from: data) else {
            throw ProviderError.server("DuckDuckGo returned an unreadable response. Try again.")
        }

        return json.results.compactMap { raw in
            let result = ImageResult(
                id: "duckduckgo-\(raw.imageToken ?? StableHash.string(raw.image))",
                title: raw.title,
                thumbnailURL: raw.thumbnail,
                fullURL: raw.image,
                sourcePageURL: raw.url,
                width: raw.width,
                height: raw.height,
                providerID: id,
                contentType: raw.encodingFormat
            )
            let accepted = filters.matches(
                width: raw.width,
                height: raw.height,
                urlPathExtension: URL(string: raw.image)?.pathExtension,
                contentType: raw.encodingFormat
            )
            return accepted ? result : nil
        }
    }

    private func vqdToken(for query: String) async throws -> String {
        if let cached = vqdCache.value(for: query) { return cached }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iar", value: "images"),
            URLQueryItem(name: "iax", value: "images"),
            URLQueryItem(name: "ia", value: "images")
        ]
        let (data, _) = try await session.data(from: components.url!)

        guard let html = String(data: data, encoding: .utf8),
              let token = Self.extractVQD(from: html) else {
            throw ProviderError.server("DuckDuckGo did not grant a search session. Try again.")
        }
        vqdCache.set(token, for: query)
        return token
    }

    public static func extractVQD(from html: String) -> String? {
        let patterns = ["vqd=\"([0-9-]+)\"", "vqd='([0-9-]+)'"]
        for pattern in patterns {
            if let range = html.range(of: pattern, options: .regularExpression) {
                let match = String(html[range])
                if let value = match.split(separator: "\"").dropFirst().first {
                    return String(value)
                }
                if let value = match.split(separator: "'").dropFirst().first {
                    return String(value)
                }
            }
        }
        return nil
    }
}

private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

private struct VQDResponse: Decodable {
    let results: [VQDItem]
}

private struct VQDItem: Decodable {
    let image: String
    let thumbnail: String
    let title: String
    let url: String?
    let width: Int?
    let height: Int?
    let imageToken: String?
    let encodingFormat: String?

    enum CodingKeys: String, CodingKey {
        case image, thumbnail, title, url, width, height
        case imageToken = "image_token"
        case encodingFormat = "encoding_format"
    }
}