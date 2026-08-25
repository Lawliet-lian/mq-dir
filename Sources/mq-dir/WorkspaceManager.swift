import Foundation

fileprivate func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

/// App-level owner of the persisted workspace: the project list, which
/// project is active, and the global Favorites surface. `MainWindowView`
/// reads from here, mutates through here, and gets re-instantiated by
/// SwiftUI whenever the active project changes (driven by `.id`).
///
/// Persistence is debounced — every mutation schedules a save 500ms in
/// the future, replacing any in-flight schedule. App termination forces
/// a synchronous flush so the most recent edit survives a clean quit.
@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspace: WorkspaceState

    private let persistence: PersistenceService?
    private var saveDebounceTask: Task<Void, Never>?

    init() {
        // Best-effort persistence — a sandbox/CI env without home-dir
        // write access still gets a working in-memory workspace.
        let service = try? PersistenceService()
        self.persistence = service

        // Load → migrate → seed favorites if needed. WorkspaceState's
        // decoder handles legacy state.json shapes; the seeding pass
        // below populates the six home subdirs the very first time.
        var loaded = service?.loadState() ?? .empty
        if !loaded.favoritesSeeded {
            loaded.favorites = SidebarViewModel.defaultSeed()
            loaded.favoritesSeeded = true
        }
        self.workspace = loaded
    }

    // MARK: Active project

    var activeProject: Project {
        workspace.projects.first(where: { $0.id == workspace.activeProjectID })
            ?? workspace.projects[0]
    }

    /// Capture the running pane state into the active project before
    /// switching. Called by `MainWindowView` right before `.id` flips
    /// and tears down its `@StateObject` panes.
    func updateActive(_ body: (inout Project) -> Void) {
        guard let idx = workspace.projects.firstIndex(where: { $0.id == workspace.activeProjectID })
        else { return }
        mutate { state in
            var project = state.projects[idx]
            body(&project)
            state.projects[idx] = project
        }
    }

    func switchTo(projectID: UUID) {
        guard projectID != workspace.activeProjectID,
              workspace.projects.contains(where: { $0.id == projectID })
        else { return }
        mutate { $0.activeProjectID = projectID }
    }

    // MARK: Project CRUD

    /// Append a new empty project, activate it, and trigger a save.
    /// Naming uses the next free integer so users get a predictable
    /// "Project 2" / "Project 3" sequence without a modal prompt.
    func createProject() {
        let project = Project(name: nextProjectName())
        mutate { state in
            state.projects.append(project)
            state.activeProjectID = project.id
        }
    }

    func rename(_ projectID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = workspace.projects.firstIndex(where: { $0.id == projectID })
        else { return }
        mutate { $0.projects[idx].name = trimmed }
    }

    /// Refuses to delete the last surviving project — the UI hides this
    /// option in that case, but enforcing it here also covers programmatic
    /// callers and external state-file edits.
    func delete(_ projectID: UUID) {
        guard workspace.projects.count > 1,
              let idx = workspace.projects.firstIndex(where: { $0.id == projectID })
        else { return }
        let wasActive = workspace.projects[idx].id == workspace.activeProjectID
        mutate { state in
            state.projects.remove(at: idx)
            if wasActive {
                // Snap to the same slot, or back one if we removed the tail.
                let nextIdx = min(idx, state.projects.count - 1)
                state.activeProjectID = state.projects[nextIdx].id
            }
        }
    }

    func move(sourceID: UUID, before targetID: UUID?) {
        guard let from = workspace.projects.firstIndex(where: { $0.id == sourceID }) else { return }
        let item = workspace.projects[from]

        var copy = workspace.projects
        copy.remove(at: from)

        let insertAt: Int
        if let targetID, let to = copy.firstIndex(where: { $0.id == targetID }) {
            insertAt = to
        } else {
            insertAt = copy.count
        }
        if insertAt == from { return }
        copy.insert(item, at: insertAt)
        mutate { $0.projects = copy }
    }

    // MARK: Favorites passthrough

    func setFavorites(_ favorites: [Favorite]) {
        mutate { $0.favorites = favorites }
    }

    // MARK: Settings passthrough

    /// Update the workspace-level colour scheme preference. Drives
    /// `mqdirApp`'s `.preferredColorScheme` binding so the change
    /// takes effect immediately, with the standard 500 ms debounced
    /// save persisting across launches.
    func setColorScheme(_ option: ColorSchemeOption) {
        guard workspace.settings.colorScheme != option else { return }
        mutate { $0.settings.colorScheme = option }
    }

    /// Toggle the "normalise Hangul filenames to NFC on drag out"
    /// preference. Read at drag-start (and at copy/move/duplicate time)
    /// off `workspace.settings.normalizeHangulOnDragOut`; the standard
    /// 500 ms debounced save persists it across launches.
    func setNormalizeHangulOnDragOut(_ enabled: Bool) {
        guard workspace.settings.normalizeHangulOnDragOut != enabled else { return }
        mutate { $0.settings.normalizeHangulOnDragOut = enabled }
    }

    /// Update the workspace-level language preference. Overrides the
    /// `AppleLanguages` UserDefaults key so the change takes effect
    /// immediately (paired with a MainWindowView re-instantiation via
    /// `.id`), with the standard 500 ms debounced save persisting
    /// across launches.
    func setLanguage(_ option: LanguageOption) {
        guard workspace.settings.language != option else { return }
        mutate { $0.settings.language = option }
        // 同步写入 UserDefaults 使 NSLocalizedString 立即生效
        if let locale = option.localeIdentifier {
            UserDefaults.standard.set([locale], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    /// Persist a user override for the given action. Passing `nil`
    /// for `binding` removes the override so the action falls back
    /// to its default. Settings → Shortcuts uses this for both Edit
    /// and Reset.
    func setShortcutBinding(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        // A user override that happens to equal the default is
        // indistinguishable from "no override" everywhere except
        // the Settings UI's reset arrow, where it would otherwise
        // suggest the action is customised when it isn't. Collapse
        // to nil so the override dictionary stays minimal.
        let normalised: ShortcutBinding?
        if let binding, binding == action.defaultBinding {
            normalised = nil
        } else {
            normalised = binding
        }
        if let normalised {
            guard workspace.settings.shortcutOverrides[action] != normalised else { return }
            mutate { $0.settings.shortcutOverrides[action] = normalised }
        } else {
            guard workspace.settings.shortcutOverrides[action] != nil else { return }
            mutate { $0.settings.shortcutOverrides.removeValue(forKey: action) }
        }
    }

    /// Drop every user override so all 10 customisable shortcuts
    /// snap back to their defaults at once. Wired to the Settings
    /// "Restore Defaults" button.
    func resetAllShortcutOverrides() {
        guard !workspace.settings.shortcutOverrides.isEmpty else { return }
        mutate { $0.settings.shortcutOverrides.removeAll() }
    }

    // MARK: Persistence

    /// Single mutation entry point: apply `body` to the live workspace and
    /// schedule a debounced save in one place so "mutate then schedule" can't
    /// drift apart across the individual mutators. Every state-changing method
    /// routes through here.
    private func mutate(_ body: (inout WorkspaceState) -> Void) {
        body(&workspace)
        scheduleSave()
    }

    private func scheduleSave() {
        guard let persistence else { return }
        saveDebounceTask?.cancel()
        // Capture only `persistence` by value; read `self.workspace` fresh
        // inside the @MainActor body after the sleep so the persisted snapshot
        // reflects any mutation that landed during the 500ms debounce window
        // rather than the by-value snapshot taken at schedule time.
        saveDebounceTask = Task { @MainActor [persistence] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await Self.persist(self.workspace, using: persistence)
        }
    }

    /// Synchronous flush, used on app termination where the runloop
    /// teardown would cancel any pending debounced task.
    func saveSynchronously() {
        guard let persistence else { return }
        saveDebounceTask?.cancel()
        try? persistence.saveState(workspace)
    }

    nonisolated private static func persist(
        _ state: WorkspaceState,
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

    // MARK: Helpers

    /// "Project N" where N is the smallest positive integer not already
    /// used as an exact name. Avoids "Project 1, Project 2, Project 1" if
    /// the user renamed an old slot back to "Project 1".
    private func nextProjectName() -> String {
        let existing = Set(workspace.projects.map(\.name))
        var n = workspace.projects.count + 1
        while existing.contains(L("mqdir.project.nextName", n)) { n += 1 }
        return L("mqdir.project.nextName", n)
    }
}
