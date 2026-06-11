import XCTest
@testable import mqdirCore

/// Coverage for `FileSystemService.enumerateMatching` — the recursive
/// search that backs the in-pane Find field. Pins the guard path, the
/// name/tag match split, the hidden-file filter, cancellation, and the
/// `.skipsPackageDescendants` boundary that keeps a `.app` bundle's
/// internals out of search results.
final class FileSystemServiceSearchTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    /// Empty query hits the `guard !query.isEmpty` early return — no walk,
    /// no results, even when matching-looking files exist.
    func testEmptyQueryReturnsEmpty() throws {
        try writeFile("anything.txt", contents: "x")
        let results = try FileSystemService().enumerateMatching(root: tempDirectory, query: "")
        XCTAssertTrue(results.isEmpty, "an empty query must short-circuit to [] before enumerating")
    }

    /// Name match is case-insensitive (`localizedCaseInsensitiveContains`)
    /// and recurses into subfolders.
    func testCaseInsensitiveNameMatch() throws {
        // Matching is a case-insensitive *substring* test
        // (`localizedCaseInsensitiveContains`), so the decoy is named to
        // contain neither the query letters nor "re" as a substring.
        try writeFile("ReadMe.md", contents: "x")
        try makeDirectory("sub")
        try writeFile("sub/Report.txt", contents: "x")
        try writeFile("photo.bin", contents: "x")

        let results = try FileSystemService().enumerateMatching(root: tempDirectory, query: "re")
        let names = Set(results.map(\.name))
        XCTAssertTrue(names.contains("ReadMe.md"), "case-insensitive 're' must match 'ReadMe.md'")
        XCTAssertTrue(names.contains("Report.txt"), "search must recurse into subfolders")
        XCTAssertFalse(names.contains("photo.bin"), "non-matching names must be excluded")
    }

    /// Tag-name match fires only when the *filename* doesn't match — the
    /// sidebar's "click a tag" path. Uses a Korean tag ("업무") to pin the
    /// NFC/NFD index-pairing the tag-colour comments justify: the file's
    /// Latin name can never contain the Korean query, so the hit must come
    /// purely from the Finder tag.
    func testTagNameMatchWhenFilenameDoesNotMatch() throws {
        let file = tempDirectory.appendingPathComponent("invoice.pdf")
        try Data("x".utf8).write(to: file)
        try FileSystemService.setTags([(name: "업무", colour: 6)], on: file)

        let results = try FileSystemService().enumerateMatching(root: tempDirectory, query: "업무")
        XCTAssertEqual(results.map(\.name), ["invoice.pdf"],
                       "a file whose name lacks the query must still match by its Finder tag name")
    }

    /// Hidden files are skipped by default and surface only with
    /// `includingHidden: true` (the `.skipsHiddenFiles` option toggle).
    func testHiddenFilesExcludedByDefaultIncludedWhenRequested() throws {
        try writeFile(".secretnote.txt", contents: "x")

        let defaultResults = try FileSystemService().enumerateMatching(root: tempDirectory, query: "note")
        XCTAssertTrue(defaultResults.isEmpty, "hidden files must be excluded by default")

        let withHidden = try FileSystemService().enumerateMatching(
            root: tempDirectory, query: "note", includingHidden: true
        )
        XCTAssertEqual(withHidden.map(\.name), [".secretnote.txt"],
                       "includingHidden:true must surface dotfiles whose name matches")
    }

    /// An `isCancelled` closure that returns true immediately must let the
    /// walk return its (partial/empty) results without crashing. The
    /// implementation only polls every 256 items, so on a tiny tree this
    /// may legitimately return everything — the contract under test is "no
    /// crash, returns an array", not a specific truncation count.
    func testCancellationReturnsWithoutCrashing() throws {
        for i in 0..<10 { try writeFile("match-\(i).txt", contents: "x") }

        let results = try FileSystemService().enumerateMatching(
            root: tempDirectory,
            query: "match",
            isCancelled: { true }
        )
        XCTAssertLessThanOrEqual(results.count, 10,
                                 "an always-cancelled walk must return a (partial) array, never crash")
    }

    /// `.skipsPackageDescendants` is set in `enumerateMatching`'s options, so
    /// a matching file *inside* a `.app` bundle must NOT be returned — the
    /// bundle is treated as an opaque package. The bundle directory itself is
    /// still a candidate if its own name matches; we query for the inner
    /// file's name to isolate the descendant-skip behaviour.
    func testSkipsPackageDescendants() throws {
        try makeDirectory("Test.app")
        try makeDirectory("Test.app/Contents")
        try writeFile("Test.app/Contents/buriedmatch.txt", contents: "x")

        let results = try FileSystemService().enumerateMatching(
            root: tempDirectory, query: "buriedmatch"
        )
        XCTAssertTrue(results.isEmpty,
                      ".skipsPackageDescendants must keep files inside a .app bundle out of search results")
    }

    // MARK: helpers

    private func writeFile(_ relativePath: String, contents: String) throws {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try Data(contents.utf8).write(to: url)
    }

    private func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
