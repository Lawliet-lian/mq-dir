import AppKit
import SwiftUI

private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

struct MainWindowView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var repoCallout: RepoCalloutController
    @StateObject private var cmux = CmuxSidebarModel()
    @StateObject private var sidebarSplitController = SidebarSplitController()

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

    /// Owning ID of the project this view instance was constructed for.
    /// `mqdirApp` keys this view on `workspace.workspace.activeProjectID`,
    /// so a project switch tears down the old `MainWindowView` (and its
    /// `@StateObject` panes) and instantiates a fresh one — no need to
    /// reload pane state in place.
    private let projectID: UUID

    /// Last persistable state pushed into the workspace, cached so
    /// `scheduleSave()` can early-return when an `objectWillChange` carried
    /// no persistable delta. Every pane VM forwards *every* nested tab's
    /// `@Published` change (selection moves, `isLoading` flips, search
    /// keystrokes, rename-draft edits) — most of which never touch the
    /// serialized snapshot. Without this gate a held arrow key rebuilds and
    /// re-pushes a full 4-pane `WindowState` on every key-repeat. `WindowState`
    /// and `Favorite` are `Equatable`, so the compare is a cheap value-type
    /// walk. `nil` until the first save schedules so the very first mutation
    /// always lands.
    @State private var lastScheduledState: WindowState?
    @State private var lastScheduledFavorites: [Favorite]?

    /// Cached free-space string for the focused pane's volume. `freeSpaceString()`
    /// did a synchronous `volumeAvailableCapacityForImportantUsage` stat on
    /// every status-bar re-render (so a stat on each keystroke, selection
    /// move, hover); that's per-render disk I/O on the main actor. We recompute
    /// only when the focused folder changes (a new folder can sit on a
    /// different volume) and on filesystem-change broadcasts (so a big copy
    /// finishing updates the number). `nil` until the first computation lands.
    @State private var freeSpaceCache: String?
    /// 启动时只给原生 NSSplitView 设置一次初始分割线位置；
    /// 后续保留系统原生拖拽行为，不在每次 SwiftUI 刷新时重置用户手动调整后的宽度。
    @State private var didApplyInitialSidebarWidth = false
    /// 四栏布局下左右分栏的交互模式：
    /// - false = 默认对齐：上下两排共享同一根中线，网格更整齐；
    /// - true  = 独立拖拽：上排和下排各自拥有一根中线，调整更自由。
    ///
    /// 本轮先只做运行时状态，不写入持久化，避免把一次 UI 交互改动扩大到
    /// `WindowState` / `PersistenceService` 的兼容面。
    @State private var fourPaneIndependentSplit = false

    init(
        workspace: WorkspaceManager,
        updateManager: UpdateManager,
        repoCallout: RepoCalloutController
    ) {
        self.workspace = workspace
        self.updateManager = updateManager
        self.repoCallout = repoCallout
        let project = workspace.activeProject
        self.projectID = project.id
        let state = project.state

        self._layout = State(initialValue: state.layout)
        self._focusedPaneIndex = State(
            initialValue: min(max(state.focusedPaneIndex, 0), 3)
        )

        // Always rehydrate four panes — any layout shrink stashes the
        // off-screen pane state so it returns when the layout grows back.
        // Each pane carries its own tab list; the VM forwards every nested
        // tab's objectWillChange so any change in any tab schedules a save.
        let panes = state.panes
        self._pane0 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[0]))
        self._pane1 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[1]))
        self._pane2 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[2]))
        self._pane3 = StateObject(wrappedValue: PaneTabsViewModel(state: panes[3]))

        // Sidebar mirrors the workspace-level Favorites list. Mutations
        // round-trip back through `workspace.setFavorites` (see the save
        // trigger in `SaveTriggers`).
        self._sidebar = StateObject(
            wrappedValue: SidebarViewModel(favorites: workspace.workspace.favorites)
        )
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
            .modifier(EditMenuNotifications(
                focusedPane: focusedPane,
                normalizeHangul: workspace.workspace.settings.normalizeHangulOnDragOut
            ))
            .modifier(EditFileActionsNotifications(
                focusedPane: focusedPane,
                normalizeHangul: workspace.workspace.settings.normalizeHangulOnDragOut
            ))
            .modifier(PaneFocusNotifications(layout: layout, focusedPaneIndex: $focusedPaneIndex))
            .modifier(TabNotifications(focusedPaneVM: focusedPaneVM))
            .modifier(GlobalNotifications(
                allPanes: [pane0, pane1, pane2, pane3],
                saveSynchronously: saveSynchronously
            ))
            .onAppear {
                // Hand the live pane VMs to the cross-pane tab drag
                // coordinator so a drop on a different pane can detach
                // from the source pane and attach here. Re-runs on
                // project switch (this view is keyed on activeProjectID
                // and gets re-instantiated, so the coordinator gets
                // fresh references for the active project).
                TabDragCoordinator.shared.register(panes: [pane0, pane1, pane2, pane3])
                // Once-per-process launch counter for the repo callout
                // gate. The controller guards against re-fires on
                // project switch.
                repoCallout.recordLaunch()
            }
    }

    /// 启动默认宽度优先读取用户在设置页中配置的值；如果用户还没配，
    /// 则回退到 Theme.swift 里的内建默认值。这样既保留了代码默认值，
    /// 也让设置页可以覆盖它，而不会影响运行中用户手动拖拽后的宽度。
    private var configuredSidebarDefaultWidth: CGFloat {
        CGFloat(workspace.workspace.settings.sidebarDefaultWidth ?? Double(Theme.Metrics.sidebarWidth))
    }

    private var windowChrome: some View {
        HSplitView {
            SidebarView(
                viewModel: sidebar,
                workspace: workspace,
                updateManager: updateManager,
                repoCallout: repoCallout,
                cmux: cmux,
                selectedURL: $sidebarSelection,
                // VM-memoized — see `FolderBrowserViewModel.tagSummaries`.
                tagsSummary: focusedPane.tagSummaries,
                onTagSelected: { tag in
                    // Dedicated tag filter: shows only current-folder entries
                    // whose `tagNames` contain this exact name — so a file
                    // tagged "업무" surfaces regardless of its filename, which
                    // the old substring-into-searchQuery hack couldn't do.
                    // Clicking the already-active tag clears the filter
                    // (toggle), matching the sidebar's "click to filter,
                    // click again to clear" affordance.
                    focusedPane.tagFilter = (focusedPane.tagFilter == tag) ? nil : tag
                }
            ) { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                focusedPane.openFolder(url)
            }
            .frame(minWidth: 0, idealWidth: configuredSidebarDefaultWidth, maxWidth: 280)
            .background(
                SidebarInitialWidthBridge(
                    width: configuredSidebarDefaultWidth,
                    hasApplied: $didApplyInitialSidebarWidth,
                    controller: sidebarSplitController
                )
            )

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

    /// Build a snapshot of every persistable bit of window state. Favorites
    /// are excluded — they live on `WorkspaceManager` because they're
    /// shared across all projects.
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
            ]
        )
    }

    /// Push the current snapshot into the workspace's active project.
    /// `WorkspaceManager` owns the debounce window and the disk write —
    /// this view just keeps the in-memory model current after every
    /// observable mutation.
    ///
    /// Gated on a value-equality compare against the last-pushed snapshot:
    /// the pane VMs fan out *every* transient `@Published` change (selection
    /// moves do persist via `selectedURLPaths`, but `isLoading` / `isSearching`
    /// / `searchResults` / `renameDraft` churn does not), so without this most
    /// emissions would rebuild and re-push an identical `WindowState`. The
    /// snapshot itself is still built per emission — that's unavoidable while
    /// the change signal is a bare `objectWillChange` — but the `updateActive`
    /// / `setFavorites` round-trip (which each schedule a 500 ms debounced disk
    /// write) only fires for the half that actually changed.
    @MainActor
    private func scheduleSave() {
        let state = snapshot()
        if state != lastScheduledState {
            workspace.updateActive { $0.state = state }
            lastScheduledState = state
        }
        // Favorites edit through the sidebar VM also feed in here so the
        // workspace's cross-project list stays in sync.
        let favorites = sidebar.favorites
        if favorites != lastScheduledFavorites {
            workspace.setFavorites(favorites)
            lastScheduledFavorites = favorites
        }
    }

    /// On app termination — flush the latest snapshot synchronously so
    /// the runloop teardown can't cancel the debounced disk write.
    @MainActor
    private func saveSynchronously() {
        let state = snapshot()
        workspace.updateActive { $0.state = state }
        workspace.setFavorites(sidebar.favorites)
        workspace.saveSynchronously()
    }

    // MARK: Toolbar (compact, ~38pt)

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Spacer for traffic-light area on the left edge of the window.
            Spacer().frame(width: 0)

            ToolbarIconButton(
                symbol: sidebarSplitController.isCollapsed ? "sidebar.squares.left" : "sidebar.left",
                help: L("mqdir.main.toggleSidebar")
            ) {
                sidebarSplitController.toggleSidebar(defaultWidth: configuredSidebarDefaultWidth)
            }

            ToolbarIconButton(symbol: "chevron.left", help: "Back (⌘[)") { focusedPane.goBack() }
                .disabled(!focusedPane.canGoBack)
            ToolbarIconButton(symbol: "chevron.right", help: "Forward (⌘])") { focusedPane.goForward() }
                .disabled(!focusedPane.canGoForward)
            ToolbarIconButton(symbol: "chevron.up", help: "Parent Folder (⌘↑)") { focusedPane.openParentFolder() }
                .disabled(focusedPane.folderURL == nil)
            ToolbarIconButton(symbol: "arrow.clockwise", help: "Reload (⌘R)") { focusedPane.reload() }
                .disabled(focusedPane.folderURL == nil)

            breadcrumb

            searchField

            // 布局分段控件单独渲染，保持原有风格不变。
            layoutSegmentedControl
                .padding(1.5)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

            // 四栏专用的模式切换按钮：做成独立按钮，和左边分段控件分开，
            // 避免视觉上混在一起。按钮始终保留可见边框，激活时边框高亮，
            // 不会出现“整块填色后图标看不见”的问题。
            if layout == .four {
                fourPaneSplitModeButton
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 12)
        .frame(height: Theme.Metrics.toolbarHeight)
        .background(Theme.Color.toolbarBg)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            if let url = focusedPane.folderURL {
                let components = url.pathComponents.filter { $0 != "/" }
                if components.isEmpty {
                    Text(L("mqdir.main.breadcrumbSep")).font(Theme.Font.breadcrumb).foregroundStyle(Theme.Color.label)
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
                Text(L("mqdir.main.noFolder"))
                    .font(Theme.Font.breadcrumb)
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
            Spacer(minLength: 0)
            breadcrumbCopyButton
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.Color.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedPane.chooseFolder() }
        .contextMenu { breadcrumbContextMenu }
    }

    /// Trailing clipboard glyph that copies the current folder's POSIX
    /// path in one click — Windows File Explorer's "address bar copy"
    /// pattern. Sits inside the breadcrumb pill so it's at hand when
    /// the user is already looking at the path. Right-click on the
    /// pill itself surfaces the longer menu for the open-elsewhere
    /// actions.
    @ViewBuilder
    private var breadcrumbCopyButton: some View {
        Button {
            focusedPane.copyCurrentFolderPath()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.labelTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("mqdir.main.copyPath"))
        .disabled(focusedPane.folderURL == nil)
    }

    @ViewBuilder
    private var breadcrumbContextMenu: some View {
        Button(L("mqdir.main.copyPath")) { focusedPane.copyCurrentFolderPath() }
            .disabled(focusedPane.folderURL == nil)
        Divider()
        // 在终端中打开当前目录
        Button(L("mqdir.breadcrumb.openInTerminal")) { focusedPane.openCurrentFolderInTerminal() }
            .disabled(focusedPane.folderURL == nil)
        if focusedPane.canOpenInCmux {
            // 在 cmux 中打开当前目录（需要 cmux 服务可用）
            Button(L("mqdir.breadcrumb.openInCmux")) { focusedPane.openCurrentFolderInCmux() }
                .disabled(focusedPane.folderURL == nil)
        }
        // 在访达中打开当前目录
        Button(L("mqdir.breadcrumb.openInFinder")) { focusedPane.openCurrentFolderInFinder() }
            .disabled(focusedPane.folderURL == nil)
        Divider()
        // 弹出 NSOpenPanel 让用户选择新文件夹打开
        Button(L("mqdir.breadcrumb.openFolder")) { focusedPane.chooseFolder() }
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
                    TextField(L("mqdir.main.search"), text: queryBinding)
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
                        .help(L("mqdir.main.searchClear"))
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
                        Text(L("mqdir.main.search"))
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
        .help(L("mqdir.main.searchHint"))
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
    }

    /// 四栏专用的分栏模式切换按钮。
    /// 采用独立按钮形态（和左边 layout 分段控件分开），并满足这几个要求：
    /// - 外框尺寸和圆角收窄，和左边分段控件里的单粒按钮保持同一观感（26 × 19）
    /// - 始终有边框描边，点击后是“边框高亮”而不是整块 accent 填色
    /// - 激活态图标直接用白色，保证在蓝色边框前不会灰掉看不见
    private var fourPaneSplitModeButton: some View {
        Button {
            fourPaneIndependentSplit.toggle()
        } label: {
            ZStack {
                // 背景：激活时给一个更明显但仍然很轻的“内部小高亮”，
                // 这样白色图标在深蓝工具栏上对比度更足；
                // 未激活时用几乎透明的底，让按钮依然有存在感但不抢戏。
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(
                        fourPaneIndependentSplit
                            ? Theme.Color.accent.opacity(0.18)
                            : Color.white.opacity(0.04)
                    )
                // 边框永远可见：
                // - 未激活：和其他次级控件一致的浅描边
                // - 激活：更亮更粗的 accent 描边，让“点击后边框高亮”足够明确
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(
                        fourPaneIndependentSplit
                            ? Theme.Color.accent
                            : Theme.Color.separator.opacity(0.75),
                        lineWidth: fourPaneIndependentSplit ? 1.0 : 0.7
                    )

                // 图标：默认态保持原语义符号；激活（独立）态改回最早的
                // 双向箭头方块符号，图形更“实”，不会像细线符号那样在小尺寸下
                // 看起来像没显示。其余尺寸、颜色、边框保持不变。
                Image(systemName: fourPaneIndependentSplit
                      ? "arrow.left.and.right.square.fill"
                      : "rectangle.split.2x2")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        fourPaneIndependentSplit
                            ? Color.white.opacity(0.88)
                            : Theme.Color.labelSecondary
                    )
            }
            .frame(width: 26, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(fourPaneIndependentSplit
                ? "mqdir.main.fourPaneMode.independent"
                : "mqdir.main.fourPaneMode.aligned"))
    }

    // Toolbar nav buttons: a comfortable 30×28 hit target with a subtle
    // hover background so the click area is obvious. Disabled state dims
    // the icon and skips the hover affordance.
    private struct ToolbarIconButton: View {
        let symbol: String
        let help: String
        let action: () -> Void

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.labelSecondary)
                    .opacity(isEnabled ? 1 : 0.35)
                    .frame(width: 30, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isEnabled && isHovering
                                  ? Color.white.opacity(0.08)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help)
        }
    }

    // MARK: Pane grid

    /// 左右可拖拽布局里每一列允许压缩到的最小宽度。这里不追求把
    /// BrowserPaneView 的所有内部控件都“完全无压缩”展示，而是提供
    /// 一个足够稳定的地板值：继续允许用户把列拖窄，同时避免过早塌到
    /// 几乎不可用的状态。若后续实测还想更宽/更窄，只改这一个常量即可。
    private static let resizablePaneMinWidth: CGFloat = 260

    @ViewBuilder
    private var paneGrid: some View {
        switch layout {
        case .one:
            paneView(0)
        case .twoH:
            // 双栏改为原生 HSplitView：这样中线由系统提供，用户可以在
            // 当前运行时直接左右拖拽宽度，不需要我们手写 DragGesture。
            HSplitView {
                resizablePaneItem(0)
                resizablePaneItem(1)
            }
        case .twoV:
            VStack(spacing: 0) {
                paneView(0)
                Divider().background(Theme.Color.separator)
                paneView(1)
            }
        case .four:
            if fourPaneIndependentSplit {
                // 独立模式：上下两排各自拥有一个 HSplitView。优点是灵活，
                // 上下互不干扰；代价是两排中线不再保证垂直对齐。
                VStack(spacing: 0) {
                    HSplitView {
                        resizablePaneItem(0)
                        resizablePaneItem(1)
                    }
                    Divider().background(Theme.Color.separator)
                    HSplitView {
                        resizablePaneItem(2)
                        resizablePaneItem(3)
                    }
                }
            } else {
                // 默认对齐模式：外层一个 HSplitView，把上下两排绑到同一根
                // 中线上，维持规整的 2x2 网格观感。
                HSplitView {
                    paneColumn(top: 0, bottom: 2)
                    paneColumn(top: 1, bottom: 3)
                }
            }
        }
    }

    /// 统一包装左右可拖拽布局中的单个 pane。把最小宽度约束集中在这里，
    /// twoH 与 four 共用一套规则，后续调参时不会漏改。
    private func resizablePaneItem(_ index: Int) -> some View {
        paneView(index)
            .frame(
                minWidth: Self.resizablePaneMinWidth,
                idealWidth: Self.resizablePaneMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
    }

    /// 对齐模式下四栏中的一整列。列内部继续上下均分，但左右由外层共享
    /// split 控制，因此上下两排会共同跟随同一根中线移动。
    private func paneColumn(top: Int, bottom: Int) -> some View {
        VStack(spacing: 0) {
            paneView(top)
            Divider().background(Theme.Color.separator)
            paneView(bottom)
        }
        .frame(
            minWidth: Self.resizablePaneMinWidth,
            idealWidth: Self.resizablePaneMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
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
        // VM-memoized — see `FolderBrowserViewModel.selectedSize`. Avoids the
        // O(selection) compactMap/reduce on every status-bar re-render.
        let selectedSize = focusedPane.selectedSize

        return HStack(spacing: 8) {
            if selectedCount > 0 {
                Text(L("mqdir.main.statusSelected", selectedCount))
                    .foregroundStyle(Theme.Color.label)
                Text(L("mqdir.main.sepDot")).foregroundStyle(Theme.Color.labelTertiary)
                Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                    .foregroundStyle(Theme.Color.labelSecondary)
            } else if focusedPane.isFiltering {
                if focusedPane.isSearching {
                    Text(L("mqdir.main.searching"))
                        .foregroundStyle(Theme.Color.labelSecondary)
                } else {
                    Text(L("mqdir.main.searchMatches", visibleCount, visibleCount == 1 ? "" : L("mqdir.main.searchMatchesPlural")))
                        .foregroundStyle(Theme.Color.labelSecondary)
                }
            } else if totalCount > 0 {
                Text(L("mqdir.main.statusTotalItems", totalCount, totalCount == 1 ? "" : L("mqdir.main.itemsPlural")))
                    .foregroundStyle(Theme.Color.labelSecondary)
            }

            Spacer()

            if focusedPane.includeHidden {
                Text(L("mqdir.main.statusHiddenVisible")).foregroundStyle(Theme.Color.labelSecondary)
                Text(L("mqdir.main.sepDot")).foregroundStyle(Theme.Color.labelTertiary)
            }

            if let free = freeSpaceCache {
                Text(free).foregroundStyle(Theme.Color.labelSecondary)
            }
        }
        .font(Theme.Font.secondary)
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.statusBarHeight)
        .background(Theme.Color.statusBarBg)
        // Refresh the cached free-space number only when the focused folder
        // moves (possibly onto another volume) or the filesystem changes —
        // never per render. `freeSpaceString()` used to stat the volume on
        // every body pass, which is synchronous disk I/O on the main actor.
        .onAppear { refreshFreeSpace() }
        .onChange(of: focusedPane.folderURL) { _, _ in refreshFreeSpace() }
        .onReceive(NotificationCenter.default.publisher(for: .mqdirFileSystemChanged)) { _ in
            refreshFreeSpace()
        }
    }

    /// Recompute the cached free-space string for the focused volume. Cheap
    /// enough to run on the triggering events (folder change, fs change); the
    /// win is *not* running it on every status-bar re-render.
    @MainActor
    private func refreshFreeSpace() {
        let url = focusedPane.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else {
            freeSpaceCache = nil
            return
        }
        freeSpaceCache = "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free"
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

/// 将一个零尺寸 NSView 挂进 SwiftUI 的 HSplitView 树中，等它真正进入
/// AppKit 视图层级后，向上找到宿主 NSSplitView，并只在窗口首次出现时
/// 调一次 `setPosition(_:ofDividerAt:)` 来设置左侧栏的启动默认宽度。
///
/// 这样做的好处：
/// 1. 仍然保留原生 HSplitView / NSSplitView 的拖拽体验；
/// 2. 默认宽度不再依赖 SwiftUI 对 `idealWidth` 的“建议式”采纳；
/// 3. 只执行一次，不会在后续状态刷新时把用户手动拖拽的宽度强行改回去。
private struct SidebarInitialWidthBridge: NSViewRepresentable {
    let width: CGFloat
    @Binding var hasApplied: Bool
    @ObservedObject var controller: SidebarSplitController

    func makeNSView(context: Context) -> SidebarInitialWidthNSView {
        let view = SidebarInitialWidthNSView()
        view.configure(width: width, hasApplied: $hasApplied, controller: controller)
        return view
    }

    func updateNSView(_ nsView: SidebarInitialWidthNSView, context: Context) {
        nsView.configure(width: width, hasApplied: $hasApplied, controller: controller)
        nsView.applyIfNeeded()
    }
}

@MainActor
private final class SidebarSplitController: ObservableObject {
    @Published private(set) var isCollapsed = false

    private weak var splitView: NSSplitView?
    private var resizeObserver: NSObjectProtocol?
    private var lastExpandedWidth: CGFloat?

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    func attach(_ splitView: NSSplitView) {
        let isSameInstance = self.splitView === splitView
        self.splitView = splitView
        if !isSameInstance {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak self] _ in
                self?.refreshState()
            }
        }
        refreshState()
    }

    /// 点击工具栏按钮时收起 / 展开左侧栏。展开优先恢复用户上一次
    /// 的非零宽度；如果还没有历史值，则回退到设置页里的默认宽度。
    func toggleSidebar(defaultWidth: CGFloat) {
        if isCollapsed {
            apply(width: lastExpandedWidth ?? defaultWidth)
        } else {
            apply(width: 0)
        }
    }

    func apply(width: CGFloat) {
        guard let splitView, splitView.subviews.count >= 2 else { return }
        let clampedWidth = min(max(width, 0), 280)
        splitView.setPosition(clampedWidth, ofDividerAt: 0)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
        refreshState()
    }

    func refreshState() {
        guard let splitView, !splitView.subviews.isEmpty else { return }
        let currentWidth = splitView.subviews[0].frame.width
        if currentWidth > 1 {
            lastExpandedWidth = currentWidth
        }
        isCollapsed = currentWidth <= 1
    }
}

private final class SidebarInitialWidthNSView: NSView {
    private var width: CGFloat = Theme.Metrics.sidebarWidth
    private var hasApplied: Binding<Bool>?
    private weak var controller: SidebarSplitController?

    func configure(
        width: CGFloat,
        hasApplied: Binding<Bool>,
        controller: SidebarSplitController
    ) {
        self.width = width
        self.hasApplied = hasApplied
        self.controller = controller
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyIfNeeded()
    }

    /// 需要等到当前 NSView 已经接入真实的 AppKit 层级后，才能找到上层的
    /// NSSplitView。首次没找到时不置位，下一次 `updateNSView` / 生命周期
    /// 回调还会继续尝试；一旦成功执行过一次，就永久停止，避免覆盖用户拖拽。
    func applyIfNeeded() {
        guard hasApplied?.wrappedValue == false else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasApplied?.wrappedValue == false else { return }
            guard let splitView = self.enclosingSplitView(), splitView.subviews.count >= 2 else { return }

            self.controller?.attach(splitView)

            // 与主视图的 `minWidth: 0` 保持一致：设置页里允许把启动默认值
            // 调到 0，桥接这里也必须用同样的范围做夹取，否则会出现
            // “设置里已经是 0，但真正启动时还是被抬到 40” 的不一致。
            let clampedWidth = min(max(self.width, 0), 280)

            self.controller?.apply(width: clampedWidth)

            self.hasApplied?.wrappedValue = true
            self.controller?.refreshState()
        }
    }

    private func enclosingSplitView() -> NSSplitView? {
        var current = superview
        while let view = current {
            if let splitView = view as? NSSplitView {
                return splitView
            }
            current = view.superview
        }
        return nil
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
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCommand)) { note in
                guard let command = AppCommand.from(note) else { return }
                switch command {
                case .openFolder:
                    focusedPane.chooseFolder()
                case .openSelected:
                    focusedPane.openSelected()
                case .revealSelected:
                    focusedPane.revealSelected()
                case .reload:
                    focusedPane.reload()
                case .parentFolder:
                    focusedPane.openParentFolder()
                case .toggleHiddenFiles:
                    focusedPane.toggleHiddenFiles()
                case .goBack:
                    focusedPane.goBack()
                case .goForward:
                    focusedPane.goForward()
                case .focusSearch:
                    searchActive = true
                    // Defer focus until after the conditional TextField has
                    // been installed by the body re-render triggered above.
                    DispatchQueue.main.async { searchFocused.wrappedValue = true }
                case .addCurrentFolderToFavorites:
                    if let url = focusedPane.folderURL {
                        sidebar.add(url: url)
                    }
                case .togglePreview:
                    focusedPane.previewVisible.toggle()
                case .setViewModeList:
                    focusedPane.viewMode = .list
                case .setViewModeTree:
                    focusedPane.viewMode = .tree
                // Edit / tab / pane-focus commands belong to the other
                // modifiers in this chain; ignore them here.
                default:
                    break
                }
            }
    }
}

/// Eagle/Finder-parity file-selection actions (Open with Default App,
/// Duplicate, Copy File Path / Folder Path / Name) — split into its
/// own modifier for the same SwiftUI type-checker reason as
/// `EditMenuNotifications`.
private struct EditFileActionsNotifications: ViewModifier {
    let focusedPane: FolderBrowserViewModel
    /// See `EditMenuNotifications.normalizeHangul` — wired so the ⌘D
    /// duplicate path also normalises the resulting NFD name when on.
    let normalizeHangul: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCommand)) { note in
                guard let command = AppCommand.from(note) else { return }
                switch command {
                case .openWithDefaultApp:
                    focusedPane.openSelectedWithDefaultApp()
                case .duplicate:
                    focusedPane.duplicateSelection(normalizeHangul: normalizeHangul)
                case .copyFilePaths:
                    focusedPane.copySelectedFilePathsToPasteboard()
                case .copyFolderPath:
                    focusedPane.copyCurrentFolderPath()
                case .copyName:
                    focusedPane.copySelectedNamesToPasteboard()
                case .rename:
                    focusedPane.beginRenameForActiveSelection()
                default:
                    break
                }
            }
    }
}

/// Edit-menu file actions (Select All / Copy / Paste / Delete) split
/// out of `NavigationNotifications` because adding more `.onReceive`
/// modifiers in one chain pushes the SwiftUI type-checker over its
/// expression-complexity ceiling. One small modifier per concern keeps
/// every `body` cheap to compile.
private struct EditMenuNotifications: ViewModifier {
    let focusedPane: FolderBrowserViewModel
    /// Live "normalise Hangul on drag out" setting, captured where this
    /// modifier is built (in `MainWindowView.body`, which owns the
    /// workspace) so the ⌘V paste path can normalise pasted-in NFD names.
    let normalizeHangul: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCommand)) { note in
                guard let command = AppCommand.from(note) else { return }
                switch command {
                case .selectAll:
                    focusedPane.selectAll()
                case .copy:
                    focusedPane.copySelectionToPasteboard()
                case .cut:
                    focusedPane.cutSelectionToPasteboard()
                case .paste:
                    focusedPane.pasteFromPasteboard(normalizeHangul: normalizeHangul)
                case .delete:
                    focusedPane.moveSelectionToTrash()
                case .permanentDelete:
                    focusedPane.permanentlyDeleteSelection()
                default:
                    break
                }
            }
    }
}

/// ⌥⌘1–4 → focus pane index 0–3. Indices outside the active layout's
/// pane count are silently ignored so a ⌥⌘4 in single-pane layout is a
/// no-op rather than a hidden focus jump into a stashed pane.
private struct PaneFocusNotifications: ViewModifier {
    let layout: PaneLayout
    @Binding var focusedPaneIndex: Int

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCommand)) { note in
                guard case let .focusPane(index) = AppCommand.from(note) else { return }
                guard index >= 0, index < layout.paneCount else { return }
                focusedPaneIndex = index
            }
    }
}

private struct TabNotifications: ViewModifier {
    @ObservedObject var focusedPaneVM: PaneTabsViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .mqdirCommand)) { note in
                guard let command = AppCommand.from(note) else { return }
                switch command {
                case .newTab:
                    focusedPaneVM.newTab()
                case .closeTab:
                    focusedPaneVM.closeActive()
                case .reopenClosedTab:
                    focusedPaneVM.reopenClosed()
                case .nextTab:
                    focusedPaneVM.nextTab()
                case .previousTab:
                    focusedPaneVM.prevTab()
                case let .selectTab(index):
                    focusedPaneVM.selectTab(at: index)
                // ⌘-click on a folder in tree/list view → new tab pointing at
                // it. Always lands in the *focused* pane so the user gets the
                // detail view next to their tree, not in some other pane.
                case let .openURLInNewTab(url):
                    focusedPaneVM.newTab(folderURL: url)
                default:
                    break
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
    MainWindowView(
        workspace: WorkspaceManager(),
        updateManager: UpdateManager(),
        repoCallout: RepoCalloutController()
    )
        .frame(width: 1100, height: 700)
}
