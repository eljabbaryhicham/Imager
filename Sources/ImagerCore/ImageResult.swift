import Foundation

public struct ImageResult: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailURL: String
    public let fullURL: String
    public let sourcePageURL: String?
    public let width: Int?
    public let height: Int?
    public let providerID: String
    public let contentType: String?

    public init(
        id: String,
        title: String,
        thumbnailURL: String,
        fullURL: String,
        sourcePageURL: String?,
        width: Int?,
        height: Int?,
        providerID: String,
        contentType: String?
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.fullURL = fullURL
        self.sourcePageURL = sourcePageURL
        self.width = width
        self.height = height
        self.providerID = providerID
        self.contentType = contentType
    }

    public var urlPathExtension: String? {
        guard let url = URL(string: fullURL) else { return nil }
        return url.pathExtension
    }

    /// Friendly website name of the image source (provider), e.g. "Unsplash"
    /// or "Pinterest" — never the full URL.
    public var providerDisplayName: String {
        switch providerID {
        case "unsplash": "Unsplash"
        case "pexels": "Pexels"
        case "pixabay": "Pixabay"
        case "google": "Google"
        case "duckduckgo": "DuckDuckGo"
        case "openverse": "Openverse"
        case "bing": "Bing"
        case "yahoo": "Yahoo"
        case "pinterest": "Pinterest"
        default: providerID.capitalized
        }
    }

    /// Domain of the actual website hosting the image (e.g. "unsplash.com"),
    /// not the search provider — falling back to the provider name only when
    /// no source host can be derived.
    public var sourceWebsiteName: String {
        if let sourcePageURL, let host = URL(string: sourcePageURL)?.host {
            return Self.cleanHostName(host)
        }
        if let host = URL(string: fullURL)?.host {
            return Self.cleanHostName(host)
        }
        return providerDisplayName
    }

    private static func cleanHostName(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var fileExtension: String {
        let ext = urlPathExtension?.lowercased() ?? ""
        if ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "tiff", "svg"].contains(ext) {
            return ext
        }
        if let contentType {
            switch contentType.lowercased() {
            case "image/jpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            default: break
            }
        }
        return "jpg"
    }

    public var suggestedFileName: String {
        let sanitized = ImageResult.sanitizeTitle(title)
        let shortID = String(id.suffix(6))
        let base = sanitized.isEmpty ? "image" : sanitized
        let trimmed = String(base.prefix(70))
        return "\(trimmed)-\(shortID).\(fileExtension)"
    }

    public static func sanitizeTitle(_ title: String) -> String {
        var allowed = title.filter { !$0.isNewline }
        for char in ":/\\?%*|\"<>#.&" {
            allowed = allowed.replacingOccurrences(of: String(char), with: "-")
        }
        let hyphenated = allowed.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return hyphenated
    }
}

/// Deterministic FNV-1a string hash, stable across launches (unlike String.hashValue,
/// which is randomized per process and would break persisted favorites matching).
enum StableHash {
    static func string(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}