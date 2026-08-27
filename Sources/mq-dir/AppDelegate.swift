import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 应用级依赖（MainWindow 与 Settings 共享）
    // 按最终架构方案：AppDelegate 直接持有这三个全局业务对象，
    // MainWindowController 通过构造注入获取它们；Settings Scene 通过
    // 通过 @NSApplicationDelegateAdaptor 取 delegate.workspace。
    let workspace = WorkspaceManager()
    let updateManager = UpdateManager()
    let repoCallout = RepoCalloutController()

    // MARK: - 主窗口控制器
    // ⚠️ 强引用，保证 App 生命周期内 MainWindowController 与 NSWindow 不被释放。
    // 产品语义上整个 App 只有这一个 MainWindowController 实例。
    var mainWindowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 构造唯一主窗口控制器并注入三个依赖。
        mainWindowController = MainWindowController(
            workspace: workspace,
            updateManager: updateManager,
            repoCallout: repoCallout
        )

        // 2. 显示主窗口 + 激活应用，启动即进入前台。
        mainWindowController.show()

        // 3. 清理之前崩溃遗留的 PDF/ZIP 临时目录（正常退出时在各 service 会自己清理，
        // 这里只处理上次异常退出场景下的孤儿目录）。
        Task.detached(priority: .background) {
            ZipPreviewService.sweepLeftoverTempDirs()
        }
    }

    // MARK: - Dock 重新打开

    /// 用户点击 Dock 图标时触发。
    ///
    /// 无论当前是否有可见窗口，统一走 `mainWindowController.show()`，
    /// 这样即使用户通过 🔴 X 或 ⌘W 把主窗口隐藏，点击 Dock 都能重新显示，
    /// 且所有 Pane / Tab / Workspace 状态保留在内存中，show() 后原样呈现。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindowController.show()
        return true
    }

    // MARK: - 外部 URL 打开（Finder 右键「在 mq-dir 中显示」等，M1 再实现完整路由）

    func application(_ application: NSApplication, open urls: [URL]) {
        // 先确保窗口显示并激活，后续 M1 再把 urls 路由到对应 Pane / Tab。
        mainWindowController.show()
    }

    // MARK: - 安全可恢复状态

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 终止前同步保存

    /// 应用即将终止（⌘Q / 菜单 Quit）时，转发为内部通知，
    /// 由 MainWindowView 监听后立刻执行同步落盘，避免 debounce 还没触发就退出导致最后一次修改丢失。
    ///
    /// 原逻辑来自 mqdirApp.init() 里的 willTerminateNotification 监听，
    /// 挪到 AppDelegate 更符合 AppKit 的设计惯例。
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .mqdirAppWillTerminate, object: nil)
    }
}
