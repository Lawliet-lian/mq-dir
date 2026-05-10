import Foundation

struct FileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let kind: String
    let isHidden: Bool
    /// Finder tags attached to this URL (`URLResourceKey.tagNamesKey`).
    /// Localised to the user's system language — "Red" vs "빨강" for
    /// the same colour tag — which is why the dot rendering keys off
    /// `labelNumber` instead of matching tag-name strings.
    let tagNames: [String]
    /// Finder colour-label index (`URLResourceKey.labelNumberKey`).
    /// `0` means "no label", `1...7` map to gray/green/purple/blue/
    /// yellow/red/orange in macOS's Finder palette. Only the most
    /// recent system label survives in this field — multi-tag rows
    /// drop their non-primary labels here but still carry the
    /// per-name tags in `tagNames`.
    let labelNumber: Int

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modificationDate: Date?,
        kind: String,
        isHidden: Bool,
        tagNames: [String] = [],
        labelNumber: Int = 0
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.kind = kind
        self.isHidden = isHidden
        self.tagNames = tagNames
        self.labelNumber = labelNumber
    }

    // URL-based id avoids collisions on case-insensitive APFS volumes where
    // `url.path` would normalize "Foo.txt" and "foo.txt" to the same string.
    var id: URL { url }
}

enum FileEntrySortKey: String, CaseIterable, Codable, Sendable {
    case name
    case modified
    case size
    case kind
}

enum FileEntrySorter {
    static func sorted(
        _ entries: [FileEntry],
        by key: FileEntrySortKey,
        ascending: Bool,
        foldersOnTop: Bool = true
    ) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if foldersOnTop, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let comparison: ComparisonResult = switch key {
            case .name:
                lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                compareOptional(lhs.modificationDate, rhs.modificationDate)
            case .size:
                compareOptional(lhs.size, rhs.size)
            case .kind:
                lhs.kind.localizedStandardCompare(rhs.kind)
            }

            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }
}

