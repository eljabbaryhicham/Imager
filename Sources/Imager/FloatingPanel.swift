import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        hasShadow = true

        // Transparent window so the Liquid Glass material can blur the desktop behind it.
        isOpaque = false
        backgroundColor = .clear
    }

    /// Borderless panels must opt into becoming key so the search field can
    /// receive text input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool {
        // A floating utility panel shouldn't steal main-window status.
        false
    }
}

/// Records the raw left mouse-down for each of Imager's panels so a SwiftUI
/// drag gesture can hand that exact press to AppKit's native title-bar-style
/// window tracking via `performDrag(with:)`. This recorder never moves any
/// window — window movement is handled entirely by AppKit inside
/// `performDrag`, which tracks the mouse in the window server until mouse-up.
private enum NativePressRecorder {
    private static var token: Any?
    private static var pressSequence = 0
    private static var presses: [ObjectIdentifier: NSEvent] = [:]

    /// Monotonic counter of recorded presses. The drag gesture uses it to hand
    /// the press to AppKit at most once per mouse-down.
    static var sequence: Int { pressSequence }

    static func ensureInstalled() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDown:
                if let window = event.window as? NSPanel {
                    pressSequence += 1
                    presses[ObjectIdentifier(window)] = event
                }
            case .leftMouseUp:
                if let window = event.window {
                    presses.removeValue(forKey: ObjectIdentifier(window))
                }
            default:
                break
            }
            return event
        }
    }

    static func pressEvent(for window: NSWindow) -> NSEvent? {
        presses[ObjectIdentifier(window)]
    }
}

/// Lets a borderless panel be dragged by clicking any empty background area.
/// The drag gesture is attached to the content, but SwiftUI gives interactive
/// child controls (buttons, text fields, pickers, scroll views) hit-test
/// priority over the parent gesture — so controls keep their own clicks and
/// only genuinely empty space triggers window drag.
///
/// Once the gesture sees real movement, the recorded mouse-down is handed to
/// `performDrag(with:)`, so AppKit owns the entire drag: title-bar tracking,
/// pixel-perfect cursor lock, and clean mouse-up. No manual frame math, so no
/// offset, no drift, and no competing drag systems.
struct NativeWindowDraggable: ViewModifier {
    /// The press sequence we already handed to AppKit. Escalation happens at
    /// most once per mouse-down; the next press bumps the sequence, re-enabling
    /// dragging for that gesture session.
    @State private var lastHandledSequence = -1

    func body(content: Content) -> some View {
        content
            .onAppear {
                NativePressRecorder.ensureInstalled()
            }
            .gesture(
                // A small dead zone so casual button taps (with microscopic
                // press drift) still register instead of becoming drags.
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        beginNativeDragIfNeeded()
                    }
            )
    }

    @MainActor
    private func beginNativeDragIfNeeded() {
        let window = topmostWindowUnderCursor() ?? NSApp.keyWindow
        guard let window,
              window is NSPanel,
              let pressEvent = NativePressRecorder.pressEvent(for: window),
              NativePressRecorder.sequence != lastHandledSequence else { return }
        lastHandledSequence = NativePressRecorder.sequence
        // AppKit tracks the full drag natively (title-bar behavior): the window
        // stays locked under the cursor and mouse-up ends it exactly, with the
        // window landing precisely where the user released.
        window.performDrag(with: pressEvent)
    }
}

/// The true topmost window under the cursor, shared by the drag and resize gestures.
@MainActor
private func topmostWindowUnderCursor() -> NSWindow? {
    let point = NSEvent.mouseLocation
    let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    guard number != 0 else { return nil }
    return NSApp.windows.first { $0.windowNumber == number }
}

/// Lets the borderless main panel be resized from any of its four corners.
/// Borderless windows get no resize handles from AppKit, so this supplies a
/// small invisible corner handle per corner whose own drag gesture takes
/// priority over the window-drag gesture and over the scrolling grid beneath.
/// The opposite corner stays fixed while the dragged corner moves, and the
/// bottom-trailing handle keeps the visible grip marking the corner.
struct ResizeGrip: ViewModifier {
    /// Only the expanded panel shows the handles; the collapsed bar auto-sizes.
    let active: Bool

    private enum ResizeCorner: String {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }
    }

    @State private var resizeWindow: NSWindow?
    @State private var startFrame: NSRect?
    @State private var startMouse: NSPoint?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) { cornerHandle(.topLeading) }
            .overlay(alignment: .topTrailing) { cornerHandle(.topTrailing) }
            .overlay(alignment: .bottomLeading) { cornerHandle(.bottomLeading) }
            .overlay(alignment: .bottomTrailing) { cornerHandle(.bottomTrailing) }
            .overlay(alignment: .bottomTrailing) {
                if active {
                    GripMark()
                        .foregroundStyle(Theme.textSecondary.opacity(hovering ? 0.9 : 0.45))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func cornerHandle(_ corner: ResizeCorner) -> some View {
        if active {
            Color.clear
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in resize(to: corner) }
                        .onEnded { _ in
                            startFrame = nil
                            startMouse = nil
                        }
                )
                .help("Resize window")
                .accessibilityLabel("Resize window")
        }
    }

    private func resize(to corner: ResizeCorner) {
        guard let window = resizeWindow ?? topmostWindowUnderCursor() ?? NSApp.keyWindow else { return }
        resizeWindow = window
        let current = NSEvent.mouseLocation
        guard let startFrame, let startMouse else {
            self.startFrame = window.frame
            self.startMouse = current
            return
        }

        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        let fixed: NSPoint
        switch corner {
        case .topLeading: fixed = NSPoint(x: startFrame.maxX, y: startFrame.minY)
        case .topTrailing: fixed = NSPoint(x: startFrame.minX, y: startFrame.minY)
        case .bottomLeading: fixed = NSPoint(x: startFrame.maxX, y: startFrame.maxY)
        case .bottomTrailing: fixed = NSPoint(x: startFrame.minX, y: startFrame.maxY)
        }

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var newWidth = startFrame.width + (corner.isLeading ? -dx : dx)
        var newHeight = startFrame.height + (corner.isBottom ? -dy : dy)
        newWidth = min(max(newWidth, 1100), visible?.width ?? 2400)
        newHeight = min(max(newHeight, 740), visible?.height ?? 1500)

        let origin = NSPoint(
            x: fixed.x - (corner.isLeading ? newWidth : 0),
            y: fixed.y - (corner.isBottom ? newHeight : 0)
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: newWidth, height: newHeight)), display: true)
    }
}

/// Three short diagonal strokes marking the resize corner.
private struct GripMark: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<3 {
                let offset = CGFloat(index) * 4.5
                var path = Path()
                path.move(to: CGPoint(x: size.width - 1 - offset, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width - 1, y: size.height - 1 - offset))
                context.stroke(path, with: .color(.white), lineWidth: 1.5)
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// Child-level drag gesture that never recognises. Because it lives on a child
/// view it always takes priority over the ancestor window-drag gesture in
/// SwiftUI's arbitration — so the window-drag can never activate while the
/// press is on this view. The threshold is unreachable, so the gesture stays
/// in the "possible" state for the entire press, perfectly blocking the
/// ancestor without interfering with taps, clicks, or any other gesture.
struct WindowDragExcluded: ViewModifier {
    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 1_000_000)
        )
    }
}

extension View {
    func windowDraggable() -> some View {
        modifier(NativeWindowDraggable())
    }

    func windowDragExcluded() -> some View {
        modifier(WindowDragExcluded())
    }

    /// Adds a bottom-right resize grip (shown when `active`); the frameless
    /// panel cannot be resized by AppKit edge dragging.
    func resizeGrip(active: Bool) -> some View {
        modifier(ResizeGrip(active: active))
    }
}