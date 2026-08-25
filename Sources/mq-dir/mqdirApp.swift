import AppKit
import SwiftUI

@main
struct mqdirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceManager()
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var repoCallout = RepoCalloutController()

    init() {
        // 启动阶段先同步一次语言设置到 UserDefaults，
        // 让 NSLocalizedString / Bundle 在 SwiftUI 初始化前就锁定正确的 locale。
        // 由于 WorkspaceManager 还未初始化（它是 @StateObject，在 body 之前构建），
        // 这里先用 PersistenceService 直接读磁盘，保持幂等且零副作用。
        if let service = try? PersistenceService(),
           let state = service.loadState() {
            Self.applyLanguagePreference(state.settings.language)
        }

        // Forward NSApplication's willTerminate to our internal notification
        // so MainWindowView can flush a synchronous save before exit.
        // Doing this in App.init keeps the wiring close to the lifecycle
        // that depends on it, and avoids touching AppDelegate's existing
        // M0-era responsibilities.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .mqdirAppWillTerminate, object: nil)
        }
    }

    /// 将用户选择的语言偏好写入 `AppleLanguages`，
    /// 使 `NSLocalizedString` 立即选择对应 locale 的 strings 文件。
    /// `.system` 时移除 override，让系统 locale 生效。
    static func applyLanguagePreference(_ option: LanguageOption) {
        if let locale = option.localeIdentifier {
            UserDefaults.standard.set([locale], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    var body: some Scene {
        WindowGroup("mq-dir") {
            // 两个维度组合作为视图的 id：
            //   1. activeProjectID → 项目切换时重建（原有逻辑）
            //   2. language rawValue → 语言切换时重建，让所有 NSLocalizedString
            //      在新的 Bundle locale 下重新求值。
            MainWindowView(
                workspace: workspace,
                updateManager: updateManager,
                repoCallout: repoCallout
            )
                // Drop the workspace into the environment so deep
                // descendants (e.g. `FileEntryContextMenu`) can pick
                // up customised shortcut bindings without an
                // ObservedObject parameter threaded through every
                // intermediate view.
                .environmentObject(workspace)
                .id("\(workspace.workspace.activeProjectID.uuidString)-\(workspace.workspace.settings.language.rawValue)")
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(workspace.workspace.settings.colorScheme.preferred)
        }
        .windowResizability(.contentMinSize)
        .commands {
            MenuCommands(workspace: workspace)
        }

        // Standard macOS Preferences window (⌘,). 包含外观、语言、
        // 韩文文件名规范化和快捷键自定义四个 Section。
        Settings {
            SettingsView(workspace: workspace)
                .preferredColorScheme(workspace.workspace.settings.colorScheme.preferred)
                // 语言切换时同时重建 SettingsView 本身，保证 Section header、
                // Picker 标签等也跟随新 locale 立即刷新。
                .id(workspace.workspace.settings.language.rawValue)
        }
    }
}
