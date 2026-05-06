import AppKit
import QuickLookUI

/// Floating Quick Look panel coordinator. Mirrors Finder: select rows,
/// hit space → system Quick Look panel pops up showing the selection
/// (multi-item navigation included via the panel's built-in arrows);
/// hit space again or Esc to dismiss.
///
/// We don't bother with the formal first-responder dance
/// (`acceptsPreviewPanelControl`, `beginPreviewPanelControl`, …) that
/// the QLPreviewPanel docs spell out. SwiftUI views aren't NSResponders
/// in the chain Quick Look queries, and forcing the wiring back through
/// an NSViewRepresentable ate more code than it saved. Owning the
/// panel directly via a singleton + `reloadData()` on every toggle
/// gives the same UX with a fraction of the surface area.
@MainActor
final class QuickLookManager: NSObject {
    static let shared = QuickLookManager()

    private var urls: [URL] = []

    private override init() { super.init() }

    /// Toggle Quick Look for the given selection. Closes the panel if
    /// it's already open; opens it otherwise. No-op on an empty
    /// selection so a stray space-key in an empty list doesn't pop a
    /// blank panel.
    func toggle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, self.urls == urls {
            panel.close()
            return
        }

        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension QuickLookManager: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

extension QuickLookManager: QLPreviewPanelDelegate {
    // No overrides needed — defaults are correct for our usage.
    // Keeping conformance so we can hook keyboard handlers later
    // (e.g. forward arrow keys back to the underlying file list)
    // without having to re-thread the delegate slot.
}
