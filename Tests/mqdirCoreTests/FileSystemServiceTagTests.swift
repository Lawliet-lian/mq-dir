import XCTest
@testable import mqdirCore

/// Tag-colour parsing and write coverage. The bug these tests pin down:
/// `com.apple.metadata:_kMDItemUserTags` has at least three on-disk shapes
/// in the wild (Apple writer's `Name\nColour\nFlag`, raw-setxattr
/// `Name\nColour`, and bare `Name`), plus legacy files that carry only a
/// `FinderInfo` colour label with no `_kMDItemUserTags` xattr at all. All
/// four paths must yield the right swatch — earlier versions only handled
/// the flat form and silently dropped every other tag to grey.
final class FileSystemServiceTagTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-tag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testParsesAppleMultiLineFormat() throws {
        // What `NSURL.setResourceValue(_, .tagNamesKey)` writes:
        // "<name>\n<colour>\n<flag>".
        let file = try writeTaggedFile("apple.txt", rawEntries: ["Red\n6\n0"])
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == file.lastPathComponent })
        XCTAssertEqual(entry.tagColors, [6], "Apple-format Red tag must surface as colour 6")
    }

    func testParsesFlatLegacyFormat() throws {
        // Raw `setxattr` callers (and the 7fe74fd-era mq-dir test fixture)
        // write the flat "<name>\n<colour>" shape.
        let file = try writeTaggedFile("flat.txt", rawEntries: ["Blue\n4"])
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == file.lastPathComponent })
        XCTAssertEqual(entry.tagColors, [4])
    }

    func testParsesNameOnlyEntries() throws {
        // Custom uncoloured tags arrive as bare "<name>" — must not
        // mis-parse the absence-of-colour as garbage.
        let file = try writeTaggedFile("plain.txt", rawEntries: ["Important"])
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == file.lastPathComponent })
        XCTAssertEqual(entry.tagNames, ["Important"])
        XCTAssertEqual(entry.tagColors, [0])
    }

    func testKoreanTagNamesParseCorrectly() throws {
        // The 7fe74fd fix exists because URLResource and the raw xattr
        // disagreed on Korean tag-name normalisation. Index-pairing must
        // still hold for the Apple multi-line format.
        let file = try writeTaggedFile(
            "korean.txt",
            rawEntries: ["빨강\n6\n0", "초록\n2\n0"]
        )
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == file.lastPathComponent })
        XCTAssertEqual(entry.tagNames.count, 2)
        XCTAssertEqual(entry.tagColors, [6, 2])
    }

    func testSetTagsRoundTripsThroughEnumeration() throws {
        let file = tempDirectory.appendingPathComponent("write.txt")
        try Data("hello".utf8).write(to: file)
        try FileSystemService.setTags(
            [(name: "Red", colour: 6), (name: "Project A", colour: 0)],
            on: file
        )
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == "write.txt" })
        XCTAssertEqual(entry.tagNames, ["Red", "Project A"])
        XCTAssertEqual(entry.tagColors, [6, 0])
    }

    func testToggleColourTagAddsThenRemoves() throws {
        let file = tempDirectory.appendingPathComponent("toggle.txt")
        try Data("hi".utf8).write(to: file)

        try FileSystemService.toggleColourTag(label: 6, displayName: "Red", on: file)
        var entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        var entry = try XCTUnwrap(entries.first { $0.name == "toggle.txt" })
        XCTAssertEqual(entry.tagColors, [6])

        try FileSystemService.toggleColourTag(label: 6, displayName: "Red", on: file)
        entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        entry = try XCTUnwrap(entries.first { $0.name == "toggle.txt" })
        XCTAssertTrue(entry.tagColors.isEmpty || entry.tagColors.allSatisfy { $0 == 0 })
        XCTAssertTrue(entry.tagNames.isEmpty)
    }

    func testFallsBackToPrimaryLabelWhenXattrMissing() throws {
        // Legacy code path: a file whose only colour is in
        // `com.apple.FinderInfo` (no `_kMDItemUserTags`). Driving the
        // static helper directly lets us verify the fallback without
        // needing a sandboxed Finder write — the enumerator threads
        // `URLResourceKey.labelNumber` straight in.
        let file = tempDirectory.appendingPathComponent("legacy.txt")
        try Data("legacy".utf8).write(to: file)
        let colours = FileSystemService.tagColors(
            for: file,
            names: ["Orange"],
            primaryLabelNumber: 7
        )
        XCTAssertEqual(colours, [7], "Legacy FinderInfo label must paint via labelNumber fallback")
    }

    func testFallbackDoesNotOverrideExplicitColour() throws {
        // The fallback only fires when the xattr left the slot at 0 —
        // an explicit xattr colour beats any stale primary label so
        // we don't mis-recolour a Red tag as Blue because the file
        // also carries an old FinderInfo stamp.
        let file = try writeTaggedFile("explicit.txt", rawEntries: ["Red\n6\n0"])
        let colours = FileSystemService.tagColors(
            for: file,
            names: ["Red"],
            primaryLabelNumber: 4
        )
        XCTAssertEqual(colours, [6])
    }

    func testToggleWithLabelZeroClearsAllTags() throws {
        let file = tempDirectory.appendingPathComponent("clear.txt")
        try Data("x".utf8).write(to: file)
        try FileSystemService.setTags(
            [(name: "Red", colour: 6), (name: "Blue", colour: 4)],
            on: file
        )
        try FileSystemService.toggleColourTag(label: 0, displayName: "", on: file)
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == "clear.txt" })
        XCTAssertTrue(entry.tagNames.isEmpty)
    }

    /// Round-trip asymmetry pin (review finding): a file tagged in Apple's
    /// three-line `"<name>\n<colour>\n<flag>"` form, read back via
    /// `currentTags`, and rewritten via `setTags`, keeps its name + colour
    /// but DROPS the trailing flag line — `currentTags`/`parseUserTagsXattr`
    /// only ever read lines 0 and 1, so the rewrite can't re-emit a flag it
    /// never parsed. This is deliberate, not a bug: for the plain user tags
    /// mq-dir creates (name + colour) the toggle round-trip is lossless.
    func testCurrentTagsToSetTagsRoundTripPreservesNameAndColour() throws {
        let file = try writeTaggedFile("rewrite.txt", rawEntries: ["Red\n6\n1", "업무\n2\n0"])

        // currentTags reads only name + colour (line 2 flag is invisible to it).
        let read = FileSystemService.currentTags(for: file)
        XCTAssertEqual(read.map(\.name), ["Red", "업무"])
        XCTAssertEqual(read.map(\.colour), [6, 2])

        // Rewrite the exact set we read back. Name + colour must survive;
        // the flag line is intentionally gone on the new write.
        try FileSystemService.setTags(read, on: file)

        let afterRewrite = FileSystemService.currentTags(for: file)
        XCTAssertEqual(afterRewrite.map(\.name), ["Red", "업무"],
                       "tag names (incl. Korean) must survive a currentTags->setTags round-trip")
        XCTAssertEqual(afterRewrite.map(\.colour), [6, 2],
                       "tag colours must survive a currentTags->setTags round-trip")

        // And the enumeration projection agrees with the rewritten xattr.
        let entries = try FileSystemService().enumerateDirectory(at: tempDirectory)
        let entry = try XCTUnwrap(entries.first { $0.name == "rewrite.txt" })
        XCTAssertEqual(entry.tagColors, [6, 2])
    }

    // MARK: helpers

    /// Stamp `rawEntries` into a fresh file's `_kMDItemUserTags` xattr
    /// without going through `URL.setResourceValues` — that's the whole
    /// point: we want to verify the parser handles whatever shape a
    /// third-party tagger could have left behind.
    private func writeTaggedFile(_ name: String, rawEntries: [String]) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
        let data = try PropertyListSerialization.data(
            fromPropertyList: rawEntries,
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes { buf -> Int32 in
            setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", buf.baseAddress, buf.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "setxattr should succeed")
        return url
    }
}
