import AppKit
import SwiftUI

/// 文件夹对比的请求载体：承载要对比的左右两个目录。
/// 遵循 Identifiable 以便 SwiftUI 的 `.sheet(item:)` 直接绑定。
struct FolderComparisonRequest: Identifiable {
    let id = UUID()
    let left: URL
    let right: URL
}

/// 文件夹对比的 Sheet 视图。
/// UI 全部采用中文（遵循项目汉化策略），行级按钮布局：
/// - 仅左侧存在 → 「打开左边」按钮在左，右侧保留同等宽度的占位，让列始终对齐
/// - 仅右侧存在 → 左侧留占位，「打开右边」按钮在右
/// - 两侧都存在 → 左右两个按钮都正常显示
struct FolderComparisonView: View {
    let request: FolderComparisonRequest
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [FolderComparisonRow] = []
    @State private var error: String?
    @State private var loading = true
    /// 用来强制刷新 task：用户点「重新对比」就换一个新的 UUID，
    /// `.task(id:)` 会取消旧任务并重新执行 load()。
    @State private var revision = UUID()

    /// 行级「打开」按钮的统一尺寸，保证有/无按钮时视觉上两列对齐。
    private static let actionButtonWidth: CGFloat = 84
    private static let actionButtonHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹对比").font(.headline)
                Spacer()
                Button("重新对比") { revision = UUID() }
                Button("关闭") { dismiss() }
            }
            // 左右两个路径文本，允许选中复制（方便用户排查）。
            Text("左侧：" + request.left.path).textSelection(.enabled)
            Text("右侧：" + request.right.path).textSelection(.enabled)
            // 方案 C 新增说明：第一层按名称/大小/修改时间比对；
            // 当两边是同名子文件夹时，会递归比对子树所有条目的元数据
            // （仍然不读文件内容、不做 MD5）。
            Text("第一层按名称、大小和修改时间比对；同为子文件夹时递归比对子条目元数据，不对比文件内容。")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView() }
            else if let error {
                // 对比执行出错时展示错误信息（红色）。
                Text(error).foregroundStyle(.red)
            }
            else if rows.isEmpty {
                Text("两个文件夹当前均为空。")
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            // 每一行：内容 24pt 垂直内边距 + 整行宽度顶/底横线。
                            // 注意：这里用 Rectangle + 固定 height 明确表示横线，
                            // 不使用 SwiftUI 的 Divider()，因为它在 HStack 上下文中
                            // 会被自动适配成竖线，不符合我们要的行间横线效果。
                            HStack {
                                Text(row.name).lineLimit(1)
                                    .frame(width: 230, alignment: .leading)
                                // 按 Status 映射成不同颜色，引导用户视觉区分：
                                //   ① 真正需要关注的差异（元数据不同 / 子文件夹有差异）→ 橙色（醒目）
                                //   ② 子文件夹确认完全一致 → 绿色（安心）
                                //   ③ 其余（左右独有 / 普通相同 / 过大跳过）→ 次级灰色
                                Text(row.status.rawValue)
                                    .foregroundStyle(Self.statusColor(for: row.status))
                                Spacer()
                                // --- 左右两个按钮 + 占位，宽度固定对齐 ---
                                Group {
                                    if let leftURL = row.left {
                                        Button("打开左边") {
                                            NSWorkspace.shared
                                                .activateFileViewerSelecting([leftURL])
                                        }
                                        .frame(width: Self.actionButtonWidth,
                                               height: Self.actionButtonHeight)
                                    } else {
                                        // 左边没条目时用同等尺寸的占位保持列对齐。
                                        Color.clear
                                            .frame(width: Self.actionButtonWidth,
                                                   height: Self.actionButtonHeight)
                                    }

                                    if let rightURL = row.right {
                                        Button("打开右边") {
                                            NSWorkspace.shared
                                                .activateFileViewerSelecting([rightURL])
                                        }
                                        .frame(width: Self.actionButtonWidth,
                                               height: Self.actionButtonHeight)
                                    } else {
                                        // 右边没条目时用同等尺寸的占位保持列对齐。
                                        Color.clear
                                            .frame(width: Self.actionButtonWidth,
                                                   height: Self.actionButtonHeight)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            // 让行内容撑满整行宽度（左对齐），
                            // 这样接下来的 overlay 横线才能贯穿到整个 ScrollView 左右边距。
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // 顶横线：用 Rectangle + 0.5pt 固定高度 + 15% 透明主色 = 横线
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.15))
                                    .frame(height: 0.5)
                            }
                            // 底横线：同上
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.15))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 400, idealHeight: 520)
        // 用户点「重新对比」时通过 revision 触发异步加载。
        .task(id: revision) { await load() }
    }

    /// 后台执行对比：把计算搬到 detached Task（非主线程），
    /// 同时使用 ProcessRunner.Cancellation 让取消信号能下传到
    /// FolderComparison.compare → FileSystemService.enumerateDirectory。
    @MainActor private func load() async {
        loading = true
        error = nil
        let token = ProcessRunner.Cancellation()
        await withTaskCancellationHandler {
            do {
                let left = request.left, right = request.right
                let result = try await Task.detached(priority: .userInitiated) {
                    try FolderComparison.compare(left: left, right: right, cancellation: token)
                }.value
                guard !Task.isCancelled else { return }
                rows = result
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        } onCancel: {
            token.cancel()
        }
    }

    // MARK: - 状态颜色映射（方案 C 新增 3 种子文件夹状态）

    /// 根据行状态决定 UI 上文字的颜色：
    /// - 有差异（文件级 / 子文件夹级）→ 橙色，提醒用户关注
    /// - 子文件夹确认内容一致 → 绿色，给用户一个安心的确认信号
    /// - 其余（左右独有、普通文件一致、过大跳过）→ 次级灰色
    private static func statusColor(for status: FolderComparisonRow.Status) -> Color {
        switch status {
        case .different, .folderDifferent:
            return .orange
        case .folderSame:
            // 用绿色偏暗一点（.green 太亮了在深色模式下刺眼），改 80% 不透明度或选 secondaryGreen
            // 这里用系统提供的 .green，然后 70% 不透明度，兼顾深/浅色模式。
            return .green.opacity(0.85)
        case .same, .leftOnly, .rightOnly, .folderTooLarge:
            return .secondary
        }
    }
}
