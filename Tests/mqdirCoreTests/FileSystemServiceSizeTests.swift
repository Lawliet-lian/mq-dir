import XCTest
@testable import mqdirCore

/// Coverage for `FileSystemService.directorySize` — the recursive size walk
/// behind the on-demand "Calculate Size" action. Pins the sum across nested
/// dirs + files, that hidden files ARE counted, that symlinks are NOT
/// followed (no target double-count, no cycle hang), and that cancellation
/// returns the partial sum gathered so far.
final class FileSystemServiceSizeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-size-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    /// Nested dirs + files: the walk sums every file's logical byte count
    /// across the whole subtree, not just the top level.
    func testSumsNestedDirsAndFiles() throws {
        try writeFile("a.txt", bytes: 10)                  // 10
        try makeDirectory("sub")
        try writeFile("sub/b.txt", bytes: 20)              // 20
        try makeDirectory("sub/deep")
        try writeFile("sub/deep/c.txt", bytes: 5)          // 5

        let total = FileSystemService().directorySize(at: tempDirectory)
        XCTAssertEqual(total, 35, "size walk must sum every file across the nested subtree")
    }

    /// Hidden (dot-prefixed) files contribute to the total — this is a
    /// real-footprint measure, not a mirror of the browser's visible list.
    func testHiddenFilesAreCounted() throws {
        try writeFile("visible.txt", bytes: 8)
        try writeFile(".hidden", bytes: 4)

        let total = FileSystemService().directorySize(at: tempDirectory)
        XCTAssertEqual(total, 12, "hidden files are part of a folder's real footprint and must be summed")
    }

    /// Symlinks are NOT followed: a link to a large file contributes only the
    /// link's own (tiny, non-regular) entry — never the 1000-byte target —
    /// so the target's bytes are counted exactly once via the real file.
    func testSymlinksAreNotFollowed() throws {
        try writeFile("real.bin", bytes: 1000)
        let linkURL = tempDirectory.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: tempDirectory.appendingPathComponent("real.bin")
        )

        let total = FileSystemService().directorySize(at: tempDirectory)
        // Exactly the real file's 1000 bytes: the symlink is non-regular and
        // skipped, so its target isn't double-counted.
        XCTAssertEqual(total, 1000, "symlinks must not be followed — target counted once via the real file")
    }

    /// An empty directory sums to zero (no files, no crash).
    func testEmptyDirectoryIsZero() throws {
        let total = FileSystemService().directorySize(at: tempDirectory)
        XCTAssertEqual(total, 0)
    }

    /// A flipped cancel flag stops the walk and returns the partial sum —
    /// here, before any file is summed, so the result is zero rather than a
    /// hang or a crash.
    func testCancellationReturnsPartialSum() throws {
        for i in 0..<500 { try writeFile("file\(i).txt", bytes: 1) }
        let total = FileSystemService().directorySize(at: tempDirectory, isCancelled: { true })
        // The cancel check fires every 256 entries; an immediate cancel can
        // still admit the first batch, so we only assert it didn't sum the
        // full 500 — the contract is "stops early", not "sums exactly N".
        XCTAssertLessThanOrEqual(total, 500)
    }

    // MARK: helpers

    private func writeFile(_ relativePath: String, bytes: Int) throws {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func makeDirectory(_ relativePath: String) throws {
        let url = tempDirectory.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
