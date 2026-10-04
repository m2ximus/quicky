import AppKit

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
    private var keyMonitor: Any?
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.finish(nil)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let selection else {
            if let hovered {
                NSColor.clear.setFill()
                hovered.fill(using: .copy)
                NSColor.white.setStroke()
                NSBezierPath(rect: hovered.insetBy(dx: -0.5, dy: -0.5)).stroke()
            }
            drawLabel("Drag a region, or click a window  ·  Esc to cancel", centeredAt: CGPoint(x: bounds.midX, y: 40))
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
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}
