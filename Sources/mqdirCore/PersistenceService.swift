import Foundation

/// Per-tab state that survives an app restart.
///
/// Folder reference is stored as a security-scoped bookmark (not a raw path)
/// so the file manager remains operable when the app moves to the App Store
/// sandbox. Selection is stored as URL-paths and re-intersected with the
/// freshly enumerated entries on restore.
struct TabState: Codable, Equatable, Sendable {
    var folderBookmark: Data?
    var sortKey: FileEntrySortKey
    var sortAscending: Bool
    var includeHidden: Bool
    var columnWidths: PaneColumnWidths
    var selectedURLPaths: [String]
    /// `.list` flat columns vs `.tree` VS Code-style nested view.
    var viewMode: PaneViewMode
    /// Filesystem paths the tree view should render expanded. Stored as
    /// raw paths (not bookmarks) because they're positional cues — losing
    /// access to a folder just means it renders collapsed, not broken.
    var expandedPaths: [String]
    /// Whether the right-side preview panel is visible for this tab.
    /// Defaults off so existing tabs don't grow a new chrome surface
    /// behind the user's back on upgrade.
    var previewVisible: Bool
    /// When true, directories sort ahead of files within the same key.
    /// Defaults true to preserve the historical Finder-list behaviour
    /// for upgraded state.json files; user can flip it per tab from the
    /// column header context menu when they want pure key-only sorting.
    var foldersOnTop: Bool

    init(
        folderBookmark: Data? = nil,
        sortKey: FileEntrySortKey = .name,
        sortAscending: Bool = true,
        includeHidden: Bool = false,
        columnWidths: PaneColumnWidths = PaneColumnWidths(),
        selectedURLPaths: [String] = [],
        viewMode: PaneViewMode = .list,
        expandedPaths: [String] = [],
        previewVisible: Bool = false,
        foldersOnTop: Bool = true
    ) {
        self.folderBookmark = folderBookmark
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeHidden = includeHidden
        self.columnWidths = columnWidths
        self.selectedURLPaths = selectedURLPaths
        self.viewMode = viewMode
        self.expandedPaths = expandedPaths
        self.previewVisible = previewVisible
        self.foldersOnTop = foldersOnTop
    }

    /// Default the new fields when reading a `state.json` written before
    /// the tree view / preview pane existed. Without this the auto-synthesized
    /// decoder would refuse to load any old file.
    private enum CodingKeys: String, CodingKey {
        case folderBookmark, sortKey, sortAscending, includeHidden,
             columnWidths, selectedURLPaths, viewMode, expandedPaths,
             previewVisible, foldersOnTop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            folderBookmark: try c.decodeIfPresent(Data.self, forKey: .folderBookmark),
            sortKey: (try c.decodeIfPresent(FileEntrySortKey.self, forKey: .sortKey)) ?? .name,
            sortAscending: (try c.decodeIfPresent(Bool.self, forKey: .sortAscending)) ?? true,
            includeHidden: (try c.decodeIfPresent(Bool.self, forKey: .includeHidden)) ?? false,
            columnWidths: (try c.decodeIfPresent(PaneColumnWidths.self, forKey: .columnWidths)) ?? PaneColumnWidths(),
            selectedURLPaths: (try c.decodeIfPresent([String].self, forKey: .selectedURLPaths)) ?? [],
            viewMode: (try c.decodeIfPresent(PaneViewMode.self, forKey: .viewMode)) ?? .list,
            expandedPaths: (try c.decodeIfPresent([String].self, forKey: .expandedPaths)) ?? [],
            previewVisible: (try c.decodeIfPresent(Bool.self, forKey: .previewVisible)) ?? false,
            foldersOnTop: (try c.decodeIfPresent(Bool.self, forKey: .foldersOnTop)) ?? true
        )
    }
}

/// Per-pane state. A pane carries an ordered list of tabs and which one is
/// currently active. Always carries at least one tab so the pane is never
/// in a tabless state — closing the last tab leaves an empty tab in place.
struct PaneState: Codable, Equatable, Sendable {
    var tabs: [TabState]
    var activeTabIndex: Int

    init(tabs: [TabState] = [TabState()], activeTabIndex: Int = 0) {
        precondition(!tabs.isEmpty, "PaneState must carry at least one tab")
        self.tabs = tabs
        self.activeTabIndex = max(0, min(activeTabIndex, tabs.count - 1))
    }

    /// Backward-compat decode: pre-tabs `state.json` had each pane stored as
    /// a flat `TabState` (folderBookmark/sortKey/...). Detect that shape and
    /// promote it to a single-tab pane so users don't lose their last folder.
    private enum CodingKeys: String, CodingKey {
        case tabs, activeTabIndex
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let tabs = try? c.decode([TabState].self, forKey: .tabs)
        {
            let active = (try? c.decodeIfPresent(Int.self, forKey: .activeTabIndex)) ?? 0
            self.init(
                tabs: tabs.isEmpty ? [TabState()] : tabs,
                activeTabIndex: active
            )
            return
        }
        // Legacy shape: decode the whole container as a single TabState.
        let legacy = try TabState(from: decoder)
        self.init(tabs: [legacy], activeTabIndex: 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(activeTabIndex, forKey: .activeTabIndex)
    }
}

/// One sidebar favorite. Folder reference is stored as a security-scoped
/// bookmark like `PaneState.folderBookmark`; `fallbackPath` is the raw path
/// at the time of save, used only to display a stale entry when bookmark
/// resolution fails (e.g. the folder was deleted on disk).
struct Favorite: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// User-editable display name. Defaults to the folder's last path
    /// component on creation; Rename overwrites it.
    var label: String
    var bookmark: Data?
    var fallbackPath: String?

    init(id: UUID = UUID(), label: String, bookmark: Data? = nil, fallbackPath: String? = nil) {
        self.id = id
        self.label = label
        self.bookmark = bookmark
        self.fallbackPath = fallbackPath
    }
}

/// Window-level state that survives an app restart, scoped to a single
/// project. Always carries four pane states even when `layout` shows
/// fewer panes — growing the layout (e.g. single → 4-pane) restores the
/// previously-loaded folders rather than reverting to empty. Favorites
/// live a level up on `WorkspaceState` because they're cross-project.
struct WindowState: Codable, Equatable, Sendable {
    var layout: PaneLayout
    var focusedPaneIndex: Int
    var panes: [PaneState]

    init(layout: PaneLayout, focusedPaneIndex: Int, panes: [PaneState]) {
        precondition(panes.count == 4, "WindowState always carries exactly 4 pane records")
        self.layout = layout
        self.focusedPaneIndex = focusedPaneIndex
        self.panes = panes
    }

    static let empty = WindowState(
        layout: .four,
        focusedPaneIndex: 0,
        panes: Array(repeating: PaneState(), count: 4)
    )
}

/// One named workspace. Carries a `WindowState` that fully describes the
/// pane/tab arrangement when this project is active. Switching projects
/// snapshots the outgoing project's `state` and applies the incoming
/// project's `state` to fresh pane VMs.
struct Project: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var state: WindowState

    init(id: UUID = UUID(), name: String, state: WindowState = .empty) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// Top-level persisted state. Holds cross-project surface (favorites)
/// alongside the project list and which one is active. Old `state.json`
/// files from before this struct existed get migrated by the custom
/// decoder into a single "Default" project so users don't lose state.
struct WorkspaceState: Codable, Equatable, Sendable {
    var favorites: [Favorite]
    /// Distinguishes "user has explicitly emptied favorites" from "first
    /// launch / pre-favorites schema." When false, the sidebar seeds the
    /// six home subdirectories and flips the flag so we don't re-seed
    /// after the user clears the list.
    var favoritesSeeded: Bool
    var activeProjectID: UUID
    var projects: [Project]

    init(
        favorites: [Favorite] = [],
        favoritesSeeded: Bool = false,
        activeProjectID: UUID,
        projects: [Project]
    ) {
        precondition(!projects.isEmpty, "WorkspaceState always carries at least one project")
        self.favorites = favorites
        self.favoritesSeeded = favoritesSeeded
        self.activeProjectID = activeProjectID
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case favorites, favoritesSeeded, activeProjectID, projects
        // Legacy keys (pre-projects schema)
        case layout, focusedPaneIndex, panes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // New shape — has a top-level `projects` array.
        if let rawProjects = try? c.decode([Project].self, forKey: .projects) {
            let projects = rawProjects.isEmpty ? [Project(name: "Default")] : rawProjects
            let active = (try? c.decode(UUID.self, forKey: .activeProjectID)) ?? projects.first!.id
            // Tolerate dangling activeProjectID — fall back to the first
            // project so a corrupt write can't lock the user out.
            let resolved = projects.contains(where: { $0.id == active }) ? active : projects.first!.id
            self.init(
                favorites: (try? c.decodeIfPresent([Favorite].self, forKey: .favorites)) ?? [],
                favoritesSeeded: (try? c.decodeIfPresent(Bool.self, forKey: .favoritesSeeded)) ?? false,
                activeProjectID: resolved,
                projects: projects
            )
            return
        }

        // Legacy shape — top-level WindowState fields. Wrap as a single
        // "Default" project so the user's last layout/panes survive the
        // upgrade unchanged.
        let layout = (try? c.decodeIfPresent(PaneLayout.self, forKey: .layout)) ?? .four
        let focused = (try? c.decodeIfPresent(Int.self, forKey: .focusedPaneIndex)) ?? 0
        let panes = (try? c.decodeIfPresent([PaneState].self, forKey: .panes))
            ?? Array(repeating: PaneState(), count: 4)
        let favorites = (try? c.decodeIfPresent([Favorite].self, forKey: .favorites)) ?? []
        let seeded = (try? c.decodeIfPresent(Bool.self, forKey: .favoritesSeeded)) ?? false

        let migrated = Project(
            name: "Default",
            state: WindowState(
                layout: layout,
                focusedPaneIndex: focused,
                panes: panes.isEmpty ? Array(repeating: PaneState(), count: 4) : panes
            )
        )
        self.init(
            favorites: favorites,
            favoritesSeeded: seeded,
            activeProjectID: migrated.id,
            projects: [migrated]
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(favoritesSeeded, forKey: .favoritesSeeded)
        try c.encode(activeProjectID, forKey: .activeProjectID)
        try c.encode(projects, forKey: .projects)
    }

    static var empty: WorkspaceState {
        let project = Project(name: "Default")
        return WorkspaceState(
            favorites: [],
            favoritesSeeded: false,
            activeProjectID: project.id,
            projects: [project]
        )
    }
}

/// Reads and writes the persisted window state to disk.
///
/// I/O is intentionally synchronous on the call site; the *caller* (typically
/// `MainWindowView` for debounced saves) is responsible for hopping off the
/// main thread via `Task.detached`. This keeps the service itself a thin,
/// testable wrapper around `JSONEncoder` / `Data.write(to:)` rather than a
/// concurrency boundary.
// `@unchecked Sendable` because the only stored property that isn't
// trivially `Sendable` is `FileManager`, which Apple documents as
// thread-safe for the read/write/exist/createDirectory operations we use.
// We never mutate the manager itself — its delegate is left nil.
struct PersistenceService: @unchecked Sendable {
    private let stateURL: URL
    private let fileManager: FileManager

    /// Production initializer: writes to
    /// `~/Library/Application Support/com.mqdir.app/state.json`.
    /// Throws if the support directory cannot be located or created.
    init(fileManager: FileManager = .default) throws {
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleDir = supportRoot.appendingPathComponent("com.mqdir.app", isDirectory: true)
        if !fileManager.fileExists(atPath: bundleDir.path) {
            try fileManager.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        }
        self.stateURL = bundleDir.appendingPathComponent("state.json", isDirectory: false)
        self.fileManager = fileManager
    }

    /// Test initializer: writes to an explicit URL. Creates the parent
    /// directory if needed. Used so tests don't touch the real
    /// `~/Library/Application Support`.
    init(stateURL: URL, fileManager: FileManager = .default) throws {
        let parent = stateURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        self.stateURL = stateURL
        self.fileManager = fileManager
    }

    /// Returns nil when the file is missing, unreadable, or contains
    /// corrupt JSON. Callers always treat a `nil` load as "first launch".
    /// Never throws — corruption recovery is part of the contract.
    func loadState() -> WorkspaceState? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceState.self, from: data)
    }

    /// Writes the state atomically. Throws so the caller (typically a
    /// debounced save) can log a failure without crashing.
    ///
    /// Lock the file down to owner-only after writing — the JSON contains
    /// security-scoped bookmarks (and, in App Store mode, what amount to
    /// authentication tokens for each remembered folder), so the default
    /// umask (often 0644) is too permissive for a multi-user box.
    /// Permission failures are non-fatal: the write succeeded, the file
    /// is just slightly more readable than ideal.
    func saveState(_ state: WorkspaceState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    /// On-disk location of the state file (exposed for diagnostics/tests).
    var fileURL: URL { stateURL }

    // MARK: - Bookmarks

    /// Creates a security-scoped bookmark for an existing folder URL.
    /// The caller stores the returned `Data` in `PaneState.folderBookmark`.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a previously-saved bookmark back to its URL.
    /// Returns `nil` if the bookmark is corrupt. The *caller* is responsible
    /// for calling `startAccessingSecurityScopedResource()` on the returned
    /// URL. A *stale* bookmark still resolves; we surface the URL so the
    /// caller can refresh on next openFolder rather than losing the entry.
    static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
