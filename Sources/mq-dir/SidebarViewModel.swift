import AppKit
import Foundation

// 文件级本地化辅助函数：默认收藏夹标签需要随系统语言本地化。
private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

/// Owns the sidebar's user-editable Favorites list. The Locations section
/// remains hardcoded and lives in `SidebarView` itself.
///
/// State change is announced via the standard `ObservableObject` channel so
/// `MainWindowView` can pick it up with `.onReceive(_.objectWillChange)` and
/// fold it into the same debounced save it already runs for the panes.
@MainActor
final class SidebarViewModel: ObservableObject {
    @Published var favorites: [Favorite]

    init(favorites: [Favorite]) {
        self.favorites = favorites
    }

    // MARK: Mutations

    /// Append a folder. No-ops on files, missing paths, and exact duplicates
    /// (same canonical resolved path) so the user can drag the same folder
    /// twice without polluting the list.
    func add(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return }

        if favorites.contains(where: { resolveURL($0)?.standardizedFileURL == url.standardizedFileURL }) {
            return
        }

        let bookmark = try? PersistenceService.makeBookmark(for: url)
        favorites.append(Favorite(
            label: url.lastPathComponent,
            bookmark: bookmark,
            fallbackPath: url.path
        ))
    }

    func remove(_ id: Favorite.ID) {
        favorites.removeAll { $0.id == id }
    }

    /// Trims and ignores empty rename attempts so the row never shows a
    /// blank label after the user clears the field and presses Enter.
    func rename(_ id: Favorite.ID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].label = trimmed
    }

    /// Move `sourceID` so that it lands immediately before `targetID`.
    /// Pass `targetID == nil` to move to the end of the list. No-ops when
    /// the source is missing or when the move would be a no-op.
    func move(sourceID: Favorite.ID, before targetID: Favorite.ID?) {
        guard let from = favorites.firstIndex(where: { $0.id == sourceID }) else { return }
        let item = favorites[from]

        var copy = favorites
        copy.remove(at: from)

        let insertAt: Int
        if let targetID, let to = copy.firstIndex(where: { $0.id == targetID }) {
            insertAt = to
        } else {
            insertAt = copy.count
        }

        if insertAt == from { return }
        copy.insert(item, at: insertAt)
        favorites = copy
    }

    // MARK: Resolution

    /// Resolves the favorite's bookmark back to a usable URL. Returns nil
    /// for stale/missing entries — the sidebar uses that to render the row
    /// in a disabled style.
    func resolveURL(_ favorite: Favorite) -> URL? {
        if let data = favorite.bookmark,
           let url = PersistenceService.resolveBookmark(data),
           FileManager.default.fileExists(atPath: url.path)
        {
            return url
        }
        if let path = favorite.fallbackPath,
           FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Seeding

    /// Build the default seed (the previously-hardcoded six home dirs).
    /// Folders that don't exist on this machine are simply skipped.
    static func defaultSeed() -> [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 系统目录候选：(显示标签 key, 路径组件)
        // 标签使用本地化 key，中文下显示"桌面/文稿/下载…"，英文下保留原名。
        let candidates: [(labelKey: String, component: String)] = [
            ("mqdir.favorites.desktop",   "Desktop"),
            ("mqdir.favorites.documents", "Documents"),
            ("mqdir.favorites.downloads", "Downloads"),
            ("mqdir.favorites.pictures",  "Pictures"),
            ("mqdir.favorites.movies",    "Movies"),
            ("mqdir.favorites.music",     "Music"),
        ]

        return candidates.compactMap { entry in
            let url = home.appendingPathComponent(entry.component)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bookmark = try? PersistenceService.makeBookmark(for: url)
            // 显示标签走本地化，fallbackPath 保留真实路径供恢复时使用
            return Favorite(label: L(entry.labelKey), bookmark: bookmark, fallbackPath: url.path)
        }
    }

    // Seeding policy lives on `WorkspaceManager.init` now — the manager
    // owns the persisted `favoritesSeeded` flag at the workspace level.
}
