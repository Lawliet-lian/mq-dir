import XCTest
@testable import mqdirCore

/// Tests for the on-disk NFD→NFC rename primitive. These exercise the
/// real filesystem in a temp dir because the whole reason `renameToNFC`
/// bypasses `FileManager.moveItem` and shells out to `Darwin.rename(2)`
/// is APFS's normalisation-insensitivity — only a real on-disk rename
/// proves the inode's name bytes actually changed.
final class HangulNFCFilenameTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-nfc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testRenameToNFC_decomposedNameBecomesComposedOnDisk() throws {
        // Build the on-disk name from decomposed (NFD) UTF-8 bytes so the
        // file genuinely lands with a decomposed name, then write it via
        // raw POSIX so Foundation can't renormalise it on the way in.
        let nfdName = "한글파일".decomposedStringWithCanonicalMapping + ".txt"
        let nfcName = nfdName.precomposedStringWithCanonicalMapping
        let nfdURL = try writeRaw(named: nfdName, contents: "x")

        let returned = HangulNFCFilename.renameToNFC(nfdURL)

        XCTAssertNotNil(returned, "a decomposed name must report a successful rename")

        // The on-disk entry is now the NFC byte sequence, and the old
        // NFD byte sequence is gone.
        let names = onDiskNames()
        XCTAssertTrue(
            names.contains { $0.utf8.elementsEqual(nfcName.utf8) },
            "the on-disk filename's UTF-8 bytes must be the NFC form"
        )
        XCTAssertFalse(
            names.contains { $0.utf8.elementsEqual(nfdName.utf8) },
            "the original NFD-named entry must no longer exist on disk"
        )
    }

    func testRenameToNFC_alreadyComposedIsNoOpReturningNil() throws {
        // API contract: the guard reads `url.lastPathComponent`. A URL
        // built via `appendingPathComponent` *always* renormalises that
        // component to NFD (the very bug the helper exists for), so the
        // genuinely-already-NFC case is the URL the helper *returns* — a
        // percent-encoded `file://` URL whose lastPathComponent survives
        // as NFC bytes. Re-running renameToNFC on that must be a nil
        // no-op (idempotency), proving the all-NFC path does no work.
        let nfcName = "한글".precomposedStringWithCanonicalMapping + ".txt"
        let nfcURL = fileURLPreservingNFC(name: nfcName, in: tempDirectory)
        try Data("x".utf8).write(to: nfcURL)
        XCTAssertFalse(nfcURL.lastPathComponent.isDecomposedRelativeToNFC,
                       "precondition: the test URL must carry an NFC lastPathComponent")

        let returned = HangulNFCFilename.renameToNFC(nfcURL)

        XCTAssertNil(returned,
                     "an already-NFC name must short-circuit to nil (no rename attempted)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nfcURL.path),
            "the already-composed file must be left untouched on disk"
        )
    }

    func testRenameToNFC_pureAsciiIsUntouched() throws {
        let asciiURL = tempDirectory.appendingPathComponent("report.txt")
        try Data("x".utf8).write(to: asciiURL)

        let returned = HangulNFCFilename.renameToNFC(asciiURL)

        XCTAssertNil(returned, "a pure-ASCII name has no NFD form, so the rename is a nil no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asciiURL.path))
    }

    // MARK: Helpers

    /// Create a file whose on-disk name is exactly `name`'s UTF-8 bytes,
    /// using POSIX `open` so Foundation's URL machinery can't renormalise
    /// the component before it hits the filesystem.
    @discardableResult
    private func writeRaw(named name: String, contents: String) throws -> URL {
        let fullPath = tempDirectory.path + "/" + name
        let fd = fullPath.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        guard fd >= 0 else {
            throw NSError(domain: "test", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open failed for \(name)"])
        }
        let bytes = Array(contents.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        return URL(fileURLWithPath: fullPath)
    }

    /// Raw directory listing as Strings, reading the actual on-disk byte
    /// sequences (not Foundation-renormalised ones) so byte comparisons
    /// against NFC/NFD are meaningful.
    private func onDiskNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
    }

    /// Build a `file://` URL whose `lastPathComponent` preserves `name`'s
    /// NFC bytes — the percent-encoded route `HangulNFCFilename` itself
    /// uses on return. `URL(fileURLWithPath:)` / `appendingPathComponent`
    /// would renormalise the component to NFD instead.
    private func fileURLPreservingNFC(name: String, in dir: URL) -> URL {
        let encName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let encDir = dir.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        return URL(string: "file://" + encDir + "/" + encName)!
    }
}
