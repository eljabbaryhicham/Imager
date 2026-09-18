import Foundation

public struct OpenverseProvider: ImageSearchProvider {
    public let id = "openverse"
    public let displayName = "Openverse (CC)"
    public let requiresAPIKey = false

    public init() {}

    public func search(query: String, filters: SearchFilters, page: Int) async throws -> [ImageResult] {
        var components = URLComponents(string: "https://api.openverse.org/v1/images/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: "24")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Imager/0.1 (https://opensource.org) image search", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw ProviderError.server("Openverse anonymous rate limit is reached for today. Try again later, or use another provider.")
            }
            throw ProviderError.server("Openverse search failed (HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode)).")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.server("Openverse returned an unreadable response.")
        }

        return decoded.results.compactMap { item in
            let result = ImageResult(
                id: "openverse-\(item.id)",
                title: item.title ?? "Untitled",
                thumbnailURL: item.thumbnail ?? item.url,
                fullURL: item.url,
                sourcePageURL: item.foreignLandingURL,
                width: item.width,
                height: item.height,
                providerID: id,
                contentType: nil
            )
            let accepted = filters.matches(
                width: item.width,
                height: item.height,
                urlPathExtension: URL(string: item.url)?.pathExtension,
                contentType: nil
            )
            return accepted ? result : nil
        }
    }
}

private struct Response: Decodable {
    let results: [Item]
}

private struct Item: Decodable {
    let id: String
    let title: String?
    let url: String
    let thumbnail: String?
    let width: Int?
    let height: Int?
    let foreignLandingURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, url, thumbnail, width, height
        case foreignLandingURL = "foreign_landing_url"
    }
}