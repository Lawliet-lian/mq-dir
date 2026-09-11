import Foundation

struct FolderComparisonRow: Identifiable, Sendable {
    /// 单行对比结果的状态枚举，rawValue 即为 UI 上显示的中文文案。
    enum Status: String, Sendable {
        /// 只在左侧文件夹存在
        case leftOnly = "仅左侧存在"
        /// 只在右侧文件夹存在
        case rightOnly = "仅右侧存在"
        /// 两侧都有同名文件，但元数据（大小/修改时间/是否文件夹）不一致
        case different = "元数据不同"
        /// 两侧都有，且大小和修改时间都一致
        case same = "元数据相同"
        /// 两侧都是同名文件夹 —— 本工具目前不递归进入子目录对比
        case folder = "同为文件夹（未对比内容）"
    }
    let id: String
    let name: String
    let left: URL?
    let right: URL?
    let status: Status
}

enum FolderComparison {
    static func compare(left: URL, right: URL, cancellation: ProcessRunner.Cancellation) throws -> [FolderComparisonRow] {
        let service = FileSystemService()
        let leftEntries = try service.enumerateDirectory(at: left, includingHidden: true, isCancelled: { cancellation.isCancelled })
        let rightEntries = try service.enumerateDirectory(at: right, includingHidden: true, isCancelled: { cancellation.isCancelled })
        let a = Dictionary(leftEntries.map { (Data($0.name.utf8), $0) }, uniquingKeysWith: { _, last in last })
        let b = Dictionary(rightEntries.map { (Data($0.name.utf8), $0) }, uniquingKeysWith: { _, last in last })
        return Set(a.keys).union(b.keys).map { key in
            let left = a[key], right = b[key]
            let status: FolderComparisonRow.Status
            if left == nil { status = .rightOnly }
            else if right == nil { status = .leftOnly }
            else if left!.isDirectory && right!.isDirectory { status = .folder }
            else if left!.isDirectory != right!.isDirectory || left!.size != right!.size || left!.modificationDate != right!.modificationDate { status = .different }
            else { status = .same }
            return FolderComparisonRow(id: key.base64EncodedString(), name: (left ?? right)!.name,
                left: left?.url, right: right?.url, status: status)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
