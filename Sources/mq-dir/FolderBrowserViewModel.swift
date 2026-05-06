import AppKit
import CoreGraphics
import Foundation

// `PaneColumnWidths` and `FileEntrySortKey` now live in `Sources/Core/` so
// that persisted pane state is fully testable from `swift test`. They are
// re-exported by being members of the same Xcode module.

@MainActor
final class FolderBrowserViewModel: ObservableObject, Identifiable {
    /// Stable identity for SwiftUI's diffing — `ObjectIdentifier` is unique
    /// per instance and free, since the VM is always class-bound. The tab
    /// bar uses this to keep its `ForEach` rows tied to the right VM across
    /// reorders and closes.
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    @Published private(set) var folderURL: URL?
    @Published private(set) var entries: [FileEntry] = []
    @Published var selection: Set<FileEntry.ID> = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var includeHidden = false {
        didSet {
            reload()
        }
    }
    /// Per-pane recursive search over `folderURL`. Case-insensitive substring
    /// match on entry name. Empties on folder navigation. Each keystroke
    /// schedules a debounced background walk that populates `searchResults`.
    /// Not persisted — transient view state.
    @Published var searchQuery: String = "" {
        didSet { scheduleSearch() }
    }
    /// Recursive matches for the active `searchQuery`. Empty when not
    /// filtering, or while the first results of a fresh query are still
    /// being gathered.
    @Published private(set) var searchResults: [FileEntry] = []
    /// True between a non-empty `searchQuery` arriving and the resulting
    /// recursive walk completing. Drives the spinner / "Searching…" hint.
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var sortKey: FileEntrySortKey = .name
    @Published private(set) var sortAscending = true
    /// When true, directories sort ahead of files within the same key.
    /// Per-tab so a user can keep folders pinned in one pane while
    /// reading a flat date-sorted list in another.
    @Published private(set) var foldersOnTop = true
    @Published var columnWidths = PaneColumnWidths()
    /// Per-tab view mode. Switching to `.tree` triggers a lazy enumeration
    /// of the root, then of any folder the user expands.
    @Published var viewMode: PaneViewMode = .list
    /// Whether the right-side preview panel is shown for this tab.
    @Published var previewVisible: Bool = false
    /// Set of expanded directory paths in tree mode. Stored as paths so
    /// it survives serialization without bookmark plumbing — losing access
    /// to a path just collapses that node, never breaks the view.
    @Published var expandedPaths: Set<String> = []
    /// Cached children per directory path for tree mode. Populated on
    /// expand, evicted on `reload()`. Doesn't bloat memory in normal use
    /// because the user only expands what they actively browse. The
    /// setter is open so `TreeFileListView` can mirror the root entries
    /// into the cache without a dedicated method on the VM.
    @Published var treeChildren: [String: [FileEntry]] = [:]
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    @Published private(set) var selectionAnchor: FileEntry.ID?

    /// Restored selection paths waiting to be matched against the next
    /// successful `entries` enumeration. Cleared after the match runs.
    private var pendingRestoredSelection: [String] = []

    /// Bookmark for the currently-open `folderURL`, refreshed on each
    /// `openFolder` so a `tabSnapshot()` returns durable state without
    /// re-creating bookmarks at save time.
    private var currentBookmark: Data?

    /// True when this VM holds a `startAccessingSecurityScopedResource()`
    /// claim that must be balanced before changing folders.
    private var hasSecurityScopeAccess = false

    /// Non-isolated mirror of the URL we hold a security-scope claim on,
    /// so `deinit` (which can't touch main-actor state under strict
    /// concurrency) can still balance it. Updated whenever the claim does.
    private nonisolated(unsafe) var scopedURL: URL?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Token handed to the in-flight enumerator so we can stop it early when
    /// a newer query supersedes it. Detached tasks don't inherit cancellation,
    /// so we propagate via a Sendable flag instead of relying on Task.isCancelled.
    private var searchCancelToken: SearchCancelToken?

    /// Default initializer — fresh, empty pane (used by previews and the
    /// first launch when no persisted state exists).
    init() {}

    /// Restoration initializer — rehydrates a tab from a saved `TabState`.
    /// If the bookmark resolves, opens the folder and queues the saved
    /// selection to be matched against the loaded entries.
    init(state: TabState) {
        self.sortKey = state.sortKey
        self.sortAscending = state.sortAscending
        self.foldersOnTop = state.foldersOnTop
        self.includeHidden = state.includeHidden
        self.columnWidths = state.columnWidths
        self.pendingRestoredSelection = state.selectedURLPaths
        self.viewMode = state.viewMode
        self.expandedPaths = Set(state.expandedPaths)
        self.previewVisible = state.previewVisible

        if let bookmark = state.folderBookmark,
           let resolved = PersistenceService.resolveBookmark(bookmark) {
            self.currentBookmark = bookmark
            // Sandbox-readiness: claim security scope before any I/O.
            if resolved.startAccessingSecurityScopedResource() {
                self.hasSecurityScopeAccess = true
                self.scopedURL = resolved
            }
            self.folderURL = resolved
            reload()
            // Pre-warm any expanded subtrees so the tree view doesn't
            // spend its first render flickering placeholders.
            for path in expandedPaths {
                loadChildren(for: URL(fileURLWithPath: path))
            }
        }
    }

    deinit {
        // Balance any outstanding security-scope claim. `scopedURL` is the
        // nonisolated mirror — deinit can't touch main-actor state, so we
        // only release through this side-channel pointer.
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Snapshot the live tab state for serialization.
    func tabSnapshot() -> TabState {
        TabState(
            folderBookmark: currentBookmark,
            sortKey: sortKey,
            sortAscending: sortAscending,
            includeHidden: includeHidden,
            columnWidths: columnWidths,
            selectedURLPaths: selectedURLs.map(\.path),
            viewMode: viewMode,
            expandedPaths: Array(expandedPaths),
            previewVisible: previewVisible,
            foldersOnTop: foldersOnTop
        )
    }

    // MARK: Tree mode

    /// Toggle expansion for a directory in tree mode. Lazy-loads children
    /// on first expand; collapsing keeps the cached children so re-expand
    /// is instant. Cache invalidates only on `reload()`.
    func toggleExpanded(_ url: URL) {
        let path = url.path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            if treeChildren[path] == nil {
                loadChildren(for: url)
            }
        }
    }

    func isExpanded(_ url: URL) -> Bool {
        expandedPaths.contains(url.path)
    }

    /// Synchronous child enumeration. The tree typically lazy-loads only
    /// the folders the user touches, so blocking the main actor briefly
    /// here is fine; the call is bounded by one directory's worth of
    /// entries. If a folder ever proves slow we can move this to a Task.
    private func loadChildren(for url: URL) {
        guard let entries = try? FileSystemService()
            .enumerateDirectory(at: url, includingHidden: includeHidden)
        else { return }
        treeChildren[url.path] = FileEntrySorter.sorted(
            entries, by: sortKey, ascending: sortAscending, foldersOnTop: foldersOnTop
        )
    }

    /// Discard cached subtree contents so a fresh `reload()` of the root
    /// also refreshes any expanded children. Re-issues child loads for the
    /// folders that were expanded, which keeps their state visible without
    /// requiring the user to toggle them again.
    func refreshTreeChildren() {
        let stillExpanded = expandedPaths
        treeChildren.removeAll()
        for path in stillExpanded {
            loadChildren(for: URL(fileURLWithPath: path))
        }
    }

    var selectedEntry: FileEntry? {
        guard let selectedID = selection.first else {
            return nil
        }

        return entries.first { $0.id == selectedID }
    }

    /// What the file list should render. Recursive `searchResults` while a
    /// query is active, the canonical `entries` for the current folder
    /// otherwise. Selection IDs always resolve against `entries` (so a
    /// recursive hit clicked into a subfolder navigates fresh).
    var visibleEntries: [FileEntry] {
        isFiltering ? searchResults : entries
    }

    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var folderDisplayPath: String {
        folderURL?.path(percentEncoded: false) ?? "No folder selected"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.message = "Choose a folder to browse in mq-dir."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        openFolder(url)
    }

    /// Navigate to a folder, recording the current location in the back stack
    /// and clearing the forward stack. This is the user-initiated path.
    /// Refreshes the security-scoped bookmark so persistence captures the
    /// latest folder reference without a separate "save bookmark" step.
    func openFolder(_ url: URL) {
        if let current = folderURL, current != url {
            backStack.append(current)
        }
        forwardStack.removeAll()
        // Refresh the durable bookmark for persistence. A failure here is
        // non-fatal — we just won't be able to restore this folder across
        // launches in sandboxed builds, which matches non-sandboxed today.
        currentBookmark = try? PersistenceService.makeBookmark(for: url)
        navigate(to: url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = folderURL {
            forwardStack.append(current)
        }
        navigate(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = folderURL {
            backStack.append(current)
        }
        navigate(to: next)
    }

    /// Bare navigation that does NOT touch back/forward stacks. Used by
    /// `goBack`, `goForward`, and the initial `openFolder` after stack
    /// bookkeeping. Resets selection and triggers a reload.
    ///
    /// Balances any outstanding security-scope access on the previous URL
    /// before assigning the new one — required for sandboxed builds.
    private func navigate(to url: URL) {
        if hasSecurityScopeAccess, let previous = folderURL, previous != url {
            previous.stopAccessingSecurityScopedResource()
            hasSecurityScopeAccess = false
            scopedURL = nil
        }
        folderURL = url
        selection.removeAll()
        // Drop the per-folder filter so a query typed in the previous folder
        // doesn't bleed into the new listing (matches Finder).
        searchQuery = ""
        // User-driven navigation supersedes any pending restored selection.
        pendingRestoredSelection = []
        reload()
    }

    /// Debounced trigger fired by the `searchQuery` setter. Cancels any
    /// in-flight enumeration, then (after a short quiet window) walks the
    /// current folder recursively, collecting entries whose name matches
    /// the query case-insensitively. Empty queries reset the result set
    /// and never schedule a walk.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchCancelToken?.cancel()

        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let root = folderURL else {
            searchResults = []
            isSearching = false
            return
        }

        let token = SearchCancelToken()
        searchCancelToken = token
        isSearching = true

        let includeHidden = includeHidden

        searchTask = Task { [weak self] in
            // Always clear the spinner on the way out, even if we get
            // cancelled (folder navigation, supersede, deinit). Without
            // this the sidebar's "Searching…" hint can stick on screen.
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.searchCancelToken === token else { return }
                    self.isSearching = false
                }
            }

            // Coalesce keystrokes — only the final pause kicks the walk.
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled || token.isCancelled { return }

            let results = await Task.detached(priority: .userInitiated) {
                (try? FileSystemService().enumerateMatching(
                    root: root,
                    query: trimmed,
                    includingHidden: includeHidden,
                    isCancelled: { token.isCancelled }
                )) ?? []
            }.value

            if Task.isCancelled || token.isCancelled { return }
            guard let self else { return }
            self.searchResults = FileEntrySorter.sorted(
                results,
                by: self.sortKey,
                ascending: self.sortAscending,
                foldersOnTop: self.foldersOnTop
            )
        }
    }

    func reload() {
        guard let folderURL else {
            return
        }

        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        let includeHidden = includeHidden
        let sortKey = sortKey
        let sortAscending = sortAscending
        let foldersOnTop = foldersOnTop

        loadTask = Task {
            do {
                let loadedEntries = try await Task.detached(priority: .userInitiated) {
                    try FileSystemService().enumerateDirectory(
                        at: folderURL,
                        includingHidden: includeHidden
                    )
                }.value

                guard !Task.isCancelled else {
                    return
                }

                entries = FileEntrySorter.sorted(
                    loadedEntries,
                    by: sortKey,
                    ascending: sortAscending,
                    foldersOnTop: foldersOnTop
                )
                // Restore selection from a persisted PaneState if any —
                // intersect saved paths with the freshly enumerated entries
                // so deleted/moved files don't leave dangling IDs.
                if !pendingRestoredSelection.isEmpty {
                    let savedPaths = Set(pendingRestoredSelection)
                    selection = Set(
                        entries.filter { savedPaths.contains($0.url.path) }.map(\.id)
                    )
                    selectionAnchor = selection.first
                    pendingRestoredSelection = []
                } else {
                    selection = selection.filter { selectedID in
                        entries.contains { $0.id == selectedID }
                    }
                }
                isLoading = false
                // Re-fetch any expanded subtrees so the tree view reflects
                // the same on-disk state the flat list just refreshed against.
                refreshTreeChildren()
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                entries = []
                selection.removeAll()
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func setSort(_ key: FileEntrySortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }

        entries = FileEntrySorter.sorted(entries, by: sortKey, ascending: sortAscending, foldersOnTop: foldersOnTop)
        // Apply the same sort across every cached tree subtree so the
        // hierarchy stays internally consistent.
        treeChildren = treeChildren.mapValues {
            FileEntrySorter.sorted($0, by: sortKey, ascending: sortAscending, foldersOnTop: foldersOnTop)
        }
    }

    /// Toggle whether directories pin to the top of every sort. Re-sorts
    /// the live entries immediately so the change is visible without
    /// needing to flip the sort key.
    func setFoldersOnTop(_ value: Bool) {
        guard foldersOnTop != value else { return }
        foldersOnTop = value
        entries = FileEntrySorter.sorted(entries, by: sortKey, ascending: sortAscending, foldersOnTop: foldersOnTop)
        treeChildren = treeChildren.mapValues {
            FileEntrySorter.sorted($0, by: sortKey, ascending: sortAscending, foldersOnTop: foldersOnTop)
        }
    }

    func openSelected() {
        guard let selectedEntry else {
            return
        }

        open(selectedEntry)
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            openFolder(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func revealSelected() {
        guard let selectedEntry else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([selectedEntry.url])
    }

    func openParentFolder() {
        guard let folderURL else {
            return
        }

        let parentURL = folderURL.deletingLastPathComponent()
        guard parentURL != folderURL else {
            return
        }

        openFolder(parentURL)
    }

    func toggleHiddenFiles() {
        includeHidden.toggle()
    }

    // MARK: Selection (multi-select with cmd / shift)

    func replaceSelection(_ id: FileEntry.ID) {
        selection = [id]
        selectionAnchor = id
    }

    func toggleSelection(_ id: FileEntry.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        selectionAnchor = id
    }

    func extendSelection(to id: FileEntry.ID) {
        guard let anchor = selectionAnchor,
              let anchorIdx = entries.firstIndex(where: { $0.id == anchor }),
              let targetIdx = entries.firstIndex(where: { $0.id == id })
        else {
            replaceSelection(id)
            return
        }
        let lower = min(anchorIdx, targetIdx)
        let upper = max(anchorIdx, targetIdx)
        selection = Set(entries[lower...upper].map(\.id))
    }

    /// Move the selection up or down by `offset` rows in `visibleEntries`,
    /// the same set the file list renders. With `extending: true` (Shift
    /// held) grows the selection from the anchor instead of replacing it,
    /// matching Finder's arrow-key behavior. No-op on an empty list.
    func moveSelection(by offset: Int, extending: Bool) {
        let visible = visibleEntries
        guard !visible.isEmpty else { return }

        let currentIdx: Int
        if let anchor = selectionAnchor,
           let idx = visible.firstIndex(where: { $0.id == anchor }) {
            currentIdx = idx
        } else if let firstID = selection.first,
                  let idx = visible.firstIndex(where: { $0.id == firstID }) {
            currentIdx = idx
        } else {
            // No prior selection — arrow-down lands on the first row,
            // arrow-up on the last (Finder convention).
            guard let target = offset >= 0 ? visible.first : visible.last
            else { return }
            replaceSelection(target.id)
            return
        }

        let newIdx = max(0, min(visible.count - 1, currentIdx + offset))
        let target = visible[newIdx]

        if extending,
           let anchor = selectionAnchor,
           let anchorIdx = visible.firstIndex(where: { $0.id == anchor }) {
            let lower = min(anchorIdx, newIdx)
            let upper = max(anchorIdx, newIdx)
            selection = Set(visible[lower...upper].map(\.id))
        } else {
            replaceSelection(target.id)
        }
    }

    /// URLs of every currently-selected entry, in row order.
    var selectedURLs: [URL] {
        entries.filter { selection.contains($0.id) }.map(\.url)
    }

    /// Right-click "Duplicate" → for each entry, copy in place with a
    /// Finder-style " 2" / " 3" suffix. Mirrors `acceptDrop`'s detached-task
    /// + system-wide reload pattern so an open second pane viewing the same
    /// folder also picks up the new copies.
    func duplicate(_ entries: [FileEntry]) {
        let urls = entries.map(\.url)
        Task {
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for source in urls {
                    let parent = source.deletingLastPathComponent()
                    let dest = Self.uniqueDestination(for: source, in: parent)
                    do {
                        try fm.copyItem(at: source, to: dest)
                    } catch {
                        FileHandle.standardError.write(
                            Data("[mq-dir duplicate] \(source.lastPathComponent): \(error.localizedDescription)\n".utf8)
                        )
                    }
                }
            }.value
            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
        }
    }

    /// Right-click "Move to Trash" → `FileManager.trashItem` per entry.
    /// Failures (permission, missing file) are logged to stderr and skipped
    /// so a partial selection doesn't abort the whole operation.
    func moveToTrash(_ entries: [FileEntry]) {
        let urls = entries.map(\.url)
        Task {
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for url in urls {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        FileHandle.standardError.write(
                            Data("[mq-dir trash] \(url.lastPathComponent): \(error.localizedDescription)\n".utf8)
                        )
                    }
                }
            }.value
            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
        }
    }

    /// Move (or copy across volumes) a list of file URLs into a destination folder.
    /// `copy=true` forces copy (Option held). Default Finder semantics: same-volume = move,
    /// cross-volume = copy. On name conflict, the destination gets " 2", " 3", ... suffix
    /// (Finder convention). After completion, broadcasts a system-wide reload.
    func acceptDrop(_ urls: [URL], into destinationFolder: URL, copy: Bool) {
        Task {
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for source in urls {
                    var dest = destinationFolder.appendingPathComponent(source.lastPathComponent)
                    if source == dest { continue }
                    // Reject dropping a folder into itself or any descendant.
                    if dest.path.hasPrefix(source.path + "/") { continue }
                    // Auto-rename on conflict instead of skipping.
                    if fm.fileExists(atPath: dest.path) {
                        dest = Self.uniqueDestination(for: source, in: destinationFolder)
                    }
                    do {
                        if copy {
                            try fm.copyItem(at: source, to: dest)
                        } else {
                            try fm.moveItem(at: source, to: dest)
                        }
                    } catch {
                        FileHandle.standardError.write(
                            Data("[mq-dir drop] \(source.lastPathComponent): \(error.localizedDescription)\n".utf8)
                        )
                    }
                }
            }.value
            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
        }
    }

    /// Generates "name 2.ext", "name 3.ext", ... for the first non-existent path.
    /// Caps at 500 attempts; falls back to a timestamped name to avoid hanging.
    nonisolated static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for n in 2...500 {
            let suffix = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(suffix)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let fallback = ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
        return folder.appendingPathComponent(fallback)
    }
}

/// Thread-safe one-shot cancel flag handed across actor boundaries to the
/// detached enumerator. Detached tasks don't inherit Swift's structured
/// cancellation, so we propagate intent through this Sendable token instead.
final class SearchCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
}
