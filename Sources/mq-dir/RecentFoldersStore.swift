import Foundation
import Combine
import AppKit

/// 全局共享的「最近使用的文件夹」存储器：
/// - 负责最近文件夹的内存状态（@Published items）和 UserDefaults 持久化；
/// - 最多保存 10 条，重复路径移到最前；
/// - 只记录“成功的目录跳转”：调用方保证传入的 folderURL 是真实存在且为目录的 URL；
/// - 路径统一保存为 `URL.standardizedFileURL.path` 后的绝对 POSIX 路径，
///   避免 `/Users/lawliet/./Documents/../Documents` 等等价路径被视为多条。
///
/// 约束：
/// - 只记录主动导航产生的跳转（双击目录、面包屑、⌘↑、⇧⌘G、「打开文件夹…」、
///   点击本菜单条目），不记录 Back / Forward / 启动 restore / 内部 navigate；
/// - 不触碰 FolderBrowserViewModel 的历史栈（backStack/forwardStack），只做 UI/菜单级
///   的最近列表。
final class RecentFoldersStore: ObservableObject {
    /// UserDefaults key，集中定义，避免项目其他位置重复字符串。
    /// 命名空间与 goToFolder / menu 的本地化 key 保持一致：mqdir.*
    static let defaultsKey = "mqdir.recentFolders.items"

    /// 最多保留的条目数（菜单「最近使用的文件夹」+ ⇧⌘G 面板共用同一份上限）。
    static let maximumItemCount = 20

    /// 最近文件夹的绝对 POSIX 路径列表。
    /// index 0 = 最近一次成功跳转的目录；UI 直接按数组顺序渲染即可。
    @Published private(set) var items: [String] = []

    /// 单例：由 AppDelegate / mqdirApp 注入到 MenuCommands 与 MainWindowView。
    /// 选择单例而不是环境对象，是因为 MenuCommands（Commands）无法使用
    /// SwiftUI 的 @EnvironmentObject，但能很方便地访问 shared。
    static let shared = RecentFoldersStore()

    /// 临时占位 URL：当需要在“用户即将通过 NSOpenPanel 选择任意目录”之前
    /// 先插入一条 expectedNavigationFrame 占位时使用。
    ///
    /// 由于 NSOpenPanel 返回的 URL 在当前架构中只能由
    /// `FolderBrowserViewModel.chooseFolder()` 内部拿到（改 VM 被禁止），
    /// 这里约定一个“不可能被误命中”的哨兵路径，并在
    /// `MainWindowView.handleFocusedPaneFolderDidChange` 中处理：
    /// 只要「expected.tabID 命中」且「当前 expected.url == placeholder」，
    /// 就接受本次 folderURL 变更对应的真实目录为“最近使用的目录”。
    /// 哨兵值不会写入 UserDefaults，仅用于单次导航前的内存占位。
    @MainActor
    static let chooseFolderPlaceholderURL: URL = URL(
        fileURLWithPath: "/.mqdir.internal.chooseFolder.placeholder.\(UUID().uuidString)",
        isDirectory: true
    )

    private init() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.stringArray(forKey: Self.defaultsKey) else {
            return
        }
        // 轻量防御：trim + 过滤空串 + 裁剪到上限。
        let cleaned = stored
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        items = Array(cleaned.prefix(Self.maximumItemCount))
    }

    // MARK: - Public API

    /// 记录一次“成功的目录跳转”。
    /// - Parameter folderURL: 已经确认存在且为目录的真实 URL。
    /// 行为：
    /// - 标准化路径后再入库；
    /// - 重复条目移到最前；
    /// - 超过 maximumItemCount 后裁掉尾部；
    /// - 更新后立即写入 UserDefaults。
    func recordFolder(_ folderURL: URL) {
        let path = folderURL.standardizedFileURL.path
        guard !path.isEmpty else { return }
        var copy = items
        if let existingIndex = copy.firstIndex(of: path) {
            copy.remove(at: existingIndex)
        }
        copy.insert(path, at: 0)
        if copy.count > Self.maximumItemCount {
            copy.removeLast(copy.count - Self.maximumItemCount)
        }
        guard copy != items else { return }
        items = copy
        persist()
    }

    /// 清空最近文件夹：
    /// - 立即清空内存 entries（菜单、⇧⌘G 面板都会同步刷新）；
    /// - 同步删除 UserDefaults 对应 key；
    /// - 不影响 Back / Forward 导航历史栈。
    func clear() {
        guard !items.isEmpty else {
            // 即使内存为空，也顺手删一次 key，避免 plist 中残留孤儿脏数据。
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        items = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// 菜单 / UI 渲染用的帮助函数：返回 displayName。
    /// 不在 store 里缓存 displayName，避免目录重命名后最近条目显示旧名字。
    func displayName(forPath path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    /// 菜单禁用态用：判断路径当前是否仍然是一个存在的目录。
    /// 不存在则菜单项灰掉，不触发跳转。
    func isDirectoryExisting(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - 主动导航白名单判定（与 MainWindowView.onReceive($folderURL) 配套）
    //
    // 背景：chooseFolder() / 双击目录进入 / ⌘O 打开面板等场景，成功 URL 只能由
    // FolderBrowserViewModel 内部拿到（且用户约束禁止修改 VM）。这里提供一组
    // UI 层可读写的内存状态，用于在「调用 VM 方法前」先设置期望，再由
    // MainWindowView.$folderURL 观察器在命中时写入最近记录。
    // Back / Forward / 启动恢复 / 切换 tab 等非主动导航，因缺少期望或命中
    // 栈计数变化，会被正确过滤掉，不会写入最近使用。

    /// 期望下一次 folderURL 变更对应的「用户主动导航」落地点。
    /// - tabID: 当前 focusedPane 的 ObjectIdentifier（每个 tab 独立一份 backStack）
    /// - url: 期望到达的目标 URL，或 chooseFolderPlaceholderURL（接受任意真实 URL）
    @Published var expectedNavigationFrame: (tabID: ObjectIdentifier, url: URL)?

    /// 每个 tab（ObjectIdentifier）上次记录时的 backStack 计数。
    /// 当本次 backStack.count < 上次，意味着发生了 Back（旧 frame 被弹出），
    /// 这种场景下不记录最近使用。
    @Published var lastBackStackCountByTab: [ObjectIdentifier: Int] = [:]

    /// 每个 tab（ObjectIdentifier）上次记录时的 forwardStack 计数。
    /// forwardStack.count < 上次意味着发生了 Forward 或 Back 清空了 forwardStack。
    @Published var lastForwardStackCountByTab: [ObjectIdentifier: Int] = [:]

    /// 在调用 `openFolder(_:)` / `chooseFolder()` 之前，先把期望落地的目标 URL
    /// 写进内存，供后续 `$folderURL` 变化时匹配命中。
    /// chooseFolder 场景下传入 `chooseFolderPlaceholderURL` 表示“接受任意真实目录”。
    @MainActor
    func expectOpenFolderNavigation(to targetURL: URL, tabID: ObjectIdentifier) {
        expectedNavigationFrame = (tabID, targetURL.standardizedFileURL)
    }

    /// 主入口：由 `MainWindowView.$folderURL` onChange 调用，按以下顺序判定：
    /// 1) Back/Forward（栈计数变化）→ 不记录，清掉期望；
    /// 2) 没有期望 → 启动恢复/内部 navigate → 不记录；
    /// 3) 切 tab（tabID 不匹配）→ 清期望，不记录；
    /// 4) URL 命中或 URL 命中 placeholder 哨兵 → recordFolder。
    /// 返回值：当前 (backCount, forwardCount)，由调用方在 defer 中更新计数。
    @MainActor
    @discardableResult
    func consumeExpectedAndRecordIfNeeded(
        folderURL newURL: URL?,
        tabID: ObjectIdentifier,
        currentBackCount: Int,
        currentForwardCount: Int
    ) -> (back: Int, forward: Int) {
        let lastBack = lastBackStackCountByTab[tabID] ?? 0
        let lastForward = lastForwardStackCountByTab[tabID] ?? 0
        // Back / Forward / 回访导航判定：
        // - back 减少 => goBack 弹出历史
        // - forward 减少 => goForward 消耗掉前驱；或 Back 触发清空 forward
        let isRevisitNavigation =
            currentBackCount < lastBack ||
            currentForwardCount < lastForward ||
            (currentBackCount > lastBack && currentForwardCount < lastForward)
        if isRevisitNavigation {
            expectedNavigationFrame = nil
            return (currentBackCount, currentForwardCount)
        }
        guard let expected = expectedNavigationFrame else {
            return (currentBackCount, currentForwardCount)
        }
        guard expected.tabID == tabID else {
            expectedNavigationFrame = nil
            return (currentBackCount, currentForwardCount)
        }
        guard let url = newURL else {
            expectedNavigationFrame = nil
            return (currentBackCount, currentForwardCount)
        }
        let placeholder = Self.chooseFolderPlaceholderURL.standardizedFileURL
        if expected.url.standardizedFileURL == url.standardizedFileURL
            || expected.url.standardizedFileURL == placeholder {
            recordFolder(url)
        }
        expectedNavigationFrame = nil
        return (currentBackCount, currentForwardCount)
    }

    // MARK: - Privates

    private func persist() {
        let defaults = UserDefaults.standard
        if items.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(items, forKey: Self.defaultsKey)
        }
    }
}
