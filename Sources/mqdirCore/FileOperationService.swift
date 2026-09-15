import Foundation

/// Stateless filesystem mechanics for the destructive / mutating file
/// operations the browser pane exposes (paste, duplicate, drop, trash,
/// permanent delete, compress, extract, new folder, rename). Pure
/// Foundation, `@Sendable`-safe, no AppKit / NotificationCenter / main
/// actor — the view model keeps the UI side effects (NSAlert presentation,
/// `.mqdirFileSystemChanged` broadcasts, pasteboard reads, selection state,
/// stderr logging) and calls in here for the actual disk work.
///
/// Per-item operations capture failures as `[(URL, Error)]` and keep going
/// past an individual error so a partial selection never aborts the whole
/// batch. Callers decide how to present (alert, stderr log, …).
public enum FileOperationService {

    // MARK: - Collision Types

    /// 用户对单个冲突文件的决策结果。
    /// - keepBoth: 保留两者（复用现有 `conflictRenamedDestination` 逻辑生成 " 2"/" 3" 后缀）
    /// - stop:     停止本次整个 transfer 任务，不再处理后续文件
    /// - replace:  替换目标位置的现有文件（走 `safeReplaceItem` 安全流程）
    public enum CollisionDecision: Sendable {
        case keepBoth
        case stop
        case replace
    }

    /// 本次 transfer 任务内的冲突处理策略。
    /// 初始为 `.ask`（每遇到冲突都调用回调询问）；
    /// 当用户勾选「应用到全部」后切换为 `.applyKeepBoth` / `.applyReplace`，
    /// 后续冲突不再弹窗，直接使用缓存决策。
    public enum CollisionPolicy: Sendable {
        case ask
        case applyKeepBoth
        case applyReplace
    }

    /// 单次「替换」操作的详细记录，供 Undo 管理器恢复被替换的原文件。
    /// `replacedOriginalBackup` 指向备份目录中的旧文件路径；
    /// 当 Undo 栈溢出被移除时，调用方应负责清理该临时备份目录。
    public struct ReplaceRecord: Sendable {
        /// 本次复制/移动的源文件路径
        public let source: URL
        /// 最终写入位置（通常就是目标文件夹/原名）
        public let destination: URL
        /// 被替换掉的原目标文件的备份路径；undo 时将其移回 destination
        public let replacedOriginalBackup: URL

        public init(source: URL, destination: URL, replacedOriginalBackup: URL) {
            self.source = source
            self.destination = destination
            self.replacedOriginalBackup = replacedOriginalBackup
        }
    }

    // MARK: - Operation Result

    /// 文件操作的统一返回结果：包含成功项和失败项。
    /// `successes` 记录每一项操作前后的 URL 映射，供上层撤销管理器构造反向操作。
    /// `failures` 存储失败项的 URL 和错误描述（使用 String 而非 Error 以满足 Sendable）。
    public struct TransferResult: Sendable {
        public var successes: [(source: URL, destination: URL)] = []
        public var failures: [(URL, String)] = []
        /// 发生了 replace 操作的条目；Undo 时需要恢复 `replacedOriginalBackup`
        public var replaceRecords: [ReplaceRecord] = []
        /// 用户是否在中途点击了「停止」，用于上层决定是否需要额外提示
        public var userStopped: Bool = false

        public init() {}
    }

    // MARK: Collision-rename (unified)

    /// The single collision-rename primitive. Returns the first
    /// non-existing URL under `folder` formed from `stem` (+ optional
    /// `extension`), trying `stem`, then `stem 2`, `stem 3`, … up to
    /// `cap`. On exhaustion returns `nil` so the caller can apply its own
    /// fallback (timestamp, original target, …) — the four legacy helpers
    /// disagreed on that fallback, so it stays caller-owned.
    ///
    /// `includePrimary` controls whether the bare `stem` (n == 1) is
    /// offered first. Paste/duplicate/drop always start from " 2" because
    /// the conflict that triggered the rename already proved the bare name
    /// is taken; compress/extract try the bare `<stem>.zip` / `<stem>`
    /// first because they call in unconditionally.
    ///
    /// `fileExists` is injected for testability and defaults to
    /// `FileManager.default`. The unified cap is **999** (the higher of the
    /// two legacy caps — paste/duplicate used 500, the rest used 999).
    public static func uniqueDestination(
        in folder: URL,
        stem: String,
        extension ext: String = "",
        includePrimary: Bool,
        cap: Int = 999,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        func candidate(_ suffixed: String) -> URL {
            folder.appendingPathComponent(
                ext.isEmpty ? suffixed : "\(suffixed).\(ext)"
            )
        }
        if includePrimary {
            let primary = candidate(stem)
            if !fileExists(primary.path) { return primary }
        }
        guard cap >= 2 else { return nil }
        for n in 2...cap {
            let c = candidate("\(stem) \(n)")
            if !fileExists(c.path) { return c }
        }
        return nil
    }

    /// Conflict-rename for an existing source URL being copied/moved into
    /// `folder` (paste / duplicate / drop). Splits the source's
    /// stem/extension, then funnels through `uniqueDestination`. Starts
    /// from " 2" (the bare name is the conflict that triggered this) and
    /// falls back to a `stem-<timestamp>.ext` name on cap exhaustion —
    /// matching the legacy `uniqueDestination(for:in:)` exactly.
    public static func conflictRenamedDestination(
        for source: URL,
        in folder: URL,
        cap: Int = 999,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: () -> Date = Date.init
    ) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        if let resolved = uniqueDestination(
            in: folder,
            stem: stem,
            extension: ext,
            includePrimary: false,
            cap: cap,
            fileExists: fileExists
        ) {
            return resolved
        }
        let stamp = Int(now().timeIntervalSince1970)
        let fallback = ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
        return folder.appendingPathComponent(fallback)
    }

    /// New-folder / generic-target collision rename: appends " 2", " 3", …
    /// before the extension of `target` itself. Returns `target` unchanged
    /// on exhaustion — matching the legacy instance `uniqueDestination(for:)`.
    public static func uniqueTargetDestination(
        for target: URL,
        cap: Int = 999,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        guard fileExists(target.path) else { return target }
        let folder = target.deletingLastPathComponent()
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        if let resolved = uniqueDestination(
            in: folder,
            stem: stem,
            extension: ext,
            includePrimary: false,
            cap: cap,
            fileExists: fileExists
        ) {
            return resolved
        }
        return target
    }

    /// `<stem>.zip`, then `<stem> 2.zip`, … under `parent`. Falls back to
    /// `<stem> <timestamp>.zip` on cap exhaustion — matching the legacy
    /// `uniqueZipDestination(in:stem:)` (space before the stamp, not dash).
    public static func uniqueZipDestination(
        in parent: URL,
        stem: String,
        cap: Int = 999,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: () -> Date = Date.init
    ) -> URL {
        if let resolved = uniqueDestination(
            in: parent,
            stem: stem,
            extension: "zip",
            includePrimary: true,
            cap: cap,
            fileExists: fileExists
        ) {
            return resolved
        }
        let stamp = Int(now().timeIntervalSince1970)
        return parent.appendingPathComponent("\(stem) \(stamp).zip")
    }

    /// Extraction-folder naming: `stem`, then `stem 2`, … under `parent`.
    /// Falls back to `stem <timestamp>` on cap exhaustion — matching the
    /// legacy `uniqueExtractionDirectory(in:stem:)`.
    public static func uniqueExtractionDirectory(
        in parent: URL,
        stem: String,
        cap: Int = 999,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: () -> Date = Date.init
    ) -> URL {
        if let resolved = uniqueDestination(
            in: parent,
            stem: stem,
            extension: "",
            includePrimary: true,
            cap: cap,
            fileExists: fileExists
        ) {
            return resolved
        }
        let stamp = Int(now().timeIntervalSince1970)
        return parent.appendingPathComponent("\(stem) \(stamp)")
    }

    // MARK: Copy / move / duplicate / delete

    /// Copy or move `sources` into `destinationFolder` with Finder-style
    /// conflict auto-rename and self-/descendant-drop rejection. Mirrors
    /// the old `acceptDrop` / `pasteFromPasteboard` detached-loop body.
    ///
    /// Per source:
    ///   - skips a no-op self-drop (`source == dest` after standardizing),
    ///   - auto-renames on an existing destination via `conflictRenamedDestination`,
    ///   - rejects dropping a folder into itself or any descendant
    ///     (checked against the *post-rename* dest),
    ///   - `move == false` copies, otherwise moves.
    ///
    /// Returns the per-item failures; the operation continues past each.
    @discardableResult
    public static func transfer(
        _ sources: [URL],
        into destinationFolder: URL,
        move: Bool,
        normalizeHangul: Bool = false,
        fileManager: FileManager = .default
    ) -> TransferResult {
        var result = TransferResult()
        for source in sources {
            var dest = destinationFolder.appendingPathComponent(source.lastPathComponent)
            // 只有 move 场景下「把文件放回自己所在目录」才是 no-op 直接跳过；
            // copy 场景下需要生成 " 2" 后缀副本（如同目录 Cmd+C/V），不能跳过。
            if move, source.standardizedFileURL == dest.standardizedFileURL { continue }
            if fileManager.fileExists(atPath: dest.path) {
                dest = conflictRenamedDestination(
                    for: source,
                    in: destinationFolder,
                    fileExists: { fileManager.fileExists(atPath: $0) }
                )
            }
            if dest.path.hasPrefix(source.path + "/") { continue }
            do {
                if move {
                    try fileManager.moveItem(at: source, to: dest)
                } else {
                    try fileManager.copyItem(at: source, to: dest)
                }
                normalizeIfRequested(dest, enabled: normalizeHangul)
                result.successes.append((source: source, destination: dest))
            } catch {
                result.failures.append((source, error.localizedDescription))
            }
        }
        return result
    }

    /// After a successful copy/move/duplicate, rename the resulting file
    /// to NFC form on disk when `enabled` and its name is decomposed
    /// Hangul (NFD). A rename failure is swallowed — the transfer itself
    /// already succeeded, so the worst case is the on-disk name stays NFD
    /// rather than the whole operation reporting failure.
    private static func normalizeIfRequested(_ url: URL, enabled: Bool) {
        guard enabled else { return }
        _ = HangulNFCFilename.renameToNFC(url)
    }

    /// Duplicate each source in place with a Finder-style " 2" / " 3"
    /// suffix. Mirrors the old `duplicate(_:)` detached-loop body.
    /// Returns per-item failures; continues past each.
    @discardableResult
    public static func duplicate(
        _ sources: [URL],
        normalizeHangul: Bool = false,
        fileManager: FileManager = .default
    ) -> TransferResult {
        var result = TransferResult()
        for source in sources {
            let parent = source.deletingLastPathComponent()
            let dest = conflictRenamedDestination(
                for: source,
                in: parent,
                fileExists: { fileManager.fileExists(atPath: $0) }
            )
            do {
                try fileManager.copyItem(at: source, to: dest)
                normalizeIfRequested(dest, enabled: normalizeHangul)
                result.successes.append((source: source, destination: dest))
            } catch {
                result.failures.append((source, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: Safe Replace

    /// 安全地将 `source` 替换到 `destination` 位置，保证失败时 `destination` 原状不丢失。
    ///
    /// 两阶段流程：
    ///   1. 先把目标位置的旧文件 move 到同盘的备份临时目录（原子、快速）
    ///   2. 再 copy/move source → destination
    ///      - 成功：返回 ReplaceRecord（含备份路径，交给 Undo 栈管理生命周期）
    ///      - 失败：把备份移回原位，清理临时目录，抛错
    ///
    /// 不追求跨盘真正原子，只保证任何异常路径都不会让用户丢失旧目标文件。
    ///
    /// - Parameters:
    ///   - source: 新文件（或文件夹）URL
    ///   - destination: 要被替换的旧目标 URL（此位置必须已存在文件）
    ///   - move: true 表示「剪切」（source 在成功后会被移除），false 表示「复制」
    ///   - fileManager: 注入用，测试时可替换
    ///   - now: 注入时间戳，测试时可固定
    /// - Returns: ReplaceRecord，包含 source / destination / 备份位置
    public static func safeReplaceItem(
        from source: URL,
        to destination: URL,
        move: Bool,
        fileManager: FileManager = .default,
        now: () -> Date = Date.init
    ) throws -> ReplaceRecord {
        // 前置断言：destination 必须存在（否则没有"替换"可言）
        guard fileManager.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "mq-dir.safeReplace",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "目标位置不存在，无法执行替换"]
            )
        }

        let destinationFolder = destination.deletingLastPathComponent()
        let destinationName = destination.lastPathComponent
        let stamp = Int(now().timeIntervalSince1970)
        let unique = UUID().uuidString.prefix(6)

        // 阶段 0：在目标目录下创建一个临时备份目录（同盘，后面的 move 都是原子的）
        // 目录名格式：.mqdir_replace_backup_<timestamp>_<uuid6>
        let backupDirName = ".mqdir_replace_backup_\(stamp)_\(unique)"
        let backupDir = destinationFolder.appendingPathComponent(backupDirName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            // 备份目录都建不起来：直接抛错，不碰源和目标，安全
            throw NSError(
                domain: "mq-dir.safeReplace",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "创建备份目录失败：\(error.localizedDescription)"]
            )
        }

        // 备份路径（放在 backupDir 内，保留原文件名以便人类识别）
        let backupURL = backupDir.appendingPathComponent(destinationName)

        // 阶段 1：把旧目标 move 到 backupURL
        do {
            try fileManager.moveItem(at: destination, to: backupURL)
        } catch {
            // 移动旧文件失败：尝试删 backupDir（大概率还是空的），然后抛错
            // destination 没动，用户数据安全
            try? fileManager.removeItem(at: backupDir)
            throw NSError(
                domain: "mq-dir.safeReplace",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "备份旧文件失败：\(error.localizedDescription)"]
            )
        }

        // 阶段 2：copy / move source → destination
        do {
            if move {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            // 写入新文件失败 → 关键：把 backupURL 里的旧文件移回原位，保证旧目标不丢失
            do {
                try fileManager.moveItem(at: backupURL, to: destination)
            } catch let rollbackError {
                // 极端：rollback 也失败（极少发生）→ 此时 backupURL 里的备份仍在，
                // 但 destination 空了。把 backupDir 路径写入错误信息提示用户手动恢复。
                throw NSError(
                    domain: "mq-dir.safeReplace",
                    code: -4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "写入新文件失败，且回滚旧文件也失败：\(rollbackError.localizedDescription)。" +
                            "旧文件备份仍保留在：\(backupURL.path)，请手动处理。"
                    ]
                )
            }
            // rollback 成功 → 清理空的 backupDir，然后把原始写入错误抛出
            try? fileManager.removeItem(at: backupDir)
            throw NSError(
                domain: "mq-dir.safeReplace",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "写入新文件失败：\(error.localizedDescription)"]
            )
        }

        // 阶段 3：成功路径。backupURL 不删，交给 UndoManager 根据栈生命周期管理。
        // 返回 ReplaceRecord，source = 源文件，destination = 写入后的目标，backup = 备份
        return ReplaceRecord(
            source: source,
            destination: destination,
            replacedOriginalBackup: backupURL
        )
    }

    // MARK: Transfer with Collision Policy

    /// 带冲突策略回调的复制/移动批量操作 — 纯同步，不做线程调度，异步由调用层（ViewModel）负责。
    ///
    /// 与旧 `transfer()` 区别：
    ///   - 遇到同名冲突时**不自动 rename**，而是根据 `policy` 决定；
    ///     `.ask` 时调用 `onCollision` 同步回调（由上层负责弹窗/返回决策）。
    ///   - 决策 `.stop` 会立即终止整个 for 循环并把 `userStopped` 置为 true。
    ///   - 决策 `.replace` 通过 `safeReplaceItem()` 走两阶段安全替换。
    ///   - 决策 `.keepBoth` 复用旧的 `conflictRenamedDestination()`。
    ///
    /// 旧 `transfer()` 保持不变，供 duplicate / 压缩 / 解压 / 撤销 内部路径继续使用
    /// （这些路径不需要弹用户冲突框）。
    ///
    /// - Parameters:
    ///   - sources: 待复制/移动的源 URL 数组
    ///   - destinationFolder: 目标目录
    ///   - move: true=剪切，false=复制
    ///   - initialPolicy: 初始策略，一般默认 `.ask`
    ///   - onCollision: 策略为 .ask 时的同步回调；上层在本回调内同步弹 NSAlert 并返回
    ///                  (决策, 是否应用到全部)。**本函数是同步的，回调也同步执行。**
    ///   - normalizeHangul: 是否在写完后 NFC 归一化韩文文件名
    ///   - fileManager: 注入 FileManager
    ///   - now: 注入时间戳
    /// - Returns: TransferResult，同旧版但包含 replaceRecords / userStopped 新字段
    @discardableResult
    public static func transfer(
        _ sources: [URL],
        into destinationFolder: URL,
        move: Bool,
        initialPolicy: CollisionPolicy = .ask,
        onCollision: (
            _ source: URL,
            _ existingDestination: URL
        ) -> (decision: CollisionDecision, applyToAll: Bool),
        normalizeHangul: Bool = false,
        fileManager: FileManager = .default,
        now: () -> Date = Date.init
    ) -> TransferResult {
        var result = TransferResult()
        // 初始策略；用户一旦勾选「应用到全部」后切换到 applyXxx 并一直复用
        var policy: CollisionPolicy = initialPolicy

        for source in sources {
            // 目标路径 = 目标目录 / 源文件名
            var dest = destinationFolder.appendingPathComponent(source.lastPathComponent)

            // ----------------------------------------------------------
            // Self-drop 检查：保持与旧 transfer() 完全一致
            // - move 且放回自己所在目录 → no-op，直接跳过
            // - copy 放回自己所在目录 → 不跳过（相当于同目录 Cmd+C/V，需要生成副本或走冲突策略）
            // ----------------------------------------------------------
            if move, source.standardizedFileURL == dest.standardizedFileURL { continue }

            // ----------------------------------------------------------
            // Descendant-drop 检查：文件夹不能放进自己的子孙目录
            // ----------------------------------------------------------
            let sourcePath = source.standardizedFileURL.path
            if dest.path.hasPrefix(sourcePath + "/") { continue }

            // ----------------------------------------------------------
            // 无冲突路径 → 直接 copy/move
            // ----------------------------------------------------------
            if !fileManager.fileExists(atPath: dest.path) {
                do {
                    if move {
                        try fileManager.moveItem(at: source, to: dest)
                    } else {
                        try fileManager.copyItem(at: source, to: dest)
                    }
                    normalizeIfRequested(dest, enabled: normalizeHangul)
                    result.successes.append((source: source, destination: dest))
                } catch {
                    result.failures.append((source, error.localizedDescription))
                }
                continue // 下一个文件
            }

            // ----------------------------------------------------------
            // 有冲突：根据当前 policy 决定下一步
            // ----------------------------------------------------------
            var decision: CollisionDecision
            switch policy {
            case .ask:
                // 调用同步回调（上层负责弹 NSAlert，这里同步阻塞等待返回）
                let (userDecision, applyToAll) = onCollision(source, dest)
                decision = userDecision
                // 「应用到全部」对 stop 无意义（stop 直接终止整个任务）
                if applyToAll {
                    switch decision {
                    case .keepBoth: policy = .applyKeepBoth
                    case .replace:  policy = .applyReplace
                    case .stop:     break // stop 直接 break out，不设 policy
                    }
                }
            case .applyKeepBoth:
                decision = .keepBoth
            case .applyReplace:
                decision = .replace
            }

            // ----------------------------------------------------------
            // 执行决策
            // ----------------------------------------------------------
            switch decision {
            case .stop:
                // 用户点了停止 → 终止整个 transfer，不再处理后续文件
                result.userStopped = true
                return result

            case .keepBoth:
                // 复用旧的 conflictRenamedDestination 生成 " 2"/" 3" 后缀
                let renamed = conflictRenamedDestination(
                    for: source,
                    in: destinationFolder,
                    fileExists: { fileManager.fileExists(atPath: $0) },
                    now: now
                )
                do {
                    if move {
                        try fileManager.moveItem(at: source, to: renamed)
                    } else {
                        try fileManager.copyItem(at: source, to: renamed)
                    }
                    normalizeIfRequested(renamed, enabled: normalizeHangul)
                    result.successes.append((source: source, destination: renamed))
                } catch {
                    result.failures.append((source, error.localizedDescription))
                }

            case .replace:
                // 两阶段安全替换
                do {
                    let record = try safeReplaceItem(
                        from: source,
                        to: dest,
                        move: move,
                        fileManager: fileManager,
                        now: now
                    )
                    normalizeIfRequested(dest, enabled: normalizeHangul)
                    result.replaceRecords.append(record)
                    result.successes.append((source: source, destination: dest))
                } catch {
                    result.failures.append((source, error.localizedDescription))
                }
            }
        }

        return result
    }

    /// Move each URL to the trash via `FileManager.trashItem`. Mirrors the
    /// old `moveToTrash(_:)` loop. Returns per-item failures; continues
    /// past each. (The AppKit recycle-sound path stays in the VM — this is
    /// pure Foundation.)
    @discardableResult
    public static func moveToTrash(
        _ urls: [URL],
        fileManager: FileManager = .default
    ) -> TransferResult {
        var result = TransferResult()
        for url in urls {
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as? URL {
                    result.successes.append((source: url, destination: trashURL))
                } else {
                    result.successes.append((source: url, destination: url))
                }
            } catch {
                result.failures.append((url, error.localizedDescription))
            }
        }
        return result
    }

    /// Permanently remove each URL via `FileManager.removeItem`. Mirrors
    /// the old `permanentlyDelete(_:)` detached loop. Returns per-item
    /// failures; continues past each. The destructive NSAlert confirm
    /// stays in the VM.
    @discardableResult
    public static func permanentlyDelete(
        _ urls: [URL],
        fileManager: FileManager = .default
    ) -> TransferResult {
        var result = TransferResult()
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                result.failures.append((url, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: New folder / rename

    /// Create a fresh directory at `target`, auto-renaming on collision
    /// (" 2", " 3", …). Returns the URL that was actually created, or
    /// throws if `createDirectory` fails. Mirrors `createNewFolder`'s
    /// mechanics minus the reload.
    @discardableResult
    public static func createDirectory(
        at target: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resolved = uniqueTargetDestination(
            for: target,
            fileExists: { fileManager.fileExists(atPath: $0) }
        )
        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: false)
        return resolved
    }

    /// Error surfaced by `rename` when the destination already exists.
    public enum RenameError: Error, Equatable {
        case destinationExists(name: String)
    }

    /// Rename `source` to `newName` within its parent folder. Refuses to
    /// overwrite an existing sibling (throws `RenameError.destinationExists`).
    /// Returns the new URL on success. Mirrors `commitRename`'s mechanics;
    /// the trim / empty / unchanged guards stay in the VM (they touch
    /// `renameDraft` / `entry.name`).
    @discardableResult
    public static func rename(
        _ source: URL,
        to newName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fileManager.fileExists(atPath: dest.path) else {
            throw RenameError.destinationExists(name: newName)
        }
        try fileManager.moveItem(at: source, to: dest)
        return dest
    }

    // MARK: Compress

    /// Why a compress request can't run before any Process spins up.
    public enum CompressError: Error, Equatable {
        /// Selection spanned more than one parent folder — zip's relative
        /// pathing assumes a single working directory.
        case crossFolder
    }

    /// The `stem` Finder would name a compress destination: a single
    /// directory keeps its name, a single file drops its extension, and a
    /// multi-selection becomes "Archive".
    public static func compressionStem(forSingleDirectory isDirectory: Bool, url: URL) -> String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// Validate + plan a compress of `urls` (paired with their `isDirectory`
    /// flags) into a single .zip in their shared parent. Rejects a
    /// cross-folder selection (`CompressError.crossFolder`). Returns the
    /// parent folder, the chosen unique `.zip` destination, and the source
    /// names (last path components) to pass to `runCompression`.
    public static func planCompression(
        urls: [(url: URL, isDirectory: Bool)],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: () -> Date = Date.init
    ) throws -> (parent: URL, destination: URL, sourceNames: [String])? {
        guard let first = urls.first else { return nil }
        let parent = first.url.deletingLastPathComponent()
        let sameParent = urls.allSatisfy { $0.url.deletingLastPathComponent() == parent }
        guard sameParent else { throw CompressError.crossFolder }

        let stem: String
        if urls.count == 1 {
            stem = compressionStem(forSingleDirectory: first.isDirectory, url: first.url)
        } else {
            stem = "Archive"
        }
        let destination = uniqueZipDestination(
            in: parent,
            stem: stem,
            fileExists: fileExists,
            now: now
        )
        return (parent, destination, urls.map { $0.url.lastPathComponent })
    }

    /// Drive `/usr/bin/zip` with `currentDirectoryURL = parent` so the
    /// archive stores relative paths. `-r` recurses, `-y` preserves
    /// symlinks, `-q` silences per-file progress. Throws on non-zero exit
    /// with the trimmed stderr (or `exit N`) as the message — identical to
    /// the legacy `runCompression`.
    public static func runCompression(
        parent: URL,
        sources: [String],
        destination: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-y", "-q", destination.path] + sources
        process.currentDirectoryURL = parent
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let trimmed = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed
            throw NSError(
                domain: "mq-dir.compress",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: summary]
            )
        }
    }

    // MARK: Extract

    /// Archive kinds we recognize; drives both the extension test in
    /// `archiveKind(for:)` and the tool/argument selection in
    /// `runExtraction`.
    public enum ArchiveKind: Sendable {
        case zip
        case tar
        case tarGz
    }

    /// Map a URL's extension to a known archive kind, case-insensitive.
    /// `.tgz` and `.tar.gz` are gzip-compressed tar; `.tar.gz` is detected
    /// from the full filename, not just the last extension.
    public static func archiveKind(for url: URL) -> ArchiveKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }

    /// Strip the archive extension so the extraction folder is named after
    /// the contents. `.tar.gz` loses both extensions; everything else loses
    /// the last one.
    public static func archiveStem(for url: URL, kind: ArchiveKind) -> String {
        let base = url.lastPathComponent
        switch kind {
        case .tarGz where base.lowercased().hasSuffix(".tar.gz"):
            return String(base.dropLast(".tar.gz".count))
        case .zip, .tar, .tarGz:
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// True when every entry's URL is a recognized archive *and* none is a
    /// directory. Empty input returns false. Takes `(url, isDirectory)`
    /// pairs so the pure logic lives here while `FileEntry` stays in the VM.
    public static func canExtract(_ entries: [(url: URL, isDirectory: Bool)]) -> Bool {
        guard !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            archiveKind(for: entry.url) != nil && !entry.isDirectory
        }
    }

    /// Drive ditto/tar against the archive. ditto's `-x -k` handles zip
    /// (preserves resource forks); tar's `-xf` handles plain tar and
    /// `-xzf` picks up gzip for `.tar.gz`/`.tgz`. `destination` must NOT
    /// exist yet — it's created here with the right mode bits. Throws on
    /// non-zero exit with the trimmed stderr — identical to the legacy
    /// `runExtraction`.
    public static func runExtraction(
        kind: ArchiveKind,
        archive: URL,
        destination: URL
    ) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
        case .tar:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", destination.path]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", destination.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let trimmed = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed
            throw NSError(
                domain: "mq-dir.extract",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: summary]
            )
        }
    }

    /// Extract one archive into a fresh sibling folder named after its
    /// stem (with " 2", " 3", … collision rename). Bundles
    /// `archiveStem` + `uniqueExtractionDirectory` + `runExtraction` so the
    /// VM's batch loop stays a thin per-archive call. Throws on failure.
    /// Returns the destination folder that was created.
    @discardableResult
    public static func extract(
        archive: URL,
        kind: ArchiveKind,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let stem = archiveStem(for: archive, kind: kind)
        let dest = uniqueExtractionDirectory(in: parent, stem: stem, fileExists: fileExists)
        try runExtraction(kind: kind, archive: archive, destination: dest)
        return dest
    }
}
