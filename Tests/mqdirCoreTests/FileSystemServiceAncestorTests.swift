import XCTest
@testable import mqdirCore

/// Coverage for `FileSystemService.ancestorFolders(from:to:)` — the pure
/// path math behind "Reveal in Tree". The chain it returns is exactly the
/// set of folders the tree must expand to surface a deep search hit: every
/// directory strictly between the root and the leaf, top-down, with both
/// endpoints excluded.
final class FileSystemServiceAncestorTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testReturnsIntermediateFoldersTopDown() {
        let root = url("/Users/me/Project")
        let leaf = url("/Users/me/Project/src/app/main.swift")
        let chain = FileSystemService.ancestorFolders(from: root, to: leaf)
        XCTAssertEqual(chain.map(\.path), [
            "/Users/me/Project/src",
            "/Users/me/Project/src/app",
        ], "must return src then src/app — shallowest first, leaf excluded")
    }

    func testDirectChildHasNoAncestors() {
        let root = url("/Users/me/Project")
        let leaf = url("/Users/me/Project/README.md")
        XCTAssertEqual(
            FileSystemService.ancestorFolders(from: root, to: leaf), [],
            "a direct child needs no folder expanded"
        )
    }

    func testLeafNotUnderRootReturnsEmpty() {
        let root = url("/Users/me/Project")
        let leaf = url("/Users/me/Other/file.txt")
        XCTAssertEqual(
            FileSystemService.ancestorFolders(from: root, to: leaf), [],
            "a leaf outside the root must yield no chain (defensive)"
        )
    }

    func testRootEqualToLeafReturnsEmpty() {
        let root = url("/Users/me/Project")
        XCTAssertEqual(FileSystemService.ancestorFolders(from: root, to: root), [])
    }

    /// A root carrying a trailing slash / non-standard form still matches a
    /// clean leaf — both sides standardise before the prefix compare.
    func testTrailingSlashRootStillMatches() {
        let root = url("/Users/me/Project/")
        let leaf = url("/Users/me/Project/a/b/c.txt")
        XCTAssertEqual(
            FileSystemService.ancestorFolders(from: root, to: leaf).map(\.lastPathComponent),
            ["a", "b"]
        )
    }
}
