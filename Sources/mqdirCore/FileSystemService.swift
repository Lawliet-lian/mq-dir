import Foundation

struct FileSystemService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func enumerateDirectory(at url: URL, includingHidden: Bool = false) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isHiddenKey,
            .tagNamesKey,
            .labelNumberKey,
        ]

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includingHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: options
        )

        return try urls.map { childURL in
            let values = try childURL.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory ?? false
            let name = childURL.lastPathComponent
            let tagNames = values.tagNames ?? []
            let tagColors = Self.tagColors(for: childURL, names: tagNames)
            let hasCustomIcon = isDirectory && Self.folderHasCustomIcon(at: childURL)

            return FileEntry(
                url: childURL,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modificationDate: values.contentModificationDate,
                kind: kind(for: childURL, isDirectory: isDirectory),
                isHidden: values.isHidden ?? name.hasPrefix("."),
                tagNames: tagNames,
                labelNumber: values.labelNumber ?? 0,
                tagColors: tagColors,
                hasCustomIcon: hasCustomIcon
            )
        }
    }

    /// Recursive name search rooted at `url`. Visits every descendant via
    /// `FileManager.enumerator`, keeping entries whose name matches `query`
    /// case-insensitively. Errors on individual children are skipped so the
    /// walk doesn't abort on a single inaccessible subfolder. The
    /// `isCancelled` callback is polled periodically so a caller can stop a
    /// long walk when a fresher query supersedes it.
    func enumerateMatching(
        root: URL,
        query: String,
        includingHidden: Bool = false,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [FileEntry] {
        guard !query.isEmpty else { return [] }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isHiddenKey,
            .tagNamesKey,
            .labelNumberKey,
        ]

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includingHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var results: [FileEntry] = []
        var visited = 0

        for case let childURL as URL in enumerator {
            // Cheap cancellation check; avoid per-item lock overhead on big trees.
            visited &+= 1
            if visited & 0xFF == 0, isCancelled() { return results }

            let name = childURL.lastPathComponent
            // Match name first (cheap) so the resourceValues fetch
            // only fires for non-name candidates that still might
            // match by Finder tag. Tag-name matching covers the
            // sidebar's "click a tag" path on systems where the
            // tag is localised (e.g. "초록색") and so never appears
            // inside Latin-named files.
            let nameMatches = name.localizedCaseInsensitiveContains(query)
            let values = try? childURL.resourceValues(forKeys: keys)
            let tagMatches: Bool
            if nameMatches {
                tagMatches = false
            } else {
                tagMatches = (values?.tagNames ?? []).contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
            }
            guard nameMatches || tagMatches else { continue }

            let isDirectory = values?.isDirectory ?? false
            let tagNames = values?.tagNames ?? []
            let tagColors = Self.tagColors(for: childURL, names: tagNames)
            let hasCustomIcon = isDirectory && Self.folderHasCustomIcon(at: childURL)
            results.append(FileEntry(
                url: childURL,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? nil : (values?.fileSize).map(Int64.init),
                modificationDate: values?.contentModificationDate,
                kind: kind(for: childURL, isDirectory: isDirectory),
                isHidden: values?.isHidden ?? name.hasPrefix("."),
                tagNames: tagNames,
                labelNumber: values?.labelNumber ?? 0,
                tagColors: tagColors,
                hasCustomIcon: hasCustomIcon
            ))
        }

        return results
    }

    /// Pull per-tag colour indices from `com.apple.metadata:_kMDItemUserTags`.
    /// macOS stores Finder tags there as a binary plist of strings, each
    /// either `"TagName"` (no colour) or `"TagName\n<0-7>"` (coloured).
    /// `URLResourceKey.labelNumber` only surfaces the file's *primary*
    /// colour, which is why a row tagged Red+Blue used to render two
    /// identical grey dots — the second tag's colour was lost. Returns
    /// an array aligned with `names` so the dot renderer can paint each
    /// tag in its real Finder swatch.
    static func tagColors(for url: URL, names: [String]) -> [Int] {
        guard !names.isEmpty else { return [] }
        let parsed = parseUserTagsXattr(for: url)
        guard !parsed.isEmpty else {
            return Array(repeating: 0, count: names.count)
        }
        let colourByName = Dictionary(parsed, uniquingKeysWith: { first, _ in first })
        return names.map { colourByName[$0] ?? 0 }
    }

    /// Decode the raw xattr into `(name, colourIndex)` pairs. Defensive
    /// against malformed data — an unparseable index collapses to `0`
    /// (no colour) rather than blowing up the whole enumeration.
    private static func parseUserTagsXattr(for url: URL) -> [(String, Int)] {
        let path = url.path
        let key = "com.apple.metadata:_kMDItemUserTags"
        let length = getxattr(path, key, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buf -> ssize_t in
            guard let base = buf.baseAddress else { return -1 }
            return getxattr(path, key, base, length, 0, 0)
        }
        guard read == length else { return [] }
        guard let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entries = raw as? [String]
        else { return [] }
        return entries.map { entry -> (String, Int) in
            // Split once on the first newline. macOS only ever stores
            // a single trailing "\n<digit>"; treating the join as the
            // tag name keeps custom names containing newlines intact
            // even though Finder's UI doesn't expose that path.
            guard let newline = entry.firstIndex(of: "\n") else {
                return (entry, 0)
            }
            let name = String(entry[..<newline])
            let suffix = entry[entry.index(after: newline)...]
            let colour = Int(suffix).flatMap { (0...7).contains($0) ? $0 : nil } ?? 0
            return (name, colour)
        }
    }

    /// Cheap presence check for the `Icon\r` sentinel macOS writes inside
    /// any folder whose icon the user changed via Get Info → drag image.
    /// One `stat(2)` per folder; we deliberately don't load the actual
    /// icon here — that work belongs to the row view via
    /// `NSWorkspace.shared.icon(forFile:)`, which caches internally.
    static func folderHasCustomIcon(at url: URL) -> Bool {
        let iconPath = url.appendingPathComponent("Icon\r").path
        return FileManager.default.fileExists(atPath: iconPath)
    }

    private func kind(for url: URL, isDirectory: Bool) -> String {
        if isDirectory {
            return "Folder"
        }

        let ext = url.pathExtension
        if ext.isEmpty {
            return "Document"
        }

        return "\(ext.uppercased()) Document"
    }
}
