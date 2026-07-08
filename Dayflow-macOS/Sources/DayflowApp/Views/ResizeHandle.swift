import SwiftUI
import AppKit

// Native AppKit resize handle. SwiftUI DragGesture next to a WKWebView sibling
// is unreliable on macOS — hover fires but mouseDown/drag events can get lost.
// Using an NSView with explicit mouseDown/mouseDragged + cursor rect is rock
// solid.
struct HorizontalResizeHandle: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var lastX: CGFloat = 0
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let t = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(t)
            trackingArea = t
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.withAlphaComponent(0.5).setFill()
            let line = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            line.fill()
        }

        override func mouseDown(with event: NSEvent) {
            lastX = event.locationInWindow.x
        }
        override func mouseDragged(with event: NSEvent) {
            let x = event.locationInWindow.x
            onDrag?(x - lastX)
            lastX = x
        }
        override func mouseUp(with event: NSEvent) { onEnd?() }
    }

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onDrag = onDrag
        v.onEnd = onEnd
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}
