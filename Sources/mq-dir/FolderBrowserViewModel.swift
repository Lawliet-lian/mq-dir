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
    @Published private(set) var entries: [FileEntry] = [] {
        didSet { rebuildEntriesIndex() }
    }
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
    /// FileEntry.id of the row currently in inline-rename mode (its
    /// label is showing a TextField instead of static text). nil means
    /// no row is being renamed. Driven by the Edit menu's Rename
    /// action, the row context menu, or the future double-click-to-
    /// rename gesture.
    @Published var renamingEntryID: FileEntry.ID?
    /// Live text the rename TextField is bound to. Cleared together
    /// with `renamingEntryID` on commit / cancel.
    @Published var renameDraft: String = ""
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
    @Published var treeChildren: [String: [FileEntry]] = [:] {
        didSet { rebuildEntriesIndex() }
    }
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

    /// FSEvents-backed watcher for the active `folderURL`. Recreated
    /// whenever the user navigates; the watcher's own `deinit` stops
    /// the underlying stream, so dropping the reference is enough to
    /// tear it down. ARC handles the final release on VM deinit.
    private var directoryWatcher: DirectoryWatcher?

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
            updateDirectoryWatcher()
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
        return findEntry(id: selectedID)
    }

    /// O(1) lookup index over `entries` plus every cached `treeChildren`
    /// subtree. Rebuilt by `rebuildEntriesIndex()` on every mutation of
    /// either source. The previous linear scan turned bulk-selection
    /// (`Cmd+A` on ~1000 entries) into O(M×N) and hung the app.
    private var entriesByID: [FileEntry.ID: FileEntry] = [:]

    /// Look up a `FileEntry` by id across both the flat root listing
    /// (`entries`) and every cached tree subtree (`treeChildren`). Tree
    /// view selections live deep in `treeChildren`, never in
    /// `entries`, so anything that operates on the active selection
    /// (rename, etc.) needs this wider search to avoid silently
    /// no-op'ing in tree mode.
    func findEntry(id: FileEntry.ID) -> FileEntry? {
        entriesByID[id]
    }

    private func rebuildEntriesIndex() {
        var index: [FileEntry.ID: FileEntry] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries {
            index[entry.id] = entry
        }
        for children in treeChildren.values {
            for entry in children {
                index[entry.id] = entry
            }
        }
        entriesByID = index
    }

    /// What the file list should render. Recursive `searchResults` while a
    /// query is active, the canonical `entries` for the current folder
    /// otherwise. Selection IDs always resolve against `entries` (so a
    /// recursive hit clicked into a subfolder navigates fresh).
    var visibleEntries: [FileEntry] {
        isFiltering ? searchResults : entries
    }

    /// Flat top-to-bottom sequence of every row currently rendered by
    /// `TreeFileListView` (root → expanded children → expanded
    /// grandchildren …). Used by arrow-key navigation so ↑/↓ in tree mode
    /// walks the same visual order the user sees, not just the root level.
    /// Mirrors `TreeFileListView.orderedForTree` (folders first, files
    /// after).
    var visibleTreeEntries: [FileEntry] {
        guard let root = folderURL else { return [] }
        let rootEntries = treeChildren[root.path] ?? entries
        return flattenTree(rootEntries)
    }

    private func flattenTree(_ entries: [FileEntry]) -> [FileEntry] {
        let folders = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
        var result: [FileEntry] = []
        for entry in folders + files {
            result.append(entry)
            if entry.isDirectory,
               isExpanded(entry.url),
               let children = treeChildren[entry.url.path] {
                result.append(contentsOf: flattenTree(children))
            }
        }
        return result
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
        updateDirectoryWatcher()
    }

    /// Spin up (or replace) the FSEvents watcher for the active folder.
    /// Called whenever `folderURL` changes — `init(state:)` post-restore
    /// and every `navigate(to:)`. The watcher's `onChange` hops back to
    /// the main actor and calls `reload()`, so external changes (a `cp`
    /// finishing in Terminal, a download landing) appear without the
    /// user pressing ⌘R.
    private func updateDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        guard let url = folderURL else { return }
        directoryWatcher = DirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
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

    /// Create "untitled folder" (or "untitled folder 2" / 3 / …) in
    /// the current directory and reload. Mirrors Finder's New Folder
    /// behaviour from the empty-area context menu and the ⌘⇧N shortcut.
    func createNewFolder() {
        guard let folder = folderURL else { return }
        let target = uniqueDestination(for: folder.appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            reload()
        } catch {
            FileHandle.standardError.write(
                Data("[mq-dir new folder] \(error.localizedDescription)\n".utf8)
            )
        }
    }

    /// Open every currently-selected URL with the system default app
    /// — including folders, which would otherwise navigate inside the
    /// pane on a plain Enter. This is what ⇧↩ binds to so users can
    /// force "open in Finder/Preview/whatever the OS associates" even
    /// when our pane navigation would have intercepted the click.
    func openSelectedWithDefaultApp() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// Duplicate every currently-selected entry. Wraps the existing
    /// `duplicate(_:)` so the Edit-menu ⌘D shortcut and the file
    /// context menu's "Duplicate" item share one path.
    func duplicateSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        duplicate(targets)
    }

    /// Newline-joined POSIX paths of the current selection on the
    /// system pasteboard. Bound to ⌘⌥C — Finder's "Copy as Pathname"
    /// shortcut. Plain text only so a paste in a terminal or text
    /// editor lands the path strings directly.
    func copySelectedFilePathsToPasteboard() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Newline-joined filenames (last path components) of the current
    /// selection on the system pasteboard.
    func copySelectedNamesToPasteboard() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
    }

    /// True when cmux.app is installed under any of its known bundle
    /// identifiers — used to gate the "Open in cmux" menu item so it
    /// hides for users who don't have cmux at all.
    var canOpenInCmux: Bool {
        CmuxClient.appURL() != nil
    }

    /// Hand the current folder to cmux as a workspace. Cmux declares
    /// `public.folder` as a CFBundleDocumentType in its Info.plist
    /// and its application(_:open:) wires dropped folders into a new
    /// workspace, so a plain `NSWorkspace.open(_:withApplicationAt:)`
    /// is enough — no URL scheme dance, no AppleScript.
    func openCurrentFolderInCmux() {
        guard let folder = folderURL, let cmux = CmuxClient.appURL() else { return }
        NSWorkspace.shared.open(
            [folder],
            withApplicationAt: cmux,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// Open the current folder in Terminal.app. Uses the modern
    /// async-completion variant of `open(_:withApplicationAt:…)` and
    /// fires-and-forgets — Terminal handles the rest.
    func openCurrentFolderInTerminal() {
        guard let folder = folderURL else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [folder],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// Open the current folder *in Finder* — i.e. show its contents in
    /// a Finder window, not reveal it inside its parent. The empty-area
    /// menu's "Open in Finder" entry binds to this.
    func openCurrentFolderInFinder() {
        guard let folder = folderURL else { return }
        NSWorkspace.shared.open(folder)
    }

    /// Write the current folder's POSIX path to the system pasteboard.
    /// Pure plain-text — no `public.file-url` — so a paste in a
    /// terminal or text editor lands the path string directly.
    func copyCurrentFolderPath() {
        guard let folder = folderURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(folder.path, forType: .string)
    }

    /// True when the system pasteboard carries one or more file URLs
    /// our `pasteFromPasteboard()` would actually copy. Used by the
    /// empty-area context menu to grey out "Paste" when there's
    /// nothing pasteable.
    var canPasteFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
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

    /// Wipe the selection. Used by the file list when the user clicks
    /// empty pane background — Finder's deselect-on-empty-click pattern.
    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.removeAll()
        selectionAnchor = nil
    }

    /// Select every row currently visible in the list (`visibleEntries`,
    /// which honours the active search filter). Anchors on the first
    /// entry so a follow-up shift-extend has a sensible starting point.
    func selectAll() {
        let all = visibleEntries
        guard !all.isEmpty else { return }
        selection = Set(all.map(\.id))
        selectionAnchor = all.first?.id
    }

    /// Write the currently selected file URLs to the system pasteboard
    /// in `public.file-url` form so a follow-up ⌘V in Finder, mqdir
    /// itself, or any other Cocoa file consumer pastes the real files.
    /// No-op on an empty selection.
    func copySelectionToPasteboard() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    /// Cut: same as copy but marks the pasteboard so a subsequent
    /// `pasteFromPasteboard()` *moves* the files instead of copying.
    /// macOS doesn't have a standard "cut" pasteboard convention so
    /// we mark with a private type that only mq-dir reads. Other apps
    /// (Finder, terminals) see the file URLs and treat the operation
    /// as a regular copy on their end — there's no way around that
    /// without OS-level cut, and matching Windows cut semantics
    /// inside mq-dir is the user-facing requirement.
    func cutSelectionToPasteboard() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        pb.setData(Data(), forType: Self.cutMarkerType)
    }

    /// Pasteboard type that marks a cut operation. Empty data — only
    /// the type's presence matters.
    static let cutMarkerType = NSPasteboard.PasteboardType("com.mqdir.cut.urls")

    /// Read file URLs off the system pasteboard and copy (or move,
    /// when the pasteboard carries our cut marker) them into the
    /// current folder. Mirrors Finder's ⌘V (copy) and Windows
    /// File Explorer's ⌘V-after-⌘X (move). Silently skips when the
    /// pasteboard has no file URLs or no folder is open.
    func pasteFromPasteboard() {
        guard let folder = folderURL else { return }
        let pb = NSPasteboard.general
        guard let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !items.isEmpty
        else { return }

        let isCut = pb.types?.contains(Self.cutMarkerType) == true
        let fm = FileManager.default
        for source in items {
            let target = uniqueDestination(for: folder.appendingPathComponent(source.lastPathComponent))
            do {
                if isCut {
                    try fm.moveItem(at: source, to: target)
                } else {
                    try fm.copyItem(at: source, to: target)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("[mq-dir paste] \(source.lastPathComponent): \(error.localizedDescription)\n".utf8)
                )
            }
        }
        // After a cut+paste the source URLs are gone, so wipe the
        // pasteboard to avoid a follow-up paste silently failing on
        // missing files. Plain-copy paste leaves the clipboard alone
        // so the user can paste the same set into multiple folders.
        if isCut {
            pb.clearContents()
        }
        reload()
        // Tell every other pane/tab to refresh — the source folder
        // (potentially open in another pane after a cross-pane
        // cut+paste) and any pane viewing the destination both need
        // to drop the stale entries / pick up the new ones. Same
        // broadcast pattern moveToTrash / acceptDrop / duplicate use.
        NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
    }

    /// Convenience around `moveToTrash` that operates on the live
    /// selection. Used by the Edit menu's Delete shortcut so the user
    /// doesn't need to right-click to trash files.
    func moveSelectionToTrash() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        moveToTrash(targets)
    }

    /// Permanent delete with a destructive NSAlert confirmation.
    /// Bypasses the trash via `FileManager.removeItem(at:)`. Used by
    /// Edit → Delete Immediately (⌘⌥⌫) and the file context menu.
    /// Failures are surfaced in a follow-up alert listing the items
    /// that could not be removed so the operation is never silently
    /// partial.
    func permanentlyDelete(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        let urls = entries.map(\.url)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Delete \u{201C}\(urls[0].lastPathComponent)\u{201D} permanently?"
            : "Delete \(urls.count) items permanently?"
        alert.informativeText = "These items will be deleted immediately. You can't undo this action."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let failures: [(URL, String)] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var failed: [(URL, String)] = []
                for url in urls {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        failed.append((url, error.localizedDescription))
                    }
                }
                return failed
            }.value

            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)

            if !failures.isEmpty {
                let report = NSAlert()
                report.alertStyle = .warning
                report.messageText = failures.count == 1
                    ? "Couldn't delete \u{201C}\(failures[0].0.lastPathComponent)\u{201D}"
                    : "Couldn't delete \(failures.count) items"
                report.informativeText = failures
                    .prefix(8)
                    .map { "• \($0.0.lastPathComponent): \($0.1)" }
                    .joined(separator: "\n")
                report.addButton(withTitle: "OK")
                report.runModal()
            }
        }
    }

    /// Selection wrapper for `permanentlyDelete(_:)` so the Edit menu
    /// shortcut and the context menu share one path.
    func permanentlyDeleteSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        permanentlyDelete(targets)
    }

    /// Compress every entry in `entries` into a single .zip in their
    /// shared parent folder via /usr/bin/zip. Mirrors Finder's
    /// "Compress N items": single selection becomes "<name>.zip"
    /// (folder keeps its name; file drops its extension); multi-
    /// selection becomes "Archive.zip". Collisions auto-rename to
    /// "<name> 2.zip" / "Archive 2.zip" / … (Finder convention).
    /// Cross-folder selections are rejected because zip's relative
    /// pathing assumes a single working directory.
    func compress(_ entries: [FileEntry]) {
        let urls = entries.map(\.url)
        guard !urls.isEmpty else { return }
        guard let parent = urls.first?.deletingLastPathComponent() else { return }
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent() == parent }
        guard sameParent else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't compress items from different folders"
            alert.informativeText = "Select items from one folder to compress them together."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let stem: String
        if entries.count == 1 {
            let only = entries[0]
            stem = only.isDirectory
                ? only.url.lastPathComponent
                : only.url.deletingPathExtension().lastPathComponent
        } else {
            stem = "Archive"
        }
        let destination = Self.uniqueZipDestination(in: parent, stem: stem)
        let sourceNames = urls.map(\.lastPathComponent)

        Task {
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try Self.runCompression(
                        parent: parent,
                        sources: sourceNames,
                        destination: destination
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)

            if let failure {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't compress \u{201C}\(destination.lastPathComponent)\u{201D}"
                alert.informativeText = failure
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Pick a non-existing `<stem>.zip` under `parent`, falling back
    /// to "<stem> 2.zip", "<stem> 3.zip", … on collision (Finder
    /// convention). Same shape as `uniqueExtractionDirectory`.
    nonisolated static func uniqueZipDestination(in parent: URL, stem: String) -> URL {
        let fm = FileManager.default
        let primary = parent.appendingPathComponent("\(stem).zip")
        if !fm.fileExists(atPath: primary.path) { return primary }
        for n in 2...999 {
            let candidate = parent.appendingPathComponent("\(stem) \(n).zip")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return parent.appendingPathComponent("\(stem) \(stamp).zip")
    }

    /// Drive /usr/bin/zip with `currentDirectoryURL = parent` so the
    /// archive stores relative paths (`foo/bar` rather than absolute
    /// `/Users/…/foo/bar`). `-r` recurses into directories, `-y`
    /// preserves symlinks rather than chasing them, `-q` silences
    /// per-file progress so stderr only carries real errors.
    nonisolated static func runCompression(
        parent: URL,
        sources: [String],
        destination: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-y", "-q", destination.path] + sources
        process.currentDirectoryURL = parent
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let trimmed = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed
            throw NSError(
                domain: "mq-dir.compress",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: summary]
            )
        }
    }

    /// True when every entry in `entries` is an archive we know how
    /// to extract (case-insensitive .zip / .tar / .tgz / .tar.gz).
    /// Used by the context menu to decide whether the "Extract"
    /// item is enabled. An empty list returns false so the entry is
    /// hidden when no rows are selected.
    nonisolated static func canExtract(_ entries: [FileEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            archiveKind(for: entry.url) != nil && !entry.isDirectory
        }
    }

    /// Extract every supported archive in `entries` into a sibling
    /// folder named after the archive stem. Each archive runs through
    /// /usr/bin/ditto (zip) or /usr/bin/tar (tar/tgz/tar.gz) on a
    /// detached utility task. After the batch finishes the VM hops
    /// back to the main actor, broadcasts a filesystem change so any
    /// open pane on the same folder picks up the new directory, and
    /// surfaces a single NSAlert with the archives that failed.
    func extractArchives(_ entries: [FileEntry]) {
        let archives: [(URL, ArchiveKind)] = entries.compactMap { entry in
            guard !entry.isDirectory,
                  let kind = Self.archiveKind(for: entry.url) else { return nil }
            return (entry.url, kind)
        }
        guard !archives.isEmpty else { return }

        Task {
            let failures: [(URL, String)] = await Task.detached(priority: .utility) {
                var failed: [(URL, String)] = []
                for (url, kind) in archives {
                    let parent = url.deletingLastPathComponent()
                    let stem = Self.archiveStem(for: url, kind: kind)
                    let dest = Self.uniqueExtractionDirectory(in: parent, stem: stem)
                    do {
                        try Self.runExtraction(kind: kind, archive: url, destination: dest)
                    } catch {
                        failed.append((url, error.localizedDescription))
                    }
                }
                return failed
            }.value

            NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)

            if !failures.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = failures.count == 1
                    ? "Couldn't extract \u{201C}\(failures[0].0.lastPathComponent)\u{201D}"
                    : "Couldn't extract \(failures.count) archives"
                alert.informativeText = failures
                    .prefix(8)
                    .map { "• \($0.0.lastPathComponent): \($0.1)" }
                    .joined(separator: "\n")
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Archive kinds we recognize; drives both the extension test in
    /// `archiveKind(for:)` and the tool/argument selection in
    /// `runExtraction`.
    enum ArchiveKind {
        case zip
        case tar
        case tarGz
    }

    /// Map a URL's extension to a known archive kind, case-insensitive.
    /// Treats `.tgz` as gzip-compressed tar; `.tar.gz` is detected by
    /// looking at the full filename, not just the last extension.
    nonisolated static func archiveKind(for url: URL) -> ArchiveKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }

    /// Strip the archive extension from a filename so we can name the
    /// extraction folder after the contents. ".tar.gz" gets both
    /// extensions trimmed; everything else loses the last one.
    nonisolated static func archiveStem(for url: URL, kind: ArchiveKind) -> String {
        let base = url.lastPathComponent
        switch kind {
        case .tarGz where base.lowercased().hasSuffix(".tar.gz"):
            return String(base.dropLast(".tar.gz".count))
        case .zip, .tar, .tarGz:
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Pick a non-existing folder under `parent` named `stem`, falling
    /// back to "stem 2", "stem 3", … on collision (Finder convention).
    /// Caps at 999 attempts and finally appends a timestamp so the
    /// extraction never silently overwrites.
    nonisolated static func uniqueExtractionDirectory(in parent: URL, stem: String) -> URL {
        let fm = FileManager.default
        let primary = parent.appendingPathComponent(stem)
        if !fm.fileExists(atPath: primary.path) { return primary }
        for n in 2...999 {
            let candidate = parent.appendingPathComponent("\(stem) \(n)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return parent.appendingPathComponent("\(stem) \(stamp)")
    }

    /// Drive ditto/tar against the archive. ditto's -x -k handles zip
    /// (preserves resource forks); tar's -xf handles plain tar and
    /// transparently picks up gzip via -xzf for .tar.gz/.tgz.
    /// `destination` must NOT exist yet — both tools create it with
    /// the right mode bits when given a fresh path.
    nonisolated static func runExtraction(
        kind: ArchiveKind,
        archive: URL,
        destination: URL
    ) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
        case .tar:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", destination.path]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", destination.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // readToEnd() is throws -> Data?, so try? wraps it as
            // Data??; flatten with ?? nil before falling back to
            // an empty Data() so the next String(data:) sees a
            // single-level optional.
            let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let trimmed = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed
            throw NSError(
                domain: "mq-dir.extract",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: summary]
            )
        }
    }

    /// If `target` already exists, append " 2", " 3", … before the
    /// extension until a free slot opens. Mirrors Finder's "untitled
    /// folder 2" behaviour for paste-into-same-dir.
    private func uniqueDestination(for target: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return target }
        let parent = target.deletingLastPathComponent()
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        for i in 2...999 {
            let candidate = parent.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            )
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return target
    }

    /// Move the selection up or down by `offset` rows in `visibleEntries`,
    /// the same set the file list renders. With `extending: true` (Shift
    /// held) grows the selection from the anchor instead of replacing it,
    /// matching Finder's arrow-key behavior. No-op on an empty list.
    func moveSelection(by offset: Int, extending: Bool) {
        // In tree mode walk the flat DFS of expanded rows (matches what
        // the user sees). In list mode keep the existing flat-listing
        // walk so search-result navigation also works.
        let visible = viewMode == .tree ? visibleTreeEntries : visibleEntries
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

    /// Every currently-selected entry, resolved across the flat root
    /// listing AND every cached tree subtree. Tree-mode selections
    /// live in `treeChildren`, never in `entries`, so list-only walks
    /// silently miss them — hence the `findEntry`-driven path.
    var selectedEntries: [FileEntry] {
        selection.compactMap { findEntry(id: $0) }
    }

    /// URLs of every currently-selected entry. Order is set-iteration
    /// order — fine for cut/copy/move where the destination handles
    /// each independently.
    var selectedURLs: [URL] {
        selectedEntries.map(\.url)
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

    /// Begin inline rename for `entry`. Seeds the draft with the
    /// current name and selects the row so the TextField that the
    /// FileEntryRow renders is pointed at the right item.
    func beginRename(_ entry: FileEntry) {
        renamingEntryID = entry.id
        renameDraft = entry.name
        replaceSelection(entry.id)
    }

    /// Begin inline rename for the currently-active selection. Used by
    /// the ⌘⇧R menu shortcut. No-op if nothing is selected.
    func beginRenameForActiveSelection() {
        guard let entry = selectedEntry else { return }
        beginRename(entry)
    }

    /// Commit the in-progress rename. Trims whitespace, no-ops on
    /// empty / unchanged names, refuses to overwrite an existing
    /// sibling, then `FileManager.moveItem` and reloads. Always
    /// clears the rename mode at the end so the row drops back to
    /// static text.
    func commitRename() {
        defer {
            renamingEntryID = nil
            renameDraft = ""
        }
        guard let id = renamingEntryID,
              let entry = findEntry(id: id)
        else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }

        let dest = entry.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else {
            errorMessage = "An item named '\(trimmed)' already exists in this folder."
            return
        }
        do {
            try fm.moveItem(at: entry.url, to: dest)
            reload()
        } catch {
            errorMessage = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    /// Discard the in-progress rename without touching the filesystem.
    func cancelRename() {
        renamingEntryID = nil
        renameDraft = ""
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
