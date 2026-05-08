import AppKit
import SwiftUI

/// VS Code Explorer-style tree view of the focused tab's folder.
///
/// Renders the root folder at depth 0 and lazily descends only into the
/// subfolders the user has explicitly expanded (tracked on the VM as
/// `expandedPaths`). Folder-first ordering inside each level — files
/// follow — matches what VS Code does and stops a deep tree from being
/// drowned in loose files at every level.
struct TreeFileListView: View {
    @ObservedObject var viewModel: FolderBrowserViewModel
    let isFocused: Bool
    let onFocus: () -> Void

    @FocusState private var treeFocused: Bool

    var body: some View {
        // ScrollViewReader provides a proxy so arrow-key nav can keep the
        // moved-to row visible. Each treeRow stamps `.id(entry.id)` so the
        // proxy can find rows by their FileEntry.ID. Mirrors what the list
        // mode does in `BrowserPaneView.fileList`.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let root = viewModel.folderURL,
                       let rootEntries = viewModel.treeChildren[root.path] ?? entriesForRoot()
                    {
                        ForEach(orderedForTree(rootEntries)) { entry in
                            treeRow(entry, depth: 0)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .focusable()
            .focused($treeFocused)
            .onAppear {
                if isFocused { treeFocused = true }
            }
            .onChange(of: isFocused) { _, newValue in
                if newValue { treeFocused = true }
            }
            .onKeyPress(.downArrow) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleArrow(by: 1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleArrow(by: -1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleRightArrow(proxy: proxy)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleLeftArrow(proxy: proxy)
                return .handled
            }
            .onKeyPress(.return) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                if !isFocused { onFocus() }
                viewModel.openSelected()
                return .handled
            }
            .onKeyPress(.space) {
                guard viewModel.renamingEntryID == nil else { return .ignored }
                if !isFocused { onFocus() }
                let urls = viewModel.selectedURLs
                guard !urls.isEmpty else { return .ignored }
                QuickLookManager.shared.toggle(urls: urls)
                return .handled
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                } else if viewModel.entries.isEmpty {
                    Text("No items")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.labelTertiary)
                }
            }
            .onAppear {
                // Populate the root cache the first time we render. The flat
                // list keeps `entries` in sync, but tree mode reads from
                // `treeChildren[root]` so the same recursion works at every
                // depth without a special case for the root.
                if let root = viewModel.folderURL, viewModel.treeChildren[root.path] == nil {
                    viewModel.treeChildren[root.path] = orderedForTree(viewModel.entries)
                }
            }
            .onChange(of: viewModel.entries) { _, newEntries in
                guard let root = viewModel.folderURL else { return }
                viewModel.treeChildren[root.path] = orderedForTree(newEntries)
            }
        }
    }

    /// ↑/↓: walk the flat DFS of currently-visible tree rows. The VM
    /// already does the right thing in tree mode; we just need to keep
    /// the moved-to anchor on screen.
    private func handleArrow(by offset: Int, proxy: ScrollViewProxy) {
        if !isFocused { onFocus() }
        let extending = NSEvent.modifierFlags.contains(.shift)
        viewModel.moveSelection(by: offset, extending: extending)
        if let anchor = viewModel.selectionAnchor {
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    /// →: expand a collapsed folder; if already expanded, descend to its
    /// first child. Files become a no-op. Finder/VS Code convention.
    private func handleRightArrow(proxy: ScrollViewProxy) {
        if !isFocused { onFocus() }
        guard let entry = viewModel.selectedEntry, entry.isDirectory else { return }
        if !viewModel.isExpanded(entry.url) {
            viewModel.toggleExpanded(entry.url)
        } else if let firstChild = viewModel.treeChildren[entry.url.path]
            .flatMap({ orderedForTree($0).first })
        {
            viewModel.replaceSelection(firstChild.id)
            proxy.scrollTo(firstChild.id, anchor: .center)
        }
    }

    /// ←: collapse an expanded folder; otherwise jump to the parent row.
    /// Parent = the directory entry whose URL matches the selected
    /// entry's parent path (anywhere in `entries` or `treeChildren`).
    private func handleLeftArrow(proxy: ScrollViewProxy) {
        if !isFocused { onFocus() }
        guard let entry = viewModel.selectedEntry else { return }
        if entry.isDirectory, viewModel.isExpanded(entry.url) {
            viewModel.toggleExpanded(entry.url)
            return
        }
        let parentURL = entry.url.deletingLastPathComponent()
        let candidates = viewModel.entries + viewModel.treeChildren.values.flatMap { $0 }
        if let parent = candidates.first(where: { $0.url == parentURL }) {
            viewModel.replaceSelection(parent.id)
            proxy.scrollTo(parent.id, anchor: .center)
        }
    }

    /// Fall-back when `treeChildren[root]` hasn't been populated yet —
    /// rely on the existing flat enumeration `viewModel.entries`. The
    /// `onAppear` above will mirror it into the cache so subsequent
    /// renders take the fast path.
    private func entriesForRoot() -> [FileEntry]? {
        viewModel.entries.isEmpty ? nil : viewModel.entries
    }

    private func orderedForTree(_ entries: [FileEntry]) -> [FileEntry] {
        let folders = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
        return folders + files
    }

    /// Returns `AnyView` to break the opaque-type recursion: a `some View`
    /// can't be defined in terms of itself, and `treeRow` calls itself for
    /// expanded folders. The erasure cost here is negligible — only the
    /// rows actually on screen materialize because the parent is a
    /// `LazyVStack`.
    @ViewBuilder
    private func treeRow(_ entry: FileEntry, depth: Int) -> AnyView {
        AnyView(treeRowBody(entry, depth: depth))
    }

    @ViewBuilder
    private func treeRowBody(_ entry: FileEntry, depth: Int) -> some View {
        let isExpanded = entry.isDirectory && viewModel.isExpanded(entry.url)
        let isSelected = viewModel.selection.contains(entry.id)

        TreeRow(
            entry: entry,
            depth: depth,
            isExpanded: isExpanded,
            isSelected: isSelected,
            paneIsFocused: isFocused,
            isRenaming: viewModel.renamingEntryID == entry.id,
            renameDraft: Binding(
                get: { viewModel.renameDraft },
                set: { viewModel.renameDraft = $0 }
            ),
            commitRename: { viewModel.commitRename() },
            cancelRename: { viewModel.cancelRename() }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                viewModel.openFolder(entry.url)
            } else {
                viewModel.open(entry)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            if !isFocused { onFocus() }
            let mods = NSEvent.modifierFlags
            // ⌘-click on a folder = open it in a new tab in this pane
            // (Finder convention). Don't expand/select — that'd double
            // the user's intent. Files fall through to the selection
            // branch; new-tab semantics for files would just duplicate
            // the row's primary action without adding value.
            if entry.isDirectory && mods.contains(.command) {
                NotificationCenter.default.post(
                    name: .mqdirOpenURLInNewTabRequested,
                    object: nil,
                    userInfo: ["url": entry.url]
                )
                return
            }
            viewModel.replaceSelection(entry.id)
            if entry.isDirectory {
                viewModel.toggleExpanded(entry.url)
            }
        })
        // Right-click selects the clicked row before the menu shows
        // (Finder parity). Tree view is single-row interaction so we
        // always replace selection with the clicked row.
        .background(
            RightClickAware {
                viewModel.replaceSelection(entry.id)
                if !isFocused { onFocus() }
            }
        )
        .contextMenu {
            if entry.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand") {
                    viewModel.toggleExpanded(entry.url)
                }
                Divider()
            }
            // Tree view is single-row interaction (no multi-select), so
            // the menu always operates on just the clicked entry.
            FileEntryContextMenu(
                viewModel: viewModel,
                targets: [entry],
                primaryName: entry.name
            )
        }
        // ScrollViewProxy.scrollTo(id) needs each row tagged so arrow-key
        // nav can keep the moved-to row visible.
        .id(entry.id)

        if isExpanded,
           let children = viewModel.treeChildren[entry.url.path]
        {
            ForEach(orderedForTree(children)) { child in
                treeRow(child, depth: depth + 1)
            }
        }
    }
}

// MARK: - Single row

private struct TreeRow: View {
    let entry: FileEntry
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let paneIsFocused: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let commitRename: () -> Void
    let cancelRename: () -> Void
    @FocusState private var renameFieldFocused: Bool

    private static let indentPerDepth: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            // Disclosure chevron — fixed slot for files too so names align
            // vertically across folder/file rows at the same depth.
            Group {
                if entry.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Color.labelSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)

            Image(systemName: FileIconStyle.symbol(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(isSelected && paneIsFocused
                                 ? Color.white
                                 : FileIconStyle.tint(for: entry))
                .frame(width: 14)

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.label.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.Color.accent, lineWidth: 1)
                    )
                    .focused($renameFieldFocused)
                    .onAppear {
                        DispatchQueue.main.async { renameFieldFocused = true }
                    }
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(entry.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(depth) * Self.indentPerDepth)
        .padding(.trailing, 6)
        .frame(minHeight: Theme.Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
                .padding(.horizontal, 4)
        )
    }

    private var rowBackground: Color {
        if !isSelected { return .clear }
        return paneIsFocused ? Theme.Color.selection : Theme.Color.selectionInactive
    }

    private var textColor: Color {
        isSelected && paneIsFocused ? .white : Theme.Color.label
    }
}
