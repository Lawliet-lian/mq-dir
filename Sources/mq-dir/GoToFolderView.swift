import AppKit
import SwiftUI
import Combine

/// 本地化为 GoToFolderView 提供的小型帮助函数，与 MainWindowView 保持同一套格式。
private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

/// 「前往文件夹…」面板使用的最近使用历史薄封装：
/// - 实际数据与持久化完全交由全局 `RecentFoldersStore.shared` 负责；
/// - 通过 Combine 订阅 store 的 items 变化，投影到本对象的 `entries`；
/// - 保持对外 API（record(absolutePath:) / clear() / entries）与旧版本一致，
///   让 MainWindowView 与 GoToFolderView 几乎无需改动即可共用一份数据。
final class GoToFolderHistory: ObservableObject {
    /// 允许保留的最大条数，直接复用 store 的统一上限，避免重复魔法数字。
    static let maximumEntryCount = RecentFoldersStore.maximumItemCount

    /// 投影自 `RecentFoldersStore.shared.items`，始终保持同步。
    @Published private(set) var entries: [String] = []

    private let store: RecentFoldersStore
    private var cancellable: AnyCancellable?

    /// 允许外部注入 store（默认使用单例），方便未来单元测试替换，
    /// 但默认路径直接与菜单共享同一份全局最近文件夹数据。
    init(store: RecentFoldersStore = .shared) {
        self.store = store
        // 首帧同步最新值，避免 SwiftUI 第一次渲染拿到空数组再抖一下。
        entries = store.items
        cancellable = store
            .$items
            .receive(on: RunLoop.main)
            .sink { [weak self] newItems in
                self?.entries = newItems
            }
    }

    /// 成功提交绝对路径时调用：桥接到 store 的 recordFolder。
    /// 入参仍然是绝对 POSIX 路径，和旧外部调用点保持一致。
    func record(absolutePath path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let url = URL(fileURLWithPath: normalized, isDirectory: true)
        store.recordFolder(url)
    }

    /// 清空最近使用：直接调用 store.clear()，
    /// 菜单与 ⇧⌘G 面板会同步清空（策略 A：共用同一份最近文件夹历史）。
    func clear() {
        store.clear()
    }
}

/// Finder 风格的「前往文件夹…」面板：
/// - 支持输入 POSIX 绝对路径与 ~/ 主目录前缀；
/// - Enter 提交；Esc 或点击右上角关闭按钮取消；
/// - 路径不存在时不跳转，且不加入最近使用；
/// - 成功跳转通过外部注入的 onCommit(URL) 回调传出，保证调用方
///   仍然只通过 focusedPane.openFolder(_:) 进入导航历史栈，面板本身
///   不直写 folderURL、不直调 navigate(to:)。
struct GoToFolderView: View {
    /// 当前输入内容。面板打开时，调用方可选地传入一段初始文本，
    /// 比如当前所在目录或上次未提交的草稿；不传则为空。
    @Binding private var input: String
    /// 最近成功跳转历史，由父视图持有（保证跨多次打开面板仍然保留，
    /// 但仍在同一个 App 会话内）。
    @ObservedObject private var history: GoToFolderHistory
    /// 用作 ~/ 的锚点目录。
    private let baseURLForRelativeResolution: URL?
    /// 提交成功回调：调用方负责调用 focusedPane.openFolder(targetURL)，
    /// 面板本身不接触 FolderBrowserViewModel 的私有入口。
    private let onCommit: (URL) -> Void
    /// 取消回调：一般是 sheet 的 dismiss。
    private let onCancel: () -> Void

    /// 输入无效（空/非法/不存在）时的轻量提示，不做弹窗打扰。
    @State private var showsInvalidInput = false

    /// 输入框引用：用于在 sheet 出现时把键盘焦点落到 TextField，
    /// 实现 ⇧⌘G 后可直接键入路径。
    @FocusState private var inputFocused: Bool

    init(
        input: Binding<String>,
        history: GoToFolderHistory,
        baseURLForRelativeResolution: URL?,
        onCommit: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _input = input
        self.history = history
        self.baseURLForRelativeResolution = baseURLForRelativeResolution
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            inputRow
            if !history.entries.isEmpty {
                recentSection
            }
            footer
        }
        .padding(16)
        .frame(width: 560)
        .background(Theme.Color.windowBg)
        .fixedSize(horizontal: false, vertical: true)
        // 禁止用户通过点击背景意外关闭：确保只有 Esc / 关闭按钮 / 成功跳转
        // 三种显式路径关闭面板，匹配 Finder 模态体验。
        .interactiveDismissDisabled(true)
        .onAppear {
            // 稍延迟到下一帧再激活焦点，避免 SwiftUI 在 sheet 动画过程中
            // 把 focus 丢回窗口。
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
        // 使用 AppKit 风格的键盘事件层：
        // - Enter / ⌘↩︎ 都提交；
        // - Esc 取消并关窗；
        // 这样 TextField 原生编辑（⌘A/C/V/X/Z 等）不受任何影响。
        .background(
            GoToFolderKeyEventHandlerView(
                onReturn: commitIfValid,
                onEscape: onCancel
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    // MARK: - 区域子视图

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L("mqdir.goToFolder.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.label)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("mqdir.goToFolder.close")))
            .help(L("mqdir.goToFolder.close"))
        }
    }

    private var inputRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.Color.labelSecondary)
                .font(.system(size: 12))
            // 输入框本身承担所有文本编辑交互；提交逻辑交给
            // GoToFolderKeyEventHandlerView 桥接的 AppKit keyDown 捕获，
            // 避免 onSubmit 在多平台/不同 focus ring 场景下行为不一致。
            TextField(L("mqdir.goToFolder.placeholder"), text: $input)
                .font(.system(size: 13))
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .overlay(validationBorder)
            Button(action: commitIfValid) {
                Text(L("mqdir.goToFolder.go"))
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 56)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    /// 最近使用区：单击一条把文本填到输入框并定位光标末尾；
    /// 直接双击则立刻执行跳转。这样兼顾「先编辑再去」和「直接去」两种习惯。
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("mqdir.goToFolder.recent"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.labelSecondary)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(history.entries.enumerated()), id: \.offset) { _, entry in
                        Button {
                            input = entry
                            // 把光标放到末尾，用户可继续编辑。
                            DispatchQueue.main.async { inputFocused = true }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Theme.Color.labelTertiary)
                                    .font(.system(size: 11))
                                Text(entry)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Color.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded { _ in
                                    input = entry
                                    commitIfValid()
                                }
                        )
                    }
                }
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.Color.rowHover.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.Color.separator, lineWidth: 0.5)
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(showsInvalidInput
                     ? L("mqdir.goToFolder.invalidPath")
                     : L("mqdir.goToFolder.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(showsInvalidInput
                                     ? Color.red
                                     : Theme.Color.labelTertiary)
                Spacer()
                Button(L("mqdir.goToFolder.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }

            // 「清空最近使用」只在存在历史时可点击：
            // - 立即清空 entries 并删除 UserDefaults 中对应 key；
            // - 不影响 Back / Forward 导航历史栈。
            Button {
                history.clear()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text(L("mqdir.goToFolder.clearRecents"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(history.entries.isEmpty
                                 ? Theme.Color.labelTertiary
                                 : Theme.Color.labelSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(history.entries.isEmpty
                              ? SwiftUI.Color.clear
                              : Theme.Color.rowHover.opacity(0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(history.entries.isEmpty
                                      ? SwiftUI.Color.clear
                                      : Theme.Color.separator.opacity(0.7),
                                      lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(history.entries.isEmpty)
            .help(L("mqdir.goToFolder.clearRecents"))
            // 无历史时仍保持占位高度，避免清空瞬间面板高度跳变。
            .frame(minHeight: 18)
        }
    }

    /// 输入非法时给 TextField 加一圈轻微红色描边，和文字提示互相印证。
    @ViewBuilder
    private var validationBorder: some View {
        if showsInvalidInput {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.red.opacity(0.7), lineWidth: 1)
        }
    }

    // MARK: - 提交与校验

    /// 按 Enter / 点击「前往」按钮时调用：
    /// 解析并校验路径；成功则传出 URL 并让调用方决定是否关窗；
    /// 失败则给出轻量提示但保持面板打开，方便用户继续修正。
    private func commitIfValid() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = resolve(trimmed), isDirectory(target) else {
            showsInvalidInput = true
            return
        }
        // 校验通过，立即收起错误提示，然后把控制权交给外层（MainWindowView），
        // 让它用 focusedPane.openFolder(_:) 触发导航并写入历史栈。
        showsInvalidInput = false
        onCommit(target)
    }

    /// 把用户输入解析为文件 URL：
    /// - 以 ~ 或 ~user 开头，使用 FileManager 展开；
    /// - 以 / 开头视作绝对路径；
    /// - 其他情况尝试相对于当前目录解析（当前目录缺失则丢弃，避免相对主目录产生意外）。
    private func resolve(_ raw: String) -> URL? {
        // NSString 提供的展开 ~ 能力与 Finder 一致，能识别 ~user 形式。
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        guard let base = baseURLForRelativeResolution else { return nil }
        // 相对路径：标准化后必须仍在同一文件系统语义中；
        // resolvingSymlinksInPath 用于把 /../ 等折叠到最终真实表示。
        let relative = base.appendingPathComponent(expanded, isDirectory: true)
        return URL(fileURLWithPath: relative.standardizedFileURL.path, isDirectory: true)
    }

    /// 只有目标目录真实存在时才允许跳转。这里不做 bookmark / 权限
    /// 申请：后续 openFolder(_:) → navigate(to:) 会统一处理安全作用域。
    private func isDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}

// MARK: - AppKit 键盘事件桥接

/// 一个极小的 NSViewRepresentable 包装，用来捕获 Return / Esc 两个键：
/// - Return → 提交；
/// - Esc → 取消。
/// 之所以用 NSViewRepresentable 而不是纯 SwiftUI .keyboardShortcut：
///   1) 防止 TextField 的 first responder 状态下，自定义 ⌘↩︎ 被吞；
///   2) 让 Esc 在不影响 TextField 撤销栈的前提下可靠地关闭面板。
///
/// 注意：使用 GoToFolder 前缀避免与 SettingsView.swift 中已有的
/// `KeyCaptureView`（快捷键录制面板的按键捕获 NSViewRepresentable）重名。
private struct GoToFolderKeyEventHandlerView: NSViewRepresentable {
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> GoToFolderKeyCaptureNSView {
        let view = GoToFolderKeyCaptureNSView()
        view.onReturn = onReturn
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: GoToFolderKeyCaptureNSView, context: Context) {
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
        // 父视图 onAppear 后，安排自己成为 nextResponder 链的一部分，
        // 保证不抢占 TextField 的文本编辑事件。
        DispatchQueue.main.async {
            if let window = nsView.window, nsView.nextResponder == nil {
                window.makeFirstResponder(nil)
            }
        }
    }
}

/// 实际捕获按键的 NSView：
/// - 只关心 keyDown 中的回车 / ⌘回车 / 小键盘回车 / Esc；
/// - 其他按键都不处理，直接向上传递，保证 TextField、系统菜单快捷键正常。
///
/// 命名加上 GoToFolder 前缀，避免与 SettingsView 里同名 `KeyCapture*` 类型冲突。
final class GoToFolderKeyCaptureNSView: NSView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36 /* Return */, 76 /* Keypad Enter */:
            // ⌘↩︎ / ↩︎ 统一视作提交；其他修饰组合（如 ⇧↩︎）也允许提交，
            // 与 Finder 的「前往文件夹」行为一致。
            onReturn?()
        case 53 /* Esc */:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}
