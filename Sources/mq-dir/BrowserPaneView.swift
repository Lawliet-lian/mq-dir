import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

// MARK: 列布局单源（FileColumnID + 统一宽度/范围/标题映射）

/// 列唯一标识：列顺序与 Finder 严格对齐
/// Name 弹性列不参与拖拽调整；其余 4 列（Modified/Size/Kind/Created）
/// 「每列右边缘 = 一根拖拽线，只调该列本身宽度」，且 Created 最右侧再追加一根线，
/// 所有列宽/range/排序 key/标题全在这里配置，Header 和 Row 共用同一套映射避免错位。
private enum FileColumnID: String, CaseIterable, Identifiable, Hashable {
    case name
    case modified
    case size
    case kind
    case created

    var id: String { rawValue }

    /// 对应的排序枚举 key（供 sortHeader 用，nil 表示不参与排序）
    var sortKey: FileEntrySortKey? {
        switch self {
        case .name:     return .name
        case .modified: return .modified
        case .size:     return .size
        case .kind:     return .kind
        case .created:  return .created
        }
    }

    /// 列标题的本地化 key
    var titleKey: String {
        switch self {
        case .name:     return "mqdir.browser.column.name"
        case .modified: return "mqdir.browser.column.modified"
        case .size:     return "mqdir.browser.column.size"
        case .kind:     return "mqdir.browser.column.kind"
        case .created:  return "mqdir.browser.column.created"
        }
    }

    /// 是否为 Name 这种弹性（maxWidth:.infinity）列，弹性列不接受拖拽改宽
    var isFlexible: Bool {
        self == .name
    }

    /// 在 PaneColumnWidths 中对应的宽度（非弹性列）；弹性列返回 nil
    func width(in widths: PaneColumnWidths) -> CGFloat? {
        switch self {
        case .name:     return nil
        case .modified: return widths.modified
        case .size:     return widths.size
        case .kind:     return widths.kind
        case .created:  return widths.created
        }
    }

    /// 该列允许的宽度范围（非弹性列）；弹性列返回 nil
    var allowedRange: ClosedRange<CGFloat>? {
        switch self {
        case .name:     return nil
        case .modified: return PaneColumnWidths.modifiedRange
        case .size:     return PaneColumnWidths.sizeRange
        case .kind:     return PaneColumnWidths.kindRange
        case .created:  return PaneColumnWidths.createdRange
        }
    }
}

/// 每一列之间 + 列和 handle 之间的视觉/命中区宽度，**必须和 ColumnResizeHandle.frame(width:) 保持完全一致**
/// 这样 Row 的 cell 对齐和 Header 的 sortHeader 才能完全对齐，不会因宽度错位触发 SwiftUI 连锁 relayout 卡顿。
private let kColumnDividerWidth: CGFloat = 12

// #region debug-point A:column-divider-reporting
@inline(__always)
private func reportColumnResizeDebug(
    _ hypothesisId: String,
    _ msg: String,
    data: [String: Any] = [:]
) {
    let envURL = URL(fileURLWithPath: ".dbg/column-resize-lines.env")
    var endpoint = "http://127.0.0.1:7777/event"
    var sessionId = "column-resize-lines"
    if let envText = try? String(contentsOf: envURL) {
        for line in envText.split(separator: "\n") {
            if line.hasPrefix("DEBUG_SERVER_URL=") {
                endpoint = String(line.dropFirst("DEBUG_SERVER_URL=".count))
            } else if line.hasPrefix("DEBUG_SESSION_ID=") {
                sessionId = String(line.dropFirst("DEBUG_SESSION_ID=".count))
            }
        }
    }
    guard let url = URL(string: endpoint),
          let body = try? JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
              "runId": "post-fix",
            "hypothesisId": hypothesisId,
            "location": "BrowserPaneView.swift",
            "msg": "[DEBUG] \(msg)",
            "data": data,
            "ts": Int(Date().timeIntervalSince1970 * 1000)
          ]) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    URLSession.shared.dataTask(with: request).resume()
}
// #endregion

/// Routes a tab drop to `paneVM.move`. The drop "happens" when the user
/// hovers over a target tab (`dropEntered`) — that gives the immediate
/// drag-to-reorder feel like Safari, instead of waiting for `performDrop`
/// which only fires on mouseUp. `performDrop` returns true so SwiftUI
/// considers the drop accepted and clears the drag state.
/// Chrome-style tab drop delegate.
///
/// Hover over a tab → an insertion-line indicator appears (blue 2pt
/// vertical bar) and the cursor's horizontal position decides whether
/// the line snaps to the leading or trailing edge of the hovered chip.
/// The actual reorder doesn't run until `performDrop`, so the bar
/// doesn't shuffle around as the user drags — it only moves the once,
/// where the user told it to land. Cross-pane drops decode the source
/// pane via `TabDragCoordinator` and detach + attach in one step.
private struct TabReorderDropDelegate: DropDelegate {
    let paneVM: PaneTabsViewModel
    let paneIndex: Int
    /// Insertion index this delegate represents, computed from hover
    /// position. For per-tab delegates we resolve leading vs trailing
    /// half via the chip width snapshot. For the trailing zone after
    /// the last tab we just hardcode `tabs.count`.
    let resolveInsertionIndex: (DropInfo) -> Int
    @Binding var insertionPreview: Int?
    @Binding var draggingID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        insertionPreview = resolveInsertionIndex(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = resolveInsertionIndex(info)
        if insertionPreview != next { insertionPreview = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionPreview = nil
    }

    @MainActor
    func performDrop(info: DropInfo) -> Bool {
        let coord = TabDragCoordinator.shared
        let insertionIndex = resolveInsertionIndex(info)
        let sourceTabID = coord.sourceTabID
        let sourcePaneIdx = coord.sourcePaneIndex

        // Clear the visual preview FIRST so the blue insertion bar
        // disappears the instant the user lets go, even if the move
        // logic short-circuits below.
        insertionPreview = nil
        draggingID = nil
        coord.clear()

        guard let sourceTabID, let sourcePaneIdx else { return false }

        if sourcePaneIdx == paneIndex {
            guard let from = paneVM.tabs.firstIndex(where: { ObjectIdentifier($0) == sourceTabID })
            else { return false }
            paneVM.move(from: from, to: insertionIndex)
        } else {
            // moveTab needs the coord state, but we already cleared it.
            // Re-arm with the cached values just for this call, then
            // clear again so any subsequent stale event sees no source.
            coord.begin(sourcePaneIndex: sourcePaneIdx, tabID: sourceTabID)
            coord.moveTab(toPaneIndex: paneIndex, atTabIndex: insertionIndex)
            coord.clear()
        }
        return true
    }
}

struct BrowserPaneView: View {
    let index: Int
    @ObservedObject var paneVM: PaneTabsViewModel
    /// Resolved via the app-level `.environmentObject(workspace)` so
    /// the pane's empty-area context menu can show the user's
    /// current Toggle Hidden Files binding (Settings → Shortcuts)
    /// instead of a stale `⌘⇧.` literal.
    @EnvironmentObject private var workspace: WorkspaceManager
    let isFocused: Bool
    let onFocus: () -> Void

    /// Live "normalise Hangul filenames to NFC on drag out" preference,
    /// read off the workspace settings and handed to the drag-source
    /// modifiers so each drag-start can rename NFD names before the
    /// pasteboard captures them.
    private var normalizeHangulOnDragOut: Bool {
        workspace.workspace.settings.normalizeHangulOnDragOut
    }

    @State private var paneIsDropTargeted = false
    @State private var rowDropTargeted: FileEntry.ID?
    /// Where the blue insertion-line indicator should render in this
    /// pane's tab bar while a tab is being dragged over it. `nil` =
    /// no preview (no drag in this pane). `0` = before the first tab,
    /// `tabs.count` = after the last tab.
    @State private var tabDropInsertionIndex: Int?
    /// Per-tab-index width snapshot, captured via a GeometryReader
    /// background on each chip. Used by the per-tab drop delegate to
    /// decide leading vs trailing half from the cursor position.
    @State private var tabChipWidths: [Int: CGFloat] = [:]
    /// Name 列本地可调宽度：不持久化，先把第一根线做成真正的 Finder 风格「Name 右边缘」。
    /// 之前 Name 是纯弹性列，没有真实 handle，导致第一根 visible line 只是装饰线而不是可拖拽边界。
    @State private var nameColumnWidth: CGFloat = 280
    /// 任意列正在拖拽改宽时置为 true。
    /// 用它让内容区文件名在拖拽阶段切换到更稳定的截断策略，避免长文件名因为中间截断
    /// 每一帧都重算省略位置，造成肉眼可见的闪烁。
    @State private var isColumnResizing = false
    /// 当前正在拖拽预览的列。
    @State private var previewResizeColumn: FileColumnID?
    /// 当前正在预览中的目标宽度。拖拽过程中只用它画竖线，不立即改内容区布局。
    @State private var previewResizeWidth: CGFloat?
    /// Observe the cross-pane drag coordinator so we can clear our
    /// insertion-marker preview the moment any drop completes — a
    /// belt-and-suspenders against SwiftUI processing a sibling drop
    /// zone's dropEntered AFTER our performDrop returns.
    @ObservedObject private var tabDragCoordinator = TabDragCoordinator.shared

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
        // Installs an NSView into the window's responder chain so this
        // window has formal standing in Quick Look's first-responder
        // arbitration (see QuickLookPanelBridge). The direct
        // `.onKeyPress(.space) → QuickLookManager.toggle` path still
        // drives the common case; this only supplements it.
        .background(QuickLookPanelBridge())
        .overlay(
            Rectangle()
                .strokeBorder(
                    paneBorderColor,
                    lineWidth: Theme.Metrics.focusBorderWidth
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onChange(of: tabDragCoordinator.sourceTabID) { _, new in
            // Drag finished (drop or cancel) → wipe any leftover
            // insertion marker AND restore the dragged tab's opacity.
            // The `draggingTabID = nil` reset used to live only inside
            // `TabReorderDropDelegate.performDrop`, so a drop landing
            // on a non-tab target (e.g. Favorites in the sidebar)
            // left the source tab stuck at 0.35 opacity. The
            // coordinator's `sourceTabID` is now the single source of
            // truth that every drop target clears via `clear()`.
            if new == nil {
                tabDropInsertionIndex = nil
                draggingTabID = nil
            }
        }
    }

    private var paneBorderColor: Color {
        if paneIsDropTargeted && rowDropTargeted == nil { return Theme.Color.accent }
        if isFocused { return Theme.Color.accent }
        return .clear
    }

    /// Right-click in the file list's empty area. Mirrors the Finder
    /// background context menu — actions that operate on the *current
    /// folder* rather than a specific file. The Sort By submenu lets
    /// users discover the sort options without finding the column
    /// headers; "Folders on Top" toggles the per-tab pin behaviour
    /// already exposed via the column-header menu.
    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        Button(L("mqdir.browser.newFolder")) { viewModel.createNewFolder() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(viewModel.folderURL == nil)

        Divider()

        Button(L("mqdir.browser.paste")) { viewModel.pasteFromPasteboard(normalizeHangul: normalizeHangulOnDragOut) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!viewModel.canPasteFiles || viewModel.folderURL == nil)

        Divider()

        // 空区域右键菜单的「排序方式」子菜单，与列头排序、Finder 排序方式对齐
        Menu(L("mqdir.browser.sortBy")) {
            sortMenuItem(L("mqdir.browser.column.name"), key: .name)
            sortMenuItem(L("mqdir.browser.sort.dateModified"), key: .modified)
            sortMenuItem(L("mqdir.browser.sort.dateCreated"), key: .created)
            sortMenuItem(L("mqdir.browser.column.size"), key: .size)
            sortMenuItem(L("mqdir.browser.column.kind"), key: .kind)
            Divider()
            // 文件夹置顶（勾选态：当前已开启时前面显示 √）
            Button(viewModel.foldersOnTop
                   ? "✓ \(L("mqdir.browser.sort.foldersOnTop"))"
                   : L("mqdir.browser.sort.foldersOnTop")) {
                viewModel.setFoldersOnTop(!viewModel.foldersOnTop)
            }
        }

        // 显示隐藏文件（勾选态同上面模式）
        Button(viewModel.includeHidden
               ? "✓ \(L("mqdir.browser.sort.showHiddenFiles"))"
               : L("mqdir.browser.sort.showHiddenFiles")) {
            viewModel.toggleHiddenFiles()
        }
        .keyboardShortcut(workspace.workspace.settings.binding(for: .toggleHiddenFiles))

        Divider()

        Button(L("mqdir.browser.openInTerminal")) { viewModel.openCurrentFolderInTerminal() }
            .disabled(viewModel.folderURL == nil)
        if viewModel.canOpenInCmux {
            Button(L("mqdir.browser.openInCmux")) { viewModel.openCurrentFolderInCmux() }
                .disabled(viewModel.folderURL == nil)
        }
        Button(L("mqdir.browser.openInFinder")) { viewModel.openCurrentFolderInFinder() }
            .disabled(viewModel.folderURL == nil)
        Button(L("mqdir.browser.copyPath")) { viewModel.copyCurrentFolderPath() }
            .disabled(viewModel.folderURL == nil)
    }

    /// One row in the Sort By submenu — current key gets a leading
    /// checkmark prefix; tapping any row swaps to that key (or flips
    /// direction if it was already active, matching column-header
    /// click behaviour).
    @ViewBuilder
    private func sortMenuItem(_ title: String, key: FileEntrySortKey) -> some View {
        let isActive = viewModel.sortKey == key
        Button(isActive ? "✓ \(title)" : title) { viewModel.setSort(key) }
    }

    /// Minimum width the Name column collapses to before the whole list
    /// strip starts horizontally scrolling. Calibrated so a typical
    /// "kebab-case-some-thing.swift" still survives middle-truncation
    /// cleanly without the row going completely blank when the preview
    /// pane opens and the pane shrinks.
    private static let nameColumnMinWidth: CGFloat = 200
    private static let nameColumnRange: ClosedRange<CGFloat> = 200...800

    /// Natural minimum of the columns strip = name floor + all non-flexible
    /// column widths (Modified/Size/Kind/Created) + 4 列间分隔符 + Created
    /// 最右侧追加的一根 handle，共 5 个 handle，每个热点宽 kColumnDividerWidth(12pt)，
    /// 再加上 header 外侧 padding(6pt × 2)。
    ///
    /// 与原手写数值版的差异：
    /// - 使用 FileColumnID.allCases 单源循环求和，避免将来新增列时忘记加宽度
    /// - 列间分隔 + 最后列右边缘 handle 计数来自：4 个列间（Modified/Size/Kind/Created 左侧各 1 个）
    ///   + 1 个 Created 最右 handle = 5
    /// 当 pane 比这个最小值窄时交给水平 ScrollView；更宽时 .frame(minWidth:geo.size.width)
    /// 会拉伸填充，避免列都堆在左边。
    private var minColumnsTotal: CGFloat {
        let widths = viewModel.columnWidths
        let fixedWidthSum = widths.modified + widths.size + widths.kind + widths.created
        let nameWidth = max(Self.nameColumnMinWidth, nameColumnWidth)
        // 5 列各自的右边缘都有一根线：Name / Modified / Size / Kind / Created
        let handleCount = 5
        let handles    = CGFloat(handleCount) * kColumnDividerWidth
        let outerPadding: CGFloat = 6 * 2
        return nameWidth + fixedWidthSum + handles + outerPadding
    }

    /// 非 Name 列一共会占掉多少水平空间。把这部分单独抽出来后，我们就
    /// 能在 pane 变宽时把剩余空间优先交给 Name 列，而不是留下大块空白。
    private var nonNameColumnsTotal: CGFloat {
        let widths = viewModel.columnWidths
        let fixedWidthSum = widths.modified + widths.size + widths.kind + widths.created
        let handleCount = 5
        let handles = CGFloat(handleCount) * kColumnDividerWidth
        let outerPadding: CGFloat = 6 * 2
        return fixedWidthSum + handles + outerPadding
    }

    /// 计算当前 pane 可见宽度下，Name 列最终应展示的宽度。
    ///
    /// 这里不直接改写 `nameColumnWidth` 状态，而是在布局阶段做“只扩不缩”
    /// 的显示扩展：
    /// - pane 变窄时，继续遵守用户拖出来的 Name 列宽度；
    /// - pane 变宽时，让新增空间优先被 Name 列吸收，避免列表内容左右留白。
    private func effectiveNameColumnWidth(for availablePaneWidth: CGFloat) -> CGFloat {
        let committedNameWidth = max(Self.nameColumnMinWidth, nameColumnWidth)
        let expandedNameWidth = availablePaneWidth - nonNameColumnsTotal
        return max(committedNameWidth, expandedNameWidth)
    }

    /// 读取某一列当前已提交到布局系统的宽度；拖拽预览态不算在这里。
    /// Name 列使用当前“实际显示宽度”，这样 pane 变宽后再拖其他列时，
    /// 预览线仍然能和屏幕上真正的列边界保持对齐。
    private func committedWidth(for col: FileColumnID, displayedNameWidth: CGFloat) -> CGFloat {
        switch col {
        case .name:
            return max(Self.nameColumnMinWidth, displayedNameWidth)
        case .modified:
            return viewModel.columnWidths.modified
        case .size:
            return viewModel.columnWidths.size
        case .kind:
            return viewModel.columnWidths.kind
        case .created:
            return viewModel.columnWidths.created
        }
    }

    /// 预览线在内容容器中的 x 坐标。拖拽时只移动这根线，内容区保持旧列宽不重排。
    private func previewDividerOffsetX(displayedNameWidth: CGFloat) -> CGFloat? {
        guard let previewResizeColumn, let previewResizeWidth else { return nil }
        let orderedColumns: [FileColumnID] = [.name, .modified, .size, .kind, .created]
        var x: CGFloat = 6 // 对齐 columnHeader/file rows 的 horizontal padding 左边距
        for col in orderedColumns {
            let width = (col == previewResizeColumn)
                ? previewResizeWidth
                : committedWidth(for: col, displayedNameWidth: displayedNameWidth)
            x += width
            if col == previewResizeColumn {
                return x + (kColumnDividerWidth / 2)
            }
            x += kColumnDividerWidth
        }
        return nil
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
            let effectiveNameWidth = effectiveNameColumnWidth(for: geo.size.width)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader(nameColumnWidth: effectiveNameWidth)
                    fileList(nameColumnWidth: effectiveNameWidth)
                }
                .overlay(alignment: .topLeading) {
                    if let previewX = previewDividerOffsetX(displayedNameWidth: effectiveNameWidth) {
                        Rectangle()
                            .fill(Theme.Color.accent)
                            .frame(width: 1, height: geo.size.height)
                            .offset(x: previewX - 0.5)
                            .allowsHitTesting(false)
                    }
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
                    tabInsertionMarker(at: idx)
                    tabChip(for: tab, at: idx)
                }
                tabInsertionMarker(at: paneVM.tabs.count)
                trailingTabDropZone
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

    /// Blue 2pt vertical bar — the Chrome-style "this is where the tab
    /// will land if you drop now" indicator. Only renders when the
    /// active drop preview matches this slot AND a drag is actually
    /// in flight (the coordinator still has a source tab). Without
    /// the second guard a stale @State preview value can survive
    /// performDrop and leave a phantom bar after the drop completes.
    @ViewBuilder
    private func tabInsertionMarker(at index: Int) -> some View {
        if tabDropInsertionIndex == index, tabDragCoordinator.sourceTabID != nil {
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(width: 2, height: Theme.Metrics.tabBarHeight - 8)
                .padding(.vertical, 4)
                .padding(.horizontal, 1)
        }
    }

    /// Captures drops in the empty area after the last tab so "drop at
    /// the end" works without forcing the user to hover the rightmost
    /// tab's trailing half.
    private var trailingTabDropZone: some View {
        Color.clear
            .frame(width: 1, height: Theme.Metrics.tabBarHeight)
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.plainText.identifier],
                delegate: TabReorderDropDelegate(
                    paneVM: paneVM,
                    paneIndex: index,
                    resolveInsertionIndex: { _ in paneVM.tabs.count },
                    insertionPreview: $tabDropInsertionIndex,
                    draggingID: $draggingTabID
                )
            )
    }

    @ViewBuilder
    private func tabChip(for tab: FolderBrowserViewModel, at idx: Int) -> some View {
        let isActive = paneVM.activeIndex == idx
        // 没有打开文件夹时，标签页标题回退为本地化的"未命名/Untitled"
        let title = tab.folderURL?.lastPathComponent ?? L("mqdir.browser.tab.untitled")
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
            .help(L("mqdir.browser.tab.close"))
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
            Button(L("mqdir.browser.tab.new")) { paneVM.newTab() }
            Divider()
            Button(L("mqdir.browser.tab.closeTab")) { paneVM.closeTab(at: idx) }
            Button(L("mqdir.browser.tab.closeOtherTabs")) { paneVM.closeOthers(keep: idx) }
                .disabled(paneVM.tabs.count <= 1)
            Button(L("mqdir.browser.tab.closeToRight")) { paneVM.closeToTheRight(of: idx) }
                .disabled(idx >= paneVM.tabs.count - 1)
            Divider()
            Button(L("mqdir.browser.tab.duplicate")) { paneVM.duplicate(at: idx) }
            if let url = tab.folderURL {
                Button(L("mqdir.menu.file.revealInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        // Drag source: ship the tab id as `public.text` but with
        // `.ownProcess` visibility so external destinations (cmux,
        // terminals, text editors) don't see the drag at all and
        // therefore can't paste the literal `ObjectIdentifier(0x…)`
        // string. The actual reorder routing reads
        // `TabDragCoordinator.shared` (which knows source pane +
        // tab id) rather than the pasteboard payload — the string is
        // only here to satisfy SwiftUI's drop-type matching.
        //
        // The tab's folder URL also rides along (same `.ownProcess`
        // visibility) so dropping a tab onto the sidebar's Favorites
        // section adds that folder — Favorites' existing drop handler
        // already accepts `public.file-url`. Tab-reorder drop targets
        // only match `plainText`, so the extra URL representation is
        // a no-op for them.
        .onDrag {
            draggingTabID = id
            TabDragCoordinator.shared.begin(sourcePaneIndex: index, tabID: id)
            let provider = NSItemProvider()
            provider.registerObject(
                String(describing: id) as NSString,
                visibility: .ownProcess
            )
            if let folderURL = tab.folderURL {
                // Default `.all` visibility so external destinations
                // (Finder, Terminal, etc.) can also receive the URL
                // when the user drags a tab outside the window — the
                // tab id NSString above stays `.ownProcess` so the
                // raw `ObjectIdentifier(0x…)` literal never escapes.
                provider.registerObject(folderURL as NSURL, visibility: .all)
            }
            return provider
        }
        .background(
            // Snapshot the live chip width so the drop delegate can
            // decide leading vs trailing half from the cursor position.
            GeometryReader { geo in
                Color.clear.onAppear { tabChipWidths[idx] = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in tabChipWidths[idx] = new }
            }
        )
        .opacity(draggingTabID == id ? 0.35 : 1)
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: TabReorderDropDelegate(
                paneVM: paneVM,
                paneIndex: index,
                resolveInsertionIndex: { info in
                    let width = tabChipWidths[idx] ?? 100
                    return info.location.x < width / 2 ? idx : idx + 1
                },
                insertionPreview: $tabDropInsertionIndex,
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
        .help(L("mqdir.browser.tab.new"))
    }

    // MARK: Folder header strip

    private var paneHeader: some View {
        HStack(spacing: 6) {
            paneHeaderTitle
            if let tag = viewModel.tagFilter {
                tagFilterChip(tag)
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

    /// Active tag-filter affordance, mounted in the pane header next to the
    /// folder title — the same strip that carries the search-active state's
    /// sibling chrome, so an active filter is always visible and dismissible.
    /// Renders the tag's Finder swatch (resolved from the focused tab's tag
    /// summaries by name) + the tag name + a ✕ that clears the filter.
    private func tagFilterChip(_ tag: String) -> some View {
        let labelNumber = viewModel.tagSummaries.first { $0.name == tag }?.labelNumber ?? 0
        return HStack(spacing: 4) {
            if let color = TagColor.color(forLabel: labelNumber) {
                Circle().fill(color).frame(width: 7, height: 7)
            } else {
                Circle()
                    .strokeBorder(Theme.Color.labelTertiary, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
            Text(tag)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Color.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                viewModel.tagFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
            .buttonStyle(.plain)
            .help(L("mqdir.browser.tagFilter.clear"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .help(L("mqdir.browser.tagFilter.applied", tag))
    }

    /// Folder name + item count strip on the left of the pane header.
    /// Doubles as a drag SOURCE for the current folder URL itself, so
    /// the user can drop the whole folder onto cmux / a terminal /
    /// another file manager without first navigating into it. Drag
    /// only attaches when a folder is actually open — the empty state
    /// label has nothing to drag.
    @ViewBuilder
    private var paneHeaderTitle: some View {
        if let url = viewModel.folderURL {
            HStack(spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Color.label)
                Text(L("mqdir.browser.empty.placeholder"))
                    .foregroundStyle(Theme.Color.labelTertiary)
                Text(itemCountLabel)
                    .foregroundStyle(Theme.Color.labelSecondary)
            }
            .contentShape(Rectangle())
            .help(url.path)
            .appKitFileDrag(primary: url, normalizeHangul: normalizeHangulOnDragOut)
            .inactiveDragSource(primary: url, normalizeHangul: normalizeHangulOnDragOut)
        } else {
            Text(L("mqdir.browser.empty.noFolder"))
                .foregroundStyle(Theme.Color.labelTertiary)
        }
    }

    /// Tiny segmented control: list-bullet / chevron-right.dotted to toggle
    /// between flat columns and the VS Code-style tree. Lives on the right
    /// edge of the pane header so it's discoverable per-tab without taking
    /// space from the breadcrumb.
    private var viewModeToggle: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                // 列表视图（平铺列）
                viewModeButton(.list, symbol: "list.bullet", help: L("mqdir.misc.listView"))
                // 树形视图（可展开子目录，VS Code 风格）
                viewModeButton(.tree, symbol: "rectangle.split.3x1", help: L("mqdir.misc.treeView"))
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
        .help(L("mqdir.browser.preview.toggle"))
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

    // 条目计数标签（显示在面板右上，区分搜索/标签过滤/普通浏览三种模式）
    private var itemCountLabel: String {
        if viewModel.isFiltering {
            // 正在搜索（可能还在遍历子目录）
            if viewModel.isSearching { return L("mqdir.browser.status.searching") }
            // 已有搜索/过滤结果
            let count = viewModel.visibleEntries.count
            return L("mqdir.browser.status.matches", count, count == 1 ? "" : L("mqdir.browser.status.matchesPlural"))
        }
        // 仅按标签过滤
        if viewModel.isTagFiltering {
            let count = viewModel.visibleEntries.count
            return L("mqdir.browser.status.matches", count, count == 1 ? "" : L("mqdir.browser.status.matchesPlural"))
        }
        // 正常显示所有条目
        let total = viewModel.entries.count
        return L("mqdir.browser.status.items", total, total == 1 ? "" : L("mqdir.browser.status.itemsPlural"))
    }

    // 空状态主文案（配合不同过滤状态给出有意义的提示）
    private var emptyStateLabel: String {
        if viewModel.isFiltering {
            // 还在遍历子目录时的中间状态
            if viewModel.isSearching { return L("mqdir.browser.empty.searching") }
            // 有搜索关键词但无命中
            let trimmed = viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
            return L("mqdir.browser.empty.noMatches", trimmed)
        }
        // 按标签过滤但无命中
        if let tag = viewModel.tagFilter {
            return L("mqdir.browser.empty.noTaggedItems", tag)
        }
        // 文件夹本身就是空的
        return L("mqdir.browser.empty.noItems")
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

    /// Resolve the Size-column string for a row. Files use their own
    /// `size`; directories (which enumerate with `size == nil`) show "…"
    /// while an on-demand size walk runs, the formatted total once it lands
    /// in the VM's `computedDirectorySizes`, or "—" until the user invokes
    /// "Calculate Size". Same `.file`-style formatter the file rows use, so
    /// computed folder totals format identically to file sizes.
    private func sizeText(for entry: FileEntry) -> String {
        if entry.isDirectory {
            if viewModel.computingSizeIDs.contains(entry.id) { return "\u{2026}" }
            if let size = viewModel.computedDirectorySizes[entry.id] {
                return Self.sizeFormatter.string(fromByteCount: size)
            }
            return "\u{2014}"
        }
        return Self.sizeFormatter.string(fromByteCount: entry.size)
    }

    /// Shared `.file`-style byte formatter for the Size column — one instance
    /// reused across every row's `sizeText(for:)` resolution.
    private static let sizeFormatter = FileSizeFormatter()

    // 列标题栏：Name/Modified/Size/Kind 四列，支持点击排序和拖拽改列宽
    // 列顺序严格按用户要求：名称 → 修改日期 → 大小 → 种类 → 创建日期（创建日期必须紧贴 Kind 右侧）
    //
    // 拖拽规则严格对齐 Finder：
    //   - 每一列（除弹性 Name 外）「右边缘」= 一根拖拽线，拖拽时只变「该列（线前面的格子）」宽度，
    //     右边所有列原地不动，超出部分交给水平 ScrollView 接管
    //   - 最右列（Created）的**最右侧**额外再追加一根线：拖拽时只变 Created（Finder 规则 B）
    //
    // 实现方式：列布局用 FileColumnID.allCases 循环生成，保证 Header 和 Row 的顺序/宽度/间距
    // 100% 一致，不会出现「Header 间隔 12pt / Row 间隔 6pt」造成的错位卡顿。
    //
    // 注意：BrowserPaneView 里 `viewModel` 是普通计算属性（非 @ObservedObject），没有 `$viewModel` 投影，
    // 传给 ColumnResizeHandle 的 Binding 用 Binding(get:set:) 手动构造读写 @Published 的 columnWidths。
    private func columnHeader(nameColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 0, height: 0)
                .task {
                    reportHeaderDividerStructure(
                        for: .name,
                        hasLeadingDecorativeDivider: false,
                        hasTrailingResizeHandle: true
                    )
                }
            sortHeader(L("mqdir.browser.column.name"), key: .name, alignment: .leading)
                .frame(
                    width: max(Self.nameColumnMinWidth, nameColumnWidth),
                    alignment: Alignment.leading
                )
            ColumnResizeHandle(
                width: $nameColumnWidth,
                range: Self.nameColumnRange,
                debugLabel: FileColumnID.name.rawValue,
                onDragStateChange: { isColumnResizing = $0 },
                onPreviewWidthChange: { width in
                    previewResizeColumn = (width == nil) ? nil : .name
                    previewResizeWidth = width
                }
            )

            Color.clear
                .frame(width: 0, height: 0)
                .task {
                    reportHeaderDividerStructure(
                        for: .modified,
                        hasLeadingDecorativeDivider: false,
                        hasTrailingResizeHandle: true
                    )
                }
            sortHeader(L("mqdir.browser.column.modified"), key: .modified, alignment: .leading)
                .frame(
                    width: viewModel.columnWidths.modified,
                    alignment: Alignment.leading
                )
            ColumnResizeHandle(
                width: columnBinding(for: .modified),
                range: PaneColumnWidths.modifiedRange,
                debugLabel: FileColumnID.modified.rawValue,
                onDragStateChange: { isColumnResizing = $0 },
                onPreviewWidthChange: { width in
                    previewResizeColumn = (width == nil) ? nil : .modified
                    previewResizeWidth = width
                }
            )

            Color.clear
                .frame(width: 0, height: 0)
                .task {
                    reportHeaderDividerStructure(
                        for: .size,
                        hasLeadingDecorativeDivider: false,
                        hasTrailingResizeHandle: true
                    )
                }
            sortHeader(L("mqdir.browser.column.size"), key: .size, alignment: .trailing)
                .frame(
                    width: viewModel.columnWidths.size,
                    alignment: Alignment.trailing
                )
            ColumnResizeHandle(
                width: columnBinding(for: .size),
                range: PaneColumnWidths.sizeRange,
                debugLabel: FileColumnID.size.rawValue,
                onDragStateChange: { isColumnResizing = $0 },
                onPreviewWidthChange: { width in
                    previewResizeColumn = (width == nil) ? nil : .size
                    previewResizeWidth = width
                }
            )

            Color.clear
                .frame(width: 0, height: 0)
                .task {
                    reportHeaderDividerStructure(
                        for: .kind,
                        hasLeadingDecorativeDivider: false,
                        hasTrailingResizeHandle: true
                    )
                }
            sortHeader(L("mqdir.browser.column.kind"), key: .kind, alignment: .leading)
                .frame(
                    width: viewModel.columnWidths.kind,
                    alignment: Alignment.leading
                )
            ColumnResizeHandle(
                width: columnBinding(for: .kind),
                range: PaneColumnWidths.kindRange,
                debugLabel: FileColumnID.kind.rawValue,
                onDragStateChange: { isColumnResizing = $0 },
                onPreviewWidthChange: { width in
                    previewResizeColumn = (width == nil) ? nil : .kind
                    previewResizeWidth = width
                }
            )

            Color.clear
                .frame(width: 0, height: 0)
                .task {
                    reportHeaderDividerStructure(
                        for: .created,
                        hasLeadingDecorativeDivider: false,
                        hasTrailingResizeHandle: true
                    )
                }
            sortHeader(L("mqdir.browser.column.created"), key: .created, alignment: .leading)
                .frame(
                    width: viewModel.columnWidths.created,
                    alignment: Alignment.leading
                )
            ColumnResizeHandle(
                width: columnBinding(for: .created),
                range: PaneColumnWidths.createdRange,
                debugLabel: FileColumnID.created.rawValue,
                onDragStateChange: { isColumnResizing = $0 },
                onPreviewWidthChange: { width in
                    previewResizeColumn = (width == nil) ? nil : .created
                    previewResizeWidth = width
                }
            )
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

    /// 构造 FileColumnID → columnWidths 属性的 Binding（集中在一处避免重复手写）
    private func columnBinding(for col: FileColumnID) -> Binding<CGFloat> {
        Binding<CGFloat>(
            get: { col.width(in: viewModel.columnWidths) ?? 0 },
            set: { newValue in
                // 根据列 ID 回写到对应的 PaneColumnWidths 字段
                switch col {
                case .modified: viewModel.columnWidths.modified = newValue
                case .size:     viewModel.columnWidths.size     = newValue
                case .kind:     viewModel.columnWidths.kind     = newValue
                case .created:  viewModel.columnWidths.created  = newValue
                case .name:
                    // Name 是弹性列，理论上 isFlexible 会提前 return，这里做兜底
                    assertionFailure("Name column should not be resizable.")
                }
            }
        )
    }

    // #region debug-point B:header-divider-structure
    private func reportHeaderDividerStructure(
        for col: FileColumnID,
        hasLeadingDecorativeDivider: Bool,
        hasTrailingResizeHandle: Bool
    ) {
        reportColumnResizeDebug(
            "B",
            "header column rendered",
            data: [
                "column": col.rawValue,
                "isFlexible": col.isFlexible,
                "hasLeadingDecorativeDivider": hasLeadingDecorativeDivider,
                "hasTrailingResizeHandle": hasTrailingResizeHandle,
                "dividerWidth": kColumnDividerWidth
            ]
        )
    }
    // #endregion

    // 单个排序表头：点击切换排序键，当前键再点一次切换升降序
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
        // 右键列头：切换"文件夹置顶"
        .contextMenu {
            Button {
                viewModel.setFoldersOnTop(!viewModel.foldersOnTop)
            } label: {
                Label(
                    L("mqdir.browser.sort.foldersOnTop"),
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
            Text(L("mqdir.browser.empty.openFolder"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.labelSecondary)
            Button(L("mqdir.browser.empty.openFolderButton")) { viewModel.chooseFolder() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            Text(L("mqdir.browser.empty.openError"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.label)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.labelSecondary)
                .multilineTextAlignment(.center)
            Button(L("mqdir.browser.empty.retry")) { viewModel.reload() }
                .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileList(nameColumnWidth: CGFloat) -> some View {
        // ScrollViewReader gives us a proxy so arrow-key navigation can keep
        // the selected row visible — Finder-style. `.id(entry.id)` on each
        // row makes the proxy able to find rows by FileEntry.ID.
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.visibleEntries) { entry in
                                rowView(for: entry, nameColumnWidth: nameColumnWidth)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 2)

                        // Fill any empty space below the last row.
                        // Clicking it clears the selection (Finder
                        // parity), right-clicking opens the
                        // empty-area context menu. Sits beneath the
                        // rows in the VStack so row gestures win when
                        // the user actually clicks a file.
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onTapGesture {
                                if !isFocused { onFocus() }
                                viewModel.clearSelection()
                            }
                            .contextMenu { emptyAreaContextMenu }
                    }
                    .frame(width: max(minColumnsTotal, geo.size.width), alignment: .topLeading)
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
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
            // Read Shift off the captured `KeyPress` instead of
            // `NSEvent.modifierFlags` — the latter is "modifiers right
            // now" and races the key handler, so Shift+↑/↓ range
            // selection was unreliable. The phase set has to include
            // `.repeat` or holding the arrow key just fires once: the
            // system key-repeat events get dropped on the floor.
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { keyPress in
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleArrowKey(by: 1, extending: keyPress.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { keyPress in
                guard viewModel.renamingEntryID == nil else { return .ignored }
                handleArrowKey(by: -1, extending: keyPress.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
            .onKeyPress(.return, phases: [.down]) { keyPress in
                // While a row is in inline-rename mode the Return key
                // belongs to the TextField (commits the rename). Don't
                // intercept it here or the parent's openSelected() races
                // the TextField's onSubmit and reorders the events
                // unpredictably. `phases: [.down]` switches the
                // closure to the `KeyPress`-receiving overload so the
                // ⌘ check below has a modifier set to read.
                guard viewModel.renamingEntryID == nil else { return .ignored }
                if !isFocused { onFocus() }
                if keyPress.modifiers.contains(.command),
                   let entry = viewModel.selectedEntry, entry.isDirectory {
                    AppCommand.openURLInNewTab(url: entry.url).post()
                } else {
                    viewModel.openSelected()
                }
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
                            copy: modifiers.contains(.option),
                            normalizeHangul: normalizeHangulOnDragOut
                        )
                    }
                }
                return true
            }
            }
        }
    }

    /// Shared body for ↑/↓ key presses on the file list. `extending`
    /// comes from the `KeyPress.modifiers` captured by `onKeyPress` so
    /// Shift+arrow walks reliably without polling `NSEvent` post hoc.
    private func handleArrowKey(by offset: Int, extending: Bool, proxy: ScrollViewProxy) {
        if !isFocused { onFocus() }
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
        // Use the VM's findEntry-backed accessor so tree-mode selections
        // (children living in `treeChildren`, not `visibleEntries`) are
        // included in right-click actions.
        return viewModel.selectedEntries
    }

    @ViewBuilder
    private func rowView(for entry: FileEntry, nameColumnWidth: CGFloat) -> some View {
        let isSelected = viewModel.selection.contains(entry.id)
        let isRowDropTarget = entry.isDirectory && rowDropTargeted == entry.id

        let row = FileEntryRow(
            entry: entry,
            isSelected: isSelected,
            paneIsFocused: isFocused,
            isDropTarget: isRowDropTarget,
            isColumnResizing: isColumnResizing,
            nameColumnWidth: max(Self.nameColumnMinWidth, nameColumnWidth),
            columnWidths: viewModel.columnWidths,
            sizeText: sizeText(for: entry),
            subtitle: searchSubtitle(for: entry),
            isRenaming: viewModel.renamingEntryID == entry.id,
            renameDraft: Binding(
                get: { viewModel.renameDraft },
                set: { viewModel.renameDraft = $0 }
            ),
            commitRename: {
                viewModel.commitRename()
                // `commitRename()` reloads `entries`, which makes
                // SwiftUI unmount the rename TextField in the same
                // turn — assigning `listFocused = true` synchronously
                // races that teardown and leaves the focus chain
                // orphaned (arrow keys silently no-op until the user
                // clicks). Hop one runloop turn so the unmount + list
                // re-render settles first; mirrors the same trick
                // search focus uses in MainWindowView.
                DispatchQueue.main.async { listFocused = true }
            },
            cancelRename: {
                viewModel.cancelRename()
                DispatchQueue.main.async { listFocused = true }
            },
            tabRename: { forward in
                viewModel.beginRenameAdjacent(forward: forward)
                // If the walk ran off the ends, no row is renaming now —
                // restore list focus so keyboard nav keeps working.
                if viewModel.renamingEntryID == nil {
                    DispatchQueue.main.async { listFocused = true }
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // ⌘+double-click on a folder opens it in a new tab —
            // mirrors Finder. Plain double-click stays the
            // "navigate into / launch file" path.
            if NSEvent.modifierFlags.contains(.command), entry.isDirectory {
                AppCommand.openURLInNewTab(url: entry.url).post()
            } else {
                viewModel.open(entry)
            }
        }
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
            // Lazy: resolving `selectedURLs` is O(M) at drag-start, and
            // doing it inside the row body would run it for every
            // selected visible row on every selection change. Cmd+A on
            // a ~1000-entry folder used to lock the main actor here.
            multiURLs: { [weak viewModel] in
                guard let viewModel,
                      isSelected,
                      viewModel.selection.count > 1
                else { return [] }
                return viewModel.selectedURLs
            },
            normalizeHangul: normalizeHangulOnDragOut
        )
        // Mirrors the SwiftUI tap + drag gestures above for the
        // inactive-window path: when mq-dir is in the background, the
        // overlay claims left-mouse-down so the window doesn't raise,
        // forwards click selection back here, and starts the AppKit
        // drag itself.
        .inactiveDragSource(
            primary: entry.url,
            multiURLs: { [weak viewModel] in
                guard let viewModel,
                      isSelected,
                      viewModel.selection.count > 1
                else { return [] }
                return viewModel.selectedURLs
            },
            normalizeHangul: normalizeHangulOnDragOut,
            onClick: { event in
                if !isFocused { onFocus() }
                let mods = event.modifierFlags
                if mods.contains(.shift) {
                    viewModel.extendSelection(to: entry.id)
                } else if mods.contains(.command) {
                    viewModel.toggleSelection(entry.id)
                } else {
                    viewModel.replaceSelection(entry.id)
                }
            },
            onDoubleClick: { _ in
                viewModel.open(entry)
            }
        )
        // Right-click should select the clicked row before the menu
        // shows (Finder parity). The NSEvent monitor fires on every
        // right-mouse-down anywhere in the window; per-row bounds
        // checking inside RightClickView decides whether THIS row was
        // the target. Selection is only replaced when the row isn't
        // already part of the current selection so a multi-row
        // right-click still operates on the whole multi-selection.
        .background(
            RightClickAware {
                if !viewModel.selection.contains(entry.id) {
                    viewModel.replaceSelection(entry.id)
                }
                if !isFocused { onFocus() }
            }
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
                            copy: modifiers.contains(.option),
                            normalizeHangul: normalizeHangulOnDragOut
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
    let isColumnResizing: Bool
    let nameColumnWidth: CGFloat
    let columnWidths: PaneColumnWidths
    /// Pre-resolved string for the Size column. Files render their formatted
    /// byte count; directories render "—" (unknown), "…" (size walk running),
    /// or the formatted on-demand total once "Calculate Size" completes. The
    /// caller (`rowView`) owns this resolution because the computed-size cache
    /// and computing set live on the VM, which the row struct doesn't hold.
    let sizeText: String
    /// Optional second line under the name — used by recursive search to show
    /// where in the tree a hit lives. `nil` keeps the row at single-line height.
    let subtitle: String?
    /// Inline-rename plumbing — non-nil when this row is the active
    /// rename target. Caller is responsible for showing only one row
    /// in rename mode at a time.
    let isRenaming: Bool
    @Binding var renameDraft: String
    let commitRename: () -> Void
    let cancelRename: () -> Void
    /// Tab / Shift-Tab while renaming — commit then advance to the
    /// next / previous visible row's rename (Finder-style).
    let tabRename: (_ forward: Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                FileRowIcon(
                    entry: entry,
                    isSelected: isSelected,
                    paneIsFocused: paneIsFocused
                )
                VStack(alignment: .leading, spacing: 1) {
                    if isRenaming {
                        RenameTextField(
                            text: $renameDraft,
                            isDirectory: entry.isDirectory,
                            onCommit: commitRename,
                            onCancel: cancelRename,
                            onTab: tabRename
                        )
                        .frame(maxWidth: .infinity)
                        .renameFieldChrome()
                    } else {
                        HStack(spacing: 5) {
                            Text(entry.name)
                                .font(Theme.Font.body)
                                .foregroundStyle(textColor)
                                .lineLimit(1)
                                // 长文件名在连续改宽时，用 middle 截断会频繁重算中间省略位置，
                                // SwiftUI 在大量行上会出现明显闪烁。拖拽期间临时改用 tail，
                                // 松手后再恢复 middle，兼顾平时可读性和拖拽稳定性。
                                .truncationMode(isColumnResizing ? .tail : .middle)
                            TagDotView(entry: entry)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .frame(minWidth: nameColumnWidth, maxWidth: .infinity, alignment: .leading)
            passiveColumnDivider

            Text(Self.modifiedDateFormatter.string(from: entry.modificationDate))
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .frame(width: columnWidths.modified, alignment: Alignment.leading)
            passiveColumnDivider

            Text(sizeText)
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .frame(width: columnWidths.size, alignment: Alignment.trailing)
            passiveColumnDivider

            Text(entry.kind)
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columnWidths.kind, alignment: Alignment.leading)
            passiveColumnDivider

            Text(Self.createdDateFormatter.string(from: entry.creationDate))
                .font(.system(size: 11))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .frame(width: columnWidths.created, alignment: Alignment.leading)
            passiveColumnDivider
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
        // While editing, drop the row's selection fill so the rename
        // field's accent ring is the dominant cue, not a competing
        // blue selection band behind it.
        if isRenaming { return .clear }
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

    /// 内容区的被动分隔条：宽度必须和 Header 的可拖拽 handle 完全一致，
    /// 这样标题和内容的竖线 x 坐标才会重合；这里只负责视觉占位，不处理拖拽。
    private var passiveColumnDivider: some View {
        Color.clear.frame(width: kColumnDividerWidth)
            .overlay(
                Rectangle()
                    .fill(Theme.Color.separator.opacity(0.35))
                    .frame(width: 0.5)
            )
    }

    // 修改日期 + 创建日期共享同一套 dateStyle/timeStyle（短日期+短时间），
    // 这里直接复用 ModifiedDateFormatter 再实例化一份，保证 UI 格式一致且 nil 兜底都显示 "—"
    private static let modifiedDateFormatter = ModifiedDateFormatter()
    private static let createdDateFormatter  = ModifiedDateFormatter()
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

/// 列拖拽分隔条：行为严格对齐 Finder 列表视图（List View）的分隔线规则
///
/// 与旧实现的 4 个关键差异（对齐 Finder）：
/// 1. 命中区 12pt（比视觉线宽，让鼠标不用精准对齐）
/// 2. minimumDistance = 3（过滤「想点排序却误触发拖拽」）
/// 3. 采用「起始宽度快照 + 绝对 translation」，不再是累积差分，
///    clamp 时不会出现「cursor 走了、线没动、松手再拖回弹」的错位感
/// 4. 签名改为 Binding<CGFloat> + ClosedRange，所有 caller 不再需要手动写 clamp，
///    语义也强制变成「一个 handle 只改它左边那列的宽度」（Finder 规则 A / B）
private struct ColumnResizeHandle: View {
    /// 绑定到「该分隔条左边列」的宽度（最后一列右边缘的 handle 绑定它自己）
    @Binding var width: CGFloat
    /// 允许的合法范围（PaneColumnWidths.*Range），拖拽时自动 clamp
    let range: ClosedRange<CGFloat>
    /// 仅用于调试：标记这根 handle 绑定的是哪一列，便于确认第一根可拖拽线到底是不是它。
    let debugLabel: String
    /// 通知上层当前是否处于列拖拽状态。用于让内容区在拖拽期间切换到更稳定的文字布局策略。
    let onDragStateChange: (Bool) -> Void
    /// 拖拽预览宽度变化：拖拽中只用来移动预览线，松手后才真正提交到内容区布局。
    let onPreviewWidthChange: (CGFloat?) -> Void

    /// 拖拽开始时的起始宽度（snapshot），后续 always + translation.width 用绝对位置算
    @State private var startWidth: CGFloat = 0
    /// 当前拖拽过程中的预览宽度。内容区不会实时跟随它变化，只用它画预览线。
    @State private var previewWidth: CGFloat = 0
    @State private var isHovered  = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            // 热点 12pt：视觉分隔线只有 0.5pt，但可点击区域 12pt（Finder 同款手感）
            .frame(width: kColumnDividerWidth, height: Theme.Metrics.columnHeaderHeight)
            .overlay(
                // 视觉分隔线居中画：不热点时 0.5pt，hover/drag 时 1pt + 高亮色
                Rectangle()
                    .fill(isHovered || isDragging ? Theme.Color.accent.opacity(0.7) : Theme.Color.separator)
                    .frame(width: isHovered || isDragging ? 1 : 0.5)
            )
            .contentShape(Rectangle())
            // 让 handle 的热点始终在 sortHeader 上方（避免 sortHeader 的 Button 拦截 handle 的 DragGesture）
            .zIndex(1)
            .task {
                // #region debug-point C:resize-handle-mounted
                reportColumnResizeDebug(
                    "C",
                    "resize handle mounted",
                    data: [
                        "column": debugLabel,
                        "width": width,
                        "min": range.lowerBound,
                        "max": range.upperBound,
                        "hitWidth": kColumnDividerWidth
                    ]
                )
                // #endregion
            }
            .onHover { hovering in
                // 拖拽进行中不再响应 hover 抖动；否则 handle 会随着鼠标轻微位移反复进出，
                // 触发不必要的状态刷新和 cursor push/pop，让拖动体感发涩。
                if isDragging { return }
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local) // 阈值 3pt + 局部坐标，
                    .onChanged { value in                               // 防止外层 ScrollView 滚动位移叠加
                        if !isDragging {
                            // 第一次 onChanged 才 snapshot 起点宽度，避免重复赋值
                            isDragging = true
                            onDragStateChange(true)
                            startWidth = width
                            previewWidth = width
                            onPreviewWidthChange(width)
                            // #region debug-point A:first-drag-start
                            reportColumnResizeDebug(
                                "A",
                                "resize handle drag started",
                                data: [
                                    "column": debugLabel,
                                    "startWidth": startWidth
                                ]
                            )
                            // #endregion
                            NSCursor.resizeLeftRight.push()
                        }
                        // Finder 同款的绝对位移模式：目标 = 起始宽度 + 拖拽总位移
                        // 再 clamp 到合法区间：避免列被拉到 0 或无限大。
                        // 这里只更新“预览宽度”，不直接改内容区列宽，这样拖拽中只动一根预览线，
                        // 内容区文字保持静止，不会因为连续重排而闪烁。
                        let target = startWidth + value.translation.width
                        let nextWidth = target.clamped(to: range).rounded()
                        if nextWidth != previewWidth {
                            previewWidth = nextWidth
                            onPreviewWidthChange(nextWidth)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragStateChange(false)
                        isHovered = false
                        width = previewWidth.clamped(to: range).rounded()
                        onPreviewWidthChange(nil)
                        // #region debug-point D:drag-ended
                        reportColumnResizeDebug(
                            "D",
                            "resize handle drag ended",
                            data: [
                                "column": debugLabel,
                                "finalWidth": width
                            ]
                        )
                        // #endregion
                        startWidth = 0
                        previewWidth = width
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
