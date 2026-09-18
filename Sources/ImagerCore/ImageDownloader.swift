import Foundation
import AppKit

public enum ImageDownloader {
    private static let thumbnailCache = NSCache<NSString, NSImage>()
    private static let fileManager = FileManager.default

    /// Browser-like headers so hotlink-protecting CDNs serve the image instead
    /// of returning 403 to a bare CFNetwork request.
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Builds a request for an image resource with headers that mimic a real
    /// browser visit, including the source page as the referer when available.
    private static func request(for url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("image", forHTTPHeaderField: "Sec-Fetch-Dest")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func errorMessage(statusCode: Int) -> String {
        "Download failed (HTTP \(statusCode)) — the host blocks direct image downloads."
    }

    /// Layered attempts for a resource URL. Hotlink protection varies by CDN:
    /// some require the source page's referer, some require a referer matching
    /// the image's own host (and reject any other), and a few block referers
    /// entirely. Each failing variant escalates to the next instead of giving up.
    private static func requestVariants(for url: URL, sourceReferer: String?) -> [URLRequest] {
        var variants: [URLRequest] = []
        if let sourceReferer, !sourceReferer.isEmpty {
            variants.append(request(for: url, referer: sourceReferer))
        }
        if let host = url.host {
            variants.append(request(for: url, referer: "\(url.scheme ?? "https")://\(host)/"))
        }
        variants.append(request(for: url, referer: nil))
        return variants
    }

    private static func fetchData(from url: URL, sourceReferer: String?) async throws -> Data {
        var lastStatus = 0
        for request in requestVariants(for: url, sourceReferer: sourceReferer) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.server("Download failed — unexpected response.")
            }
            if 200..<300 ~= http.statusCode { return data }
            lastStatus = http.statusCode
        }
        throw ProviderError.server(errorMessage(statusCode: lastStatus))
    }

    public static func thumbnail(for urlString: String, size: CGSize, referer: String? = nil) async -> NSImage? {
        let cacheKey = "\(urlString)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }

        guard let url = URL(string: urlString),
              let data = try? await fetchData(from: url, sourceReferer: referer),
              let source = NSImage(data: data) else { return nil }

        let thumbnail = source.scaled(toFit: size)
        thumbnailCache.setObject(thumbnail, forKey: cacheKey)
        return thumbnail
    }

    /// Loads the full-resolution image, unscaled (best-effort; returns nil on failure).
    public static func image(from urlString: String, referer: String? = nil) async -> NSImage? {
        guard let url = URL(string: urlString),
              let data = try? await fetchData(from: url, sourceReferer: referer),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    /// A preview image plus whether it is only thumbnail quality.
    public struct LoadedImage: Sendable {
        public let image: NSImage
        public let isPreviewQuality: Bool
    }

    /// Best-effort full preview: direct fetch, then alternates scraped from
    /// the source page, then the thumbnail itself (which demonstrably loads,
    /// since the grid shows it). Returns nil only for dead links.
    public static func bestEffortImage(for result: ImageResult) async -> LoadedImage? {
        if let image = await image(from: result.fullURL, referer: result.sourcePageURL) {
            return LoadedImage(image: image, isPreviewQuality: false)
        }
        if let pageString = result.sourcePageURL, let pageURL = URL(string: pageString) {
            for candidate in await scrapedImageURLs(from: pageURL, referer: pageString) {
                if candidate.absoluteString == result.fullURL { continue }
                if let image = await image(from: candidate.absoluteString, referer: pageString) {
                    return LoadedImage(image: image, isPreviewQuality: false)
                }
            }
        }
        if let thumbURL = URL(string: result.thumbnailURL),
           let data = try? await fetchData(from: thumbURL, sourceReferer: result.sourcePageURL),
           let image = NSImage(data: data) {
            return LoadedImage(image: image, isPreviewQuality: true)
        }
        return nil
    }

    public static func imageData(from urlString: String, referer: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await fetchData(from: url, sourceReferer: referer)
    }

    /// Downloads the full image, saving a copy into `directory` with a unique filename,
    /// reporting progress (0...1) as bytes arrive. When the server omits a content
    /// length, `progress` is never called and callers should keep an indeterminate state.
    public static func downloadToDirectory(
        _ result: ImageResult,
        directory: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try await downloadBestEffort(result, directory: directory, progress: progress).url
    }

    /// Best-effort download with graceful fallbacks for hostile hosts:
    /// 1. Direct download with browser headers and referer variants.
    /// 2. Scrape the source page for an alternate image URL (og:image, etc.).
    /// 3. Save the already-visible preview thumbnail instead of failing.
    /// Only dead links (or a missing thumbnail) still throw.
    public static func downloadBestEffort(
        _ result: ImageResult,
        directory: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadOutcome {
        guard let url = URL(string: result.fullURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let destination = try? await downloadStreamed(
            from: url, sourceReferer: result.sourcePageURL, directory: directory,
            fileName: result.suggestedFileName, progress: progress
        ) {
            return DownloadOutcome(url: destination, isPreviewQuality: false)
        }
        if let pageString = result.sourcePageURL, let pageURL = URL(string: pageString) {
            for candidate in await scrapedImageURLs(from: pageURL, referer: pageString) {
                if candidate.absoluteString == result.fullURL { continue }
                if let destination = try? await downloadStreamed(
                    from: candidate, sourceReferer: pageString, directory: directory,
                    fileName: fileName(suggested: result.suggestedFileName, for: candidate), progress: progress
                ) {
                    return DownloadOutcome(url: destination, isPreviewQuality: false)
                }
            }
        }
        if let thumbURL = URL(string: result.thumbnailURL),
           let data = try? await fetchData(from: thumbURL, sourceReferer: result.sourcePageURL) {
            let destination = try ensureUniqueFileURL(
                directory: directory,
                fileName: fileName(suggested: result.suggestedFileName, for: thumbURL)
            )
            try data.write(to: destination)
            return DownloadOutcome(url: destination, isPreviewQuality: true)
        }
        throw ProviderError.server(errorMessage(statusCode: 403))
    }

    /// Downloads the full image, saving a copy into `directory` with a unique filename.
    public static func downloadToDirectory(_ result: ImageResult, directory: URL) async throws -> URL {
        try await downloadToDirectory(result, directory: directory, progress: nil)
    }

    /// Result of a best-effort download: the saved file, plus whether it is
    /// only preview quality (full file refused, thumbnail saved instead).
    public struct DownloadOutcome: Sendable {
        public let url: URL
        public let isPreviewQuality: Bool
    }

    /// Streams one URL through the referer variants, saving on the first
    /// 2xx response. Returns nil when every variant is refused.
    private static func downloadStreamed(
        from url: URL,
        sourceReferer: String?,
        directory: URL,
        fileName: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL? {
        for request in requestVariants(for: url, sourceReferer: sourceReferer) {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.server("Download failed — unexpected response.")
            }
            guard 200..<300 ~= http.statusCode else { continue }
            let expected = http.expectedContentLength
            var data = Data()
            if expected > 0 { data.reserveCapacity(Int(min(expected, 100_000_000))) }
            var received: Int64 = 0
            var lastReported: Int64 = 0
            for try await byte in stream {
                data.append(byte)
                received += 1
                if let progress, expected > 0 {
                    // Throttle to roughly 1%-steps so large files don't flood callers
                    // (every unthrottled update used to spawn a main-actor Task).
                    let step = max(expected / 100, 64 * 1024)
                    if received >= lastReported + step || received >= expected {
                        lastReported = received
                        progress(Double(received) / Double(expected))
                    }
                }
            }
            let destination = try ensureUniqueFileURL(directory: directory, fileName: fileName)
            try data.write(to: destination)
            return destination
        }
        return nil
    }

    /// Pulls alternate image URLs out of a source page (og:image,
    /// twitter:image, image_src), resolved against the page URL. Limited to a
    /// handful of candidates so a hostile page can't trigger many downloads.
    private static func scrapedImageURLs(from pageURL: URL, referer: String?) async -> [URL] {
        guard let htmlData = try? await fetchData(from: pageURL, sourceReferer: referer),
              let html = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .isoLatin1) else { return [] }
        let head = String(html.prefix(200_000))
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image["']"#,
            #"<link[^>]+rel=["']image_src["'][^>]+href=["']([^"']+)["']"#,
            #"<link[^>]+href=["']([^"']+)["'][^>]+rel=["']image_src["']"#,
        ]
        var seen = Set<String>()
        var ordered: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  ordered.count < 5 else { continue }
            let range = NSRange(head.startIndex..., in: head)
            for match in regex.matches(in: head, range: range) {
                guard ordered.count < 5,
                      let capture = Range(match.range(at: 1), in: head) else { break }
                let raw = String(head[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, seen.insert(raw).inserted,
                      let resolved = URL(string: raw, relativeTo: pageURL)?.absoluteURL,
                      let scheme = resolved.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                ordered.append(resolved)
            }
        }
        return ordered
    }

    /// Keeps the suggested file name but swaps in the candidate URL's image
    /// extension when it has a sane one (thumbnails often differ in format).
    private static func fileName(suggested: String, for url: URL) -> String {
        let allowed = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "tif", "tiff", "svg", "ico"]
        let ext = url.pathExtension.lowercased()
        guard allowed.contains(ext) else { return suggested }
        let base = (suggested as NSString).deletingPathExtension
        return "\(base).\(ext)"
    }

    /// Writes an image copy into a temp folder for use as a drag payload.
    public static func downloadToTempFile(_ result: ImageResult) async throws -> URL {
        let data = try await imageData(from: result.fullURL)
        let directory = fileManager.temporaryDirectory.appendingPathComponent("ImagerDrag", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let destination = try ensureUniqueFileURL(directory: directory, fileName: result.suggestedFileName)
        try data.write(to: destination)
        return destination
    }

    public static func ensureUniqueFileURL(directory: URL, fileName: String) throws -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

extension NSImage {
    func scaled(toFit maxSize: CGSize) -> NSImage {
        guard maxSize.width > 0, maxSize.height > 0 else { return self }
        let target = aspectFitSize(in: maxSize)
        let image = NSImage(size: target)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        return image
    }

    private func aspectFitSize(in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let f = min(max(scale, 0.1), 4)
        return CGSize(width: size.width * f, height: size.height * f)
    }
}