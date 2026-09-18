import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let applicationModel = ApplicationModel()

    private var statusItem: NSStatusItem?
    private var isShowingMenu = false
    private var outsideClickToken: Any?
    /// The initial activation of a borderless accessory app can briefly pulse
    /// "inactive" right after the panel opens, which would hide it immediately.
    /// Ignore all panel-hide signals until this launch has had time to settle.
    private var hideDisabledUntil: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockVisibility()
        hideDisabledUntil = Date().addingTimeInterval(2.5)
        installMainMenu()
        applicationModel.onGlobalShortcutChanged = { [weak self] in
            self?.refreshGlobalShortcut()
        }
        applicationModel.onStatusItemVisibilityChanged = { [weak self] in
            self?.updateStatusItemVisibility()
        }
        applicationModel.onDockVisibilityChanged = { [weak self] in
            self?.updateDockVisibility()
        }
        setupStatusItem()
        applicationModel.showPanel()
        observeResignActive()
        observeBecomeActive()
        installClickOutsideToHide()
        ImagerLog.log("launch bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
        refreshGlobalShortcut()
    }

    private var isHideDisabled: Bool {
        Date() < hideDisabledUntil
    }

    // MARK: - Main menu (keyboard editing shortcuts)

    /// A menu-bar app normally has no main menu, so keyboard editing commands
    /// (⌘V paste, ⌘C copy, ⌘X cut, ⌘A select all, ⌘Z undo) have no key
    /// equivalent to dispatch through. Right-click paste still works because
    /// the text field supplies its own context menu, but the shortcuts need
    /// an Edit menu. The menu bar itself stays hidden for an accessory app;
    /// its key equivalents still route to the first responder.
    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Imager")
        appMenuItem.submenu = appMenu
        let quitItem = NSMenuItem(
            title: "Quit Imager",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Dismiss when the app stops being active

    /// Fires whenever the user clicks into another app while Imager was
    /// active (the reliable outside-click signal), in addition to the global
    /// mouse monitor below, which covers clicks while Imager was never active.
    private func observeResignActive() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidResignActive() {
        let suppressed = isHideDisabled
        ImagerLog.log("resignActive hide=\(!suppressed)")
        guard !suppressed else { return }
        applicationModel.hidePanel()
    }

    // MARK: - Re-arm the hotkey when keyboard access is granted

    /// Refreshes the shortcut whenever the app becomes active again. This is
    /// how a freshly granted Accessibility permission takes effect without the
    /// user having to quit and relaunch Imager.
    private func observeBecomeActive() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        if applicationModel.settings.globalShortcutEnabled, !GlobalHotkey.shared.isGlobalTapActive {
            refreshGlobalShortcut()
        }
    }

    // MARK: - Menu bar status item

    private func setupStatusItem() {
        guard applicationModel.settings.showMenuBarIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "photo.on.rectangle.angled",
                accessibilityDescription: "Imager"
            )
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Fire for both click types so left-click toggles the window and
            // right-click opens the menu — a plain MenuBarExtra can't pop a
            // menu on right-click only.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Imager (⌘⇧Space)"
        }
        statusItem = item
    }

    /// Shows or hides the Dock icon to match the current setting.
    func updateDockVisibility() {
        NSApp.setActivationPolicy(applicationModel.settings.showDockIcon ? .regular : .accessory)
    }

    /// Creates or removes the menu-bar icon to match the current setting.
    private func updateStatusItemVisibility() {
        if applicationModel.settings.showMenuBarIcon {
            if statusItem == nil {
                setupStatusItem()
            }
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // performClick below reposts a synthetic click while the menu opens;
        // swallow it so it doesn't also toggle the panel.
        guard !isShowingMenu else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popUpMenu()
        } else {
            applicationModel.togglePanel()
        }
    }

    private func popUpMenu() {
        guard let item = statusItem, let button = item.button else { return }
        let menu = NSMenu()

        let settingsItem = menu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self

        menu.addItem(.separator())

        let quitItem = menu.addItem(
            withTitle: "Quit Imager",
            action: #selector(quitImager),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]

        // Setting the temporary menu and performing a click is the standard
        // way to display a status-item menu only on demand.
        item.menu = menu
        isShowingMenu = true
        button.performClick(nil)
        isShowingMenu = false
        item.menu = nil
    }

    @objc private func showSettings() {
        applicationModel.showSettings()
    }

    @objc private func quitImager() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Dismiss on outside click

    /// Hides the main panel when the user clicks anywhere that isn't one of
    /// Imager's own windows (panels, popovers, or the status item), so the
    /// floating palette gets out of the way. Clicks on the status item are
    /// left alone — that toggles the panel via `statusItemClicked`.
    private func installClickOutsideToHide() {
        outsideClickToken = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isHideDisabled else { return }
                let point = NSEvent.mouseLocation
                if !self.isClickInsideImager(at: point) {
                    self.applicationModel.hidePanel()
                }
            }
        }
    }

    private func isClickInsideImager(at point: NSPoint) -> Bool {
        if let statusWindow = statusItem?.button?.window, statusWindow.frame.contains(point) {
            return true
        }
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
    }

    // MARK: - Global shortcut

    private var lastGlobalShortcutTrigger: Date = .distantPast

    func refreshGlobalShortcut() {
        GlobalHotkey.shared.uninstall()
        guard applicationModel.settings.globalShortcutEnabled else { return }
        GlobalHotkey.shared.install(
            keyCode: UInt32(applicationModel.settings.hotkeyKeyCode),
            modifiers: UInt32(applicationModel.settings.hotkeyModifiers)
        ) { [weak self] source in
            self?.handleGlobalShortcut(source: source)
        }
        ImagerLog.log("shortcut installed combo=\(applicationModel.settings.hotkeyLabel) enabled=\(applicationModel.settings.globalShortcutEnabled) carbon=\(GlobalHotkey.shared.isRegistered) eventTap=\(GlobalHotkey.shared.isGlobalTapActive)")
    }

    /// Multiple receivers (Carbon + event tap) may notice the same physical
    /// press; collapse them into a single toggle.
    private func handleGlobalShortcut(source: String = "unknown") {
        let now = Date()
        guard now.timeIntervalSince(lastGlobalShortcutTrigger) > 0.25 else { return }
        lastGlobalShortcutTrigger = now
        // Re-activating an accessory app from the background pulses a
        // resign-active a moment after the panel appears, which would instantly
        // hide it again. Suppress panel-hide signals briefly, just as launch
        // does, so the panel stays up when summoned by the hotkey.
        hideDisabledUntil = Date().addingTimeInterval(0.6)
        ImagerLog.log("shortcut FIRED via=\(source)")
        applicationModel.togglePanel()
    }
}