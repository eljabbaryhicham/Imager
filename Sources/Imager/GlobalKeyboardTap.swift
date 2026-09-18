import CoreGraphics
import ApplicationServices
import Foundation

/// OS-level keyboard tap that watches for the global hotkey in every
/// application. This is the mechanism menu-bar utilities rely on: once the
/// process is granted Accessibility (or Input Monitoring) access, it reliably
/// sees key events from any frontmost app — which NSEvent monitors and Carbon
/// hotkeys have both failed to do for this app.
///
/// The tap is listen-only, so the key still reaches its original target.
@MainActor
final class GlobalKeyboardTap {
    private static let modifierMask: UInt64 = UInt64((1 << 20) | (1 << 19) | (1 << 18) | (1 << 17))
    // Bit 20 only; used to log "any command-key combo" for diagnostics without
    // logging every single keystroke.
    private static let commandMask: UInt64 = UInt64(1 << 20)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (() -> Void)?
    private var keyCode: UInt32 = 0
    private var modifiers: UInt32 = 0
    private var lastInvocation: Date = .distantPast

    static let shared = GlobalKeyboardTap()
    private init() {}

    /// True when the tap was created (meaning the OS let this process observe
    /// the keyboard). False until the user grants Accessibility access.
    var isActive: Bool { eventTap != nil }

    /// True when the OS granted this process the right to observe the keyboard.
    /// Requires Accessibility or Input Monitoring consent; without it a tap
    /// cannot be created and macOS would only refuse (and beep).
    private static var hasPermission: Bool {
        AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    @discardableResult
    func install(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        uninstall()
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler

        guard Self.hasPermission else { return false }

        let interest = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: interest,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GlobalKeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
                // macOS periodically silence slow taps (kCGEventTapDisabledByTimeout)
                // and never wakes them again unless we re-enable them.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Task { @MainActor in
                        owner.rearm()
                    }
                    return Unmanaged.passUnretained(event)
                }
                Task { @MainActor in
                    owner.handle(event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        return true
    }

    func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        handler = nil
    }

    /// Re-arm a tap macOS silenced because the main thread was busy. Without
    /// this, a temporarily-disabled tap stays dead and the shortcut silently
    /// stops working.
    private func rearm() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            ImagerLog.log("event tap re-enabled (was silenced by the system)")
        }
    }

    private func handle(event: CGEvent) {
        guard event.type == .keyDown else { return }
        let actual = event.flags.rawValue & Self.modifierMask
        let hitKeyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        // Diagnostic: log what the tap actually sees so a real ⌘⇧Space press can
        // be audited end-to-end; removed once the shortcut is confirmed working.
        if hitKeyCode == keyCode || (actual & Self.commandMask) != 0 {
            ImagerLog.log("tap keyDown code=\(hitKeyCode) mods=\(String(actual, radix: 16))")
        }
        guard hitKeyCode == keyCode, actual == UInt64(modifiers) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastInvocation) > 0.25 else { return }
        lastInvocation = now
        handler?()
    }
}