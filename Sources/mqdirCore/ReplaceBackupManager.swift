import Foundation

/// Centralized manager for replace backups used by Finder-style "Replace"
/// operations.
///
/// Design goals for this manager:
/// - Store every replace backup under the app cache directory instead of next
///   to the user's actual files/folders.
/// - Keep the filesystem mechanics in `mqdirCore` so UI / App lifecycle code
///   can call into a pure Foundation layer.
/// - Support the existing undo/redo model where backup ownership moves between
///   undo and redo records by swapping the current destination with a stored
///   backup snapshot.
public enum ReplaceBackupManager {

    // MARK: - Root Directory

    /// Resolve the canonical replace-backup root:
    /// `~/Library/Caches/mq-dir/replace-backups/`
    ///
    /// The caller can inject `cachesDirectory` in tests so the test suite does
    /// not pollute the real user cache directory. Production code always uses
    /// the default `FileManager` lookup and therefore stays aligned with the
    /// requested cache location.
    public static func replaceBackupsRoot(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) throws -> URL {
        let cacheBase = cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let appCache = cacheBase.appendingPathComponent("mq-dir", isDirectory: true)
        let root = appCache.appendingPathComponent("replace-backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Return true when `url` is inside the canonical replace-backup root.
    /// This guards delete operations so we only remove folders that belong to
    /// this backup mechanism.
    public static func isManagedBackupItem(
        _ url: URL,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) -> Bool {
        guard let root = try? replaceBackupsRoot(fileManager: fileManager, cachesDirectory: cachesDirectory) else {
            return false
        }
        let standardizedRoot = root.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        return standardizedURL == standardizedRoot || standardizedURL.hasPrefix(standardizedRoot + "/")
    }

    // MARK: - Backup Creation

    /// Create a fresh backup directory using a UUID folder name under the
    /// replace-backup root and return that directory URL.
    public static func createBackupDirectory(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) throws -> URL {
        let root = try replaceBackupsRoot(fileManager: fileManager, cachesDirectory: cachesDirectory)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    /// Move the current destination item into a managed backup directory and
    /// return the backup item URL.
    ///
    /// Example:
    /// - destination: `/Users/me/Desktop/a.txt`
    /// - returned backup item:
    ///   `~/Library/Caches/mq-dir/replace-backups/<UUID>/a.txt`
    ///
    /// The destination item itself is moved, not copied, so we preserve the
    /// existing "safe replace" semantics: first secure the old target, then
    /// write the new content.
    public static func stageExistingDestinationForReplace(
        _ destination: URL,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) throws -> URL {
        let backupDir = try createBackupDirectory(fileManager: fileManager, cachesDirectory: cachesDirectory)
        let backupItem = backupDir.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        do {
            try fileManager.moveItem(at: destination, to: backupItem)
            return backupItem
        } catch {
            // If we fail before the backup becomes usable, remove the empty
            // UUID directory so we never leak an orphan directory for a failed
            // staging attempt.
            try? fileManager.removeItem(at: backupDir)
            throw error
        }
    }

    // MARK: - Swap For Undo / Redo

    /// Swap the current destination content with an existing managed backup.
    ///
    /// This powers both Undo and Redo without redesigning the current data
    /// model:
    /// 1. Move the current destination item into a fresh managed backup.
    /// 2. Move the provided `backupItem` back to the destination path.
    /// 3. Delete the now-empty old backup directory.
    /// 4. Return the newly created backup item URL so the opposite stack record
    ///    can take ownership of it.
    ///
    /// If step 2 fails, step 1 is rolled back so the destination remains
    /// unchanged and no orphan backup is left behind.
    public static func swapDestinationWithBackup(
        destination: URL,
        backupItem: URL,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) throws -> URL {
        let newBackup = try createBackupDirectory(fileManager: fileManager, cachesDirectory: cachesDirectory)
        let newBackupItem = newBackup.appendingPathComponent(destination.lastPathComponent, isDirectory: false)

        do {
            try fileManager.moveItem(at: destination, to: newBackupItem)
        } catch {
            try? fileManager.removeItem(at: newBackup)
            throw error
        }

        do {
            try fileManager.moveItem(at: backupItem, to: destination)
        } catch {
            // If the second move fails, restore the destination to the exact
            // path it had before the swap attempt and remove the temporary
            // backup directory created for the failed swap.
            try? fileManager.moveItem(at: newBackupItem, to: destination)
            try? fileManager.removeItem(at: newBackup)
            throw error
        }

        // The old backup item has been consumed by the move above, so its UUID
        // parent directory should now be empty. Remove it immediately to avoid
        // stale cache directories staying around while ownership has already
        // moved to the newly returned backup item.
        removeBackup(for: backupItem, fileManager: fileManager, cachesDirectory: cachesDirectory)

        return newBackupItem
    }

    // MARK: - Cleanup

    /// Remove the UUID backup directory that owns the provided backup item.
    ///
    /// We delete the parent directory instead of the item itself so the cache
    /// root never accumulates empty UUID folders.
    public static func removeBackup(
        for backupItem: URL,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        let backupDir = backupItem.deletingLastPathComponent()
        guard isManagedBackupItem(backupDir, fileManager: fileManager, cachesDirectory: cachesDirectory) else {
            return
        }
        try? fileManager.removeItem(at: backupDir)
    }

    /// Remove every backup referenced by the provided replace records.
    public static func removeBackups(
        for records: [FileOperationService.ReplaceRecord],
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        for record in records {
            removeBackup(
                for: record.replacedOriginalBackup,
                fileManager: fileManager,
                cachesDirectory: cachesDirectory
            )
        }
    }

    /// Remove all replace backups under the cache root.
    ///
    /// Because replace undo is explicitly session-scoped, startup cleanup can
    /// safely delete everything under this root.
    public static func cleanupAllBackups(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        guard let root = try? replaceBackupsRoot(fileManager: fileManager, cachesDirectory: cachesDirectory) else {
            return
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Startup sweep for leftovers from a previous session, crash or forced
    /// quit. Since undo does not survive app restarts, every old backup is
    /// invalid and can be removed immediately.
    public static func cleanupLeftoverBackupsOnLaunch(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        cleanupAllBackups(fileManager: fileManager, cachesDirectory: cachesDirectory)
    }
}
