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

    var body: some View {
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
            paneIsFocused: isFocused
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
        .contextMenu {
            if entry.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand") {
                    viewModel.toggleExpanded(entry.url)
                }
                Divider()
            }
            Button("Open") { viewModel.open(entry) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }

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

            Text(entry.name)
                .font(Theme.Font.body)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)

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
