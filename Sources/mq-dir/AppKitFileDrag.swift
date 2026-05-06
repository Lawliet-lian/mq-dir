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
    func appKitFileDrag(primary: URL, multiURLs: [URL] = []) -> some View {
        modifier(AppKitFileDragModifier(primary: primary, multiURLs: multiURLs))
    }
}

private struct AppKitFileDragModifier: ViewModifier {
    let primary: URL
    let multiURLs: [URL]

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

        let item = NSPasteboardItem()
        if let data = primary.absoluteString.data(using: .utf8) {
            item.setData(data, forType: .fileURL)
        }
        if multiURLs.count > 1,
           let data = try? JSONEncoder().encode(multiURLs.map(\.absoluteString)) {
            item.setData(
                data,
                forType: NSPasteboard.PasteboardType(DragDropSupport.mqdirSelectionTypeIdentifier)
            )
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let icon = NSWorkspace.shared.icon(forFile: primary.path)
        let iconSize = NSSize(width: 32, height: 32)
        icon.size = iconSize
        let cursorInView = view.convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(
                x: cursorInView.x - iconSize.width / 2,
                y: cursorInView.y - iconSize.height / 2,
                width: iconSize.width,
                height: iconSize.height
            ),
            contents: icon
        )

        view.beginDraggingSession(
            with: [draggingItem],
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
