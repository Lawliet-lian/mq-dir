import Foundation

/// 单行对比结果：表示「左侧 URL 下的某个相对路径条目」和「右侧 URL 下同名相对路径条目」
/// 的对齐对比结果。
struct FolderComparisonRow: Identifiable, Sendable {
    /// 对比结果状态枚举，rawValue 即 UI 上直接展示的中文文案。
    enum Status: String, Sendable {
        /// 该名字只在左侧文件夹存在（第一层文件/直接子文件夹都算）。
        case leftOnly = "仅左侧存在"
        /// 该名字只在右侧文件夹存在。
        case rightOnly = "仅右侧存在"
        /// 同名条目都存在，但元数据不一致。可能是：一边是文件一边是文件夹、
        /// 文件大小不同、修改时间不同。
        case different = "元数据不同"
        /// 同名条目都存在，且元数据完全一致（类型、大小、修改时间）。
        case same = "元数据相同"
        /// 两边同名条目都是文件夹，且递归比对**所有子条目元数据**（不含文件内容）
        /// 后判定完全一致。
        case folderSame = "同为文件夹（内容一致）"
        /// 两边同名条目都是文件夹，但递归比对后发现有差异（子条目集合或子条目的
        /// 元数据有任何不同即判不同）。
        case folderDifferent = "同为文件夹（有差异）"
        /// 两边同名条目都是文件夹，但由于单侧条目总数超过 50,000 限制或递归过程
        /// 中出现读失败，为性能和可靠性考虑直接跳过不给出结论。
        /// 这种情况用户可以点「打开左边/右边」自己去 Finder 里手动比对。
        case folderTooLarge = "同为文件夹（条目过多，已跳过）"
    }
    let id: String
    let name: String
    let left: URL?
    let right: URL?
    let status: Status
}

enum FolderComparison {
    // MARK: - 公开入口

    /// 对比两个文件夹的第一层内容。
    /// - 对于同名文件：按（类型、大小、修改时间）三个维度判断是否相同。
    /// - 对于同名子文件夹：额外递归读取两边子树（仅限元数据，不读文件内容、不做 MD5）
    ///   对比后给出「内容一致 / 有差异 / 条目过多跳过」三种结论。
    /// - 所有比较都支持中途取消（通过 cancellation）。
    static func compare(
        left: URL,
        right: URL,
        cancellation: ProcessRunner.Cancellation
    ) throws -> [FolderComparisonRow] {
        let service = FileSystemService()
        let isCancelled = { cancellation.isCancelled }

        // 第 1 步：列出两边第一层的目录内容（含隐藏文件）。
        let leftEntries = try service.enumerateDirectory(
            at: left, includingHidden: true, isCancelled: isCancelled)
        let rightEntries = try service.enumerateDirectory(
            at: right, includingHidden: true, isCancelled: isCancelled)

        // 第 2 步：用文件名作为 key 建两个字典，便于 O(1) 对齐同名条目。
        // key 选择 Data(name.utf8) 而不是 String，避免大小写敏感系统上的
        // 潜在桥接差异。upstream 原版用 Data，这里保持一致。
        let a = Dictionary(leftEntries.map { (Data($0.name.utf8), $0) },
                           uniquingKeysWith: { _, last in last })
        let b = Dictionary(rightEntries.map { (Data($0.name.utf8), $0) },
                           uniquingKeysWith: { _, last in last })

        // 第 3 步：取两边文件名并集作为最终行的集合（保证无论哪一边独有都不漏）。
        return Set(a.keys).union(b.keys).map { key in
            let leftEntry = a[key]
            let rightEntry = b[key]
            let status: FolderComparisonRow.Status

            // 严格优先级顺序：左右独有 → 同为文件夹（递归判）→ 元数据不同 → 元数据相同。
            if leftEntry == nil {
                status = .rightOnly
            } else if rightEntry == nil {
                status = .leftOnly
            } else if leftEntry!.isDirectory && rightEntry!.isDirectory {
                // ★ 方案 C：同为文件夹时做递归子树元数据快照比对。
                status = Self.compareFolderSnapshots(
                    left: leftEntry!.url,
                    right: rightEntry!.url,
                    cancellation: cancellation
                )
            } else if leftEntry!.isDirectory != rightEntry!.isDirectory
                        || leftEntry!.size != rightEntry!.size
                        || leftEntry!.modificationDate != rightEntry!.modificationDate {
                status = .different
            } else {
                status = .same
            }

            // name 从左右任一存在的条目取（两者至少有一个非 nil）。
            let name = (leftEntry ?? rightEntry)!.name
            return FolderComparisonRow(
                id: key.base64EncodedString(),
                name: name,
                left: leftEntry?.url,
                right: rightEntry?.url,
                status: status
            )
        }.sorted {
            // 按 Finder 风格的本地化标准排序；同名时用 id 做兜底稳定排序。
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id
                                               : comparison == .orderedAscending
        }
    }

    // MARK: - 文件夹递归快照比对（方案 C 核心）

    /// 两个子文件夹的递归对比。返回三种结论之一：内容一致 / 有差异 / 过大跳过。
    /// 全程只读元数据（相对路径 + isDirectory + size + modDate），不读取任何文件
    /// 内容，不做哈希。
    private static func compareFolderSnapshots(
        left: URL,
        right: URL,
        cancellation: ProcessRunner.Cancellation
    ) -> FolderComparisonRow.Status {
        do {
            let isCancelled = { cancellation.isCancelled }
            // 收集左边整棵子树：key = 相对路径（UTF-8 Data），value = 元数据三元组。
            let leftSnapshot = try Self.recursivelyCollectEntries(
                root: left,
                isCancelled: isCancelled
            )
            // 如果左边已经命中过大跳过，立刻返回，避免再跑右边浪费时间。
            if case .tooLarge = leftSnapshot {
                return .folderTooLarge
            }

            let rightSnapshot = try Self.recursivelyCollectEntries(
                root: right,
                isCancelled: isCancelled
            )
            if case .tooLarge = rightSnapshot {
                return .folderTooLarge
            }

            // 两边都成功收集，用常规集合 + 逐 key 对比。
            guard case .collected(let lhs) = leftSnapshot,
                  case .collected(let rhs) = rightSnapshot else {
                return .folderTooLarge
            }
            // 1. 相对路径集合不同 → 有条目独缺或新增 → 有差异。
            if lhs.keys != rhs.keys {
                return .folderDifferent
            }
            // 2. 对每个共有的相对路径，检查元数据是否完全相同。
            for (pathKey, lhsMeta) in lhs {
                guard let rhsMeta = rhs[pathKey] else {
                    // keys 已经相等，理论上不会走到这里，防御式编程留一手。
                    return .folderDifferent
                }
                if lhsMeta != rhsMeta {
                    return .folderDifferent
                }
            }
            // 3. 集合相等 + 元数据全等 → 内容一致。
            return .folderSame
        } catch {
            // 任何异常（无权限、中途取消、子文件夹被并发删除等）都归到「过大跳过」
            // 让用户自行去 Finder 看，而不是阻塞整个对比。
            return .folderTooLarge
        }
    }

    /// 单个文件夹快照的收集结果：要么成功返回字典，要么超过条目上限返回 tooLarge。
    private enum SnapshotResult {
        case collected([Data: EntryMeta])
        case tooLarge
    }

    /// 单个条目的元数据（用来比较子文件夹内容是否一致）。
    /// 选择结构体而不是元组，方便做 Equatable 和语义化字段名。
    private struct EntryMeta: Equatable, Sendable {
        let isDirectory: Bool
        // 文件夹条目 size 在 macOS 上通常是 nil/0，我们统一用 Int64.min 占位，
        // 但对比时真正只看：isDirectory 相等、文件条目 size 相等（文件夹不看 size）
        // 以及 modificationDate 相等。不过为了简单直接，把文件夹 size 统一成 nil
        // 会更稳健。所以我们在构造时就把文件夹 size 清为 nil，然后对比时再判相等。
        let fileSize: Int64?
        let modificationDate: Date
    }

    /// 从根目录递归收集所有子条目（包括所有嵌套层级）。
    /// 三重防护：深度 ≤ 20、单侧条目数 ≤ 50,000、周期性检查 cancellation。
    private static func recursivelyCollectEntries(
        root: URL,
        isCancelled: @escaping () -> Bool
    ) throws -> SnapshotResult {
        // 最多往下 20 层；防止恶意符号链接环、极深嵌套目录导致栈爆或耗时过长。
        let maxDepth = 20
        // 单侧最多抓 5 万条目；超过就直接 tooLarge，用户手动去 Finder 里看。
        let maxEntries = 50_000
        // 和 FileSystemService 一样，用 URLResourceValues 预抓取，避免每文件二次 syscall。
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
        ]
        // .skipsPackageDescendants 跳过 .app/.framework 这类包内部，避免大量无用条目。
        // 隐藏文件我们依然枚举（保持和第一层一致的 includingHidden: true 语义）。
        let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: options,
            errorHandler: { _, _ in true }   // 任何单个子条目读失败都跳过去，不中断整棵树。
        ) else {
            // 根本建不出来 enumerator，通常是 root 不存在/无权限。归到 tooLarge。
            return .tooLarge
        }

        var snapshot = [Data: EntryMeta]()
        snapshot.reserveCapacity(1024)   // 预分配常见场景容量，减少 rehash。
        var count = 0

        while let childURL = enumerator.nextObject() as? URL {
            // 取消检查：每 32 个条目查一次，平衡响应性和开销。
            if count.isMultiple(of: 32), isCancelled() {
                throw NSError(domain: "FolderComparison", code: -999,
                              userInfo: [NSLocalizedDescriptionKey: "cancelled"])
            }

            // 深度限制：enumerator 自带 level 属性，超过 maxDepth 就跳过该目录
            // 的整棵子树（调用 skipDescendants）。
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            count += 1
            if count > maxEntries {
                return .tooLarge
            }

            // 计算「childURL 相对于 root 的相对路径」。
            // 注意：URL.relativePath 是**不带参数的只读属性**（返回文件系统的绝对路径
            // 字符串），没有 URL.relativePath(from:) 这个方法；之前误写成方法形式
            // 就会报 "Cannot call value of non-function type 'String'"。
            // 同样地，FileManager.DirectoryEnumerator 在 Swift 里也没有 public 的
            // relativePath 成员，所以最稳健、所有 macOS 版本都能用的方式就是：
            // 把 root 和 child 的 URL 都标准化（standardizedFileURL）后取路径
            // 字符串做前缀裁剪，得到形如 "SubA/SubB/file.txt" 的相对路径。
            let rootPath = root.standardizedFileURL.path
            let childPath = childURL.standardizedFileURL.path
            let relativePath: String
            if childPath.hasPrefix(rootPath) {
                // 去掉 root 前缀 + 前缀后面紧跟的那一个 "/"（如果有的话）
                var rel = childPath.dropFirst(rootPath.count)
                if rel.hasPrefix("/") { rel.removeFirst() }
                relativePath = String(rel)
            } else {
                // 理论上不会发生（enumerator 出的都是 root 子节点），
                // 但万一出现，直接退回完整路径做 key，保证至少能对齐。
                relativePath = childPath
            }
            let pathKey = Data(relativePath.utf8)

            // 读元数据。
            let values = try childURL.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory ?? false
            let size: Int64? = isDirectory ? nil : (values.fileSize.map(Int64.init) ?? nil)
            let modDate = values.contentModificationDate ?? .distantPast

            snapshot[pathKey] = EntryMeta(
                isDirectory: isDirectory,
                fileSize: size,
                modificationDate: modDate
            )
        }

        return .collected(snapshot)
    }
}
