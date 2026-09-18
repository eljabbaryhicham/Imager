import SwiftUI
import AppKit
import ImagerCore

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let onProvidersChanged: () -> Void
    let onGlobalShortcutChanged: () -> Void
    let onStatusItemVisibilityChanged: () -> Void
    let onDockVisibilityChanged: () -> Void

    private struct KeyedProvider: Identifiable {
        let id: String
        let name: String
        let signupURL: String
    }

    private let keyedProviders = [
        KeyedProvider(id: "unsplash", name: "Unsplash", signupURL: "https://unsplash.com/developers"),
        KeyedProvider(id: "pexels", name: "Pexels", signupURL: "https://www.pexels.com/api/"),
        KeyedProvider(id: "pixabay", name: "Pixabay", signupURL: "https://pixabay.com/api/docs/")
    ]

    @State private var draftKeys: [String: String] = [:]
    @State private var savedIDs: Set<String> = []
    @State private var startupError: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Imager")
                            .font(.title.weight(.semibold))
                        Text("Version \(appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("A menu-bar image search palette. Drag any image into another app, download it, or open its source page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }

            Section("Downloads") {
                LabeledContent("Save images to") {
                    HStack(spacing: 12) {
                        Text(settings.saveDirectoryURL.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            settings.chooseSaveDirectory()
                        }
                    }
                }
                Toggle("Save a copy automatically when dragging", isOn: $settings.autoSaveOnDrag)
                    .tint(Theme.accent)
                    .help("When off, dragging still works, but no copy is saved to your save folder.")
            }

            Section("Previews") {
                Toggle("Show hover previews", isOn: $settings.hoverPreviewsEnabled)
                    .tint(Theme.accent)
                    .help("When off, hovering a result no longer opens a larger preview.")
            }

            Section {
                Toggle("Shortcut shows the window from anywhere", isOn: $settings.globalShortcutEnabled)
                    .tint(Theme.accent)
                    .onChange(of: settings.globalShortcutEnabled) { onGlobalShortcutChanged() }

                HotkeyRecorderView(
                    keyCode: $settings.hotkeyKeyCode,
                    modifiers: $settings.hotkeyModifiers,
                    label: $settings.hotkeyLabel,
                    enabled: settings.globalShortcutEnabled,
                    onChanged: onGlobalShortcutChanged
                )
            } header: {
                Text("Shortcut")
            }

            Section {
                Toggle("Show icon in the menu bar", isOn: $settings.showMenuBarIcon)
                    .tint(Theme.accent)
                    .onChange(of: settings.showMenuBarIcon) {
                        // With no menu-bar icon the shortcut is the only way in;
                        // keep it reachable so the user can never lock themselves out.
                        if !settings.showMenuBarIcon && !settings.globalShortcutEnabled {
                            settings.globalShortcutEnabled = true
                        }
                        onStatusItemVisibilityChanged()
                    }
                    .help("When off, Imager hides from the menu bar and is reached through its shortcut or the gear button in the search window.")
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Hide the icon for a cleaner menu bar; the gear button in the search window still opens Settings.")
            }

            Section {
                Toggle("Show in Dock", isOn: $settings.showDockIcon)
                    .tint(Theme.accent)
                    .onChange(of: settings.showDockIcon) {
                        // With neither Dock nor menu-bar icon the shortcut is
                        // the only way in; keep it reachable so the user can
                        // never lock themselves out.
                        if !settings.showDockIcon && !settings.showMenuBarIcon && !settings.globalShortcutEnabled {
                            settings.globalShortcutEnabled = true
                        }
                        onDockVisibilityChanged()
                    }
                    .help("When off, Imager hides from the Dock and is reached through its menu-bar icon or shortcut.")
            } header: {
                Text("Dock")
            } footer: {
                Text("Hide Imager from the Dock for a cleaner workspace.")
            }

            Section {
                Toggle("Start Imager at login", isOn: Binding(
                    get: { settings.runAtLogin },
                    set: { newValue in
                        do {
                            try settings.setRunAtLogin(newValue)
                            startupError = nil
                        } catch {
                            startupError = error.localizedDescription
                        }
                    }
                ))
                .tint(Theme.accent)
                .help("Opens Imager automatically when you log in to your Mac.")

                if let startupError {
                    Text(startupError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Move Imager into your Applications folder so it can start reliably at login.")
            }

            Section("Built-in sources (no key needed)") {
                LabeledContent("DuckDuckGo") {
                    Text("Web image search")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Openverse") {
                    Text("Creative Commons")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Bing") {
                    Text("Web image search")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Yahoo") {
                    Text("Web image search")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Pinterest") {
                    Text("Pin search")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(keyedProviders) { provider in
                    keyedProviderRow(provider)
                }
                googleRow
            } header: {
                Text("Providers with API keys")
            } footer: {
                Text("Keys are stored locally in Imager's settings. Add one to enable the provider in the search window.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 900)
        .onAppear(perform: reloadDrafts)
    }

    private func keyedProviderRow(_ provider: KeyedProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.name)
                Spacer()
                Link("Get free key", destination: URL(string: provider.signupURL)!)
                    .font(.callout)
                    .tint(Theme.accent)
            }
            HStack(spacing: 12) {
                SecureField("API key", text: Binding(
                    get: { draftKeys[provider.id] ?? "" },
                    set: { draftKeys[provider.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Button("Save") {
                    settings.setAPIKey(draftKeys[provider.id], for: provider.id)
                    onProvidersChanged()
                    markSaved(provider.id)
                }
                .disabled((draftKeys[provider.id] ?? "").isEmpty)
                .glassSurface(cornerRadius: 16)

                if settings.apiKey(for: provider.id) != nil {
                    Button("Remove") {
                        draftKeys[provider.id] = ""
                        settings.setAPIKey(nil, for: provider.id)
                        onProvidersChanged()
                    }
                    .glassSurface(cornerRadius: 16)
                }
            }
            if savedIDs.contains(provider.id) {
                Text("Saved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func draftBinding(for id: String) -> Binding<String> {
        Binding(
            get: { draftKeys[id] ?? "" },
            set: { draftKeys[id] = $0 }
        )
    }

    /// Google now uses SerpApi, so it needs only a SerpApi API key.
    /// Any obsolete Custom Search engine ID is removed when saving/removing.
    private var googleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Google")
                Spacer()
                Link("Get SerpApi key", destination: URL(string: "https://serpapi.com/google-images-api")!)
                    .font(.callout)
                    .tint(Theme.accent)
            }
            SecureField("SerpApi API key", text: draftBinding(for: "google"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("Save") {
                    settings.setAPIKey(draftKeys["google"], for: "google")
                    settings.setAPIKey(nil, for: "google_cx")
                    onProvidersChanged()
                    markSaved("google")
                }
                .disabled((draftKeys["google"] ?? "").isEmpty)
                .glassSurface(cornerRadius: 16)

                if settings.apiKey(for: "google") != nil {
                    Button("Remove") {
                        draftKeys["google"] = ""
                        settings.setAPIKey(nil, for: "google")
                        settings.setAPIKey(nil, for: "google_cx")
                        onProvidersChanged()
                    }
                    .glassSurface(cornerRadius: 16)
                }
            }
            if savedIDs.contains("google") {
                Text("Saved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Google Custom Search is no longer used; this source now uses SerpApi.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func reloadDrafts() {
        for provider in keyedProviders {
            draftKeys[provider.id] = settings.apiKey(for: provider.id) ?? ""
        }
        draftKeys["google"] = settings.apiKey(for: "google") ?? ""
    }

    private func markSaved(_ id: String) {
        savedIDs.insert(id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            savedIDs.remove(id)
        }
    }
}

/// Standard macOS shortcut recorder: click "Change…", press the new key combo
/// (Esc cancels). While recording, keystrokes are swallowed so they don't leak
/// into other settings fields.
private struct HotkeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var label: String
    let enabled: Bool
    let onChanged: () -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            if isRecording {
                Text("Press the new shortcut — Esc cancels")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text(label.isEmpty ? "None" : label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.textSecondary.opacity(0.08), in: Capsule())
            }
            if isRecording {
                Button("Cancel") { stopRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button("Change…") { startRecording() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(!enabled)
            }
            Button("Reset") { resetToDefault() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(!enabled || isRecording)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard isRecording else { return event }
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            let mask = UInt((1 << 20) | (1 << 18) | (1 << 19) | (1 << 17))
            let mods = event.modifierFlags
                .intersection([.command, .control, .option, .shift])
                .rawValue & mask
            guard mods != 0, let keyName = ShortcutFormatter.keyName(for: event) else {
                return nil
            }
            keyCode = Int(event.keyCode)
            modifiers = Int(mods)
            label = ShortcutFormatter.combine(modifiers: Int(mods), keyName: keyName)
            stopRecording()
            onChanged()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isRecording = false
    }

    private func resetToDefault() {
        stopRecording()
        keyCode = SettingsStore.defaultHotkeyKeyCode
        modifiers = SettingsStore.defaultHotkeyModifiers
        label = SettingsStore.defaultHotkeyLabel
        onChanged()
    }
}

/// Turns Carbon key codes + modifier bits into a readable shortcut label.
private enum ShortcutFormatter {
    static let controlBit = 1 << 18
    static let optionBit = 1 << 19
    static let shiftBit = 1 << 17
    static let commandBit = 1 << 20

    static let specialKeyNames: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        126: "Up Arrow", 125: "Down Arrow", 124: "Right Arrow", 123: "Left Arrow",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    static let modifierKeyCodes: Set<Int> = [55, 56, 58, 59, 60, 61, 62, 63] // ⌘ ⇧ ⌥ ⌃, left/right + Fn

    /// The key's display name; nil when the press is only a modifier.
    static func keyName(for event: NSEvent) -> String? {
        let code = Int(event.keyCode)
        guard !modifierKeyCodes.contains(code) else { return nil }
        if let special = specialKeyNames[code] { return special }
        if let chars = event.charactersIgnoringModifiers {
            let trimmed = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.count > 1 ? trimmed : trimmed.uppercased() }
        }
        return nil
    }

    static func combine(modifiers: Int, keyName: String) -> String {
        var result = ""
        if modifiers & controlBit != 0 { result += "⌃" }
        if modifiers & optionBit != 0 { result += "⌥" }
        if modifiers & shiftBit != 0 { result += "⇧" }
        if modifiers & commandBit != 0 { result += "⌘" }
        return result + keyName
    }
}