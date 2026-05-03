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
    static let mqdirFileSystemChanged = Notification.Name("mqdir.fileSystemChanged")
    /// Posted by `mqdirApp` when the OS notifies us of imminent termination,
    /// so the active window can flush a synchronous save before exit.
    static let mqdirAppWillTerminate = Notification.Name("mqdir.appWillTerminate")
}

