import Carbon.HIToolbox
import AppKit

/// Global shortcut combining two independent receivers:
///
///  1. Carbon RegisterEventHotKey — the classic, permission-free system hotkey.
///  2. GlobalKeyboardTap — an OS-level listen-only key tap (needs Accessibility
///     access; see GlobalKeyboardTap).
///
/// Both toggle the same callback; the trailing overhead of a single press is
/// collapsed by the debounce so exactly one toggle runs no matter how many
/// receivers noticed the key.
///
/// Carbon's event handler must be installed exactly once per process.
/// Re-installing it (e.g. on every settings save) fails with
/// eventNotInstalledErr (-9866), silently killing the shortcut. The
/// `isHandlerInstalled` flag guards it.
@MainActor
final class GlobalHotkey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var isHandlerInstalled = false

    private var handler: ((String) -> Void)?
    private var keyCode: UInt32 = 0
    private var modifiers: UInt32 = 0

    static let shared = GlobalHotkey()
    private init() {}

    var isRegistered: Bool { Self.hotKeyRef != nil }

    /// True when the OS-level tap is live (requires Accessibility grant).
    var isGlobalTapActive: Bool { GlobalKeyboardTap.shared.isActive }

    @discardableResult
    func install(keyCode: UInt32, modifiers: UInt32, handler: @escaping (String) -> Void) -> Bool {
        uninstall()
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler

        var installedAny = false

        if !Self.isHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            if InstallEventHandler(GetApplicationEventTarget(), hotKeyPressHandler, 1, &eventType, nil, nil) == noErr {
                Self.isHandlerInstalled = true
            }
        }

        if Self.isHandlerInstalled {
            if let ref = Self.hotKeyRef {
                UnregisterEventHotKey(ref)
                Self.hotKeyRef = nil
            }
            var hotKeyID = EventHotKeyID(signature: 0x494D4749, id: 1)
            var ref: EventHotKeyRef?
            // RegisterEventHotKey expects Carbon modifier bits (cmdKey 256,
            // shiftKey 512, optionKey 2048, controlKey 4096), NOT Cocoa
            // NSEvent.ModifierFlags. Passing Cocoa flags directly never matches.
            let registerStatus = RegisterEventHotKey(keyCode, Self.carbonModifiers(fromCocoa: modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if registerStatus == noErr {
                Self.hotKeyRef = ref
                installedAny = true
            }
        }

        if GlobalKeyboardTap.shared.install(keyCode: keyCode, modifiers: modifiers, handler: { [weak self] in self?.invoke(source: "tap") }) {
            installedAny = true
        }

        return installedAny
    }

    /// Translates Cocoa NSEvent.ModifierFlags bits to Carbon modifier bits.
    /// Cocoa: shift 0x20000, control 0x40000, option 0x80000, command 0x100000.
    /// Carbon: shiftKey 512, controlKey 4096, optionKey 2048, cmdKey 256.
    private static func carbonModifiers(fromCocoa cocoa: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if cocoa & 0x100000 != 0 { carbon |= 256 }   // command -> cmdKey
        if cocoa & 0x20000 != 0 { carbon |= 512 }    // shift -> shiftKey
        if cocoa & 0x80000 != 0 { carbon |= 2048 }   // option -> optionKey
        if cocoa & 0x40000 != 0 { carbon |= 4096 }   // control -> controlKey
        return carbon
    }

    func uninstall() {
        if let ref = Self.hotKeyRef {
            UnregisterEventHotKey(ref)
            Self.hotKeyRef = nil
        }
        GlobalKeyboardTap.shared.uninstall()
        handler = nil
    }

    func invoke(source: String = "carbon") {
        handler?(source)
    }
}

private let hotKeyPressHandler: EventHandlerUPP = { _, _, _ in
    Task { @MainActor in
        GlobalHotkey.shared.invoke(source: "carbon")
    }
    return noErr
}