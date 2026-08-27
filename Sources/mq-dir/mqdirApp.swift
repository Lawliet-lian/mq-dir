import AppKit
import SwiftUI

@main
struct mqdirApp: App {
    // 通过 adaptor 拿到 AppDelegate，MainWindowController / workspace / updateManager
    // 等依赖现在都由 AppDelegate 持有，避免 SwiftUI App struct 同时承担 Scene 构造 + DI。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 启动阶段先同步一次语言设置到 UserDefaults，
        // 让 NSLocalizedString / Bundle 在 SwiftUI 初始化前就锁定正确的 locale。
        // 由于 AppDelegate 的 workspace 还没完全准备好（AppDelegate 初始化时序），
        // 这里仍然直接用 PersistenceService 读磁盘，保持幂等且零副作用。
        if let service = try? PersistenceService(),
           let state = service.loadState() {
            Self.applyLanguagePreference(state.settings.language)
        }
        // 注意：原 init() 中的 willTerminateNotification 转发逻辑
        // 已移入 AppDelegate.applicationWillTerminate(_:)，更符合 AppKit 设计惯例。
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
        // ⚠️ 不再使用 SwiftUI WindowGroup。
        // 产品设计上整个 App 只存在一个 MainWindow，其生命周期完全由
        // AppDelegate + MainWindowController（AppKit）管控。
        // SwiftUI 这里只保留原生 Settings Scene（系统设置 ⌘,）。

        // Standard macOS Preferences window (⌘,). 包含外观、语言、
        // 韩文文件名规范化和快捷键自定义四个 Section。
        // workspace 从 AppDelegate 取，保证与 MainWindowController 使用的是同一实例。
        Settings {
            SettingsView(workspace: appDelegate.workspace)
                .preferredColorScheme(appDelegate.workspace.workspace.settings.colorScheme.preferred)
                // 语言切换时同时重建 SettingsView 本身，保证 Section header、
                // Picker 标签等也跟随新 locale 立即刷新。
                .id(appDelegate.workspace.workspace.settings.language.rawValue)
        }
        // MenuCommands（File / Edit / View / Window 菜单）之前是挂在 WindowGroup 上，
        // 现在 WindowGroup 已移除，仍需要挂在某个 Scene 上才能生效，所以放在 Settings 后面。
        // workspace 同样从 AppDelegate 取。
        .commands {
            MenuCommands(workspace: appDelegate.workspace)
        }
    }
}
