import AppKit
import SwiftUI

// Apple's documented recipe for "drag a file out of an inactive window
// without raising it" — the behaviour Finder, Mail, and Xcode all use.
// `acceptsFirstMouse` alone only stops *activation*; the window can
// still re-order itself to front on mouseUp. The full three-piece
// dance:
//
//   1. `acceptsFirstMouse(for:) -> true` — accept the click on an
//      inactive window without activating the app.
//   2. `shouldDelayWindowOrdering(for:) -> true` — tell AppKit "this
//      click might start a drag, defer the raise/activate until I say
//      otherwise".
//   3. Call `NSApp.preventWindowOrdering()` inside `mouseDown(with:)`
//      — cancel the deferred raise entirely.
//
// And it has to live on a *real* AppKit `NSView` in the hit path —
// SwiftUI mounts deeper internal NSViews inside its hosting tree that
// AppKit hit-tests instead of any wrapper we layer underneath, so we
// put a dedicated overlay on top of the row.
//
// This overlay only claims clicks when the window is inactive *and*
// the event is a left-mouse-down — every other case (right-click,
// active-window taps, hover) returns `nil` from `hitTest(_:)` so the
// existing SwiftUI gesture pipeline (`appKitFileDrag` +
// `.simultaneousGesture` selection + `.onTapGesture(count: 2)` open)
// runs untouched in the active path.
extension View {
    /// Add an inactive-window-aware drag source to this row. Pair with
    /// the existing `appKitFileDrag(...)` modifier — that one drives
    /// the active-window path via SwiftUI gestures; this one takes
    /// over only when the window is in the background.
    ///
    /// `multiURLs` is a provider closure so the row body never has to
    /// build the full multi-selection up-front — that array gets
    /// resolved lazily at drag-start, keeping per-row body cost flat.
    func inactiveDragSource(
        primary: URL,
        multiURLs: @escaping () -> [URL] = { [] },
        onClick: ((NSEvent) -> Void)? = nil,
        onDoubleClick: ((NSEvent) -> Void)? = nil
    ) -> some View {
        overlay(
            InactiveDragSourceRepresentable(
                primary: primary,
                multiURLs: multiURLs,
                onClick: onClick,
                onDoubleClick: onDoubleClick
            )
        )
    }
}

private struct InactiveDragSourceRepresentable: NSViewRepresentable {
    let primary: URL
    let multiURLs: () -> [URL]
    let onClick: ((NSEvent) -> Void)?
    let onDoubleClick: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> InactiveDragSourceNSView {
        let v = InactiveDragSourceNSView()
        v.configure(
            primary: primary,
            multiURLs: multiURLs,
            onClick: onClick,
            onDoubleClick: onDoubleClick
        )
        return v
    }

    func updateNSView(_ nsView: InactiveDragSourceNSView, context: Context) {
        nsView.configure(
            primary: primary,
            multiURLs: multiURLs,
            onClick: onClick,
            onDoubleClick: onDoubleClick
        )
    }
}

private final class InactiveDragSourceNSView: NSView, NSDraggingSource {
    private var primary: URL = URL(fileURLWithPath: "/")
    private var multiURLsProvider: () -> [URL] = { [] }
    private var onClick: ((NSEvent) -> Void)?
    private var onDoubleClick: ((NSEvent) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    func configure(
        primary: URL,
        multiURLs: @escaping () -> [URL],
        onClick: ((NSEvent) -> Void)?,
        onDoubleClick: ((NSEvent) -> Void)?
    ) {
        self.primary = primary
        self.multiURLsProvider = multiURLs
        self.onClick = onClick
        self.onDoubleClick = onDoubleClick
    }

    /// Only claim hits when the window is inactive *and* the triggering
    /// event is a left-mouse-down. Right-click, active-window taps, and
    /// hover tracking all fall through (`nil`) so SwiftUI's existing
    /// gestures run normally.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown,
              window?.isKeyWindow == false else {
            return nil
        }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Cancel the raise/activate that AppKit had been planning to
        // do on mouseUp now that we've seen the click.
        NSApp.preventWindowOrdering()
        mouseDownPoint = event.locationInWindow
        didStartDrag = false
        if event.clickCount >= 2 {
            onDoubleClick?(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didStartDrag else { return }
        let here = event.locationInWindow
        if hypot(here.x - start.x, here.y - start.y) >= 4 {
            didStartDrag = true
            startDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didStartDrag = false
        }
        // Click without drag → forward to SwiftUI selection so the row
        // updates even though the window stayed in the background.
        if !didStartDrag, event.clickCount == 1 {
            onClick?(event)
        }
    }

    private func startDrag(with event: NSEvent) {
        let resolvedMulti = multiURLsProvider()
        let urls: [URL] = resolvedMulti.count > 1 ? resolvedMulti : [primary]
        let cursorInView = convert(event.locationInWindow, from: nil)
        let iconSize = NSSize(width: 32, height: 32)
        var items: [NSDraggingItem] = []
        for (index, url) in urls.enumerated() {
            let pbItem = NSPasteboardItem()
            if let data = url.absoluteString.data(using: .utf8) {
                pbItem.setData(data, forType: .fileURL)
            }
            // Stamp the multi-selection on the first item so in-process
            // drops can grab the whole set in one hop — same convention
            // as `AppKitFileDrag.swift`.
            if index == 0, urls.count > 1,
               let data = try? JSONEncoder().encode(urls.map(\.absoluteString)) {
                pbItem.setData(
                    data,
                    forType: NSPasteboard.PasteboardType(DragDropSupport.mqdirSelectionTypeIdentifier)
                )
            }
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = iconSize
            let offset = CGFloat(index) * 4
            dragItem.setDraggingFrame(
                NSRect(
                    x: cursorInView.x - iconSize.width / 2 + offset,
                    y: cursorInView.y - iconSize.height / 2 - offset,
                    width: iconSize.width,
                    height: iconSize.height
                ),
                contents: icon
            )
            items.append(dragItem)
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.copy, .link]
        case .withinApplication: return [.copy, .move, .link]
        @unknown default: return [.copy]
        }
    }
}
