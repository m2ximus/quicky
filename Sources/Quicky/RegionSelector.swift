import AppKit
import Carbon.HIToolbox

struct Selection {
    let screen: NSScreen
    /// Points, origin at the screen's top-left.
    let rect: CGRect

    /// The same rectangle in global AppKit coordinates (origin bottom-left).
    var globalFrame: CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

/// Dims every screen and lets the user drag out a rectangle, or click a window, on one of them.
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var escapeKey: HotKey?
    private var previousApp: NSRunningApplication?
    private var completion: ((Selection?) -> Void)?

    func begin(completion: @escaping (Selection?) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        let windowFrames = Self.windowFrames()
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let origin = CGDisplayBounds(screen.displayID).origin
            view.windowRects = windowFrames
                .map { $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(view.bounds) }
                .filter { !$0.isEmpty }
            view.onFinish = { [weak self] rect in
                self?.finish(rect.map { Selection(screen: screen, rect: $0) })
            }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        // A system-wide hotkey, not a local key monitor: macOS may refuse to activate us, and the
        // overlay would then cover every screen with no key press able to dismiss it.
        escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0, id: 2) { [weak self] in self?.cancel() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        finish(nil)
    }

    /// Frames of other apps' normal windows, front to back, in global top-left coordinates.
    private static func windowFrames() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer] as? Int == 0,
                  window[kCGWindowOwnerPID] as? pid_t != getpid(),
                  window[kCGWindowAlpha] as? Double ?? 1 > 0,
                  let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 50, frame.height >= 50 else { return nil }
            return frame
        }
    }

    private func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil
        escapeKey = nil
        windows.forEach { $0.close() }
        windows = []
        // Give focus back so the recorded app does not look inactive.
        previousApp?.activate()
        completion(selection)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private static let minimumSize: CGFloat = 16

    var onFinish: ((CGRect?) -> Void)?
    /// Windows on this screen, front to back, in view coordinates.
    var windowRects: [CGRect] = []
    private var start: CGPoint?
    private var selection: CGRect?
    /// The window under the cursor, offered as a one-click selection.
    private var hovered: CGRect?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let window = windowRects.first { $0.contains(point) }
        if window != hovered {
            hovered = window
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(bounds).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width >= Self.minimumSize, selection.height >= Self.minimumSize {
            onFinish?(selection)
            return
        }
        // No real drag: treat it as a click on the window under the cursor, if any.
        let point = convert(event.locationInWindow, from: nil)
        if let window = windowRects.first(where: { $0.contains(point) }) {
            onFinish?(window)
        } else {
            start = nil
            selection = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let selection else {
            if let hovered {
                // Lift the hovered window a little, but keep it dimmed: a window as big as the screen
                // would otherwise leave no visible sign that Quicky is waiting for a selection.
                NSColor.black.withAlphaComponent(0.2).setFill()
                hovered.fill(using: .copy)
                NSColor.white.setStroke()
                let outline = NSBezierPath(rect: hovered.insetBy(dx: -1, dy: -1))
                outline.lineWidth = 2
                outline.stroke()
                drawLabel("Click to record this window", centeredAt: CGPoint(x: hovered.midX, y: hovered.midY))
            }
            drawLabel("Quicky: drag a region, or click a window  ·  Esc to cancel", centeredAt: CGPoint(x: bounds.midX, y: hovered == nil ? bounds.midY : 60))
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)).stroke()
        drawLabel("\(Int(selection.width)) × \(Int(selection.height))", centeredAt: CGPoint(x: selection.midX, y: min(selection.maxY + 16, bounds.maxY - 12)))
    }

    private func drawLabel(_ text: String, centeredAt point: CGPoint) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        // A dark pill behind the text keeps it readable over any content.
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -14, dy: -8), xRadius: 10, yRadius: 10).fill()
        string.draw(at: origin)
    }
}
