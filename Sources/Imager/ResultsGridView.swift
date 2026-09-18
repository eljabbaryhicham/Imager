import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImagerCore

// MARK: - Drag payloads

@MainActor
final class DragSession {
    let result: ImageResult
    let settings: SettingsStore
    private var memoizedURL: URL?
    private var tempURL: URL?
    private var prefetchTask: Task<URL?, Never>?

    init(result: ImageResult, settings: SettingsStore) {
        self.result = result
        self.settings = settings
    }

    /// Starts downloading the full image to a temp file in the background.
    /// Always temp — never the save directory — so hovering has no visible
    /// side effects. Safe to call repeatedly; cancelled via cancelPrefetch().
    func prefetchTemp() {
        if tempURL != nil || prefetchTask != nil { return }
        prefetchTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let url = try await ImageDownloader.downloadToTempFile(self.result)
                self.tempURL = url
                return url
            } catch {
                return nil
            }
        }
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// A file URL that already exists on disk, for synchronous handoff to
    /// strict drop targets (Premiere, etc.) that reject async promises.
    var readyTempURL: URL? {
        guard let tempURL,
              FileManager.default.fileExists(atPath: tempURL.path) else { return nil }
        return tempURL
    }

    /// The file handed to the drop target. When auto-save is enabled this is the
    /// persisted copy in the save directory; otherwise a temp copy.
    func resourceURL() async throws -> URL {
        if let memoizedURL { return memoizedURL }
        let url: URL
        if settings.autoSaveOnDrag {
            url = try await ImageDownloader.downloadToDirectory(result, directory: settings.saveDirectoryURL)
        } else if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) {
            url = tempURL
        } else {
            url = try await ImageDownloader.downloadToTempFile(result)
        }
        memoizedURL = url
        return url
    }
}

enum ImageDragFactory {
    @MainActor
    static func makeProvider(result: ImageResult, session: DragSession) -> NSItemProvider {
        // Fast path: the file is already on disk (prefetched on hover), so
        // hand over a concrete file URL synchronously. Strict drop targets
        // (Premiere, etc.) only accept real files, not async promises.
        if let url = session.readyTempURL, let provider = NSItemProvider(contentsOf: url) {
            provider.suggestedName = result.suggestedFileName
            if session.settings.autoSaveOnDrag {
                // Preserve "save a copy automatically when dragging" without
                // blocking the drop on the save-directory download.
                Task { @MainActor in
                    _ = try? await session.resourceURL()
                }
            }
            return provider
        }

        let provider = NSItemProvider()
        // Without this, targets that take the image-data representation
        // (e.g. Finder) invent a generic name like "PNG image.png".
        provider.suggestedName = result.suggestedFileName

        if let type = UTType(filenameExtension: result.fileExtension, conformingTo: .image) {
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                Task { @MainActor in
                    do {
                        let url = try await session.resourceURL()
                        completion(url, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return nil
            }
        }

        provider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { completion in
            Task {
                do {
                    let data = try await ImageDownloader.imageData(from: result.fullURL)
                    completion(data, nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }

        return provider
    }
}

// MARK: - Remote thumbnail

struct RemoteThumb: View {
    let url: String
    let referer: String?

    @State private var image: NSImage?
    @State private var revealed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(revealed ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: revealed)
                } else {
                    Color(nsColor: .quaternaryLabelColor)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: "\(url)|\(referer ?? "")") {
            image = await ImageDownloader.thumbnail(for: url, size: CGSize(width: 520, height: 480), referer: referer)
            revealed = true
        }
    }
}

// MARK: - Shared result cell

struct ResultCell: View {
    let result: ImageResult
    let isFavorite: Bool
    @Bindable var settings: SettingsStore
    let isDownloading: Bool
    let downloadProgress: Double?
    let onDownload: () -> Void
    let onToggleFavorite: () -> Void
    let onPreview: () -> Void
    let onOpenSourcePage: (() -> Void)?
    let onCopyFeedback: (String) -> Void
    let isSelected: Bool
    let thumbnailHeight: CGFloat

    @State private var isHovered = false
    @State private var dragSession: DragSession?
    @State private var previewImage: NSImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var showHoverPreview = false

    init(
        result: ImageResult,
        isFavorite: Bool,
        settings: SettingsStore,
        isDownloading: Bool,
        downloadProgress: Double?,
        onDownload: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onPreview: @escaping () -> Void,
        onOpenSourcePage: (() -> Void)? = nil,
        onCopyFeedback: @escaping (String) -> Void,
        isSelected: Bool = false,
        thumbnailHeight: CGFloat = 270
    ) {
        self.result = result
        self.isFavorite = isFavorite
        self._settings = Bindable(wrappedValue: settings)
        self.isDownloading = isDownloading
        self.downloadProgress = downloadProgress
        self.onDownload = onDownload
        self.onToggleFavorite = onToggleFavorite
        self.onPreview = onPreview
        self.onOpenSourcePage = onOpenSourcePage
        self.onCopyFeedback = onCopyFeedback
        self.isSelected = isSelected
        self.thumbnailHeight = thumbnailHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                RemoteThumb(url: result.thumbnailURL, referer: result.sourcePageURL)
                    .frame(height: thumbnailHeight)

                if isDownloading {
                    if let downloadProgress {
                        DownloadProgressRing(progress: downloadProgress)
                            .padding(8)
                            .background(Theme.popoverMaterial, in: Circle())
                            .help("Downloading…")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(6)
                            .background(Theme.popoverMaterial, in: Circle())
                            .help("Downloading…")
                    }
                }

                ViewThatFits(in: .horizontal) {
                    hoverBarLabeled
                    hoverBarIcons
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.popoverMaterial)
            }
            .frame(height: thumbnailHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title.isEmpty ? "Image" : result.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(result.sourceWebsiteName)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.surface)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .overlay(alignment: .topLeading) {
            if let width = result.width, let height = result.height {
                Text("\(width)×\(height)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.popoverMaterial, in: Capsule())
                    .padding(10)
                    .accessibilityLabel("Image dimensions \(width) by \(height) pixels")
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: result.width)
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(10)
                    .background(Theme.popoverMaterial, in: Circle())
                    .padding(10)
                    .accessibilityLabel("Favorited")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isFavorite)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((isSelected || isHovered) ? Theme.accent : Color.clear, lineWidth: 2)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onTapGesture { onPreview() }
        .onHover {
            isHovered = $0
            // Warm the drag file while the pointer rests here so a later
            // drop can hand over a concrete file instantly. Cancelled as
            // soon as the pointer leaves, so fly-bys cost nothing.
            if $0 {
                if dragSession == nil {
                    dragSession = DragSession(result: result, settings: settings)
                }
                dragSession?.prefetchTemp()
                startHoverPreview()
            } else {
                dragSession?.cancelPrefetch()
                cancelHoverPreview()
            }
        }
        .onDisappear {
            dragSession?.cancelPrefetch()
            cancelHoverPreview()
        }
        .onChange(of: settings.hoverPreviewsEnabled) {
            if !settings.hoverPreviewsEnabled {
                cancelHoverPreview()
            }
        }
        .popover(isPresented: $showHoverPreview) {
            VStack(spacing: 10) {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Text(result.title)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 480)
                if let width = result.width, let height = result.height {
                    Text("\(width) × \(height) · \(result.providerID)")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(width: 520)
            .background(Theme.popoverMaterial)
            // Informational only: never intercept the pointer, otherwise moving
            // across cards passes over the popover,enter/exit events stop
            // reaching the cells, and the green border gets stuck on the old card.
            .allowsHitTesting(false)
        }
        .onDrag {
            // A file drag starting here must dismiss the hover preview:
            // hover-exit never fires after the drop lands elsewhere,
            // which would otherwise leave the popover stuck open.
            cancelHoverPreview()
            let session = dragSession ?? DragSession(result: result, settings: settings)
            return ImageDragFactory.makeProvider(result: result, session: session)
        }
        .contextMenu {
            Button("Preview") { onPreview() }
            Button("Download") { onDownload() }
            Button(isFavorite ? "Remove from Favorites" : "Save to Favorites") { onToggleFavorite() }
            Button("Copy image URL") { copyImageUrl() }
            if result.sourcePageURL != nil {
                Button("Copy source page URL") { copySourcePageUrl() }
            }
            if let page = result.sourcePageURL, let url = URL(string: page) {
                Divider()
                Link("Open source page", destination: url)
            }
        }
        .help(result.title)
    }

    /// Full labeled hover bar, used when the tile is wide enough to fit it
    /// on one line. Narrower tiles fall back to `hoverBarIcons`.
    private var hoverBarLabeled: some View {
        HStack(spacing: 2) {
            hoverAction(icon: "square.and.arrow.down", text: "Save", help: "Download to save folder", action: onDownload)
            hoverAction(icon: "magnifyingglass", text: "View", help: "Preview", action: onPreview)
            favoriteButton
            hoverAction(icon: "copy", text: "Copy URL", help: "Copy full image URL", action: copyImageUrl)
            if result.sourcePageURL != nil, let onOpenSourcePage {
                hoverAction(icon: "arrow.up.right.square", text: "Source", help: "Preview source page", action: onOpenSourcePage)
            }
            Spacer(minLength: 0)
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .help("Drag into any app — a copy is saved automatically")
        }
    }

    /// Icon-only hover bar for narrow tiles where labels would wrap.
    private var hoverBarIcons: some View {
        HStack(spacing: 14) {
            iconButton(icon: "square.and.arrow.down", help: "Download to save folder", action: onDownload)
            iconButton(icon: "magnifyingglass", help: "Preview", action: onPreview)
            favoriteButton
            iconButton(icon: "copy", help: "Copy full image URL", action: copyImageUrl)
            if result.sourcePageURL != nil, let onOpenSourcePage {
                iconButton(icon: "arrow.up.right.square", help: "Preview source page", action: onOpenSourcePage)
            }
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 18))
                .foregroundStyle(isFavorite ? Theme.accent : .primary)
                .shadow(color: isFavorite ? Theme.accentGlow : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Save to Favorites")
    }

    private func iconButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Icon + text action for the hover bar, so actions are labeled and
    /// tappable without guessing what each glyph means.
    private func hoverAction(icon: String, text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(text)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help(help)
    }
    
    /// Copies URLs to the macOS clipboard.
    private func copyImageUrl() {
        copyString(result.fullURL, feedback: "Copied image URL")
    }

    private func copySourcePageUrl() {
        guard let sourcePageURL = result.sourcePageURL else { return }
        copyString(sourcePageURL, feedback: "Copied source page URL")
    }

    private func copyString(_ string: String, feedback: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        onCopyFeedback(feedback)
    }

    /// Shows a larger cached preview after a short hover delay. Fly-bys never
    /// trigger a download because the pending request is cancelled on exit.
    private func startHoverPreview() {
        guard settings.hoverPreviewsEnabled else { return }
        // Never pop a preview while a mouse button is held: hovering other
        // tiles mid-file-drag must not open (and strand) popovers.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            guard let image = await ImageDownloader.thumbnail(
                for: result.fullURL,
                size: CGSize(width: 560, height: 420),
                referer: result.sourcePageURL
            ) else { return }
            guard !Task.isCancelled else { return }
            // The pointer may have moved on while the thumbnail was loading;
            // never pop (or re-light) a card that is no longer hovered.
            guard isHovered else { return }
            previewImage = image
            showHoverPreview = true
        }
    }

    private func cancelHoverPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewImage = nil
        showHoverPreview = false
    }
}

/// Small determinate ring showing download progress as a fraction (0...1).
struct DownloadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Toast feedback

enum ToastKind {
    case success
    case error
    case info

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: Theme.accent
        case .error: .red
        case .info: Theme.textSecondary
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String?
    let kind: ToastKind

    init(title: String, detail: String? = nil, kind: ToastKind = .info) {
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

struct ToastBanner: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: message.kind.icon)
                .font(.system(size: 20))
                .foregroundStyle(message.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let detail = message.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.popoverMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(message.kind.color.opacity(0.35), lineWidth: 1)
        )
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("\(message.title). \(message.detail ?? "")")
    }
}

// MARK: - Loading skeleton

struct SearchSkeletonView: View {
    let tileHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Searching…")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: tileHeight)
                }
            }
            .padding(6)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Searching for images")
    }
}

// MARK: - Search results grid

struct ResultsGridView: View {
    @Bindable var search: SearchViewModel
    @Bindable var favorites: FavoritesStore
    let settings: SettingsStore

    @State private var toast: ToastMessage?
    @State private var toastDismissal: Task<Void, Never>?
    @State private var downloadingProgress: [String: Double] = [:]
    @State private var previewPanel: PreviewPanel?
    @State private var selectedID: String?
    @FocusState private var gridFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if let toast {
                ToastBanner(message: toast)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: toast)
        .animation(.easeOut(duration: 0.25), value: search.results.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if search.isLoading && search.results.isEmpty {
            // Scroll-bounded so the tall placeholder grid can never push the
            // window taller while loading (which visibly shoved the top rows
            // up, then down again when results arrived).
            ScrollView {
                SearchSkeletonView(tileHeight: search.gridDensity.tileHeight)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else if let message = search.errorMessage, search.results.isEmpty {
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        } else if search.results.isEmpty {
            if search.hasSearched {
                let providerName = search.selectedProvider?.displayName ?? "the selected provider"
                ContentUnavailableView {
                    Label("No matching images", systemImage: "photo")
                } description: {
                    Text("No matches in \(providerName) for “\(search.query)” with \(search.quality.label.lowercased()) and \(search.format.label.lowercased()).")
                } actions: {
                    if search.quality != .any || search.format != .any {
                        Button("Reset filters") { search.resetFilters() }
                    }
                }
            } else {
                if search.providerOptions.isEmpty {
                    ContentUnavailableView {
                        Label("No image source", systemImage: "photo.badge.plus")
                    } description: {
                        Text("Open Settings from the menu bar and add at least one provider API key.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Search the web", systemImage: "magnifyingglass")
                    } description: {
                        Text("Type a query and press Return. Click the results, then use arrow keys to move and Return to preview.")
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: search.gridDensity.minimumWidth), spacing: 16)], spacing: 16) {
                            ForEach(search.sortedResults) { result in
                                cell(for: result)
                                    .id(result.id)
                            }
                        }
                        .padding(4)
                        .padding(.bottom, 48)

                        if search.isLoadingMore {
                            ProgressView()
                                .controlSize(.large)
                                .padding(.bottom, 40)
                        } else if search.hasMore {
                            Button("Load more") {
                                search.loadMore()
                            }
                            .buttonStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.bottom, 40)
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($gridFocused)
                    .onKeyPress(.leftArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -columnStep)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: columnStep)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        openSelectedPreview()
                        return .handled
                    }
                    .onChange(of: selectedID) {
                        if let selectedID {
                            withAnimation {
                                proxy.scrollTo(selectedID, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: search.results.map(\.id)) {
                        selectedID = nil
                        // Temporary diagnostic: captures the window frame the
                        // moment results arrive and 0.5s later, to catch any
                        // push-and-return transient tied to image loading.
                        if let window = NSApp.windows.first(where: { $0 is FloatingPanel }) {
                            let f = window.frame
                            ImagerLog.log("results arrived frame=\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width))x\(Int(f.size.height))")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                let g = window.frame
                                ImagerLog.log("results settled frame=\(Int(g.origin.x)),\(Int(g.origin.y)),\(Int(g.size.width))x\(Int(g.size.height))")
                            }
                        }
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private var columnStep: Int {
        search.gridDensity == .compact ? 4 : 3
    }

    private func moveSelection(by offset: Int) {
        let ids = search.sortedResults.map(\.id)
        guard !ids.isEmpty else { return }
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            let next = min(max(index + offset, 0), ids.count - 1)
            self.selectedID = ids[next]
        } else {
            self.selectedID = offset > 0 ? ids[0] : ids[ids.count - 1]
        }
    }

    private func openSelectedPreview() {
        guard let selectedID,
              let result = search.sortedResults.first(where: { $0.id == selectedID }) else { return }
        openPreview(result)
    }

    private func cell(for result: ImageResult) -> some View {
        ResultCell(
            result: result,
            isFavorite: favorites.isFavorite(result),
            settings: settings,
            isDownloading: downloadingProgress[result.id] != nil,
            downloadProgress: downloadingProgress[result.id],
            onDownload: { download(result) },
            onToggleFavorite: { favorites.toggle(result) },
            onPreview: { openPreview(result) },
            onOpenSourcePage: { openSourcePage(result) },
            onCopyFeedback: { title in
                showToast(ToastMessage(title: title, kind: .success))
            },
            isSelected: result.id == selectedID,
            thumbnailHeight: search.gridDensity.tileHeight
        )
    }

    private func download(_ result: ImageResult) {
        guard downloadingProgress[result.id] == nil else { return }
        downloadingProgress[result.id] = 0
        Task { @MainActor in
            do {
                let outcome = try await ImageDownloader.downloadBestEffort(
                    result,
                    directory: settings.saveDirectoryURL,
                    progress: { [id = result.id] fraction in
                        Task { @MainActor in
                            if downloadingProgress[id] != nil {
                                downloadingProgress[id] = fraction
                            }
                        }
                    }
                )
                if outcome.isPreviewQuality {
                    showToast(ToastMessage(title: "Saved preview", detail: "\(outcome.url.lastPathComponent) — full image blocked by host", kind: .success))
                } else {
                    showToast(ToastMessage(title: "Saved", detail: outcome.url.lastPathComponent, kind: .success))
                }
            } catch {
                showToast(ToastMessage(title: "Download failed", detail: error.localizedDescription, kind: .error))
            }
            downloadingProgress.removeValue(forKey: result.id)
        }
    }

    private func openPreview(_ result: ImageResult) {
        previewPanel?.close()
        let panel = PreviewPanel(
            result: result,
            favorites: favorites,
            settings: settings
        )
        panel.show()
        previewPanel = panel
    }

    private func openSourcePage(_ result: ImageResult) {
        previewPanel?.close()
        let panel = PreviewPanel(
            result: result,
            favorites: favorites,
            settings: settings,
            showingSource: true
        )
        panel.show()
        previewPanel = panel
    }

    private func showToast(_ message: ToastMessage) {
        toastDismissal?.cancel()
        toast = message
        toastDismissal = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            if toast == message {
                toast = nil
            }
        }
    }
}

// MARK: - Favorites view

struct FavoritesView: View {
    @Bindable var favorites: FavoritesStore
    let settings: SettingsStore

    @State private var toast: ToastMessage?
    @State private var toastDismissal: Task<Void, Never>?
    @State private var downloadingProgress: [String: Double] = [:]
    @State private var previewPanel: PreviewPanel?

    var body: some View {
        ZStack(alignment: .bottom) {
            if favorites.items.isEmpty {
                ContentUnavailableView {
                    Label("No favorites yet", systemImage: "heart")
                } description: {
                    Text("Tap the heart on any search result to keep it here.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(favorites.items) { item in
                            ResultCell(
                                result: item.image,
                                isFavorite: true,
                                settings: settings,
                                isDownloading: downloadingProgress[item.image.id] != nil,
                                downloadProgress: downloadingProgress[item.image.id],
                                onDownload: { download(item.image) },
                                onToggleFavorite: { favorites.toggle(item.image) },
                                onPreview: { openPreview(item.image) },
                                onOpenSourcePage: { openSourcePage(item.image) },
                                onCopyFeedback: { title in
                                    showToast(ToastMessage(title: title, kind: .success))
                                }
                            )
                        }
                    }
                    .padding(4)
                    .padding(.bottom, 16)
                }
            }

            if let toast {
                ToastBanner(message: toast)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: toast)
    }

    private func download(_ result: ImageResult) {
        guard downloadingProgress[result.id] == nil else { return }
        downloadingProgress[result.id] = 0
        Task { @MainActor in
            do {
                let outcome = try await ImageDownloader.downloadBestEffort(
                    result,
                    directory: settings.saveDirectoryURL,
                    progress: { [id = result.id] fraction in
                        Task { @MainActor in
                            if downloadingProgress[id] != nil {
                                downloadingProgress[id] = fraction
                            }
                        }
                    }
                )
                if outcome.isPreviewQuality {
                    showToast(ToastMessage(title: "Saved preview", detail: "\(outcome.url.lastPathComponent) — full image blocked by host", kind: .success))
                } else {
                    showToast(ToastMessage(title: "Saved", detail: outcome.url.lastPathComponent, kind: .success))
                }
            } catch {
                showToast(ToastMessage(title: "Download failed", detail: error.localizedDescription, kind: .error))
            }
            downloadingProgress.removeValue(forKey: result.id)
        }
    }

    private func openPreview(_ result: ImageResult) {
        previewPanel?.close()
        let panel = PreviewPanel(
            result: result,
            favorites: favorites,
            settings: settings
        )
        panel.show()
        previewPanel = panel
    }

    private func openSourcePage(_ result: ImageResult) {
        previewPanel?.close()
        let panel = PreviewPanel(
            result: result,
            favorites: favorites,
            settings: settings,
            showingSource: true
        )
        panel.show()
        previewPanel = panel
    }

    private func showToast(_ message: ToastMessage) {
        toastDismissal?.cancel()
        toast = message
        toastDismissal = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            if toast == message {
                toast = nil
            }
        }
    }
}