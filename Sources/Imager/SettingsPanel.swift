import SwiftUI
import AppKit
import ImagerCore

/// A frameless, floating Liquid Glass settings window that stays above the main panel.
final class SettingsPanel: NSPanel {
    private let hostingController: NSHostingController<SettingsPanelView>
    private let onClose: (() -> Void)?

    init(
        settings: SettingsStore,
        onProvidersChanged: @escaping () -> Void,
        onGlobalShortcutChanged: @escaping () -> Void,
        onStatusItemVisibilityChanged: @escaping () -> Void,
        onDockVisibilityChanged: @escaping () -> Void,
        onClose: (() -> Void)?
    ) {
        let view = SettingsPanelView(
            settings: settings,
            onProvidersChanged: onProvidersChanged,
            onGlobalShortcutChanged: onGlobalShortcutChanged,
            onStatusItemVisibilityChanged: onStatusItemVisibilityChanged,
            onDockVisibilityChanged: onDockVisibilityChanged,
            onClose: onClose
        )
        let hosting = NSHostingController(rootView: view)
        self.hostingController = hosting
        self.onClose = onClose

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 860),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc closes Settings even when a nested control holds keyboard focus
    /// (where SwiftUI's exit command never arrives).
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    func show() {
        center()
        orderFront(nil)
        makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Glass chrome around the settings form; keeps it in front of the main panel.
struct SettingsPanelView: View {
    let settings: SettingsStore
    let onProvidersChanged: () -> Void
    let onGlobalShortcutChanged: () -> Void
    let onStatusItemVisibilityChanged: () -> Void
    let onDockVisibilityChanged: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Theme.textPrimary)
                            .glassSurface(cornerRadius: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Settings")
                    .windowDragExcluded()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            SettingsView(
                settings: settings,
                onProvidersChanged: onProvidersChanged,
                onGlobalShortcutChanged: onGlobalShortcutChanged,
                onStatusItemVisibilityChanged: onStatusItemVisibilityChanged,
                onDockVisibilityChanged: onDockVisibilityChanged
            )
            .windowDragExcluded()
        }
        .padding(20)
        .frame(width: 900, height: 800)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.panelMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.15))
        )
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .themeAware(settings.theme)
        .windowDraggable()
        .onExitCommand { onClose?() }
    }
}