import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Routes a tab drop to `paneVM.move`. The drop "happens" when the user
/// hovers over a target tab (`dropEntered`) — that gives the immediate
/// drag-to-reorder feel like Safari, instead of waiting for `performDrop`
/// which only fires on mouseUp. `performDrop` returns true so SwiftUI
/// considers the drop accepted and clears the drag state.
private struct TabReorderDropDelegate: DropDelegate {
    let target: ObjectIdentifier
    let paneVM: PaneTabsViewModel
    @Binding var draggingID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target,
              let from = paneVM.tabs.firstIndex(where: { ObjectIdentifier($0) == dragging }),
              let to = paneVM.tabs.firstIndex(where: { ObjectIdentifier($0) == target })
        else { return }
        // Insert AFTER the target if the drag came from earlier in the bar,
        // BEFORE if it came from later — matches the visual swap users expect.
        let dest = from < to ? to + 1 : to
        paneVM.move(from: from, to: dest)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct BrowserPaneView: View {
    let index: Int
    @ObservedObject var paneVM: PaneTabsViewModel
    let isFocused: Bool
    let onFocus: () -> Void

    @State private var paneIsDropTargeted = false
    @State private var rowDropTargeted: FileEntry.ID?
    /// Tab being dragged for in-pane reorder. Carries the source tab's
    /// identity so the drop target can resolve the right index even after
    /// SwiftUI re-renders the row layout mid-drag.
    @State private var draggingTabID: ObjectIdentifier?
    /// Bridges this pane's "active for keyboard input" state into SwiftUI's
    /// focus chain so `.onKeyPress` on the file list actually fires. Tracks
    /// `isFocused` — clicking another pane updates `focusedPaneIndex`
    /// upstream which flips `isFocused`, which we mirror here.
    @FocusState private var listFocused: Bool

    /// Compatibility alias — the body code throughout this file used to
    /// read `viewModel` when one pane held one folder. Now it routes to
    /// the pane's currently-active tab so call sites keep working.
    private var viewModel: FolderBrowserViewModel { paneVM.activeTab }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            paneHeader
            content
        }
        .background(Theme.Color.paneBg)
        .overlay(
            Rectangle()
                .strokeBorder(
                    paneBorderColor,
                    lineWidth: Theme.Metrics.focusBorderWidth
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var paneBorderColor: Color {
        if paneIsDropTargeted && rowDropTargeted == nil { return Theme.Color.accent }
        if isFocused { return Theme.Color.accent }
        return .clear
    }

    /// Minimum width the Name column collapses to before the whole list
    /// strip starts horizontally scrolling. Calibrated so a typical
    /// "kebab-case-some-thing.swift" still survives middle-truncation
    /// cleanly without the row going completely blank when the preview
    /// pane opens and the pane shrinks.
    private static let nameColumnMinWidth: CGFloat = 200

    /// Natural minimum of the columns strip = name floor + the
    /// configured Modified/Size/Kind widths + 3 resize-handle gaps
    /// (6pt each) + outer header padding (6pt × 2). When the pane is
    /// narrower than this we let the horizontal ScrollView take over;
    /// when it's wider, the .frame(minWidth: geo.size.width) below
    /// stretches the strip to fill so columns don't pile up on the left.
    private var minColumnsTotal: CGFloat {
        let widths = viewModel.columnWidths
        let handles: CGFloat = 6 * 3
        let outerPadding: CGFloat = 6 * 2
        return Self.nameColumnMinWidth + widths.modified + widths.size + widths.kind + handles + outerPadding
    }

    /// Header + list wrapped in a horizontal ScrollView so the Name
    /// column stays anchored on the left when the pane shrinks (e.g.
    /// when the preview pane opens). Without this, SwiftUI's flexible
    /// `.frame(maxWidth: .infinity)` on Name lets it collapse to zero
    /// and the filenames disappear entirely while Modified/Size/Kind
    /// crowd the visible area. The GeometryReader pins the inner
    /// height so the inner vertical scroll keeps working.
    private var listWithHorizontalScroll: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    columnHeader
                    fileList
                }
                .frame(minWidth: max(minColumnsTotal, geo.size.width), alignment: .leading)
                .frame(height: geo.size.height, alignment: .top)
            }
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(paneVM.tabs.enumerated()), id: \.element.id) { idx, tab in
                    tabChip(for: tab, at: idx)
                }
                newTabButton
                Spacer(minLength: 0)
            }
        }
        .frame(height: Theme.Metrics.tabBarHeight)
        .background(Theme.Color.tabBarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.separator).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func tabChip(for tab: FolderBrowserViewModel, at idx: Int) -> some View {
        let isActive = paneVM.activeIndex == idx
        let title = tab.folderURL?.lastPathComponent ?? "Untitled"
        let id = ObjectIdentifier(tab)

        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundStyle(isActive
                                 ? Theme.Color.accent.opacity(0.85)
                                 : Theme.Color.labelTertiary)
            Text(title)
                .font(Theme.Font.tab)
                .foregroundStyle(isActive ? Theme.Color.label : Theme.Color.labelSecondary)
                .lineLimit(1)
            Button {
                paneVM.closeTab(at: idx)
                if !isFocused { onFocus() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Color.labelTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Theme.Metrics.tabBarHeight)
        .background(isActive ? Color.white.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            // 1pt accent underline for the active tab — subtle but reads
            // immediately even with low chrome contrast.
            if isActive {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(height: 1.5)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Color.separatorFaint).frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            paneVM.selectTab(at: idx)
            if !isFocused { onFocus() }
        }
        .contextMenu {
            Button("New Tab") { paneVM.newTab() }
            Divider()
            Button("Close Tab") { paneVM.closeTab(at: idx) }
            Button("Close Other Tabs") { paneVM.closeOthers(keep: idx) }
                .disabled(paneVM.tabs.count <= 1)
            Button("Close Tabs to the Right") { paneVM.closeToTheRight(of: idx) }
                .disabled(idx >= paneVM.tabs.count - 1)
            Divider()
            Button("Duplicate Tab") { paneVM.duplicate(at: idx) }
            if let url = tab.folderURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        // Drag source: ship the tab's ObjectIdentifier as plain text so the
        // drop target can route to `paneVM.move`. Pasteboard stays internal —
        // dragging a tab out of the bar onto Finder/etc. simply does nothing.
        .onDrag {
            draggingTabID = id
            return NSItemProvider(object: String(describing: id) as NSString)
        }
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: TabReorderDropDelegate(
                target: id,
                paneVM: paneVM,
                draggingID: $draggingTabID
            )
        )
    }

    private var newTabButton: some View {
        Button {
            paneVM.newTab()
            if !isFocused { onFocus() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.labelSecondary)
                .frame(width: 28, height: Theme.Metrics.tabBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
    }

    // MARK: Folder header strip

    private var paneHeader: some View {
        HStack(spacing: 6) {
            if let url = viewModel.folderURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Color.label)
                Text("—")
                    .foregroundStyle(Theme.Color.labelTertiary)
                Text(itemCountLabel)
                    .foregroundStyle(Theme.Color.labelSecondary)
            } else {
                Text("No folder open")
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
            Spacer(minLength: 0)
            viewModeToggle
        }
        .font(.system(size: 10))
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.paneHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.separatorFaint).frame(height: 0.5)
        }
    }

    /// Tiny segmented control: list-bullet / chevron-right.dotted to toggle
    /// between flat columns and the VS Code-style tree. Lives on the right
    /// edge of the pane header so it's discoverable per-tab without taking
    /// space from the breadcrumb.
    private var viewModeToggle: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                viewModeButton(.list, symbol: "list.bullet", help: "List View")
                viewModeButton(.tree, symbol: "rectangle.split.3x1", help: "Tree View")
            }
            .padding(1)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))

            previewToggleButton
        }
    }

    /// Eye-icon toggle for the right-side preview panel. Distinct from
    /// the view-mode segmented control because it's a binary on/off,
    /// orthogonal to list-vs-tree.
    private var previewToggleButton: some View {
        Button {
            viewModel.previewVisible.toggle()
        } label: {
            Image(systemName: viewModel.previewVisible
                  ? "sidebar.right"
                  : "sidebar.squares.right")
                .font(.system(size: 9))
                .foregroundStyle(viewModel.previewVisible
                                 ? Theme.Color.label
                                 : Theme.Color.labelSecondary)
                .frame(width: 22, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(viewModel.previewVisible
                              ? Color.white.opacity(0.10)
                              : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .help("Preview Pane (⌘⇧P)")
    }

    private func viewModeButton(_ mode: PaneViewMode, symbol: String, help: String) -> some View {
        Button {
            viewModel.viewMode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(viewModel.viewMode == mode
                                 ? Theme.Color.label
                                 : Theme.Color.labelSecondary)
                .frame(width: 22, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(viewModel.viewMode == mode
                              ? Color.white.opacity(0.10)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var itemCountLabel: String {
        if viewModel.isFiltering {
            if viewModel.isSearching { return "searching\u{2026}" }
            let count = viewModel.visibleEntries.count
            return "\(count) match\(count == 1 ? "" : "es")"
        }
        let total = viewModel.entries.count
        return "\(total) item\(total == 1 ? "" : "s")"
    }

    private var emptyStateLabel: String {
        if viewModel.isFiltering {
            if viewModel.isSearching { return "Searching\u{2026}" }
            let trimmed = viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
            return "No matches for \u{201C}\(trimmed)\u{201D}"
        }
        return "No items"
    }

    /// While a recursive search is active, show the entry's parent folder
    /// path relative to the search root so users can tell which subfolder a
    /// hit lives in. Direct children of the search root get no subtitle.
    private func searchSubtitle(for entry: FileEntry) -> String? {
        guard viewModel.isFiltering, let root = viewModel.folderURL else { return nil }
        let parent = entry.url.deletingLastPathComponent()
        guard parent != root else { return nil }
        let rootPrefix = root.path(percentEncoded: false)
        let parentPath = parent.path(percentEncoded: false)
        guard parentPath.hasPrefix(rootPrefix) else { return parentPath }
        let stripped = parentPath.dropFirst(rootPrefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: Column header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            sortHeader("Name", key: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            ColumnResizeHandle { delta in
                let next = (viewModel.columnWidths.modified - delta)
                    .clamped(to: PaneColumnWidths.modifiedRange)
                viewModel.columnWidths.modified = next
            }

            sortHeader("Modified", key: .modified, alignment: .leading)
                .frame(width: viewModel.columnWidths.modified, alignment: .leading)

            ColumnResizeHandle { delta in
                let nextMod = viewModel.columnWidths.modified + delta
                let nextSize = viewModel.columnWidths.size - delta
                if PaneColumnWidths.modifiedRange.contains(nextMod),
                   PaneColumnWidths.sizeRange.contains(nextSize) {
                    viewModel.columnWidths.modified = nextMod
                    viewModel.columnWidths.size = nextSize
                }
            }

            sortHeader("Size", key: .size, alignment: .trailing)
                .frame(width: viewModel.columnWidths.size, alignment: .trailing)

            ColumnResizeHandle { delta in
                let nextSize = viewModel.columnWidths.size + delta
                let nextKind = viewModel.columnWidths.kind - delta
                if PaneColumnWidths.sizeRange.contains(nextSize),
                   PaneColumnWidths.kindRange.contains(nextKind) {
                    viewModel.columnWidths.size = nextSize
                    viewModel.columnWidths.kind = nextKind
                }
            }

            sortHeader("Kind", key: .kind, alignment: .leading)
                .frame(width: viewModel.columnWidths.kind, alignment: .leading)
        }
        .font(Theme.Font.columnHeader)
        .foregroundStyle(Theme.Color.labelSecondary)
        .padding(.horizontal, 6)
        .frame(height: Theme.Metrics.columnHeaderHeight)
        .background(Theme.Color.columnHeaderBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.separator).frame(height: 0.5)
        }
    }

    private func sortHeader(_ title: String, key: FileEntrySortKey, alignment: HorizontalAlignment) -> some View {
        let isActive = viewModel.sortKey == key
        return Button {
            viewModel.setSort(key)
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .foregroundStyle(isActive ? Theme.Color.label : Theme.Color.labelSecondary)
                if isActive {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Color.labelSecondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Right-click any column header to toggle folder pinning. Same
        // surface as the sort key affordance, so users discover it
        // when they're already thinking about how the list is sorted.
        .contextMenu {
            Button {
                viewModel.setFoldersOnTop(!viewModel.foldersOnTop)
            } label: {
                Label(
                    "Folders on Top",
                    systemImage: viewModel.foldersOnTop ? "checkmark" : ""
                )
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.folderURL == nil {
            emptyState
        } else if let errorMessage = viewModel.errorMessage {
            errorState(errorMessage)
        } else if viewModel.previewVisible {
            // Preview panel takes the right ~40%; user can drag the
            // split handle to retune. List/tree mode applies on the left.
            HSplitView {
                primaryFileView
                    .frame(minWidth: 220, idealWidth: 380)
                PreviewPanel(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 280)
            }
        } else {
            primaryFileView
        }
    }

    /// Just the file list/tree, factored out so it can render either
    /// standalone or as the left half of the preview split.
    @ViewBuilder
    private var primaryFileView: some View {
        if viewModel.viewMode == .tree {
            TreeFileListView(
                viewModel: viewModel,
                isFocused: isFocused,
                onFocus: onFocus
            )
        } else {
            listWithHorizontalScroll
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(Theme.Color.labelTertiary)
            Text("Open a folder")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.labelSecondary)
            Button("Open Folder…") { viewModel.chooseFolder() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            Text("Could not open folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.label)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.labelSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { viewModel.reload() }
                .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        // ScrollViewReader gives us a proxy so arrow-key navigation can keep
        // the selected row visible — Finder-style. `.id(entry.id)` on each
        // row makes the proxy able to find rows by FileEntry.ID.
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.visibleEntries) { entry in
                                rowView(for: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 2)

                        // Fill any empty space below the last row. Clicking
                        // it clears the selection — Finder parity. Sits
                        // beneath the rows in the VStack so row gestures
                        // win when the user actually clicks a file.
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onTapGesture {
                                if !isFocused { onFocus() }
                                viewModel.clearSelection()
                            }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            .focusable()
            .focused($listFocused)
            .onAppear {
                if isFocused { listFocused = true }
            }
            .onChange(of: isFocused) { _, newValue in
                // Mirror pane focus into SwiftUI's focus chain so the
                // currently-focused pane's list claims keyboard input.
                if newValue { listFocused = true }
            }
            .onKeyPress(.downArrow) {
                handleArrowKey(by: 1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.upArrow) {
                handleArrowKey(by: -1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.return) {
                if !isFocused { onFocus() }
                viewModel.openSelected()
                return .handled
            }
            .onKeyPress(.space) {
                if !isFocused { onFocus() }
                let urls = viewModel.selectedURLs
                guard !urls.isEmpty else { return .ignored }
                QuickLookManager.shared.toggle(urls: urls)
                return .handled
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                } else if viewModel.visibleEntries.isEmpty {
                    Text(emptyStateLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.labelTertiary)
                }
            }
            // Drop on the pane background → drop INTO the current folder.
            // We use the lower-level NSItemProvider API so a single drop can carry
            // a multi-item internal selection (see DragDropSupport).
            .onDrop(of: DragDropSupport.acceptedDropTypes, isTargeted: $paneIsDropTargeted) { providers in
                guard let folder = viewModel.folderURL else { return false }
                let modifiers = NSEvent.modifierFlags
                Task {
                    let urls = await DragDropSupport.resolveURLs(from: providers)
                    guard !urls.isEmpty else { return }
                    await MainActor.run {
                        viewModel.acceptDrop(
                            urls,
                            into: folder,
                            copy: modifiers.contains(.option)
                        )
                    }
                }
                return true
            }
            }
        }
    }

    /// Shared body for ↑/↓ key presses on the file list. Honors Shift to
    /// extend the selection, focuses this pane if it wasn't already, and
    /// scrolls the new anchor into view so keyboard nav off-screen still
    /// keeps the user oriented.
    private func handleArrowKey(by offset: Int, proxy: ScrollViewProxy) {
        if !isFocused { onFocus() }
        let extending = NSEvent.modifierFlags.contains(.shift)
        viewModel.moveSelection(by: offset, extending: extending)
        if let anchor = viewModel.selectionAnchor {
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    /// Resolve the right-click target list. If the clicked row is part of
    /// a multi-selection, every selected row gets the action — Finder's
    /// behavior. Otherwise just the clicked row, even if a different row
    /// is the current single selection (matches what users expect when
    /// they right-click outside their selection).
    private func targetEntries(for clicked: FileEntry) -> [FileEntry] {
        let selection = viewModel.selection
        guard selection.contains(clicked.id), selection.count > 1 else {
            return [clicked]
        }
        return viewModel.visibleEntries.filter { selection.contains($0.id) }
    }

    @ViewBuilder
    private func rowView(for entry: FileEntry) -> some View {
        let isSelected = viewModel.selection.contains(entry.id)
        let isRowDropTarget = entry.isDirectory && rowDropTargeted == entry.id

        let row = FileEntryRow(
            entry: entry,
            isSelected: isSelected,
            paneIsFocused: isFocused,
            isDropTarget: isRowDropTarget,
            columnWidths: viewModel.columnWidths,
            subtitle: searchSubtitle(for: entry)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewModel.open(entry) }
        .simultaneousGesture(TapGesture().onEnded {
            if !isFocused { onFocus() }
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift) {
                viewModel.extendSelection(to: entry.id)
            } else if mods.contains(.command) {
                viewModel.toggleSelection(entry.id)
            } else {
                viewModel.replaceSelection(entry.id)
            }
        })
        // Drag SOURCE: bypass SwiftUI's `.onDrag` (which adds an
        // auto-promise that materialises a cache copy on the receiver
        // side) and drive an AppKit NSDraggingSession directly with our
        // own NSPasteboardItem. Carries `public.file-url` for external
        // apps plus a private multi-URL payload when this row is part
        // of a multi-selection (internal pane↔pane).
        .appKitFileDrag(
            primary: entry.url,
            multiURLs: (isSelected && viewModel.selection.count > 1)
                ? viewModel.selectedURLs
                : []
        )
        // `.contextMenu` MUST sit outside `.onDrag` — SwiftUI on macOS lets
        // the drag gesture eat right-mouse events when the menu is the
        // inner modifier, so the menu only fires on the second right-click.
        // Keeping contextMenu as the outermost modifier here makes the
        // first right-click reliably show the menu.
        .contextMenu {
            FileEntryContextMenu(
                viewModel: viewModel,
                targets: targetEntries(for: entry),
                primaryName: entry.name
            )
        }

        if entry.isDirectory {
            // Folder rows are drop TARGETS — drop INTO the subfolder, with
            // a per-row isTargeted state for the highlight.
            row.onDrop(
                of: DragDropSupport.acceptedDropTypes,
                isTargeted: Binding(
                    get: { rowDropTargeted == entry.id },
                    set: { rowDropTargeted = $0 ? entry.id : nil }
                )
            ) { providers in
                let modifiers = NSEvent.modifierFlags
                Task {
                    let urls = await DragDropSupport.resolveURLs(from: providers)
                    guard !urls.isEmpty else { return }
                    await MainActor.run {
                        viewModel.acceptDrop(
                            urls,
                            into: entry.url,
                            copy: modifiers.contains(.option)
                        )
                    }
                }
                return true
            }
        } else {
            row
        }
    }
}

// MARK: Row

private struct FileEntryRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let paneIsFocused: Bool
    let isDropTarget: Bool
    let columnWidths: PaneColumnWidths
    /// Optional second line under the name — used by recursive search to show
    /// where in the tree a hit lives. `nil` keeps the row at single-line height.
    let subtitle: String?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: FileIconStyle.symbol(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected && paneIsFocused
                                     ? Color.white
                                     : FileIconStyle.tint(for: entry))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Spacer matching the header's resize-handle width so columns
            // stay vertically aligned with the column dividers.
            Color.clear.frame(width: 6)

            Text(Self.modifiedDateFormatter.string(from: entry.modificationDate))
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .frame(width: columnWidths.modified, alignment: .leading)

            Color.clear.frame(width: 6)

            Text(Self.sizeFormatter.string(fromByteCount: entry.size))
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .frame(width: columnWidths.size, alignment: .trailing)

            Color.clear.frame(width: 6)

            Text(entry.kind)
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columnWidths.kind, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, subtitle == nil ? 0 : 2)
        .frame(minHeight: Theme.Metrics.rowHeight)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(rowBackground)
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Color.accent.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.Color.accent, lineWidth: 1)
                }
            }
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

    private var secondaryColor: Color {
        if isSelected && paneIsFocused {
            return Color.white.opacity(0.85)
        }
        return Theme.Color.labelSecondary
    }

    private static let modifiedDateFormatter = ModifiedDateFormatter()
    private static let sizeFormatter = FileSizeFormatter()
}

private struct ModifiedDateFormatter {
    private let formatter: DateFormatter

    init() {
        formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
    }

    func string(from date: Date?) -> String {
        guard let date else { return "—" }
        return formatter.string(from: date)
    }
}

private struct FileSizeFormatter {
    private let formatter: ByteCountFormatter

    init() {
        formatter = ByteCountFormatter()
        formatter.countStyle = .file
    }

    func string(fromByteCount size: Int64?) -> String {
        guard let size else { return "—" }
        return formatter.string(fromByteCount: size)
    }
}

// MARK: Column resize handle

private struct ColumnResizeHandle: View {
    let onChange: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6, height: Theme.Metrics.columnHeaderHeight)
            .overlay(
                Rectangle()
                    .fill(isHovered || isDragging ? Theme.Color.accent.opacity(0.7) : Theme.Color.separator)
                    .frame(width: isHovered || isDragging ? 1 : 0.5)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            lastTranslation = 0
                            NSCursor.resizeLeftRight.push()
                        }
                        let delta = value.translation.width - lastTranslation
                        lastTranslation = value.translation.width
                        onChange(delta)
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslation = 0
                        NSCursor.pop()
                    }
            )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
