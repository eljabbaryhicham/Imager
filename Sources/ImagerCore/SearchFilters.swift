import Foundation

public enum QualityFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .any: return "Any size"
        case .small: return "Small (≤ 640px)"
        case .medium: return "Medium (640–1920px)"
        case .large: return "Large (> 1920px)"
        }
    }

    public var minimumEdge: Int? {
        switch self {
        case .any, .small: return nil
        case .medium: return 640
        case .large: return 1920
        }
    }
}

public enum FormatFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case jpg
    case png
    case gif
    case webp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .any: return "Any format"
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .gif: return "GIF"
        case .webp: return "WebP"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .any: return []
        case .jpg: return ["jpg", "jpeg"]
        case .png: return ["png"]
        case .gif: return ["gif"]
        case .webp: return ["webp"]
        }
    }
}

public struct SearchFilters: Equatable, Sendable {
    public var quality: QualityFilter
    public var format: FormatFilter

    public init(quality: QualityFilter = .any, format: FormatFilter = .any) {
        self.quality = quality
        self.format = format
    }

    public func matches(width: Int?, height: Int?, urlPathExtension: String?, contentType: String?) -> Bool {
        if format != .any {
            let allowed = format.fileExtensions
            let fromURL = urlPathExtension.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            let fromMIME = contentType.flatMap { mimeExtension($0) }
            let matched = [fromURL, fromMIME].compactMap { $0 }.contains { allowed.contains($0) }
            if !matched { return false }
        }

        if quality != .any {
            switch (width, height) {
            case (let w?, let h?):
                let maxDim = max(w, h)
                switch quality {
                case .small:
                    if maxDim > 640 { return false }
                case .medium:
                    if maxDim <= 640 || maxDim > 1920 { return false }
                case .large:
                    if maxDim <= 1920 { return false }
                case .any:
                    break
                }
            case (let w?, nil), (nil, let w?):
                switch quality {
                case .small:
                    if w > 640 { return false }
                case .medium:
                    if w <= 640 || w > 1920 { return false }
                case .large:
                    if w <= 1920 { return false }
                case .any:
                    break
                }
            case (nil, nil):
                break
            }
        }
        return true
    }

    private func mimeExtension(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return nil
        }
    }
}