import AppKit
import SwiftUI

struct MainWindowView: View {
    @StateObject private var pane0: PaneTabsViewModel
    @StateObject private var pane1: PaneTabsViewModel
    @StateObject private var pane2: PaneTabsViewModel
    @StateObject private var pane3: PaneTabsViewModel
    @StateObject private var sidebar: SidebarViewModel

    @State private var layout: PaneLayout
    @State private var focusedPaneIndex: Int
    @State private var sidebarSelection: URL?
    @FocusState private var searchFocused: Bool
    /// Gates the real TextField behind a tap. While false the field renders
    /// as a static placeholder so SwiftUI doesn't auto-promote it to the
    /// window's first responder on appearance.
    @State private var searchActive: Bool = false

    /// Coalesces rapid state mutations into one save. Cancelled and
    /// restarted whenever a watched value changes; on natural completion
    /// (no further changes for ~500ms) it serializes the snapshot off the
    /// main actor.
    @State private var saveDebounceTask: Task<Void, Never>?

    /// Lazily-resolved persistence service. Held as a constant so we don't
    /// re-create the support directory on every save.
    private let persistence: PersistenceService?

    init() {
        // Resolve the persistence service first so the initial state can
        // come from disk. Failure to create it (e.g. read-only home dir in
        // CI) degrades gracefully to a fresh window.
        let service = try? PersistenceService()
        let restored = service?.loadState() ?? WindowState.empty

        self.persistence = service
        self._layout = State(initialValue: restored.layout)
        self._focusedPaneIndex = State(
            initialValue: min(max(restored.focusedPaneIndex, 0), 3)
        )

        // Always rehydrate four panes — any layout shrink stashes the
        // off-screen pane state so it returns when the layout grows back.
        // Each pane carries its own tab list; the VM forwards every nested
        // tab's objectWillChange so the debounced save still fires when
        // any tab anywhere mutates state.
        let panes = restored.panes
        self._pane0 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[0]))
        self._pane1 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[1]))
        self._pane2 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[2]))
        self._pane3 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[3]))

        // First-run seeding for the sidebar. After this point the saved
        // `favoritesSeeded` is always true so subsequent launches respect
        // the user's edits (including "removed everything").
        let seed = SidebarViewModel.seedIfNeeded(restored)
        self._sidebar = StateObject(wrappedValue: SidebarViewModel(favorites: seed.favorites))
    }

    var body: some View {
        windowChrome
            .background(Theme.Color.windowBg)
            .modifier(SaveTriggers(
                pane0: pane0, pane1: pane1, pane2: pane2, pane3: pane3,
                sidebar: sidebar,
                layout: $layout,
                focusedPaneIndex: $focusedPaneIndex,
                scheduleSave: scheduleSave
            ))
            .modifier(NavigationNotifications(
                focusedPane: focusedPane,
                searchActive: $searchActive,
                searchFocused: $searchFocused,
                sidebar: sidebar
            ))
            .modifier(TabNotifications(focusedPaneVM: focusedPaneVM))
            .modifier(GlobalNotifications(
                allPanes: [pane0, pane1, pane2, pane3],
                saveSynchronously: saveSynchronously
            ))
    }

    private var windowChrome: some View {
        HSplitView {
            SidebarView(viewModel: sidebar, selectedURL: $sidebarSelection) { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                focusedPane.openFolder(url)
            }
            .frame(minWidth: 160, idealWidth: Theme.Metrics.sidebarWidth, maxWidth: 280)

            VStack(spacing: 0) {
                toolbar
                Divider().background(Theme.Color.separator)
                paneGrid
                Divider().background(Theme.Color.separator)
                globalStatusBar
            }
            .background(Theme.Color.windowBg)
        }
    }

    // MARK: Persistence wiring

    /// Build a snapshot of every persistable bit of window state.
    @MainActor
    private func snapshot() -> WindowState {
        WindowState(
            layout: layout,
            focusedPaneIndex: focusedPaneIndex,
            panes: [
                pane0.snapshot(),
                pane1.snapshot(),
                pane2.snapshot(),
                pane3.snapshot(),
            ],
            favorites: sidebar.favorites,
            // `init()` always runs SidebarViewModel.seedIfNeeded, so by the
            // time we save we've definitely either preserved an existing
            // seeded list or just produced a fresh one — either way, true.
            favoritesSeeded: true
        )
    }

    /// Debounce window: 500ms of quiet before serialization.
    /// Cancels any in-flight save scheduled within the same window.
    @MainActor
    private func scheduleSave() {
        guard let persistence else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor [persistence] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            // Snapshot stays on the main actor (it reads @Published state).
            // The encoded write goes off the main actor via Task.detached,
            // and only the Sendable WindowState value crosses the boundary.
            let state = snapshot()
            await Self.persist(state, using: persistence)
        }
    }

    /// Off-main-actor write helper. Pulled out as a static so the detached
    /// closure captures only Sendable values (`state`, `persistence`),
    /// satisfying strict concurrency without an `@unchecked Sendable` view.
    nonisolated private static func persist(
        _ state: WindowState,
        using persistence: PersistenceService
    ) async {
        await Task.detached(priority: .utility) {
            do {
                try persistence.saveState(state)
            } catch {
                FileHandle.standardError.write(
                    Data("[mq-dir persist] save failed: \(error.localizedDescription)\n".utf8)
                )
            }
        }.value
    }

    /// Skip the debounce window; called on app termination so we don't
    /// lose the most recent state changes when the runloop tears down.
    @MainActor
    private func saveSynchronously() {
        guard let persistence else { return }
        saveDebounceTask?.cancel()
        do {
            try persistence.saveState(snapshot())
        } catch {
            FileHandle.standardError.write(
                Data("[mq-dir persist] terminal save failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    // MARK: Toolbar (compact, ~38pt)

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Spacer for traffic-light area on the left edge of the window.
            Spacer().frame(width: 64)

            iconButton("chevron.left", help: "Back (⌘[)") { focusedPane.goBack() }
                .disabled(!focusedPane.canGoBack)
            iconButton("chevron.right", help: "Forward (⌘])") { focusedPane.goForward() }
                .disabled(!focusedPane.canGoForward)
            iconButton("chevron.up", help: "Parent Folder (⌘↑)") { focusedPane.openParentFolder() }
                .disabled(focusedPane.folderURL == nil)
            iconButton("arrow.clockwise", help: "Reload (⌘R)") { focusedPane.reload() }
                .disabled(focusedPane.folderURL == nil)

            breadcrumb

            searchField

            layoutSegmentedControl
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.toolbarHeight)
        .background(Theme.Color.toolbarBg)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            if let url = focusedPane.folderURL {
                let components = url.pathComponents.filter { $0 != "/" }
                if components.isEmpty {
                    Text("/").font(Theme.Font.breadcrumb).foregroundStyle(Theme.Color.label)
                } else {
                    ForEach(Array(components.enumerated()), id: \.offset) { idx, name in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Color.labelTertiary)
                        }
                        Text(name)
                            .font(Theme.Font.breadcrumb)
                            .foregroundStyle(idx == components.count - 1
                                             ? Theme.Color.label
                                             : Theme.Color.labelSecondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("No Folder")
                    .font(Theme.Font.breadcrumb)
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.Color.separator, lineWidth: 0.5)
        )
        .onTapGesture { focusedPane.chooseFolder() }
    }

    private var searchField: some View {
        // Bind directly to the focused pane's query so the field reflects
        // (and edits) the per-pane filter state. Switching focus repoints
        // the binding to the newly-focused pane's value.
        let queryBinding = Binding<String>(
            get: { focusedPane.searchQuery },
            set: { focusedPane.searchQuery = $0 }
        )
        let isEmpty = focusedPane.searchQuery.isEmpty
        let showField = searchActive || !isEmpty

        return Group {
            if showField {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.labelTertiary)
                    TextField("Search", text: queryBinding)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.breadcrumb)
                        .foregroundStyle(Theme.Color.label)
                        .frame(maxWidth: .infinity)
                        .focused($searchFocused)
                        .onKeyPress(.escape) {
                            if !focusedPane.searchQuery.isEmpty {
                                focusedPane.searchQuery = ""
                            } else {
                                searchFocused = false
                                searchActive = false
                            }
                            return .handled
                        }
                    if !isEmpty {
                        Button {
                            focusedPane.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Color.labelTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
            } else {
                Button {
                    searchActive = true
                    DispatchQueue.main.async { searchFocused = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.labelTertiary)
                        Text("Search")
                            .font(Theme.Font.breadcrumb)
                            .foregroundStyle(Theme.Color.labelTertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 160, height: 22)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(searchFocused ? Theme.Color.accent : Theme.Color.separator,
                              lineWidth: searchFocused ? 1 : 0.5)
        )
        .onChange(of: searchFocused) { _, focused in
            // When the user tabs/clicks away from an empty field, drop back
            // to the static placeholder so the next session starts inert.
            if !focused && focusedPane.searchQuery.isEmpty {
                searchActive = false
            }
        }
        .help("Search this folder (⌘F)")
    }

    private var layoutSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(PaneLayout.allCases) { paneLayout in
                Button {
                    layout = paneLayout
                } label: {
                    Image(systemName: paneLayout.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(layout == paneLayout ? Theme.Color.label : Theme.Color.labelSecondary)
                        .frame(width: 26, height: 19)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(layout == paneLayout ? Color.white.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(paneLayout.help)
            }
        }
        .padding(1.5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.labelSecondary)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Pane grid

    @ViewBuilder
    private var paneGrid: some View {
        switch layout {
        case .one:
            paneView(0)
        case .twoH:
            HStack(spacing: 0) {
                paneView(0)
                Divider().background(Theme.Color.separator)
                paneView(1)
            }
        case .twoV:
            VStack(spacing: 0) {
                paneView(0)
                Divider().background(Theme.Color.separator)
                paneView(1)
            }
        case .four:
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    paneView(0)
                    Divider().background(Theme.Color.separator)
                    paneView(1)
                }
                Divider().background(Theme.Color.separator)
                HStack(spacing: 0) {
                    paneView(2)
                    Divider().background(Theme.Color.separator)
                    paneView(3)
                }
            }
        }
    }

    private func paneView(_ index: Int) -> some View {
        BrowserPaneView(
            index: index,
            paneVM: paneVM(at: index),
            isFocused: focusedPaneIndex == index
        ) {
            focusedPaneIndex = index
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Global status bar

    private var globalStatusBar: some View {
        let totalCount = focusedPane.entries.count
        let visibleCount = focusedPane.visibleEntries.count
        let selectedCount = focusedPane.selection.count
        let selectedSize = focusedPane.entries
            .filter { focusedPane.selection.contains($0.id) }
            .compactMap { $0.size }
            .reduce(0, +)

        return HStack(spacing: 8) {
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .foregroundStyle(Theme.Color.label)
                Text("·").foregroundStyle(Theme.Color.labelTertiary)
                Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                    .foregroundStyle(Theme.Color.labelSecondary)
            } else if focusedPane.isFiltering {
                if focusedPane.isSearching {
                    Text("Searching\u{2026}")
                        .foregroundStyle(Theme.Color.labelSecondary)
                } else {
                    Text("\(visibleCount) match\(visibleCount == 1 ? "" : "es")")
                        .foregroundStyle(Theme.Color.labelSecondary)
                }
            } else if totalCount > 0 {
                Text("\(totalCount) item\(totalCount == 1 ? "" : "s")")
                    .foregroundStyle(Theme.Color.labelSecondary)
            }

            Spacer()

            if focusedPane.includeHidden {
                Text("Hidden visible").foregroundStyle(Theme.Color.labelSecondary)
                Text("·").foregroundStyle(Theme.Color.labelTertiary)
            }

            if let free = freeSpaceString() {
                Text(free).foregroundStyle(Theme.Color.labelSecondary)
            }
        }
        .font(Theme.Font.secondary)
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.statusBarHeight)
        .background(Theme.Color.statusBarBg)
    }

    private func freeSpaceString() -> String? {
        guard let url = focusedPane.folderURL ?? FileManager.default.homeDirectoryForCurrentUser as URL?,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free"
    }

    // MARK: Helpers

    /// The currently-focused pane's tab list. Use this for tab-list operations
    /// (new tab, close, reopen, switch). For tab-content actions like
    /// navigation or selection, prefer `focusedPane` so the call routes to
    /// the active tab inside the pane.
    private var focusedPaneVM: PaneTabsViewModel { paneVM(at: focusedPaneIndex) }

    /// The active tab inside the focused pane. Compatibility shim: every
    /// pre-tabs call site (`focusedPane.openFolder`, `focusedPane.goBack`,
    /// `focusedPane.searchQuery`, …) keeps working unchanged because what
    /// "the pane" used to mean is now "the active tab of the pane."
    private var focusedPane: FolderBrowserViewModel { focusedPaneVM.activeTab }

    private func paneVM(at index: Int) -> PaneTabsViewModel {
        switch index {
        case 0: pane0
        case 1: pane1
        case 2: pane2
        default: pane3
        }
    }
}

// MARK: - Body modifier chunks
//
// SwiftUI's view-builder type checker collapses on a body with ~25 chained
// modifiers, so the wiring is split into focused `ViewModifier` chunks. Each
// modifier owns one slice of the cross-cutting concern (save triggers,
// navigation notifications, tab notifications, app lifecycle), and the body
// applies them in sequence. The split is purely a compile-time concession;
// the runtime semantics match the original flat chain.

private struct SaveTriggers: ViewModifier {
    @ObservedObject var pane0: PaneTabsViewModel
    @ObservedObject var pane1: PaneTabsViewModel
    @ObservedObject var pane2: PaneTabsViewModel
    @ObservedObject var pane3: PaneTabsViewModel
    @ObservedObject var sidebar: SidebarViewModel
    @Binding var layout: PaneLayout
    @Binding var focusedPaneIndex: Int
    let scheduleSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: layout) { _, newLayout in
                if focusedPaneIndex >= newLayout.paneCount {
                    focusedPaneIndex = 0
                }
                scheduleSave()
            }
            .onChange(of: focusedPaneIndex) { _, _ in scheduleSave() }
            .onReceive(pane0.objectWillChange) { _ in scheduleSave() }
            .onReceive(pane1.objectWillChange) { _ in scheduleSave() }
            .onReceive(pane2.objectWillChange) { _ in scheduleSave() }
            .onReceive(pane3.objectWillChange) { _ in scheduleSave() }
            .onReceive(sidebar.objectWillChange) { _ in scheduleSave() }
    }
}

private struct NavigationNotifications: ViewModifier {
    let focusedPane: FolderBrowserViewModel
    @Binding var searchActive: Bool
    var searchFocused: FocusState<Bool>.Binding
    @ObservedObject var sidebar: SidebarViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirOpenFolderRequested)) { _ in
                focusedPane.chooseFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirOpenSelectedRequested)) { _ in
                focusedPane.openSelected()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirRevealSelectedRequested)) { _ in
                focusedPane.revealSelected()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirReloadRequested)) { _ in
                focusedPane.reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirParentFolderRequested)) { _ in
                focusedPane.openParentFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirToggleHiddenFilesRequested)) { _ in
                focusedPane.toggleHiddenFiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirGoBackRequested)) { _ in
                focusedPane.goBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirGoForwardRequested)) { _ in
                focusedPane.goForward()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirFocusSearchRequested)) { _ in
                searchActive = true
                // Defer focus until after the conditional TextField has been
                // installed by the body re-render triggered above.
                DispatchQueue.main.async { searchFocused.wrappedValue = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirAddCurrentFolderToFavoritesRequested)) { _ in
                if let url = focusedPane.folderURL {
                    sidebar.add(url: url)
                }
            }
    }
}

private struct TabNotifications: ViewModifier {
    @ObservedObject var focusedPaneVM: PaneTabsViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirNewTabRequested)) { _ in
                focusedPaneVM.newTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCloseTabRequested)) { _ in
                focusedPaneVM.closeActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirReopenClosedTabRequested)) { _ in
                focusedPaneVM.reopenClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirNextTabRequested)) { _ in
                focusedPaneVM.nextTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirPreviousTabRequested)) { _ in
                focusedPaneVM.prevTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mqdirSelectTabAtIndexRequested)) { note in
                if let index = note.userInfo?["index"] as? Int {
                    focusedPaneVM.selectTab(at: index)
                }
            }
    }
}

private struct GlobalNotifications: ViewModifier {
    let allPanes: [PaneTabsViewModel]
    let saveSynchronously: () -> Void

    func body(content: Content) -> some View {
        content
            // FSEvents lands in M3 per plan §3 — until then drag/drop posts
            // an explicit "I changed the filesystem" notification and every
            // open tab in every pane refetches its folder.
            .onReceive(NotificationCenter.default.publisher(for: .mqdirFileSystemChanged)) { _ in
                for paneVM in allPanes {
                    for tab in paneVM.tabs { tab.reload() }
                }
            }
            // Synchronous save on app termination (debounce would be cancelled
            // by the runloop tearing down). Posted by mqdirApp.
            .onReceive(NotificationCenter.default.publisher(for: .mqdirAppWillTerminate)) { _ in
                saveSynchronously()
            }
    }
}

#Preview {
    MainWindowView()
        .frame(width: 1100, height: 700)
}
