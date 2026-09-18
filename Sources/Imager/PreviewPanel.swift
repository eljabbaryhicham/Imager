import SwiftUI
import AppKit
import WebKit
import ImagerCore

/// A dedicated, resizable window showing one result at full size with actions.
final class PreviewPanel: NSPanel, @unchecked Sendable {
    private let hostingController: NSHostingController<PreviewView>

    init(result: ImageResult, favorites: FavoritesStore, settings: SettingsStore, showingSource: Bool = false) {
        let view = PreviewView(result: result, favorites: favorites, settings: settings, startsOnSource: showingSource)
        let hosting = NSHostingController(rootView: view)
        self.hostingController = hosting

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 980),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 880, height: 740)
        contentViewController = hosting
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Borderless panels must opt into becoming key so Esc, download focus,
    /// and the custom close control keep working without a title bar.
    override var canBecomeKey: Bool { true }

    /// Esc closes the preview even when the embedded web view holds keyboard
    /// focus (where SwiftUI's exit command never arrives). When SwiftUI does
    /// handle Esc (backing out of the source view), the event never reaches here.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Full-size preview with glass styling, download progress, favorite toggle and drag.
struct PreviewView: View {
    let result: ImageResult
    @Bindable var favorites: FavoritesStore
    let settings: SettingsStore

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var isPreviewQuality = false
    @State private var showingSource: Bool
    @State private var downloadProgress: Double?
    @State private var toast: ToastMessage?
    @State private var toastDismissal: Task<Void, Never>?

    init(result: ImageResult, favorites: FavoritesStore, settings: SettingsStore, startsOnSource: Bool = false) {
        self.result = result
        self.favorites = favorites
        self.settings = settings
        self._showingSource = State(initialValue: startsOnSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.white.opacity(0.06))

            imageArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .windowDragExcluded()

            Divider()
                .overlay(Color.white.opacity(0.06))

            infoFooter
        }
        .background(Theme.panelMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .windowDraggable()
        .themeAware(settings.theme)
        .onExitCommand {
            if showingSource {
                showingSource = false
            } else {
                NSApp.keyWindow?.close()
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastBanner(message: toast)
                    .padding(.bottom, 70)
            }
        }
        .task(id: result.id) {
            isLoading = true
            isPreviewQuality = false
            if let loaded = await ImageDownloader.bestEffortImage(for: result) {
                image = loaded.image
                isPreviewQuality = loaded.isPreviewQuality
            }
            isLoading = false
        }
        .animation(.easeInOut(duration: 0.15), value: toast)
        .animation(.easeOut(duration: 0.25), value: isLoading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            if showingSource {
                Button {
                    showingSource = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Back to image")
                .glassSurface(cornerRadius: 22)
                .windowDragExcluded()
            }

            Text(headerTitle)
                .font(.title2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                favorites.toggle(result)
            } label: {
                Image(systemName: favorites.isFavorite(result) ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(favorites.isFavorite(result) ? Theme.accent : Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .help(favorites.isFavorite(result) ? "Remove from Favorites" : "Save to Favorites")
            .glassSurface(cornerRadius: 22)
            .windowDragExcluded()

            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(Theme.textPrimary)
                    .glassSurface(cornerRadius: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Preview (Esc)")
            .windowDragExcluded()
        }
        .padding(18)
    }

    private var headerTitle: String {
        if showingSource { return "Source page" }
        return result.title.isEmpty ? "Preview" : result.title
    }

    @ViewBuilder
    private var imageArea: some View {
        if showingSource {
            if let page = result.sourcePageURL, let url = URL(string: page) {
                SourcePageWebView(url: url)
            } else {
                ContentUnavailableView {
                    Label("No source page", systemImage: "safari")
                } description: {
                    Text("This result doesn't include a page to preview.")
                }
            }
        } else if isLoading {
            ProgressView("Loading preview…")
        } else if let image {
            ImagePreview(nsImage: image, result: result, settings: settings)
                .transition(.opacity.combined(with: .scale(0.98)))
        } else {
            ContentUnavailableView {
                Label("Couldn't load the image", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The provider may have restricted this file.")
            }
        }
    }

    private var infoFooter: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                Text(result.providerID)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                if let width = result.width, let height = result.height {
                    Text("· \(width) × \(height)")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                if isPreviewQuality {
                    Text("· preview quality")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            if let downloadProgress {
                DownloadProgressRing(progress: downloadProgress)
                    .frame(width: 44, height: 44)
                    .help("Downloading…")
            }

            Button {
                download()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Theme.accentGlow, radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(downloadProgress != nil)
            .help("Download to save folder")
            .windowDragExcluded()

            if result.sourcePageURL != nil {
                Button {
                    showingSource.toggle()
                } label: {
                    Image(systemName: showingSource ? "photo" : "safari")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showingSource ? Theme.accent : Theme.textPrimary)
                .help(showingSource ? "Show the image" : "Preview source page")
                .windowDragExcluded()
            }

            if let page = result.sourcePageURL, let url = URL(string: page) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 46, height: 46)
                }
                .tint(Theme.accent)
                .help("Open source page in browser")
                .windowDragExcluded()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func download() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        Task { @MainActor in
            do {
                let outcome = try await ImageDownloader.downloadBestEffort(
                    result,
                    directory: settings.saveDirectoryURL,
                    progress: { fraction in
                        Task { @MainActor in
                            if downloadProgress != nil {
                                downloadProgress = fraction
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
            downloadProgress = nil
        }
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

/// Resizable, drag-capable full image fitted to the available space.
struct ImagePreview: View {
    let nsImage: NSImage
    let result: ImageResult
    let settings: SettingsStore

    @State private var dragSession: DragSession?

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    // Opening the preview is explicit intent: warm the drag
                    // file now so a later drop hands over a concrete file.
                    if dragSession == nil {
                        dragSession = DragSession(result: result, settings: settings)
                    }
                    dragSession?.prefetchTemp()
                }
                .onDisappear {
                    dragSession?.cancelPrefetch()
                }
                .onDrag {
                    let session = dragSession ?? DragSession(result: result, settings: settings)
                    return ImageDragFactory.makeProvider(result: result, session: session)
                }
                .help("Drag the image into any app")
        }
    }
}

/// Loads an image's source page inside the preview window so users can inspect
/// it without leaving Imager. Backed by WKWebView (WebKit ships with macOS).
struct SourcePageWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        nsView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
    }
}