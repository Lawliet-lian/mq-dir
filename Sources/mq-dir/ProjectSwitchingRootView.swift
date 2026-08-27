import SwiftUI

/// 项目切换的 SwiftUI 根视图。
///
/// **唯一职责**：监听 `WorkspaceManager` 的 `activeProjectID` 变化，
/// 当项目切换时通过 SwiftUI 的 `.id()` 机制销毁并重建内部的 `MainWindowView`，
/// 让 MainWindowView 的 `@State` / `@StateObject` 在 init 时从新 Project 的
/// `WindowState` 初始化，从而恢复对应项目的 4 Pane / Tab / Layout 状态。
///
/// 设计动机：
/// - MainWindowController（AppKit）只负责窗口生命周期，不介入 SwiftUI 的状态刷新。
/// - Project 切换由 SwiftUI 响应式链路自洽处理，保持 AppKit / SwiftUI 两层职责清晰。
///
/// 状态流：
/// ```
/// Sidebar 点击另一个项目
///     → WorkspaceManager.switchTo(projectID:)
///     → @Published workspace 发布变化
///     → @ObservedObject workspace 在此 View 的 body 重新计算
///     → .id(newProjectID) 与旧值不同
///     → SwiftUI 销毁旧 MainWindowView，创建新 MainWindowView
///     → 新 MainWindowView.init 从 workspace.activeProject.state 加载新状态
/// ```
struct ProjectSwitchingRootView: View {

    // MARK: - 外部注入的依赖（由 MainWindowController 创建时传入）
    // 用 @ObservedObject 订阅 WorkspaceManager 的 @Published，确保 activeProjectID
    // 改变时 body 重新求值，从而 .id 参数获得新值。
    @ObservedObject var workspace: WorkspaceManager
    // updateManager / repoCallout 仅透传给 MainWindowView，不观察变化。
    let updateManager: UpdateManager
    let repoCallout: RepoCalloutController

    var body: some View {
        MainWindowView(
            workspace: workspace,
            updateManager: updateManager,
            repoCallout: repoCallout
        )
        // ⚠️ 关键：使用 activeProjectID 作为 MainWindowView 的稳定身份标识。
        // 当 ID 变化时，SwiftUI 将旧视图完全从视图树移除并销毁（释放其 @StateObject PaneVM），
        // 然后创建新实例，MainWindowView.init 会从当前 activeProject.state 重新初始化。
        // 这是项目切换场景下刷新 4 Pane 状态的最小代价方案。
        .id(workspace.workspace.activeProjectID)
        // workspace 通过 environment 再次传递，方便深层子视图（如 FileEntryContextMenu）
        // 无需手动传递即可拿到工作区实例，行为与原 WindowGroup 版本保持一致。
        .environmentObject(workspace)
        // 最小尺寸双重保护：AppKit 层 NSWindow.minSize 已设 900x600，
        // SwiftUI 层再设一道，防止内容布局在极端场景下挤压窗口。
        .frame(minWidth: 900, minHeight: 600)
        // 跟随用户在 Settings → 外观 中选择的浅色 / 深色 / 跟随系统。
        .preferredColorScheme(workspace.workspace.settings.colorScheme.preferred)
    }
}
