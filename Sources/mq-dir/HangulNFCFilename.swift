import Foundation
import Darwin

/// Filesystem-level helper for renaming a single file from NFD to NFC
/// form on disk. Shared by the right-click "Normalize Filename to NFC"
/// action (`FolderBrowserViewModel.normalizeFilenamesToNFC`) and the
/// drag-out auto-normaliser (`AppKitFileDragModifier.startDrag`), so
/// both paths use the same correct implementation.
///
/// Why this exists instead of a one-liner around `FileManager.moveItem`:
///
/// 1. `URL(fileURLWithPath: nfcString)` and
///    `URL.appendingPathComponent(nfcString)` silently re-normalise
///    the path component to NFD on construction. The "NFC URL" you
///    think you handed to `moveItem(at:to:)` actually carries NFD
///    bytes by the time the underlying system call fires.
/// 2. APFS is normalisation-insensitive, so a rename from an NFD name
///    to a Foundation-renormalised NFD name reads as "rename to same
///    name" and is a silent no-op — the file's on-disk bytes stay
///    unchanged, even though `moveItem` reports success.
///
/// POSIX `rename(2)` takes raw C strings, so passing the NFC UTF-8
/// bytes directly forces APFS to rewrite the inode's name. The URL
/// returned to the caller is rebuilt via
/// `URL(string: "file://…<percent-encoded NFC>…")` because
/// `URL(fileURLWithPath:)` would re-NFD it on the way back into the
/// drag pasteboard — verified empirically, not from docs.
enum HangulNFCFilename {
    /// Rename the on-disk file at `url` from NFD to NFC. Returns the
    /// new NFC-preserving URL on success, `nil` if the name was
    /// already NFC or the rename failed (logged to stderr; the
    /// caller should treat `nil` as "skip — don't block the user").
    static func renameToNFC(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.isDecomposedRelativeToNFC else { return nil }
        let nfc = name.precomposedStringWithCanonicalMapping
        let dirPath = url.deletingLastPathComponent().path
        let srcPath = dirPath + "/" + name
        let dstPath = dirPath + "/" + nfc

        let rc = srcPath.withCString { s in
            dstPath.withCString { d in Darwin.rename(s, d) }
        }
        guard rc == 0 else {
            let err = errno
            FileHandle.standardError.write(
                Data("[mq-dir NFC] rename(2) failed for \(srcPath): errno=\(err)\n".utf8)
            )
            return nil
        }

        if let encodedDir = dirPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let encodedName = nfc.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let nfcURL = URL(string: "file://" + encodedDir + "/" + encodedName) {
            return nfcURL
        }
        // The rename succeeded; only the URL rebuild failed. Hand back
        // a path-based URL so the caller still points at the right
        // inode — its lastPathComponent may render as NFD, but at
        // least the on-disk file is now correct.
        return URL(fileURLWithPath: dstPath)
    }
}
