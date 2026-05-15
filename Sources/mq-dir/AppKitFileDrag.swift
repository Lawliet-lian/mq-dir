import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SwiftUI's `.onDrag` on macOS layers an auto-promise handler over
// every NSItemProvider it ships, so destinations that read the drag
// via `loadFileRepresentation` / WebKit's `dataTransfer.files` (cmux,
// browsers, IDEs that "open the dropped file") receive a synthesised
// copy in `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/<name>`
// instead of the original path. Registering `.openInPlace` on the
// NSItemProvider doesn't help — SwiftUI's promise wins.
//
// This modifier sidesteps SwiftUI's drag plumbing entirely. We detect
// the drag intent with a simultaneous DragGesture, then begin an
// AppKit `NSDraggingSession` driven by an `NSPasteboardItem` we own,
// with no promise types, so receivers see the real file URL.
extension View {
    /// `multiURLs` is a provider rather than a `[URL]` so the row's view
    /// body never has to materialise the whole multi-selection just to
    /// hand it to a drag modifier that is dormant 99% of the time. The
    /// closure runs at drag-start, off the SwiftUI render hot path.
    func appKitFileDrag(primary: URL, multiURLs: @escaping () -> [URL] = { [] }) -> some View {
        modifier(AppKitFileDragModifier(primary: primary, multiURLs: multiURLs))
    }
}

private struct AppKitFileDragModifier: ViewModifier {
    let primary: URL
    let multiURLs: () -> [URL]

    @State private var dragInFlight = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    guard !dragInFlight else { return }
                    if startDrag() { dragInFlight = true }
                }
                .onEnded { _ in dragInFlight = false }
        )
    }

    @discardableResult
    private func startDrag() -> Bool {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let window = event.window,
              let view = window.contentView else { return false }

        // External destinations (Finder, cmux/WebKit, IDEs) read the
        // pasteboard one item at a time — they only see "all the dragged
        // files" if we put one NSPasteboardItem per file. Stuffing the
        // extra URLs into the private mqdirSelection type is enough for
        // pane↔pane drops within mq-dir but not for anyone else.
        let resolvedMulti = multiURLs()
        let urls: [URL] = resolvedMulti.count > 1 ? resolvedMulti : [primary]

        let iconSize = NSSize(width: 32, height: 32)
        let cursorInView = view.convert(event.locationInWindow, from: nil)
        var draggingItems: [NSDraggingItem] = []

        for (index, url) in urls.enumerated() {
            // Each item carries ONLY `public.file-url` so Slack sees
            // every NSDraggingItem as the same shape and accepts the
            // whole multi-file session. Using NSURL as the writer
            // also added `public.url` / `public.filename`
            // representations, and Slack's PDF-handling path treated
            // those as a competing content type and silently dropped
            // every item past the first. The plain string form for
            // `.fileURL` is what Finder writes and what Slack's
            // file-attachment receiver picks up unconditionally.
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = iconSize
            // Stack the icons with a small offset so a multi-drag reads
            // visually as "more than one file" instead of overlapping
            // pixel-perfect on the cursor.
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
            draggingItems.append(dragItem)
        }

        view.beginDraggingSession(
            with: draggingItems,
            event: event,
            source: AppKitFileDragSource.shared
        )
        return true
    }
}

private final class AppKitFileDragSource: NSObject, NSDraggingSource {
    static let shared = AppKitFileDragSource()

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
