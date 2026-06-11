import XCTest
@testable import mqdirCore

/// Edge coverage for `FileEntrySorter` beyond the happy-path
/// folders-first test in `FileSystemServiceTests`. Pins: pure key sort
/// with `foldersOnTop: false`, where nil `size` (directories) lands in
/// the order, the name tiebreak for equal sort keys, and descending name.
final class FileEntrySorterTests: XCTestCase {

    /// `foldersOnTop: false` drops the directory-pinning short-circuit, so
    /// files and folders interleave purely by the requested key. Sorting by
    /// name ascending must order strictly by name regardless of directoryness.
    func testFoldersOnTopFalseMixesFilesAndFolders() {
        let bFolder = entry(name: "b-folder", isDirectory: true, size: nil)
        let aFile = entry(name: "a-file.txt", isDirectory: false, size: 10)
        let cFile = entry(name: "c-file.txt", isDirectory: false, size: 10)

        let sorted = FileEntrySorter.sorted(
            [bFolder, aFile, cFile], by: .name, ascending: true, foldersOnTop: false
        )
        XCTAssertEqual(sorted.map(\.name), ["a-file.txt", "b-folder", "c-file.txt"],
                       "foldersOnTop:false must sort purely by key, interleaving folders and files")
    }

    /// Directories carry `size == nil`. `compareOptional` orders a present
    /// value before nil, so with `foldersOnTop: false` a nil-size directory
    /// sorts LAST in ascending size order.
    func testNilSizeSortsLastAscending() {
        let folder = entry(name: "folder", isDirectory: true, size: nil)
        let small = entry(name: "small.txt", isDirectory: false, size: 1)
        let big = entry(name: "big.txt", isDirectory: false, size: 99)

        let sorted = FileEntrySorter.sorted(
            [folder, big, small], by: .size, ascending: true, foldersOnTop: false
        )
        XCTAssertEqual(sorted.map(\.name), ["small.txt", "big.txt", "folder"],
                       "ascending size: real sizes first (1, 99), nil size (directory) last")
    }

    /// Descending size flips the real-size order AND moves nil-size to the
    /// front, because `compareOptional(nil, value) == .orderedDescending`
    /// satisfies the descending predicate. Pins actual `compareOptional`
    /// placement rather than assuming nil is "always last".
    func testNilSizeSortsFirstDescending() {
        let folder = entry(name: "folder", isDirectory: true, size: nil)
        let small = entry(name: "small.txt", isDirectory: false, size: 1)
        let big = entry(name: "big.txt", isDirectory: false, size: 99)

        let sorted = FileEntrySorter.sorted(
            [small, folder, big], by: .size, ascending: false, foldersOnTop: false
        )
        XCTAssertEqual(sorted.map(\.name), ["folder", "big.txt", "small.txt"],
                       "descending size: nil-size (directory) sorts first, then 99, then 1")
    }

    /// When the primary sort key compares equal (identical dates), the sort
    /// falls through to the localized name comparison as a stable tiebreak.
    func testEqualDatesFallThroughToNameTiebreak() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let zebra = entry(name: "zebra.txt", isDirectory: false, size: 5, date: date)
        let apple = entry(name: "apple.txt", isDirectory: false, size: 5, date: date)

        let sorted = FileEntrySorter.sorted(
            [zebra, apple], by: .modified, ascending: true, foldersOnTop: false
        )
        XCTAssertEqual(sorted.map(\.name), ["apple.txt", "zebra.txt"],
                       "equal modification dates must tiebreak by name ascending")
    }

    /// Descending name sort reverses the localized name order.
    func testDescendingNameSort() {
        let a = entry(name: "alpha.txt", isDirectory: false, size: 1)
        let m = entry(name: "mike.txt", isDirectory: false, size: 1)
        let z = entry(name: "zulu.txt", isDirectory: false, size: 1)

        let sorted = FileEntrySorter.sorted(
            [a, z, m], by: .name, ascending: false, foldersOnTop: false
        )
        XCTAssertEqual(sorted.map(\.name), ["zulu.txt", "mike.txt", "alpha.txt"],
                       "descending name sort must reverse the alphabetical order")
    }

    // MARK: helpers

    private func entry(
        name: String,
        isDirectory: Bool,
        size: Int64?,
        date: Date? = nil
    ) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            size: size,
            modificationDate: date,
            kind: isDirectory ? "Folder" : "Document",
            isHidden: false
        )
    }
}
