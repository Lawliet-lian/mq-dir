import Foundation
import AppKit

/// 撤销操作类型枚举
public enum UndoOperationType: Sendable {
    /// 文件移动（从 source 移到 destination）
    case move
    /// 文件复制（从 source 复制出 destination）
    case copy
    /// 重命名（source 是旧路径，destination 是新路径）
    case rename
    /// 移到废纸篓（source 是原路径，destination 是废纸篓中的路径）
    case trash
    /// 从废纸篓恢复（source 是废纸篓路径，destination 是原路径）— 由撤销 trash 时动态生成
    case restoreFromTrash
    /// 删除复制出的文件（撤销 duplicate / copy 操作时删除目标文件）
    case deleteDestination
}

/// 单个可撤销的文件操作记录，包含足够信息用于构造反向操作
public struct UndoableFileOperation: Sendable {
    /// 操作唯一标识
    public let id: UUID
    /// 操作类型
    public let operationType: UndoOperationType
    /// 成功项映射：(source 原路径, destination 操作后路径)
    public let successes: [(source: URL, destination: URL)]
    /// 操作时间戳
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        successes: [(source: URL, destination: URL)],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.operationType = operationType
        self.successes = successes
        self.timestamp = timestamp
    }
}

/// 全局单例撤销管理器
/// 维护 undoStack / redoStack 两个栈（最大容量 20），负责：
/// 1. 接收 ViewModel 层注册的文件操作记录
/// 2. 执行 undo / redo 时调用 FileOperationService 构造反向操作
/// 3. 维护 canUndo / canRedo 发布状态，供菜单绑定禁用态
@MainActor
public final class AppUndoManager: ObservableObject {

    // MARK: - 单例

    public static let shared = AppUndoManager()

    // MARK: - 常量

    /// 撤销栈最大容量
    private let maxStackDepth: Int = 20

    // MARK: - 状态

    /// 撤销栈：最新操作在末尾，undo 时 pop 末尾
    @Published public private(set) var undoStack: [UndoableFileOperation] = []

    /// 重做栈：redo 时 pop 末尾，执行新操作时清空
    @Published public private(set) var redoStack: [UndoableFileOperation] = []

    /// 是否可以撤销
    public var canUndo: Bool { !undoStack.isEmpty }

    /// 是否可以重做
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - 初始化

    private init() {}

    // MARK: - 注册操作

    /// 注册一个可撤销的文件操作。
    /// - Parameters:
    ///   - operationType: 操作类型（move / copy / rename / trash）
    ///   - result: FileOperationService 返回的结果（只取 successes 部分）
    ///
    /// 调用时机：ViewModel 层调用完 FileOperationService.* 成功后
    public func registerOperation(
        operationType: UndoOperationType,
        result: FileOperationService.TransferResult
    ) {
        // 没有成功项就不记录
        guard !result.successes.isEmpty else { return }

        let op = UndoableFileOperation(
            operationType: operationType,
            successes: result.successes
        )
        pushUndo(op)
    }

    /// 注册重命名操作（rename 返回单个 URL，不走 TransferResult）
    public func registerRename(oldURL: URL, newURL: URL) {
        let op = UndoableFileOperation(
            operationType: .rename,
            successes: [(source: oldURL, destination: newURL)]
        )
        pushUndo(op)
    }

    // MARK: - 入栈辅助

    /// 推入撤销栈；超出容量时移除最旧的（栈底）
    private func pushUndo(_ op: UndoableFileOperation) {
        undoStack.append(op)
        if undoStack.count > maxStackDepth {
            undoStack.removeFirst(undoStack.count - maxStackDepth)
        }
        // 新操作清空 redo 栈（经典撤销语义）
        redoStack.removeAll()
    }

    /// 推入重做栈；超出容量时移除最旧的
    private func pushRedo(_ op: UndoableFileOperation) {
        redoStack.append(op)
        if redoStack.count > maxStackDepth {
            redoStack.removeFirst(redoStack.count - maxStackDepth)
        }
    }

    // MARK: - Undo / Redo 执行

    /// 执行一次撤销
    public func undo() {
        guard let op = undoStack.popLast() else { return }
        // 构造反向操作并执行
        if let redoOp = executeInverse(of: op) {
            pushRedo(redoOp)
        }
        // 操作后广播刷新
        NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
    }

    /// 执行一次重做
    public func redo() {
        guard let op = redoStack.popLast() else { return }
        // 构造反向操作并执行
        if let undoOp = executeInverse(of: op) {
            pushUndo(undoOp)
        }
        // 操作后广播刷新
        NotificationCenter.default.post(name: .mqdirFileSystemChanged, object: nil)
    }

    /// 清空全部撤销/重做栈
    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - 反向操作核心

    /// 根据操作类型，构造并执行反向操作；返回需要推入对端栈的记录
    /// - Parameter op: 当前要撤销/重做的操作
    /// - Returns: 反向操作的记录（成功项需要用实际执行后的 successes，不是理论映射）
    private func executeInverse(of op: UndoableFileOperation) -> UndoableFileOperation? {
        switch op.operationType {
        case .rename:
            // rename 通常是同目录内纯重命名（或跨目录 move+rename），不走 transfer：
            // 若走 transfer 的 move，则在 "destFolder = 当前目录" 时会命中 self-drop 判断
            // (即使源/目标名不同也因 standardized 比较后相同父目录被跳过)。
            // 这里直接循环用底层 FileManager.moveItem：若目标已存在则先 conflict 改名。
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                let currentURL = pair.destination   // 当前磁盘上的文件路径（改名后的）
                let targetURL = pair.source         // 想要改回的原路径/原名
                guard FileManager.default.fileExists(atPath: currentURL.path) else { continue }
                do {
                    var dest = targetURL
                    // 若目标位置已存在（比如用户手动又建了同名文件），按 Finder 风格自动加 " 2"
                    if FileManager.default.fileExists(atPath: dest.path) {
                        let destFolder = dest.deletingLastPathComponent()
                        dest = FileOperationService.conflictRenamedDestination(
                            for: currentURL,
                            in: destFolder,
                            fileExists: { FileManager.default.fileExists(atPath: $0) }
                        )
                        // conflictRenamedDestination 使用的是 source.lastPathComponent 作为 stem，
                        // 这里我们要强行用 targetURL 的文件名当 stem，所以重写一遍：
                        let stem = targetURL.deletingPathExtension().lastPathComponent
                        let ext = targetURL.pathExtension
                        if let resolved = FileOperationService.uniqueDestination(
                            in: destFolder,
                            stem: stem,
                            extension: ext,
                            includePrimary: false,
                            fileExists: { FileManager.default.fileExists(atPath: $0) }
                        ) {
                            dest = resolved
                        }
                    }
                    try FileManager.default.moveItem(at: currentURL, to: dest)
                    inverseOps.append((source: currentURL, destination: dest))
                } catch {
                    FileHandle.standardError.write(
                        Data("[mq-dir undo] rename \(currentURL.lastPathComponent): \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            guard !inverseOps.isEmpty else { return nil }
            return UndoableFileOperation(operationType: .rename, successes: inverseOps)

        case .move:
            // move：跨目录转移，走 transfer(move:true)；注意如果是 rename 式的 move
            // （父目录相同仅文件名不同）也会走这里，同样可能命中 self-drop，
            // 所以先判断父目录是否相同，相同就按 rename 分支的逻辑直接 moveItem。
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                let currentURL = pair.destination
                let targetURL = pair.source
                guard FileManager.default.fileExists(atPath: currentURL.path) else { continue }
                let currentFolder = currentURL.deletingLastPathComponent()
                let targetFolder = targetURL.deletingLastPathComponent()
                do {
                    if currentFolder == targetFolder {
                        // 同目录 move = 纯 rename：按上面 rename 路径处理
                        var dest = targetURL
                        if FileManager.default.fileExists(atPath: dest.path) {
                            let stem = targetURL.deletingPathExtension().lastPathComponent
                            let ext = targetURL.pathExtension
                            if let resolved = FileOperationService.uniqueDestination(
                                in: targetFolder,
                                stem: stem,
                                extension: ext,
                                includePrimary: false,
                                fileExists: { FileManager.default.fileExists(atPath: $0) }
                            ) {
                                dest = resolved
                            }
                        }
                        try FileManager.default.moveItem(at: currentURL, to: dest)
                        inverseOps.append((source: currentURL, destination: dest))
                    } else {
                        // 跨目录 move：调用 transfer 自动处理冲突重命名
                        let transferResult = FileOperationService.transfer(
                            [currentURL],
                            into: targetFolder,
                            move: true
                        )
                        // 如果期望的文件名被改了（冲突），也接受，不再额外 rename 回去
                        inverseOps.append(contentsOf: transferResult.successes)
                    }
                } catch {
                    FileHandle.standardError.write(
                        Data("[mq-dir undo] move \(currentURL.lastPathComponent): \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            guard !inverseOps.isEmpty else { return nil }
            return UndoableFileOperation(operationType: .move, successes: inverseOps)

        case .copy:
            // copy / duplicate 的反向：删除复制出的 destination 文件
            // 注意：这是永久删除，但 Finder 对撤销复制也是永久删除
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                if FileManager.default.fileExists(atPath: pair.destination.path) {
                    do {
                        try FileManager.default.removeItem(at: pair.destination)
                        inverseOps.append((source: pair.destination, destination: pair.source))
                    } catch {
                        FileHandle.standardError.write(
                            Data("[mq-dir undo] delete copy \(pair.destination.lastPathComponent): \(error.localizedDescription)\n".utf8)
                        )
                    }
                }
            }
            guard !inverseOps.isEmpty else { return nil }
            // redo 时需要再次复制，所以记录为 copy 类型（但 sources/destinations 被换了含义，需要特殊处理）
            // 实际上 redo copy 我们应该用 pair.source -> somewhere，所以这里存入 deleteDestination 类型
            // 用于提示 executeInverse 走另一条路：重新做 copy
            return UndoableFileOperation(operationType: .deleteDestination, successes: inverseOps.map { (source: $0.destination, destination: $0.source) })

        case .trash:
            // trash 的反向：把废纸篓中的 destination 移回 source
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                // pair.destination 是废纸篓中的路径，pair.source 是原路径
                let trashURL = pair.destination
                let originalFolder = pair.source.deletingLastPathComponent()
                let originalName = pair.source.lastPathComponent
                if FileManager.default.fileExists(atPath: trashURL.path) {
                    // 先 move 回原文件夹
                    let result = FileOperationService.transfer(
                        [trashURL],
                        into: originalFolder,
                        move: true
                    )
                    if let first = result.successes.first {
                        // 如果冲突被重命名了，尝试改回原名
                        if first.destination.lastPathComponent != originalName {
                            do {
                                let renamed = try FileOperationService.rename(first.destination, to: originalName)
                                inverseOps.append((source: trashURL, destination: renamed))
                            } catch {
                                inverseOps.append(contentsOf: result.successes)
                            }
                        } else {
                            inverseOps.append(contentsOf: result.successes)
                        }
                    }
                }
            }
            guard !inverseOps.isEmpty else { return nil }
            // redo 的反向：再次 trash（使用 restoreFromTrash 类型，executeInverse 会再转回来）
            return UndoableFileOperation(operationType: .restoreFromTrash, successes: inverseOps.map { (source: $0.destination, destination: $0.source) })

        case .restoreFromTrash:
            // 这是 redo trash 时进入的分支：重新 trash 原文件
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                let result = FileOperationService.moveToTrash([pair.source])
                inverseOps.append(contentsOf: result.successes)
            }
            guard !inverseOps.isEmpty else { return nil }
            return UndoableFileOperation(operationType: .trash, successes: inverseOps)

        case .deleteDestination:
            // 这是 redo copy 时进入的分支：重新把 source 复制到 destination 的文件夹
            var inverseOps: [(source: URL, destination: URL)] = []
            for pair in op.successes {
                // pair.source: 原文件（复制源），pair.destination: 被删除的副本的路径（用来推断目标文件夹）
                let destFolder = pair.destination.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: pair.source.path) {
                    let result = FileOperationService.transfer(
                        [pair.source],
                        into: destFolder,
                        move: false
                    )
                    inverseOps.append(contentsOf: result.successes)
                }
            }
            guard !inverseOps.isEmpty else { return nil }
            return UndoableFileOperation(operationType: .copy, successes: inverseOps)
        }
    }
}
