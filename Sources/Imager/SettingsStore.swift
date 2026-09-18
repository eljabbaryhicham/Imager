import AppKit
import Foundation
import Observation
import ImagerCore
import ServiceManagement

@MainActor
@Observable
final class SettingsStore {
    static let saveDirectoryKey = "Imager.saveDirectoryPath"
    static let autoSaveKey = "Imager.autoSaveOnDrag"
    static let shortcutKey = "Imager.globalShortcutEnabled"
    static let hotkeyKeyCodeKey = "Imager.hotkeyKeyCode"
    static let hotkeyModifiersKey = "Imager.hotkeyModifiers"
    static let hotkeyLabelKey = "Imager.hotkeyLabel"
    static let hoverPreviewKey = "Imager.hoverPreviewsEnabled"
    static let themeKey = "Imager.theme"
    static let runAtLoginKey = "Imager.runAtLogin"
    static let showMenuBarIconKey = "Imager.showMenuBarIcon"
    static let showDockIconKey = "Imager.showDockIcon"

    /// Default global shortcut: Command-Shift-Space.
    static let defaultHotkeyKeyCode = 49
    static let defaultHotkeyModifiers = (1 << 20) | (1 << 17)
    static let defaultHotkeyLabel = "⌘⇧Space"

    var saveDirectoryURL: URL {
        didSet {
            UserDefaults.standard.set(saveDirectoryURL.path, forKey: Self.saveDirectoryKey)
        }
    }

    var autoSaveOnDrag: Bool {
        didSet {
            UserDefaults.standard.set(autoSaveOnDrag, forKey: Self.autoSaveKey)
        }
    }

    var globalShortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalShortcutEnabled, forKey: Self.shortcutKey)
        }
    }

    /// Key code of the global shortcut (Carbon virtual-key code).
    var hotkeyKeyCode: Int {
        didSet {
            UserDefaults.standard.set(hotkeyKeyCode, forKey: Self.hotkeyKeyCodeKey)
        }
    }

    /// Carbon modifier mask for the global shortcut (⌃⌥⇧⌘ bits).
    var hotkeyModifiers: Int {
        didSet {
            UserDefaults.standard.set(hotkeyModifiers, forKey: Self.hotkeyModifiersKey)
        }
    }

    /// Human-readable copy of the shortcut (e.g. "⌘⇧Space"), kept alongside
    /// the key code so exotic keys display correctly regardless of layout.
    var hotkeyLabel: String {
        didSet {
            UserDefaults.standard.set(hotkeyLabel, forKey: Self.hotkeyLabelKey)
        }
    }

    /// Whether the menu-bar status icon is shown.
    var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Self.showMenuBarIconKey)
        }
    }

    /// Whether Imager appears in the Dock.
    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconKey)
        }
    }

    var hoverPreviewsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hoverPreviewsEnabled, forKey: Self.hoverPreviewKey)
        }
    }

    var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
            Theme.apply(theme)
        }
    }

    /// Whether Imager is registered as a login item (starts when you log in).
    /// Persisted only after a successful `SMAppService.register`/`unregister`.
    private(set) var runAtLogin: Bool {
        didSet {
            guard runAtLogin != oldValue else { return }
            UserDefaults.standard.set(runAtLogin, forKey: Self.runAtLoginKey)
        }
    }

    /// In-memory API-key cache. Sole writer is setAPIKey below.
    private var keyCache: [String: String] = [:]
    private var keyCacheMiss: Set<String> = []

    private static func apiKeyDefaultsKey(_ providerID: String) -> String {
        "Imager.apiKey.\(providerID)"
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.saveDirectoryKey) {
            self.saveDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let desktop = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
            self.saveDirectoryURL = URL(fileURLWithPath: desktop, isDirectory: true)
        }
        if defaults.object(forKey: Self.autoSaveKey) != nil {
            self.autoSaveOnDrag = defaults.bool(forKey: Self.autoSaveKey)
        } else {
            self.autoSaveOnDrag = true
        }
        if defaults.object(forKey: Self.shortcutKey) != nil {
            self.globalShortcutEnabled = defaults.bool(forKey: Self.shortcutKey)
        } else {
            self.globalShortcutEnabled = true
        }
        if defaults.object(forKey: Self.hotkeyKeyCodeKey) != nil {
            self.hotkeyKeyCode = defaults.integer(forKey: Self.hotkeyKeyCodeKey)
        } else {
            self.hotkeyKeyCode = Self.defaultHotkeyKeyCode
        }
        if defaults.object(forKey: Self.hotkeyModifiersKey) != nil {
            self.hotkeyModifiers = defaults.integer(forKey: Self.hotkeyModifiersKey)
        } else {
            self.hotkeyModifiers = Self.defaultHotkeyModifiers
        }
        if let label = defaults.string(forKey: Self.hotkeyLabelKey) {
            self.hotkeyLabel = label
        } else {
            self.hotkeyLabel = Self.defaultHotkeyLabel
        }
        if defaults.object(forKey: Self.showMenuBarIconKey) != nil {
            self.showMenuBarIcon = defaults.bool(forKey: Self.showMenuBarIconKey)
        } else {
            self.showMenuBarIcon = true
        }
        if defaults.object(forKey: Self.showDockIconKey) != nil {
            self.showDockIcon = defaults.bool(forKey: Self.showDockIconKey)
        } else {
            self.showDockIcon = true
        }
        if defaults.object(forKey: Self.hoverPreviewKey) != nil {
            self.hoverPreviewsEnabled = defaults.bool(forKey: Self.hoverPreviewKey)
        } else {
            self.hoverPreviewsEnabled = true
        }
        if let rawTheme = defaults.string(forKey: Self.themeKey), let stored = AppTheme(rawValue: rawTheme) {
            self.theme = stored
        } else {
            self.theme = .matteBlack
        }
        // Reflect the real login-item state; a stored value is only trusted when
        // it exists (meaning it came from a successful toggle in this app).
        if defaults.object(forKey: Self.runAtLoginKey) != nil {
            self.runAtLogin = defaults.bool(forKey: Self.runAtLoginKey)
        } else {
            self.runAtLogin = Self.isLoginItemRegistered
        }
        Theme.apply(theme)
    }

    private static var isLoginItemRegistered: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Turns "start at login" on or off through the system login items.
    /// Throws so the UI can show why a change didn't take effect.
    func setRunAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if !Self.isLoginItemRegistered {
                try service.register()
            }
        } else {
            if Self.isLoginItemRegistered {
                try service.unregister()
            }
        }
        runAtLogin = enabled
    }

    func apiKey(for providerID: String) -> String? {
        if let hit = keyCache[providerID] { return hit }
        if keyCacheMiss.contains(providerID) { return nil }
        let value = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey(providerID))
        if let value {
            keyCache[providerID] = value
        } else {
            keyCacheMiss.insert(providerID)
        }
        return value
    }

    func setAPIKey(_ value: String?, for providerID: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            keyCache[providerID] = trimmed
            keyCacheMiss.remove(providerID)
            UserDefaults.standard.set(trimmed, forKey: Self.apiKeyDefaultsKey(providerID))
        } else {
            keyCache.removeValue(forKey: providerID)
            keyCacheMiss.insert(providerID)
            UserDefaults.standard.removeObject(forKey: Self.apiKeyDefaultsKey(providerID))
            KeychainStore.delete(KeychainStore.apiKeyKey(providerID: providerID))
        }
    }

    func chooseSaveDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose where downloaded images are saved."
        openPanel.directoryURL = saveDirectoryURL
        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.saveDirectoryURL = url
        }
    }
}