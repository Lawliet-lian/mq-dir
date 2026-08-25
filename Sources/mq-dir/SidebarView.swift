import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var repoCallout: RepoCalloutController
    @ObservedObject var cmux: CmuxSidebarModel
    @Binding var selectedURL: URL?
    /// Distinct Finder tags observed in the focused tab's current
    /// listing. Empty when the focused folder has no tagged items.
    /// MainWindowView recomputes this on every focused-tab change so
    /// the sidebar always mirrors what's visible in the active pane.
    let tagsSummary: [TagSummary]
    /// Tap handler for a sidebar tag row. The owning view typically
    /// pushes the name into the focused tab's `searchQuery` so the
    /// list filters down to matching items.
    let onTagSelected: (String) -> Void
    let onSelect: (URL) -> Void

    /// Custom drag-payload identifier for project rows. Distinct from the
    /// favorite reorder type so dragging a project onto a favorite (or
    /// vice versa) is silently ignored instead of firing the wrong move.
    static let projectDragType = "com.mqdir.project.uuid"

    /// Whichever favorite is currently being inline-renamed. Cleared on
    /// commit (Enter) or cancel (Esc / focus loss with empty input).
    @State private var editingFavoriteID: Favorite.ID?
    /// Working draft for the rename TextField. Mirrored to a focus
    /// state so we can autoselect on entry.
    @State private var editingFavoriteDraft: String = ""
    @FocusState private var renameFavoriteFocused: Favorite.ID?

    /// Same idea for the Projects section, kept on a separate state slot
    /// so editing a project name doesn't leak into a favorite editor.
    @State private var editingProjectID: UUID?
    @State private var editingProjectDraft: String = ""
    @FocusState private var renameProjectFocused: UUID?

    /// Drop highlights for favorites — section vs row, mutually exclusive.
    @State private var favSectionDropTargeted = false
    @State private var favRowDropTargetedID: Favorite.ID?
    /// Drop highlight for project reorder.
    @State private var projectRowDropTargetedID: UUID?
    /// Project being dragged for reorder.
    @State private var draggingProjectID: UUID?

    @State private var showingFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    favoritesSection
                        .padding(.bottom, 8)

                    tagsSection
                        .padding(.bottom, 8)

                    projectsSection

                    if cmux.cmuxAvailable {
                        cmuxSection
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            sidebarFooter
        }
        .background(Theme.Color.sidebarBg)
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet(repoCallout: repoCallout)
        }
    }

    /// Bottom row: a help menu (always visible) and an update pill that
    /// only appears when Sparkle's background check has flagged a new
    /// version. The pill is loud on purpose — the previous flat bar was
    /// quiet enough that users missed available updates.
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            helpMenu
            if updateManager.updateAvailable {
                updatePill
            }
            if repoCallout.shouldShowPill {
                repoPill
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Color.separator).frame(height: 0.5)
        }
    }

    private var helpMenu: some View {
        Menu {
            // 欢迎页链接：打开产品官网
            Button(L("mqdir.sidebar.help.welcome")) { openURL("https://mqdir.com") }
            // 反馈表单入口：打开内置的 FeedbackSheet
            Button(L("mqdir.sidebar.feedback")) { showingFeedback = true }
            // GitHub 仓库：鼓励用户为项目 Star
            Button(L("mqdir.sidebar.starGithub")) {
                repoCallout.openRepo()
            }
            Divider()
            // 手动检查更新：走 Sparkle 的 UI 入口
            Button(L("mqdir.sidebar.checkUpdates")) {
                updateManager.checkForUpdatesAndShowUI()
            }
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Color.label.opacity(0.55))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("mqdir.sidebar.help"))
    }

    private var updatePill: some View {
        Button {
            updateManager.checkForUpdatesAndShowUI()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(pillLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.Color.accent)
            )
        }
        .buttonStyle(.plain)
        .help(L("mqdir.sidebar.installUpdate"))
    }

    // 更新提示 Pill 的文字：有版本号时显示具体版本
    private var pillLabel: String {
        if let version = updateManager.availableVersion {
            return L("mqdir.sidebar.updateAvailableVersion", version)
        }
        return L("mqdir.sidebar.updateAvailable")
    }

    /// Repo callout. Mirrors `updatePill`'s capsule style with a yellow
    /// tint so the two pills read as a related but distinct "quiet CTA"
    /// family. Right-click is the explicit anti-nag escape hatch —
    /// once dismissed, never returns.
    private var repoPill: some View {
        Button {
            repoCallout.openRepo()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("mqdir.sidebar.starProject"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.yellow)
            )
        }
        .buttonStyle(.plain)
        .help(L("mqdir.sidebar.githubHint"))
        .contextMenu {
            // 永久隐藏 Star 提示胶囊
            Button(L("mqdir.sidebar.dismissPill")) {
                repoCallout.dismissPermanently()
            }
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 使用本地化的 section key，交由 sectionHeader() 统一渲染（含大写转换等）
            sectionHeader(L("mqdir.sidebar.section.favorites"))

            if viewModel.favorites.isEmpty {
                emptyFavoritesHint
            } else {
                ForEach(viewModel.favorites) { favorite in
                    favoriteRow(favorite)
                }
            }
        }
        // Whole-section drop zone so users can drop a folder anywhere in
        // the Favorites area (not just on an existing row) to append.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(favSectionDropTargeted ? Theme.Color.accent.opacity(0.10) : .clear)
                .padding(.horizontal, 6)
        )
        .onDrop(
            of: DragDropSupport.acceptedDropTypes,
            isTargeted: $favSectionDropTargeted
        ) { providers in
            handleDrop(providers: providers, before: nil)
            return true
        }
    }

    private var emptyFavoritesHint: some View {
        Text(L("mqdir.sidebar.dropHere"))
            .font(.system(size: 10))
            .foregroundStyle(Theme.Color.labelTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tags (read-only view of Finder tags in the focused tab)

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 使用本地化 section key（中文下直接显示「标签」，英文下 sectionHeader 会转大写）
            sectionHeader(L("mqdir.sidebar.section.tags"))
            if tagsSummary.isEmpty {
                Text(L("mqdir.sidebar.tags.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.labelTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(tagsSummary) { summary in
                    tagRow(summary)
                }
            }
        }
    }

    private func tagRow(_ summary: TagSummary) -> some View {
        Button {
            onTagSelected(summary.name)
        } label: {
            HStack(spacing: 8) {
                if let color = TagColor.color(forLabel: summary.labelNumber) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .strokeBorder(Theme.Color.labelTertiary, lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
                Text(summary.name)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("mqdir.sidebar.tags.filterHint", summary.name))
    }

    @ViewBuilder
    private func favoriteRow(_ favorite: Favorite) -> some View {
        let resolved = viewModel.resolveURL(favorite)
        let isActive = resolved != nil && selectedURL == resolved
        let isStale = resolved == nil
        let isEditing = editingFavoriteID == favorite.id
        let isDropTarget = favRowDropTargetedID == favorite.id

        let row = HStack(spacing: 6) {
            iconView(for: resolved)
                .frame(width: 14)
                .opacity(isStale ? 0.4 : 1)
            if isEditing {
                TextField("", text: $editingFavoriteDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Color.label)
                    .focused($renameFavoriteFocused, equals: favorite.id)
                    .onSubmit { commitRename(favorite.id) }
                    .onKeyPress(.escape) {
                        cancelRename()
                        return .handled
                    }
            } else {
                Text(favorite.label)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(isStale ? Theme.Color.labelTertiary : Theme.Color.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, isActive ? 10 : 14)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(rowBackground(isActive: isActive, isDropTarget: isDropTarget))
        .overlay(alignment: .top) {
            // Insertion indicator when reordering / dropping a folder
            // before this row. The bar visually replaces the section
            // highlight while a row-level drop is active.
            if isDropTarget {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .help(isStale ? (favorite.fallbackPath ?? L("mqdir.sidebar.folderUnavailable")) : (resolved?.path ?? favorite.label))
        .onTapGesture {
            guard !isEditing else { return }
            if let url = resolved {
                selectedURL = url
                onSelect(url)
            }
        }
        .contextMenu {
            // 重命名收藏夹条目：开始内联编辑
            Button(L("mqdir.sidebar.rename")) { startRename(favorite) }
                .disabled(isStale)
            // 从侧边栏移除该收藏夹
            Button(L("mqdir.sidebar.removeFavorite"), role: .destructive) {
                viewModel.remove(favorite.id)
            }
        }

        // Row is both a drag SOURCE (reorder) and a drop TARGET (reorder
        // OR external folder add at this insertion point).
        row
            .onDrag {
                NSItemProvider(
                    object: favorite.id.uuidString as NSString
                )
            }
            .onDrop(
                of: DragDropSupport.acceptedDropTypes + [UTType.plainText.identifier],
                isTargeted: Binding(
                    get: { favRowDropTargetedID == favorite.id },
                    set: { favRowDropTargetedID = $0 ? favorite.id : nil }
                )
            ) { providers in
                handleDrop(providers: providers, before: favorite.id)
                return true
            }
    }

    private func iconView(for url: URL?) -> some View {
        Group {
            if let url {
                // NSWorkspace returns the actual Finder icon (custom icon,
                // tag color, sync overlay). Falls back to the generic
                // folder symbol when something goes wrong.
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
        }
    }

    private func rowBackground(isActive: Bool, isDropTarget: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isActive ? Color.white.opacity(0.06) : Color.clear)
            .padding(.horizontal, isActive ? 6 : 0)
    }

    // MARK: Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(L("mqdir.sidebar.section.projects"))
                    .font(Theme.Font.sidebarHeader)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Color.labelTertiary)
                Spacer(minLength: 0)
                Button {
                    workspace.createProject()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Color.labelSecondary)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("mqdir.sidebar.project.new"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ForEach(workspace.workspace.projects) { project in
                projectRow(project)
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        let isActive = workspace.workspace.activeProjectID == project.id
        let isEditing = editingProjectID == project.id
        let isDropTarget = projectRowDropTargetedID == project.id
        let isOnlyProject = workspace.workspace.projects.count == 1

        let row = HStack(spacing: 6) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Theme.Color.accent.opacity(0.85) : Color(white: 0.55))
                .frame(width: 14)
            if isEditing {
                TextField("", text: $editingProjectDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Color.label)
                    .focused($renameProjectFocused, equals: project.id)
                    .onSubmit { commitProjectRename(project.id) }
                    .onKeyPress(.escape) {
                        cancelProjectRename()
                        return .handled
                    }
            } else {
                Text(project.name)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(isActive ? Theme.Color.label : Theme.Color.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, isActive ? 10 : 14)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.white.opacity(0.06) : Color.clear)
                .padding(.horizontal, isActive ? 6 : 0)
        )
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            workspace.switchTo(projectID: project.id)
        }
        .contextMenu {
            // 重命名项目：开始内联编辑
            Button(L("mqdir.sidebar.rename")) { startProjectRename(project) }
            // 删除项目（最后一个项目禁用，因为 App 需要至少一个项目作为容器）
            Button(L("mqdir.sidebar.deleteProject"), role: .destructive) {
                workspace.delete(project.id)
            }
            // Last-project guard. The manager refuses too, but disabling
            // the menu item makes the intent visible up-front.
            .disabled(isOnlyProject)
        }

        row
            .onDrag {
                draggingProjectID = project.id
                return makeProjectDragProvider(project.id)
            }
            .onDrop(
                of: [Self.projectDragType],
                delegate: ProjectReorderDropDelegate(
                    target: project.id,
                    workspace: workspace,
                    draggingID: $draggingProjectID,
                    highlightID: $projectRowDropTargetedID
                )
            )
    }

    /// Build an item provider whose payload is the project UUID under
    /// our private type identifier. Using a custom type (instead of plain
    /// text) keeps a project drag from accidentally triggering the
    /// favorite-reorder drop target during a sloppy mouse path.
    private func makeProjectDragProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.projectDragType,
            visibility: .ownProcess
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    // MARK: cmux

    private var cmuxSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(L("mqdir.sidebar.section.cmux"))
                    .font(Theme.Font.sidebarHeader)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Color.labelTertiary)
                Spacer(minLength: 0)
                cmuxSyncChip
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if cmux.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cmuxEmptyStateMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.labelTertiary)
                    if cmux.lastSyncDate == nil && cmux.lastError == nil {
                        // Sidebar real estate is tight — give the one
                        // recipe most users will pick and link to the
                        // README for the password-mode alternative.
                        Text(L("mqdir.sidebar.cmux.hint"))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.labelTertiary)
                            .opacity(0.75)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(cmux.workspaces) { ws in
                    cmuxRow(ws)
                }
            }
        }
    }

    /// Pill-shaped Sync button. Higher hit-target + label than the bare
    /// refresh icon — easier to find for someone who's never used the
    /// integration before. Swaps to "Syncing…" with a spinner while a
    /// fetch is in flight, and disables to prevent double-taps.
    private var cmuxSyncChip: some View {
        Button {
            Task { await cmux.sync() }
        } label: {
            HStack(spacing: 4) {
                if cmux.isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                }
                // 同步按钮文案：同步中显示"Syncing…"，否则"Sync"
                Text(cmux.isSyncing
                     ? L("mqdir.sidebar.cmux.syncing")
                     : L("mqdir.sidebar.cmux.syncAction"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.Color.label)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.white.opacity(cmux.isSyncing ? 0.04 : 0.10))
            )
            .overlay(
                Capsule().strokeBorder(Theme.Color.separator, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(cmux.isSyncing)
        .help(L("mqdir.sidebar.cmux.sync"))
    }

    /// Picks the right one-liner for an empty workspaces list. Three
    /// distinct states the previous version collapsed to one message:
    /// (1) sync errored, (2) sync ran but cmux genuinely has no
    /// workspaces, (3) we haven't synced yet.
    // cmux 空状态文案：三态（有错误 / 已同步但空 / 尚未同步）
    private var cmuxEmptyStateMessage: String {
        if let err = cmux.lastError { return err }
        if cmux.lastSyncDate != nil { return L("mqdir.sidebar.cmux.noWorkspaces") }
        return L("mqdir.sidebar.cmux.pressSync")
    }

    private func cmuxRow(_ ws: CmuxWorkspace) -> some View {
        let cwd = ws.currentDirectory.flatMap { URL(fileURLWithPath: $0) }
        let isActive = cwd != nil && selectedURL == cwd

        return Button {
            guard let url = cwd else { return }
            // ⌘-click → open in a new tab in the focused pane (matches
            // the Finder convention used by tree-view ⌘-click).
            // Plain click → swap the focused pane's active tab to it.
            if NSEvent.modifierFlags.contains(.command) {
                AppCommand.openURLInNewTab(url: url).post()
            } else {
                selectedURL = url
                onSelect(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: ws.selected ? "play.circle.fill" : "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(ws.selected
                                     ? Theme.Color.accent.opacity(0.85)
                                     : Color(white: 0.55))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ws.title)
                        .font(Theme.Font.sidebarItem)
                        .foregroundStyle(Theme.Color.label)
                        .lineLimit(1)
                    if let cwd {
                        Text(cwd.lastPathComponent)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Color.labelTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, isActive ? 10 : 14)
            .padding(.trailing, 8)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.white.opacity(0.06) : Color.clear)
                    .padding(.horizontal, isActive ? 6 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(cwd == nil)
        // cwd 为 nil 时提供兜底的本地化帮助文本
        .help(ws.currentDirectory ?? L("mqdir.sidebar.cmux.noWorkingDir"))
    }

    // MARK: Section chrome

    // 自定义 section header 渲染：仅 ASCII 字符强制大写。
    // 理由：英文惯例 FAVORITES / TAGS 用大写全角分隔效果，但中文没有大小写，强行 uppercased()
    // 会导致某些非拉丁语系在 Foundation 下的大小写转换出现意料外行为，故仅对 ASCII 大写。
    // 注意：由于函数体有 >1 条语句（let + if/else），Swift 不再走"单表达式隐式 return"，
    // 所以 Text(...).modifiers 链必须显式 return，否则会报 opaque type 无法推断 + padding unused。
    private func sectionHeader(_ title: String) -> some View {
        let transformed: String
        if title.allSatisfy(\.isASCII) {
            transformed = title.uppercased()
        } else {
            transformed = title
        }
        return Text(transformed)
            .font(Theme.Font.sidebarHeader)
            .tracking(0.5)
            .foregroundStyle(Theme.Color.labelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    // MARK: Rename flow

    private func startRename(_ favorite: Favorite) {
        editingFavoriteID = favorite.id
        editingFavoriteDraft = favorite.label
        DispatchQueue.main.async { renameFavoriteFocused = favorite.id }
    }

    private func commitRename(_ id: Favorite.ID) {
        viewModel.rename(id, to: editingFavoriteDraft)
        cancelRename()
    }

    private func cancelRename() {
        editingFavoriteID = nil
        editingFavoriteDraft = ""
        renameFavoriteFocused = nil
    }

    private func startProjectRename(_ project: Project) {
        editingProjectID = project.id
        editingProjectDraft = project.name
        DispatchQueue.main.async { renameProjectFocused = project.id }
    }

    private func commitProjectRename(_ id: UUID) {
        workspace.rename(id, to: editingProjectDraft)
        cancelProjectRename()
    }

    private func cancelProjectRename() {
        editingProjectID = nil
        editingProjectDraft = ""
        renameProjectFocused = nil
    }

    // MARK: Drop dispatch

    /// Routes incoming drops. Resolves URLs first so tab drags (which
    /// carry both a `.ownProcess` plain-text id *and* a file-URL) land
    /// on the add-favorite path; the UUID-string fallback only fires
    /// when no URL is present, which keeps favorite-row reorder
    /// working. The previous order checked plain-text first and would
    /// silently swallow tab drops because `UUID(uuidString:)` rejected
    /// the `ObjectIdentifier(0x…)` literal.
    private func handleDrop(providers: [NSItemProvider], before targetID: Favorite.ID?) {
        Task {
            let urls = await DragDropSupport.resolveURLs(from: providers)
            if !urls.isEmpty {
                await MainActor.run {
                    // Add each dropped URL, capturing the ID of every
                    // favorite that's genuinely new (`add` no-ops on
                    // files/dupes, so we diff against the prior set
                    // rather than assuming `favorites.last` is ours).
                    var addedIDs: [Favorite.ID] = []
                    for url in urls {
                        let before = Set(viewModel.favorites.map(\.id))
                        viewModel.add(url: url)
                        if let new = viewModel.favorites.first(where: { !before.contains($0.id) }) {
                            addedIDs.append(new.id)
                        }
                    }
                    // Move the whole batch as a contiguous block before
                    // the target, preserving drop order — dropping 3
                    // folders lands all 3 at the drop point, not just
                    // the last. Moving in forward order works because
                    // each `move(before: targetID)` inserts immediately
                    // before the target, after the previously-moved
                    // item, so the block ends up as [first … last] right
                    // before the target row.
                    if let targetID {
                        for id in addedIDs where id != targetID {
                            viewModel.move(sourceID: id, before: targetID)
                        }
                    }
                    // No-op when the drop didn't originate from a tab;
                    // when it did, clearing here flips
                    // `BrowserPaneView`'s opacity overlay back on so
                    // the source tab stops looking disabled.
                    TabDragCoordinator.shared.clear()
                }
                return
            }
            // No URLs — fall back to favorite reorder via UUID payload.
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
                provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let str = obj as? String,
                          let uuid = UUID(uuidString: str)
                    else { return }
                    Task { @MainActor in
                        viewModel.move(sourceID: uuid, before: targetID)
                    }
                }
            }
        }
    }
}

// MARK: Project reorder

/// Project equivalent of the tab reorder delegate. Hovering a sibling row
/// only previews the landing spot (the blue insertion bar driven by
/// `highlightID`); the actual `workspace.move` runs ONCE in `performDrop`.
///
/// The previous version mutated the model in `dropEntered` on every
/// hover-cross, which armed a debounced save per crossing and — when the
/// *active* project moved — re-keyed `MainWindowView` mid-drag (the app
/// keys the window on `activeProjectID`). Deferring the commit to mouse-up
/// mirrors `TabReorderDropDelegate` and keeps the drag visually stable.
private struct ProjectReorderDropDelegate: DropDelegate {
    let target: UUID
    @ObservedObject var workspace: WorkspaceManager
    @Binding var draggingID: UUID?
    @Binding var highlightID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target else { return }
        // Preview only — show where the row will land, don't move it yet.
        highlightID = target
    }

    func dropExited(info: DropInfo) {
        if highlightID == target { highlightID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            highlightID = nil
        }
        guard let dragging = draggingID, dragging != target else { return false }
        // Insert AFTER the target if dragging from earlier in the list,
        // BEFORE if dragging from later — same convention as favorites.
        let projects = workspace.workspace.projects
        guard let from = projects.firstIndex(where: { $0.id == dragging }),
              let to = projects.firstIndex(where: { $0.id == target })
        else { return false }
        let beforeID: UUID? = from < to
            ? (to + 1 < projects.count ? projects[to + 1].id : nil)
            : projects[to].id
        workspace.move(sourceID: dragging, before: beforeID)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
