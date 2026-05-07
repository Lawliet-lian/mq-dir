import Foundation

/// Cross-pane tab drag bookkeeping.
///
/// Tab reorder lives in `TabReorderDropDelegate` but had no way to learn
/// which pane the dragged chip came from — a per-pane `@State` binding
/// only sees same-pane drags. This singleton remembers (sourcePane,
/// tabID) for the duration of a drag so a drop on a different pane can
/// detach the tab from its origin and attach it to the destination.
///
/// Lifetime: a `MainWindowView` instance registers the four pane VMs on
/// init via `register(panes:)`. A project switch tears down the
/// `MainWindowView` (`.id(activeProjectID)` keys its identity) and the
/// next instance re-registers, so the coordinator's pane references
/// always match the live panes for the active project.
@MainActor
final class TabDragCoordinator: ObservableObject {
    static let shared = TabDragCoordinator()

    private var allPanes: [PaneTabsViewModel] = []
    /// Published so each `BrowserPaneView` can observe the
    /// drag-in-flight state and clear its insertion-marker preview the
    /// instant the drag ends. The `setPreview`-via-Binding path inside
    /// the drop delegate isn't always enough — SwiftUI sometimes
    /// processes a sibling drop zone's dropEntered AFTER performDrop
    /// returns, re-setting the preview. Observing this gives every
    /// pane a single source-of-truth signal.
    @Published private(set) var sourcePaneIndex: Int?
    @Published private(set) var sourceTabID: ObjectIdentifier?

    private init() {}

    func register(panes: [PaneTabsViewModel]) {
        self.allPanes = panes
    }

    func begin(sourcePaneIndex: Int, tabID: ObjectIdentifier) {
        self.sourcePaneIndex = sourcePaneIndex
        self.sourceTabID = tabID
    }

    func clear() {
        sourcePaneIndex = nil
        sourceTabID = nil
    }

    /// Detach the dragging tab from its source pane and insert it into
    /// `targetPaneIndex` at `tabIndex`. Returns true on success. Updates
    /// `sourcePaneIndex` to the destination so a subsequent reorder
    /// inside the destination pane works correctly during the same
    /// drag session.
    @discardableResult
    func moveTab(toPaneIndex targetPaneIndex: Int, atTabIndex tabIndex: Int) -> Bool {
        guard let source = sourcePaneIndex,
              let tabID = sourceTabID,
              source != targetPaneIndex,
              allPanes.indices.contains(source),
              allPanes.indices.contains(targetPaneIndex)
        else { return false }

        guard let detached = allPanes[source].detachTab(id: tabID) else { return false }
        allPanes[targetPaneIndex].attachTab(detached, at: tabIndex)
        sourcePaneIndex = targetPaneIndex
        return true
    }
}
