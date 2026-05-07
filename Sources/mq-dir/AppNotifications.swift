import Foundation

extension Notification.Name {
    static let mqdirOpenFolderRequested = Notification.Name("mqdir.openFolderRequested")
    static let mqdirOpenSelectedRequested = Notification.Name("mqdir.openSelectedRequested")
    static let mqdirRevealSelectedRequested = Notification.Name("mqdir.revealSelectedRequested")
    static let mqdirReloadRequested = Notification.Name("mqdir.reloadRequested")
    static let mqdirParentFolderRequested = Notification.Name("mqdir.parentFolderRequested")
    static let mqdirToggleHiddenFilesRequested = Notification.Name("mqdir.toggleHiddenFilesRequested")
    static let mqdirGoBackRequested = Notification.Name("mqdir.goBackRequested")
    static let mqdirGoForwardRequested = Notification.Name("mqdir.goForwardRequested")
    static let mqdirFocusSearchRequested = Notification.Name("mqdir.focusSearchRequested")
    /// Add the focused pane's current folder to the sidebar Favorites list.
    /// Bound to ⌘D in MenuCommands; mirrors Finder's "Add to Sidebar" hotkey.
    static let mqdirAddCurrentFolderToFavoritesRequested =
        Notification.Name("mqdir.addCurrentFolderToFavoritesRequested")
    /// Tabs in the focused pane.
    static let mqdirNewTabRequested = Notification.Name("mqdir.newTabRequested")
    static let mqdirCloseTabRequested = Notification.Name("mqdir.closeTabRequested")
    static let mqdirReopenClosedTabRequested = Notification.Name("mqdir.reopenClosedTabRequested")
    static let mqdirNextTabRequested = Notification.Name("mqdir.nextTabRequested")
    static let mqdirPreviousTabRequested = Notification.Name("mqdir.previousTabRequested")
    /// Posted by ⌘1…⌘9. `userInfo["index"]` is the zero-based tab index;
    /// the focused pane silently ignores out-of-range values.
    static let mqdirSelectTabAtIndexRequested =
        Notification.Name("mqdir.selectTabAtIndexRequested")
    /// "Open in new tab" — ⌘-click on a folder row in tree view. The
    /// receiver appends a new tab in the *focused* pane pointing at
    /// `userInfo["url"]`. Mirrors Finder's ⌘-click-on-folder behavior
    /// rather than VS Code's open-to-the-side, since the user wants the
    /// new view to live next to the source rather than across panes.
    static let mqdirOpenURLInNewTabRequested =
        Notification.Name("mqdir.openURLInNewTabRequested")
    /// Toggle the right-side preview panel for the focused pane's active
    /// tab. Bound to ⌘⇧P, matching Finder's "Show/Hide Preview" hotkey.
    static let mqdirTogglePreviewRequested =
        Notification.Name("mqdir.togglePreviewRequested")
    /// View → As List / As Tree. Bound to ⌘⌥1 / ⌘⌥2 (Finder's ⌘1/⌘2
    /// already belong to tab switching here, Safari-style).
    static let mqdirSetViewModeListRequested =
        Notification.Name("mqdir.setViewModeListRequested")
    static let mqdirSetViewModeTreeRequested =
        Notification.Name("mqdir.setViewModeTreeRequested")
    /// Edit → Select All for the focused pane's file list. Dispatched
    /// via the Edit menu rather than a SwiftUI .onKeyPress on the list,
    /// because the system's standard Select All menu item intercepts
    /// ⌘A before it ever reaches a focused View. The MenuCommands
    /// handler defensively forwards to the system NSText action when a
    /// text field is the first responder so renames / search input
    /// keep their normal text-Select-All behaviour.
    static let mqdirSelectAllRequested =
        Notification.Name("mqdir.selectAllRequested")
    /// Edit → Copy / Paste / Delete for file selections. Same dispatcher
    /// pattern as Select All — the menu item routes here when the
    /// focused responder isn't a text view, so renames / search input
    /// keep their native edit behaviour.
    static let mqdirCopyRequested = Notification.Name("mqdir.copyRequested")
    static let mqdirPasteRequested = Notification.Name("mqdir.pasteRequested")
    static let mqdirDeleteRequested = Notification.Name("mqdir.deleteRequested")
    static let mqdirFileSystemChanged = Notification.Name("mqdir.fileSystemChanged")
    /// Posted by `mqdirApp` when the OS notifies us of imminent termination,
    /// so the active window can flush a synchronous save before exit.
    static let mqdirAppWillTerminate = Notification.Name("mqdir.appWillTerminate")
}

