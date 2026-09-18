import SwiftUI
import AppKit
import ImagerCore

/// Drawer-glide state for the main panel's expand/collapse. The resize
/// observer (which outlives any single SwiftUI view value) uses it to re-pin
/// the panel's top edge on every step of the animated 90↔740 resize, so the
/// search row never moves while the panel glides open downward.
final class PanelGlide {
    var anchorTop: CGFloat = 0
    var pinUntil = Date.distantPast
    var corrections = 0
}

@MainActor
@Observable
final class ApplicationModel {
    let settings: SettingsStore
    let favorites: FavoritesStore
    let search: SearchViewModel
    let panelGlide = PanelGlide()
    private var panel: FloatingPanel?
    private var settingsPanel: SettingsPanel?
    /// Remembers whether the main panel was ever placed: centering runs only
    /// for the first show, so hiding/showing never yanks the window back from
    /// where the user dragged it.
    private var didPlacePanel = false

    /// Injected by the app delegate so the settings panel can re-register the
    /// global shortcut handler.
    var onGlobalShortcutChanged: (() -> Void)?

    /// Injected by the app delegate; informs it when the menu-bar icon setting
    /// changes so the status item can be created or removed.
    var onStatusItemVisibilityChanged: (() -> Void)?

    /// Injected by the app delegate; informs it when the Dock icon setting
    /// changes so the activation policy can be switched.
    var onDockVisibilityChanged: (() -> Void)?

    init() {
        self.settings = SettingsStore()
        self.favorites = FavoritesStore()
        self.search = SearchViewModel(providers: Self.makeProviders(settings: settings))
    }

    func refreshProviders() {
        search.refreshProviders(providers: Self.makeProviders(settings: settings))
    }

    private static func makeProviders(settings: SettingsStore) -> [any ImageSearchProvider] {
        ProviderRegistry.make(
            unsplashKey: settings.apiKey(for: "unsplash"),
            pexelsKey: settings.apiKey(for: "pexels"),
            pixabayKey: settings.apiKey(for: "pixabay"),
            googleKey: settings.apiKey(for: "google")
        )
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            ImagerLog.log("panel hide (toggle)")
        } else {
            showPanel()
        }
    }

    func hidePanel() {
        panel?.orderOut(nil)
        ImagerLog.log("panel hide")
    }

    func showSettings() {
        let panel = settingsPanel ?? makeSettingsPanel()
        panel.show()
    }

    func hideSettings() {
        settingsPanel?.orderOut(nil)
    }

    func showPanel() {
        let panel = panel ?? makePanel()
        if !didPlacePanel {
            placePanelTopCenter(panel)
            didPlacePanel = true
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ImagerLog.log("panel show visible=\(panel.isVisible) appActive=\(NSApp.isActive)")
    }

    /// Places the panel horizontally centered but hanging from near the top of
    /// the screen (Spotlight-style), instead of dead center. The panel grows
    /// from 90pt to 740pt when expanded; centered placement would push its
    /// bottom off-screen and macOS would shove the whole window up to fit —
    /// the visible "jump". Top placement leaves room below so it grows
    /// downward without the window server relocating it.
    private func placePanelTopCenter(_ panel: FloatingPanel) {
        panel.center()
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let top = min(panel.frame.maxY, visible.maxY - 120)
        var origin = panel.frame.origin
        origin.y = max(top - panel.frame.height, visible.minY)
        panel.setFrameOrigin(origin)
        ImagerLog.log("panel placed top=\(Int(top)) screenH=\(Int(visible.height))")
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820))
        let hostingController = NSHostingController(
            rootView: FloatingContentView(
                settings: settings,
                search: search,
                favorites: favorites,
                glide: panelGlide,
                onHide: { [weak self] in self?.hidePanel() },
                onShowSettings: { [weak self] in self?.showSettings() }
            )
        )
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        self.panel = panel
        installTopPinObserver(for: panel)
        return panel
    }

    /// Re-pins the panel's top edge to the glide anchor on every resize while
    /// a drawer-glide is running. SwiftUI animates the 90↔740 size change
    /// around a fixed bottom edge; without this the search row would ride up
    /// and down. `setFrameOrigin` posts a move (not a resize), so this cannot
    /// recurse.
    private func installTopPinObserver(for panel: FloatingPanel) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel, Date() < self.panelGlide.pinUntil else { return }
            var origin = panel.frame.origin
            origin.y = self.panelGlide.anchorTop - panel.frame.height
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
            }
            panel.setFrameOrigin(origin)
            self.panelGlide.corrections += 1
        }
    }

    private func makeSettingsPanel() -> SettingsPanel {
        let panel = SettingsPanel(
            settings: settings,
            onProvidersChanged: { [weak self] in self?.refreshProviders() },
            onGlobalShortcutChanged: { [weak self] in self?.onGlobalShortcutChanged?() },
            onStatusItemVisibilityChanged: { [weak self] in self?.onStatusItemVisibilityChanged?() },
            onDockVisibilityChanged: { [weak self] in self?.onDockVisibilityChanged?() },
            onClose: { [weak self] in self?.hideSettings() }
        )
        self.settingsPanel = panel
        return panel
    }
}