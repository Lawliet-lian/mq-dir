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

    // MARK: - Operation Result

    /// 文件操作的统一返回结果：包含成功项和失败项。
    /// `successes` 记录每一项操作前后的 URL 映射，供上层撤销管理器构造反向操作。
    /// `failures` 存储失败项的 URL 和错误描述（使用 String 而非 Error 以满足 Sendable）。
    public struct TransferResult: Sendable {
        public var successes: [(source: URL, destination: URL)] = []
        public var failures: [(URL, String)] = []

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
