import Foundation

private let userAgent = "Imager/0.1 (macOS image palette)"

// MARK: - Unsplash

public struct UnsplashProvider: ImageSearchProvider {
    public let id = "unsplash"
    public let displayName = "Unsplash"
    public let requiresAPIKey = true
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://api.unsplash.com/search/photos")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: "30")
        ]
        return try await Self.fetch(components: components, apiKey: apiKey, providerID: id, filters: filters)
    }

    static func fetch(components: URLComponents, apiKey: String, providerID: String, filters: SearchFilters) async throws -> [ImageResult] {
        var request = URLRequest(url: components.url!)
        request.setValue("Client-ID \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Unsplash request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 { throw ProviderError.server("Unsplash API key is invalid.") }
            throw ProviderError.server("Unsplash search failed (HTTP \(http.statusCode)).")
        }
        guard let decoded = try? JSONDecoder().decode(UnsplashResponse.self, from: data) else {
            throw ProviderError.server("Unsplash returned an unreadable response.")
        }

        return decoded.results.compactMap { photo in
            let result = ImageResult(
                id: "unsplash-\(photo.id)",
                title: photo.altDescription ?? "Unsplash photo",
                thumbnailURL: photo.urls.small,
                fullURL: photo.urls.raw,
                sourcePageURL: photo.links.html,
                width: photo.width,
                height: photo.height,
                providerID: providerID,
                contentType: "image/jpeg"
            )
            let accepted = filters.matches(
                width: photo.width,
                height: photo.height,
                urlPathExtension: "jpg",
                contentType: "image/jpeg"
            )
            return accepted ? result : nil
        }
    }
}

private struct UnsplashResponse: Decodable {
    let results: [Photo]
    struct Photo: Decodable {
        let id: String
        let altDescription: String?
        let urls: URLs
        let links: Links
        let width: Int?
        let height: Int?
        struct URLs: Decodable {
            let raw: String
            let small: String
        }
        struct Links: Decodable {
            let html: String
        }
        enum CodingKeys: String, CodingKey {
            case id, urls, links, width, height
            case altDescription = "alt_description"
        }
    }
}

// MARK: - Pexels

public struct PexelsProvider: ImageSearchProvider {
    public let id = "pexels"
    public let displayName = "Pexels"
    public let requiresAPIKey = true
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://api.pexels.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: "40")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Pexels request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 { throw ProviderError.server("Pexels API key is invalid.") }
            throw ProviderError.server("Pexels search failed (HTTP \(http.statusCode)).")
        }
        guard let decoded = try? JSONDecoder().decode(PexelsResponse.self, from: data) else {
            throw ProviderError.server("Pexels returned an unreadable response.")
        }

        return decoded.photos.compactMap { photo in
            let result = ImageResult(
                id: "pexels-\(photo.id)",
                title: photo.alt ?? "Pexels photo \(photo.id)",
                thumbnailURL: photo.src.medium,
                fullURL: photo.src.original,
                sourcePageURL: photo.url,
                width: photo.width,
                height: photo.height,
                providerID: id,
                contentType: "image/jpeg"
            )
            let accepted = filters.matches(
                width: photo.width,
                height: photo.height,
                urlPathExtension: URL(string: photo.src.original)?.pathExtension,
                contentType: nil
            )
            return accepted ? result : nil
        }
    }
}

private struct PexelsResponse: Decodable {
    let photos: [Photo]
    struct Photo: Decodable {
        let id: Int
        let alt: String?
        let url: String
        let src: Sources
        let width: Int?
        let height: Int?
        struct Sources: Decodable {
            let original: String
            let medium: String
        }
    }
}

// MARK: - Pixabay

public struct PixabayProvider: ImageSearchProvider {
    public let id = "pixabay"
    public let displayName = "Pixabay"
    public let requiresAPIKey = true
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://pixabay.com/api/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: "40"),
            URLQueryItem(name: "safesearch", value: "true")
        ]
        if let minimumEdge = filters.quality.minimumEdge {
            components.queryItems?.append(URLQueryItem(name: "min_width", value: String(minimumEdge)))
            components.queryItems?.append(URLQueryItem(name: "min_height", value: String(minimumEdge)))
        }

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Pixabay request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 400 { throw ProviderError.server("Pixabay API key is invalid.") }
            throw ProviderError.server("Pixabay search failed (HTTP \(http.statusCode)).")
        }
        guard let decoded = try? JSONDecoder().decode(PixabayResponse.self, from: data) else {
            throw ProviderError.server("Pixabay returned an unreadable response.")
        }

        return decoded.hits.compactMap { hit in
            let result = ImageResult(
                id: "pixabay-\(hit.id)",
                title: hit.tags ?? "Pixabay photo",
                thumbnailURL: hit.webformatURL,
                fullURL: hit.largeImageURL,
                sourcePageURL: hit.pageURL,
                width: hit.imageWidth,
                height: hit.imageHeight,
                providerID: id,
                contentType: nil
            )
            let accepted = filters.matches(
                width: hit.imageWidth,
                height: hit.imageHeight,
                urlPathExtension: URL(string: hit.largeImageURL)?.pathExtension,
                contentType: nil
            )
            return accepted ? result : nil
        }
    }
}

private struct PixabayResponse: Decodable {
    let hits: [Hit]
    struct Hit: Decodable {
        let id: Int
        let tags: String?
        let webformatURL: String
        let largeImageURL: String
        let pageURL: String
        let imageWidth: Int?
        let imageHeight: Int?
        enum CodingKeys: String, CodingKey {
            case id, tags
            case webformatURL = "webformatURL"
            case largeImageURL = "largeImageURL"
            case pageURL = "pageURL"
            case imageWidth = "imageWidth"
            case imageHeight = "imageHeight"
        }
    }
}

// MARK: - Google via SerpApi

/// Google Images provider via SerpApi's `google_images` engine.
/// Uses only a SerpApi API key stored in the macOS Keychain; no new package is needed.
public struct GoogleSerpApiProvider: ImageSearchProvider {
    public let id = "google"
    public let displayName = "Google"
    public let requiresAPIKey = true
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://serpapi.com/search.json")!
        components.queryItems = [
            URLQueryItem(name: "engine", value: "google_images"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "google_domain", value: "google.com"),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "us"),
            URLQueryItem(name: "ijn", value: String(min(max(page - 1, 0), 99)))
        ]
        guard let url = components.url else {
            throw ProviderError.server("Google could not build its search URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Google request failed.")
        }
        guard 200..<300 ~= http.statusCode else {
            switch http.statusCode {
            case 401:
                throw ProviderError.server("Google rejected the key (invalid SerpApi key).")
            case 429:
                throw ProviderError.server("Google is rate-limited or the SerpApi quota is exhausted.")
            default:
                throw ProviderError.server("Google search failed (HTTP \(http.statusCode)).")
            }
        }
        return try Self.results(from: data, filters: filters)
    }

    /// Decodes a SerpApi `google_images` JSON payload into results (public for tests).
    public static func results(from data: Data, filters: SearchFilters) throws -> [ImageResult] {
        guard let decoded = try? JSONDecoder().decode(SerpApiGoogleImagesResponse.self, from: data) else {
            throw ProviderError.server("Google returned an unreadable response.")
        }
        if let error = decoded.error, !error.isEmpty {
            throw ProviderError.server(error)
        }
        return (decoded.imagesResults ?? []).compactMap { item in
            let fullURL = httpURL(item.original) ?? httpURL(item.thumbnail) ?? httpURL(item.link)
            guard let fullURL, !fullURL.isEmpty else { return nil }
            let accepted = filters.matches(
                width: item.originalWidth,
                height: item.originalHeight,
                urlPathExtension: URL(string: fullURL)?.pathExtension,
                contentType: nil
            )
            guard accepted else { return nil }
            let identity = item.original ?? item.thumbnail ?? item.link ?? "result-\(item.position ?? 0)"
            return ImageResult(
                id: "google-\(identity)",
                title: item.title ?? item.source ?? "Google result",
                thumbnailURL: httpURL(item.thumbnail) ?? fullURL,
                fullURL: fullURL,
                sourcePageURL: httpURL(item.link),
                width: item.originalWidth,
                height: item.originalHeight,
                providerID: "google",
                contentType: nil
            )
        }
    }

    private static func httpURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return value
    }
}

private struct SerpApiGoogleImagesResponse: Decodable {
    let imagesResults: [SerpApiGoogleImage]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case imagesResults = "images_results"
        case error
    }

    struct SerpApiGoogleImage: Decodable {
        let position: Int?
        let thumbnail: String?
        let title: String?
        let link: String?
        let source: String?
        let original: String?
        let originalWidth: Int?
        let originalHeight: Int?

        enum CodingKeys: String, CodingKey {
            case position, thumbnail, title, link, source, original
            case originalWidth = "original_width"
            case originalHeight = "original_height"
        }
    }
}