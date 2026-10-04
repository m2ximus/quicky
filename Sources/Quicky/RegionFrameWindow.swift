import AppKit

/// A click-through outline around the region: shows the countdown, then turns red while recording.
final class RegionFrameWindow: NSWindow {
    private static let outset: CGFloat = 3
    private let frameView = RegionFrameView()

    init(selection: Selection) {
        let frame = selection.globalFrame.insetBy(dx: -Self.outset, dy: -Self.outset)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = frameView
    }

    func showCountdown(_ count: Int) {
        frameView.count = count
        orderFrontRegardless()
    }

    func showRecording() {
        frameView.count = nil
    }
}

private final class RegionFrameView: NSView {
    /// Seconds left before recording starts; nil once recording.
    var count: Int? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        (count == nil ? NSColor.systemRed : NSColor.white).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()

        guard let count else { return }
        let fontSize = max(24, min(96, bounds.height * 0.5))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 8
        let string = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ])
        let size = string.size()
        string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
