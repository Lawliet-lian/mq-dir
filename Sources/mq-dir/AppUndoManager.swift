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
    /// 对 replace 的项：destination 就是目标位置（文件名未变，但内容已被换成新）
    public let successes: [(source: URL, destination: URL)]
    /// 操作时间戳
    public let timestamp: Date
    /// 本操作中发生了「替换」的子项列表：每个 ReplaceRecord 携带了
    /// 被替换掉的旧文件的备份路径；undo 时把这些备份移回 destination。
    /// 非 replace 的 copy/move 场景此字段为空数组。
    public let replaceRecords: [FileOperationService.ReplaceRecord]

    public init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        successes: [(source: URL, destination: URL)],
        replaceRecords: [FileOperationService.ReplaceRecord] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.operationType = operationType
        self.successes = successes
        self.replaceRecords = replaceRecords
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
    ///   - result: FileOperationService 返回的结果（successes + replaceRecords）
    ///
    /// 调用时机：ViewModel 层调用完 FileOperationService.* 成功后
    public func registerOperation(
        operationType: UndoOperationType,
        result: FileOperationService.TransferResult
    ) {
        // 没有成功项 + 没有 replace 记录 → 不记录
        guard !result.successes.isEmpty || !result.replaceRecords.isEmpty else { return }

        let op = UndoableFileOperation(
            operationType: operationType,
            successes: result.successes,
            replaceRecords: result.replaceRecords
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
            // 栈溢出：把溢出的最旧操作的 replace 备份目录删掉，避免磁盘残留
            let overflowCount = undoStack.count - maxStackDepth
            let overflow = Array(undoStack.prefix(overflowCount))
            for over in overflow {
                cleanupReplaceBackupDirectories(in: over)
            }
            undoStack.removeFirst(overflowCount)
        }
        // 新操作清空 redo 栈（经典撤销语义）
        // 清空 redo 前也得先把 redo 里的备份目录删掉
        for red in redoStack {
            cleanupReplaceBackupDirectories(in: red)
        }
        redoStack.removeAll()
    }

    /// 推入重做栈；超出容量时移除最旧的
    private func pushRedo(_ op: UndoableFileOperation) {
        redoStack.append(op)
        if redoStack.count > maxStackDepth {
            let overflowCount = redoStack.count - maxStackDepth
            let overflow = Array(redoStack.prefix(overflowCount))
            for over in overflow {
                cleanupReplaceBackupDirectories(in: over)
            }
            redoStack.removeFirst(overflowCount)
        }
    }

    // MARK: - 备份目录清理

    /// 当一条 Undo/Redo 记录彻底出栈（溢出/clear）时，
    /// 同步删除它携带的所有 replace 备份目录。
    ///
    /// 这里不关心 backup 具体存在哪，只根据 ReplaceRecord 里持有的 backup URL
    /// 交给 ReplaceBackupManager 清理。这样 Undo/Redo 数据模型保持不变，
    /// 只替换了 backup 的物理存储位置和生命周期执行者。
    private func cleanupReplaceBackupDirectories(in op: UndoableFileOperation) {
        ReplaceBackupManager.removeBackups(for: op.replaceRecords)
    }

    /// 清空全部撤销/重做栈（同时清理所有备份目录）
    public func clear() {
        for op in undoStack { cleanupReplaceBackupDirectories(in: op) }
        for op in redoStack { cleanupReplaceBackupDirectories(in: op) }
        undoStack.removeAll()
        redoStack.removeAll()
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

    // MARK: - 反向操作核心

    /// 处理一条 Undo 中「replace 子项」的回滚：
    /// 把 destination 中当前的「新内容」移到 redo-temp，
    /// 再把 replacedOriginalBackup 中的「旧内容」移回 destination。
    /// 返回的 ReplaceRecord 用于 redo（backup 指向新生成的 redo-temp）。
    /// 本 helper 同步处理 move/copy 场景下 replace 的源文件状态（move 的 replace 需把 source 移回）。
    private func executeReplaceInverse(
        records: [FileOperationService.ReplaceRecord],
        isUndo: Bool  // true = 撤销 replace（旧内容回 destination）；false = 重做 replace（新内容回 destination）
    ) -> [FileOperationService.ReplaceRecord] {
        var redoRecords: [FileOperationService.ReplaceRecord] = []
        let fm = FileManager.default

        for record in records {
            // isUndo=true:  currentDestination 是新内容，要换成旧内容（record.replacedOriginalBackup）
            // isUndo=false: 则相反（把 destination 当前的旧内容换回去的过程）。
            // 注意：redo 场景进来的 record 其 replacedOriginalBackup 存的是「undo 时的 redo-temp」，也就是新内容本身。
            let currentDest = record.destination
            guard fm.fileExists(atPath: currentDest.path) else { continue }

            // 对端（另一侧）的备份内容
            let oppositeBackup = record.replacedOriginalBackup
            guard fm.fileExists(atPath: oppositeBackup.path) else { continue }

            let tempBackup: URL
            do {
                tempBackup = try ReplaceBackupManager.swapDestinationWithBackup(
                    destination: currentDest,
                    backupItem: oppositeBackup,
                    fileManager: fm
                )
            } catch {
                continue
            }

            // 构造对端栈使用的 ReplaceRecord：source 保持不变，backup 指向新的 tempBackup
            redoRecords.append(
                FileOperationService.ReplaceRecord(
                    source: record.source,
                    destination: record.destination,
                    replacedOriginalBackup: tempBackup
                )
            )
        }
        return redoRecords
    }

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
            // move：跨目录转移，走 transfer(move:true)；含 replace 子项时做额外处理
            // --------------------------------------------------
            // 先把 successes 分成两类：
            //   A. 普通 move 项（不在 replaceRecords 里）→ 按旧逻辑 move 回去
            //   B. replace 项 → 内容回滚走 executeReplaceInverse，
            //      另外：move 语义下 source 在正向操作中被删除了，undo 时要恢复一份
            // --------------------------------------------------
            let fm = FileManager.default
            let replaceDestSet = Set(op.replaceRecords.map { $0.destination })
            var inverseOps: [(source: URL, destination: URL)] = []

            for pair in op.successes {
                // 跳过 replace 的项，后面统一走 executeReplaceInverse
                if replaceDestSet.contains(pair.destination) { continue }
                let currentURL = pair.destination
                let targetURL = pair.source
                guard fm.fileExists(atPath: currentURL.path) else { continue }
                let currentFolder = currentURL.deletingLastPathComponent()
                let targetFolder = targetURL.deletingLastPathComponent()
                do {
                    if currentFolder == targetFolder {
                        var dest = targetURL
                        if fm.fileExists(atPath: dest.path) {
                            let stem = targetURL.deletingPathExtension().lastPathComponent
                            let ext = targetURL.pathExtension
                            if let resolved = FileOperationService.uniqueDestination(
                                in: targetFolder,
                                stem: stem,
                                extension: ext,
                                includePrimary: false,
                                fileExists: { fm.fileExists(atPath: $0) }
                            ) {
                                dest = resolved
                            }
                        }
                        try fm.moveItem(at: currentURL, to: dest)
                        inverseOps.append((source: currentURL, destination: dest))
                    } else {
                        let transferResult = FileOperationService.transfer(
                            [currentURL],
                            into: targetFolder,
                            move: true
                        )
                        inverseOps.append(contentsOf: transferResult.successes)
                    }
                } catch {
                    FileHandle.standardError.write(
                        Data("[mq-dir undo] move \(currentURL.lastPathComponent): \(error.localizedDescription)\n".utf8)
                    )
                }
            }

            // 处理 replaceRecords 的内容回滚
            let redoReplaceRecords = executeReplaceInverse(records: op.replaceRecords, isUndo: true)

            // Move+Replace 额外：恢复正向操作中被删除的 source 文件
            // （正向 move 把 source 搬到了 destination，现在 destination 的「新内容」刚被
            //  executeReplaceInverse 搬到了 tempBackup，再从 tempBackup copy 一份回 source）
            for (orig, redoRec) in zip(op.replaceRecords, redoReplaceRecords) {
                let sourceURL = orig.source
                guard !fm.fileExists(atPath: sourceURL.path) else { continue }
                let sourceParent = sourceURL.deletingLastPathComponent()
                let srcName = sourceURL.lastPathComponent
                do {
                    try fm.createDirectory(at: sourceParent, withIntermediateDirectories: true)
                    // 从 tempBackup 复制一份回 source 位置（tempBackup 本身保留给 redo 栈）
                    try fm.copyItem(at: redoRec.replacedOriginalBackup, to: sourceURL)
                    // 如果 sourceParent 下已有同名，说明 copy 抛错上面已经被 catch；
                    // 这里额外做一次 conflict rename 尽力恢复
                } catch let createErr {
                    // 恢复 source 失败：打印日志，但不影响整体 undo（destination 已经回滚）
                    FileHandle.standardError.write(
                        Data("[mq-dir undo] move+replace restore source \(srcName): \(createErr.localizedDescription)\n".utf8)
                    )
                }
            }

            guard !inverseOps.isEmpty || !redoReplaceRecords.isEmpty else { return nil }
            return UndoableFileOperation(
                operationType: .move,
                successes: inverseOps,
                replaceRecords: redoReplaceRecords
            )

        case .copy:
            // copy / duplicate 的反向：
            //   - 普通 copy：删除复制出的 destination（永久删除，同 Finder 语义）
            //   - replace 子项：用 executeReplaceInverse 把 destination 内容换回旧文件
            //                 （当前 destination 的「新内容」会被搬到 redo-temp，
            //                  用作 redo 时的新内容备份）
            let fm = FileManager.default
            let replaceDestSet = Set(op.replaceRecords.map { $0.destination })
            var inverseOps: [(source: URL, destination: URL)] = []

            for pair in op.successes {
                if replaceDestSet.contains(pair.destination) { continue } // replace 项跳过
                guard fm.fileExists(atPath: pair.destination.path) else { continue }
                do {
                    try fm.removeItem(at: pair.destination)
                    inverseOps.append((source: pair.destination, destination: pair.source))
                } catch {
                    FileHandle.standardError.write(
                        Data("[mq-dir undo] delete copy \(pair.destination.lastPathComponent): \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            // replace 子项走专用路径
            let redoReplaceRecords = executeReplaceInverse(records: op.replaceRecords, isUndo: true)

            guard !inverseOps.isEmpty || !redoReplaceRecords.isEmpty else { return nil }
            // redo 时走 deleteDestination 分支重新做 copy / replace
            return UndoableFileOperation(
                operationType: .deleteDestination,
                successes: inverseOps.map { (source: $0.destination, destination: $0.source) },
                replaceRecords: redoReplaceRecords
            )

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
            // 这是 redo copy 时进入的分支：重新把 source 复制到 destination 的文件夹。
            // 普通项走旧 transfer 逻辑；replace 的 redo 走 executeReplaceInverse(isUndo=false)
            // —— 注意：redo replace 的语义是「重新把内容换成新文件」，恰好是 undo 的反向：
            //   undo 把备份（旧内容）换回 destination，当前内容（新）进 redo-temp；
            //   redo 则把备份（新内容）换回 destination，当前内容（旧）进新的 undo-temp。
            //   executeReplaceInverse 对正反方向做的动作相同，因此可以复用。
            let fm = FileManager.default
            let replaceDestSet = Set(op.replaceRecords.map { $0.destination })
            var inverseOps: [(source: URL, destination: URL)] = []

            for pair in op.successes {
                // replace 项跳过，走下面统一的 redo
                if replaceDestSet.contains(pair.destination) { continue }
                let destFolder = pair.destination.deletingLastPathComponent()
                if fm.fileExists(atPath: pair.source.path) {
                    let result = FileOperationService.transfer(
                        [pair.source],
                        into: destFolder,
                        move: false
                    )
                    inverseOps.append(contentsOf: result.successes)
                }
            }
            // replace 子项走对称的内容替换（redo 方向）
            let redoReplaceRecords = executeReplaceInverse(records: op.replaceRecords, isUndo: false)

            guard !inverseOps.isEmpty || !redoReplaceRecords.isEmpty else { return nil }
            return UndoableFileOperation(
                operationType: .copy,
                successes: inverseOps,
                replaceRecords: redoReplaceRecords
            )
        }
    }
}
