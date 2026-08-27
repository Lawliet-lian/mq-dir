import AppKit
import SwiftUI

/// App 唯一主窗口的控制器。
///
/// 职责：
/// - 创建并持有唯一 `NSWindow` 实例
/// - 用 `NSHostingView` 承载 SwiftUI 的 `MainWindowView`
/// - 统一提供 `show()` / `hide()` 作为窗口生命周期入口
/// - 通过 `NSWindowDelegate` 拦截「红圈 X」和「⌘W」改为隐藏而非销毁窗口
///
/// 该控制器由 `AppDelegate` 强引用，App 生命周期内唯一。
final class MainWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - 依赖（由 AppDelegate 注入）
    // 这些是 MainWindowView 所需的全局业务对象，MWC 自己持有它们，
    // 避免 AppDelegate 逐渐变成 DI 容器。
    let workspace: WorkspaceManager
    let updateManager: UpdateManager
    let repoCallout: RepoCalloutController

    // MARK: - 初始化
    /// 创建主窗口控制器。
    ///
    /// - Parameters:
    ///   - workspace: 工作区管理器（项目、收藏夹、持久化入口）
    ///   - updateManager: 更新检查控制器
    ///   - repoCallout: 仓库提示控制器
    init(
        workspace: WorkspaceManager,
        updateManager: UpdateManager,
        repoCallout: RepoCalloutController
    ) {
        self.workspace = workspace
        self.updateManager = updateManager
        self.repoCallout = repoCallout
        super.init(window: nil)
        setupMainWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 窗口构造
    /// 配置唯一 NSWindow 实例并把 SwiftUI MainWindowView 挂载进去。
    private func setupMainWindow() {
        // 初始尺寸：给一个合理的默认值（1200x800），位置从屏幕左上偏移一段距离。
        // 持久化窗口尺寸将在后续阶段接入 PersistenceService。
        let initialFrame = NSRect(
            x: 200,
            y: 200,
            width: 1200,
            height: 800
        )

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        // 与原 WindowGroup 中的 .frame(minWidth: 900, minHeight: 600) 对齐。
        window.minSize = NSSize(width: 900, height: 600)
        window.title = "mq-dir"
        // ⚠️ 关键：即使某些系统边缘场景触发了 close，也不释放 window 对象。
        // 真正的内存安全保障来自 AppDelegate 对 MWC 的强引用链，但这里再加一道保险。
        window.isReleasedWhenClosed = false
        window.delegate = self

        // MARK: - SwiftUI 内容包装
        // 最外层挂载 ProjectSwitchingRootView，由它负责观察 workspace.activeProjectID
        // 并在项目切换时重建 MainWindowView。具体机制见 ProjectSwitchingRootView.swift。
        // 原先直接写在 MWC 里的 .id / environment / frame / preferredColorScheme
        // 已移到 ProjectSwitchingRootView 中统一管理，MWC 不再介入 SwiftUI 内部状态。
        let rootView = ProjectSwitchingRootView(
            workspace: workspace,
            updateManager: updateManager,
            repoCallout: repoCallout
        )

        window.contentView = NSHostingView(rootView: rootView)
        self.window = window
    }

    // MARK: - 统一生命周期入口

    /// 显示主窗口并激活应用。
    ///
    /// 所有入口（Dock 点击、Finder 右键 URL、外部命令行）都应该调用这个方法，
    /// 不要各自调用 `makeKeyAndOrderFront` / `NSApp.activate`，避免行为不一致。
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 隐藏主窗口（保留在内存中，App 继续运行）。
    ///
    /// 对应「🔴 红圈 X」和「⌘W」触发的「关闭窗口」语义。
    /// 不会销毁任何 Pane / Tab / Workspace 状态，下次 show() 原样恢复。
    func hide() {
        window?.orderOut(nil)
    }

    /// 在显示和隐藏之间切换（供未来菜单条目或全局快捷键使用）。
    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    // MARK: - NSWindowDelegate

    /// 拦截所有「关闭窗口」动作（🔴 X / ⌘W / performClose:），改为隐藏窗口。
    ///
    /// 由于这个 NSWindow 完全由我们自己创建（而非 SwiftUI WindowGroup 托管），
    /// 在这里返回 false 并 orderOut 是 AppKit 单窗口应用的标准模式。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
