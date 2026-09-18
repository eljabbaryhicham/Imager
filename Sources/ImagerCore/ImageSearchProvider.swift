import Foundation

public protocol ImageSearchProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var requiresAPIKey: Bool { get }
    func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult]
}

public enum ProviderError: LocalizedError {
    case missingAPIKey(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add a \(provider) API key in Settings to use this source."
        case .server(let message):
            return message
        }
    }
}

public enum ProviderRegistry {
    public static func make(unsplashKey: String?, pexelsKey: String?, pixabayKey: String?, googleKey: String? = nil) -> [any ImageSearchProvider] {
        var providers: [any ImageSearchProvider] = [
            DuckDuckGoProvider(),
            OpenverseProvider(),
            BingScrapeProvider(),
            YahooScrapeProvider(),
            PinterestScrapeProvider()
        ]
        if let key = unsplashKey, !key.isEmpty {
            providers.append(UnsplashProvider(apiKey: key))
        }
        if let key = pexelsKey, !key.isEmpty {
            providers.append(PexelsProvider(apiKey: key))
        }
        if let key = pixabayKey, !key.isEmpty {
            providers.append(PixabayProvider(apiKey: key))
        }
        if let key = googleKey, !key.isEmpty {
            providers.append(GoogleSerpApiProvider(apiKey: key))
        }
        return providers
    }
}