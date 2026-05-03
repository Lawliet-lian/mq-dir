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
    static let mqdirFileSystemChanged = Notification.Name("mqdir.fileSystemChanged")
    /// Posted by `mqdirApp` when the OS notifies us of imminent termination,
    /// so the active window can flush a synchronous save before exit.
    static let mqdirAppWillTerminate = Notification.Name("mqdir.appWillTerminate")
}

