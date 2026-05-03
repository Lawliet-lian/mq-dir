import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var cmux: CmuxSidebarModel
    @Binding var selectedURL: URL?
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    favoritesSection
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
            // Bottom-left update affordance — only renders when Sparkle's
            // background check has surfaced an available update.
            if updateManager.updateAvailable {
                updateAvailableButton
            }
        }
        .background(Theme.Color.sidebarBg)
    }

    /// Tinted bar that lives at the bottom of the sidebar when an update
    /// is waiting. Click → Sparkle's standard "install update" dialog.
    private var updateAvailableButton: some View {
        Button {
            updateManager.checkForUpdatesAndShowUI()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.accent)
                Text("Update Available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.accent.opacity(0.12))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Color.separator).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .help("Install the available update")
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Favorites")

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
        Text("Drag folders here to add")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Color.labelTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .help(isStale ? (favorite.fallbackPath ?? "Folder unavailable") : (resolved?.path ?? favorite.label))
        .onTapGesture {
            guard !isEditing else { return }
            if let url = resolved {
                selectedURL = url
                onSelect(url)
            }
        }
        .contextMenu {
            Button("Rename") { startRename(favorite) }
                .disabled(isStale)
            Button("Remove from Sidebar", role: .destructive) {
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
                Text("PROJECTS")
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
                .help("New Project")
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
            Button("Rename") { startProjectRename(project) }
            Button("Delete", role: .destructive) {
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
                Text("CMUX")
                    .font(Theme.Font.sidebarHeader)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Color.labelTertiary)
                Spacer(minLength: 0)
                Button {
                    Task { await cmux.sync() }
                } label: {
                    Image(systemName: cmux.isSyncing
                          ? "arrow.triangle.2.circlepath"
                          : "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Color.labelSecondary)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cmux.isSyncing)
                .help("Sync cmux workspaces")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if cmux.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cmux.lastError ?? "Press ⟳ to sync cmux workspaces")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.labelTertiary)
                    if cmux.lastSyncDate == nil && cmux.lastError == nil {
                        // First-run prerequisite hint — easy to miss otherwise,
                        // because cmux ships with the restrictive socket mode.
                        Text("Requires cmux → Settings → Automation → Socket Control Mode = Allow All.")
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

    private func cmuxRow(_ ws: CmuxWorkspace) -> some View {
        let cwd = ws.currentDirectory.flatMap { URL(fileURLWithPath: $0) }
        let isActive = cwd != nil && selectedURL == cwd

        return Button {
            guard let url = cwd else { return }
            // ⌘-click → open in a new tab in the focused pane (matches
            // the Finder convention used by tree-view ⌘-click).
            // Plain click → swap the focused pane's active tab to it.
            if NSEvent.modifierFlags.contains(.command) {
                NotificationCenter.default.post(
                    name: .mqdirOpenURLInNewTabRequested,
                    object: nil,
                    userInfo: ["url": url]
                )
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
        .help(ws.currentDirectory ?? "no working directory")
    }

    // MARK: Section chrome

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            content()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
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

    /// Routes incoming drops. Plain-text payloads are treated as a favorite
    /// reorder (the dragged row's UUID); file URLs are treated as a new
    /// favorite to add at the given insertion point.
    private func handleDrop(providers: [NSItemProvider], before targetID: Favorite.ID?) {
        // Try internal reorder first — if any provider has plain text,
        // assume it's our UUID payload and skip the file-URL path.
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let str = obj as? String,
                      let uuid = UUID(uuidString: str)
                else { return }
                Task { @MainActor in
                    viewModel.move(sourceID: uuid, before: targetID)
                }
            }
            return
        }

        // External folder drop → resolve URLs and append (or insert before
        // `targetID` once added; we always append here for simplicity, then
        // reorder so the newest entry lands at the requested slot).
        Task {
            let urls = await DragDropSupport.resolveURLs(from: providers)
            await MainActor.run {
                for url in urls {
                    viewModel.add(url: url)
                    if let targetID,
                       let newest = viewModel.favorites.last,
                       newest.id != targetID
                    {
                        viewModel.move(sourceID: newest.id, before: targetID)
                    }
                }
            }
        }
    }
}

// MARK: Project reorder

/// Project equivalent of the favorite reorder delegate. Reordering happens
/// on `dropEntered` (not `performDrop`) so the user sees the row swap as
/// soon as the cursor crosses a sibling, mirroring Safari's tab strip
/// instead of waiting until mouse-up.
private struct ProjectReorderDropDelegate: DropDelegate {
    let target: UUID
    @ObservedObject var workspace: WorkspaceManager
    @Binding var draggingID: UUID?
    @Binding var highlightID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target else { return }
        highlightID = target
        // Insert AFTER the target if dragging from earlier in the list,
        // BEFORE if dragging from later — same convention as favorites.
        let projects = workspace.workspace.projects
        guard let from = projects.firstIndex(where: { $0.id == dragging }),
              let to = projects.firstIndex(where: { $0.id == target })
        else { return }
        let beforeID: UUID? = from < to
            ? (to + 1 < projects.count ? projects[to + 1].id : nil)
            : projects[to].id
        workspace.move(sourceID: dragging, before: beforeID)
    }

    func dropExited(info: DropInfo) {
        if highlightID == target { highlightID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        highlightID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
