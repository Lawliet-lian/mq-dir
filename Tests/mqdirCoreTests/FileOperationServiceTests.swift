import XCTest
@testable import mqdirCore

final class FileOperationServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-fileop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: Collision rename

    func testConflictRename_firstConflictAppendsTwo() throws {
        try writeFile("a.txt", contents: "x")
        let source = tempDirectory.appendingPathComponent("a.txt")
        let dest = FileOperationService.conflictRenamedDestination(for: source, in: tempDirectory)
        XCTAssertEqual(dest.lastPathComponent, "a 2.txt")
    }

    func testConflictRename_repeatedAppendsThree() throws {
        try writeFile("a.txt", contents: "x")
        try writeFile("a 2.txt", contents: "x")
        let source = tempDirectory.appendingPathComponent("a.txt")
        let dest = FileOperationService.conflictRenamedDestination(for: source, in: tempDirectory)
        XCTAssertEqual(dest.lastPathComponent, "a 3.txt")
    }

    func testConflictRename_preservesExtension() throws {
        try writeFile("report.final.txt", contents: "x")
        let source = tempDirectory.appendingPathComponent("report.final.txt")
        let dest = FileOperationService.conflictRenamedDestination(for: source, in: tempDirectory)
        // pathExtension is the last component only — "report.final" stem + "txt" ext.
        XCTAssertEqual(dest.lastPathComponent, "report.final 2.txt")
    }

    func testConflictRename_noExtension() throws {
        try makeDirectory("Folder")
        let source = tempDirectory.appendingPathComponent("Folder")
        let dest = FileOperationService.conflictRenamedDestination(for: source, in: tempDirectory)
        XCTAssertEqual(dest.lastPathComponent, "Folder 2")
    }

    func testConflictRename_capExhaustionFallsBackToTimestamp() {
        // Pretend everything exists so the cap is exhausted; inject a fixed clock.
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let source = tempDirectory.appendingPathComponent("a.txt")
        let dest = FileOperationService.conflictRenamedDestination(
            for: source,
            in: tempDirectory,
            cap: 3,
            fileExists: { _ in true },
            now: { fixed }
        )
        XCTAssertEqual(dest.lastPathComponent, "a-1700000000.txt")
    }

    func testUniqueTargetDestination_returnsTargetWhenFree() {
        let target = tempDirectory.appendingPathComponent("untitled folder")
        let dest = FileOperationService.uniqueTargetDestination(for: target)
        XCTAssertEqual(dest, target)
    }

    func testUniqueTargetDestination_appendsSuffixWhenTaken() throws {
        try makeDirectory("untitled folder")
        let target = tempDirectory.appendingPathComponent("untitled folder")
        let dest = FileOperationService.uniqueTargetDestination(for: target)
        XCTAssertEqual(dest.lastPathComponent, "untitled folder 2")
    }

    func testUniqueTargetDestination_returnsOriginalOnCapExhaustion() {
        let target = tempDirectory.appendingPathComponent("untitled folder")
        let dest = FileOperationService.uniqueTargetDestination(
            for: target,
            cap: 3,
            fileExists: { _ in true }
        )
        XCTAssertEqual(dest, target)
    }

    func testUniqueZipDestination_primaryThenSuffix() throws {
        try writeFile("Archive.zip", contents: "x")
        let dest = FileOperationService.uniqueZipDestination(in: tempDirectory, stem: "Archive")
        XCTAssertEqual(dest.lastPathComponent, "Archive 2.zip")
    }

    func testUniqueZipDestination_timestampFallbackUsesSpace() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let dest = FileOperationService.uniqueZipDestination(
            in: tempDirectory,
            stem: "Archive",
            cap: 2,
            fileExists: { _ in true },
            now: { fixed }
        )
        XCTAssertEqual(dest.lastPathComponent, "Archive 1700000000.zip")
    }

    func testUniqueExtractionDirectory_primaryThenSuffix() throws {
        try makeDirectory("payload")
        let dest = FileOperationService.uniqueExtractionDirectory(in: tempDirectory, stem: "payload")
        XCTAssertEqual(dest.lastPathComponent, "payload 2")
    }

    func testUnifiedCapDefaultsTo999() {
        // The unified default cap is 999 (the higher of the two legacy caps).
        // With everything-exists, n iterates 2...999 then returns nil so the
        // caller fallback fires; assert the boundary by capping at 999 and
        // checking that a 999-th slot resolves.
        var existing = Set<String>()
        for n in 2...998 {
            existing.insert(tempDirectory.appendingPathComponent("a \(n)").path)
        }
        let dest = FileOperationService.uniqueDestination(
            in: tempDirectory,
            stem: "a",
            includePrimary: false,
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(dest?.lastPathComponent, "a 999")
    }

    // MARK: transfer (copy / move)

    func testTransfer_copyBasicSuccess() throws {
        try writeFile("src.txt", contents: "hello")
        let dst = try makeDirectory("dst")
        let result = FileOperationService.transfer(
            [tempDirectory.appendingPathComponent("src.txt")],
            into: dst,
            move: false
        )
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("src.txt").path))
        // Copy leaves the source.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("src.txt").path))
    }

    func testTransfer_moveRemovesSource() throws {
        try writeFile("src.txt", contents: "hello")
        let dst = try makeDirectory("dst")
        let result = FileOperationService.transfer(
            [tempDirectory.appendingPathComponent("src.txt")],
            into: dst,
            move: true
        )
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("src.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("src.txt").path))
    }

    func testTransfer_collisionAutoRenames() throws {
        let dst = try makeDirectory("dst")
        try writeFile("src.txt", contents: "new")
        // Pre-seed a colliding file in dst.
        try Data("old".utf8).write(to: dst.appendingPathComponent("src.txt"))
        let result = FileOperationService.transfer(
            [tempDirectory.appendingPathComponent("src.txt")],
            into: dst,
            move: false
        )
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("src.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("src 2.txt").path))
    }

    func testTransfer_failureRecordedAndOperationContinues() throws {
        let dst = try makeDirectory("dst")
        try writeFile("good.txt", contents: "x")
        let missing = tempDirectory.appendingPathComponent("nonexistent.txt")
        let good = tempDirectory.appendingPathComponent("good.txt")
        let result = FileOperationService.transfer([missing, good], into: dst, move: false)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.0, missing)
        // The good file still transferred despite the earlier failure.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("good.txt").path))
    }

    func testTransfer_selfDropIsNoOp() throws {
        try writeFile("file.txt", contents: "x")
        let src = tempDirectory.appendingPathComponent("file.txt")
        // Dropping into its own parent folder: dest == source, skipped, no rename copy made.
        let result = FileOperationService.transfer([src], into: tempDirectory, move: false)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("file 2.txt").path))
    }

    func testTransfer_folderIntoOwnDescendantRejected() throws {
        let parent = try makeDirectory("parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // Move "parent" into "parent/child" — descendant target, must be rejected.
        let result = FileOperationService.transfer([parent], into: child, move: true)
        XCTAssertTrue(result.failures.isEmpty)
        // parent still exists where it was, nothing was moved into child.
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("parent").path))
    }

    // MARK: duplicate

    func testDuplicate_namesWithSpaceSuffix() throws {
        try writeFile("photo.png", contents: "x")
        let result = FileOperationService.duplicate([tempDirectory.appendingPathComponent("photo.png")])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("photo 2.png").path))
    }

    func testDuplicate_failureRecorded() {
        let missing = tempDirectory.appendingPathComponent("ghost.txt")
        let result = FileOperationService.duplicate([missing])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.0, missing)
    }

    // MARK: normalize-on-write (NFD → NFC)

    func testTransfer_normalizeHangulTrueComposesDestinationName() throws {
        // Source carries a decomposed (NFD) Hangul name on disk; with
        // normalizeHangul on, the copied file's on-disk name must be NFC.
        let nfdName = "한글".decomposedStringWithCanonicalMapping + ".txt"
        let nfcName = nfdName.precomposedStringWithCanonicalMapping
        let src = try writeRaw(named: nfdName, in: tempDirectory, contents: "x")
        let dst = try makeDirectory("dst")

        let result = FileOperationService.transfer([src], into: dst, move: false, normalizeHangul: true)

        XCTAssertTrue(result.failures.isEmpty)
        let names = onDiskNames(in: dst)
        XCTAssertTrue(names.contains { $0.utf8.elementsEqual(nfcName.utf8) },
                      "destination name must be NFC bytes when normalizeHangul is true")
        XCTAssertFalse(names.contains { $0.utf8.elementsEqual(nfdName.utf8) },
                       "no NFD-named entry must survive in the destination")
    }

    func testTransfer_normalizeHangulFalseLeavesDestinationDecomposed() throws {
        let nfdName = "한글".decomposedStringWithCanonicalMapping + ".txt"
        let src = try writeRaw(named: nfdName, in: tempDirectory, contents: "x")
        let dst = try makeDirectory("dst")

        let result = FileOperationService.transfer([src], into: dst, move: false, normalizeHangul: false)

        XCTAssertTrue(result.failures.isEmpty)
        let names = onDiskNames(in: dst)
        XCTAssertTrue(names.contains { $0.utf8.elementsEqual(nfdName.utf8) },
                      "destination name must stay NFD bytes when normalizeHangul is false")
    }

    func testDuplicate_normalizeHangulTrueComposesCopyName() throws {
        let nfdStem = "한글".decomposedStringWithCanonicalMapping
        let src = try writeRaw(named: nfdStem + ".txt", in: tempDirectory, contents: "x")

        let result = FileOperationService.duplicate([src], normalizeHangul: true)

        XCTAssertTrue(result.failures.isEmpty)
        // The duplicate's stem is " 2"-suffixed; assert the copy on disk
        // is NFC by checking no entry still carries a decomposed name.
        let names = onDiskNames(in: tempDirectory)
        XCTAssertFalse(
            names.contains { $0 != (nfdStem + ".txt") && $0.utf8.elementsEqual((nfdStem + " 2.txt").utf8) },
            "the duplicated copy must be written/renamed to NFC, not NFD"
        )
        XCTAssertTrue(
            names.contains { $0.utf8.elementsEqual((nfdStem.precomposedStringWithCanonicalMapping + " 2.txt").utf8) },
            "the duplicate's NFC name must be present on disk"
        )
    }

    // MARK: delete

    func testPermanentlyDelete_removesAndRecordsFailures() throws {
        try writeFile("doomed.txt", contents: "x")
        let doomed = tempDirectory.appendingPathComponent("doomed.txt")
        let missing = tempDirectory.appendingPathComponent("absent.txt")
        let result = FileOperationService.permanentlyDelete([doomed, missing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.0, missing)
    }

    // MARK: createDirectory / rename

    func testCreateDirectory_autoRenamesOnCollision() throws {
        try makeDirectory("untitled folder")
        let created = try FileOperationService.createDirectory(
            at: tempDirectory.appendingPathComponent("untitled folder")
        )
        XCTAssertEqual(created.lastPathComponent, "untitled folder 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    func testRename_movesToNewName() throws {
        try writeFile("old.txt", contents: "x")
        let result = try FileOperationService.rename(
            tempDirectory.appendingPathComponent("old.txt"),
            to: "new.txt"
        )
        XCTAssertEqual(result.lastPathComponent, "new.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("old.txt").path))
    }

    func testRename_refusesExistingSibling() throws {
        try writeFile("a.txt", contents: "x")
        try writeFile("b.txt", contents: "x")
        XCTAssertThrowsError(
            try FileOperationService.rename(tempDirectory.appendingPathComponent("a.txt"), to: "b.txt")
        ) { error in
            XCTAssertEqual(error as? FileOperationService.RenameError, .destinationExists(name: "b.txt"))
        }
    }

    // MARK: compress planning

    func testPlanCompression_singleFileDropsExtension() throws {
        try writeFile("notes.txt", contents: "x")
        let plan = try FileOperationService.planCompression(
            urls: [(url: tempDirectory.appendingPathComponent("notes.txt"), isDirectory: false)]
        )
        XCTAssertEqual(plan?.destination.lastPathComponent, "notes.zip")
        XCTAssertEqual(plan?.sourceNames, ["notes.txt"])
    }

    func testPlanCompression_singleDirectoryKeepsName() throws {
        let dir = try makeDirectory("MyFolder")
        let plan = try FileOperationService.planCompression(
            urls: [(url: dir, isDirectory: true)]
        )
        XCTAssertEqual(plan?.destination.lastPathComponent, "MyFolder.zip")
    }

    func testPlanCompression_multiSelectionBecomesArchive() throws {
        try writeFile("a.txt", contents: "x")
        try writeFile("b.txt", contents: "x")
        let plan = try FileOperationService.planCompression(
            urls: [
                (url: tempDirectory.appendingPathComponent("a.txt"), isDirectory: false),
                (url: tempDirectory.appendingPathComponent("b.txt"), isDirectory: false),
            ]
        )
        XCTAssertEqual(plan?.destination.lastPathComponent, "Archive.zip")
        XCTAssertEqual(plan?.sourceNames, ["a.txt", "b.txt"])
    }

    func testPlanCompression_crossFolderRejected() throws {
        let other = try makeDirectory("other")
        try writeFile("a.txt", contents: "x")
        try Data("x".utf8).write(to: other.appendingPathComponent("b.txt"))
        XCTAssertThrowsError(
            try FileOperationService.planCompression(
                urls: [
                    (url: tempDirectory.appendingPathComponent("a.txt"), isDirectory: false),
                    (url: other.appendingPathComponent("b.txt"), isDirectory: false),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? FileOperationService.CompressError, .crossFolder)
        }
    }

    // MARK: archive classification table

    func testArchiveKindClassification() {
        let cases: [(String, FileOperationService.ArchiveKind?)] = [
            ("file.zip", .zip),
            ("FILE.ZIP", .zip),
            ("bundle.tar", .tar),
            ("bundle.TAR", .tar),
            ("data.tgz", .tarGz),
            ("data.tar.gz", .tarGz),
            ("data.TAR.GZ", .tarGz),
            ("plain.txt", nil),
            ("noext", nil),
            ("archive.gz", nil),
        ]
        for (name, expected) in cases {
            let url = tempDirectory.appendingPathComponent(name)
            XCTAssertEqual(FileOperationService.archiveKind(for: url), expected, "for \(name)")
        }
    }

    func testArchiveStemStripping() {
        let zip = tempDirectory.appendingPathComponent("photos.zip")
        XCTAssertEqual(FileOperationService.archiveStem(for: zip, kind: .zip), "photos")

        let tar = tempDirectory.appendingPathComponent("backup.tar")
        XCTAssertEqual(FileOperationService.archiveStem(for: tar, kind: .tar), "backup")

        let tarGz = tempDirectory.appendingPathComponent("src.tar.gz")
        XCTAssertEqual(FileOperationService.archiveStem(for: tarGz, kind: .tarGz), "src")

        let tgz = tempDirectory.appendingPathComponent("src.tgz")
        XCTAssertEqual(FileOperationService.archiveStem(for: tgz, kind: .tarGz), "src")
    }

    func testCanExtract() {
        XCTAssertFalse(FileOperationService.canExtract([]))
        XCTAssertTrue(FileOperationService.canExtract([
            (url: tempDirectory.appendingPathComponent("a.zip"), isDirectory: false),
            (url: tempDirectory.appendingPathComponent("b.tar.gz"), isDirectory: false),
        ]))
        // A directory named like an archive is not extractable.
        XCTAssertFalse(FileOperationService.canExtract([
            (url: tempDirectory.appendingPathComponent("a.zip"), isDirectory: true),
        ]))
        // A non-archive in the mix disqualifies the whole batch.
        XCTAssertFalse(FileOperationService.canExtract([
            (url: tempDirectory.appendingPathComponent("a.zip"), isDirectory: false),
            (url: tempDirectory.appendingPathComponent("b.txt"), isDirectory: false),
        ]))
    }

    // MARK: compress/extract round-trip (Process-based)

    func testZipRoundTrip() throws {
        // Create a folder with a couple files, compress it, verify the zip
        // exists, extract it, verify the contents come back.
        let payload = try makeDirectory("payload")
        try Data("alpha".utf8).write(to: payload.appendingPathComponent("one.txt"))
        try Data("beta".utf8).write(to: payload.appendingPathComponent("two.txt"))

        let plan = try FileOperationService.planCompression(
            urls: [(url: payload, isDirectory: true)]
        )
        let unwrapped = try XCTUnwrap(plan)
        try FileOperationService.runCompression(
            parent: unwrapped.parent,
            sources: unwrapped.sourceNames,
            destination: unwrapped.destination
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unwrapped.destination.path),
            "archive should exist after compression"
        )

        // Move the archive into a clean directory so extraction is isolated.
        let extractRoot = try makeDirectory("extractRoot")
        let movedZip = extractRoot.appendingPathComponent(unwrapped.destination.lastPathComponent)
        try FileManager.default.moveItem(at: unwrapped.destination, to: movedZip)

        let kind = try XCTUnwrap(FileOperationService.archiveKind(for: movedZip))
        let outDir = try FileOperationService.extract(archive: movedZip, kind: kind)

        // ditto preserves the "payload/" top-level folder inside the zip.
        let extractedOne = outDir.appendingPathComponent("payload/one.txt")
        let extractedTwo = outDir.appendingPathComponent("payload/two.txt")
        XCTAssertEqual(try String(contentsOf: extractedOne, encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: extractedTwo, encoding: .utf8), "beta")
    }

    // MARK: Helpers

    @discardableResult
    private func writeFile(_ name: String, contents: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func makeDirectory(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Create a file whose on-disk name is exactly `name`'s UTF-8 bytes
    /// via POSIX `open`, so Foundation's URL machinery can't renormalise
    /// an NFD component to NFC before it hits the filesystem. Required to
    /// genuinely land a decomposed-Hangul name for the normalise-on-write
    /// tests.
    @discardableResult
    private func writeRaw(named name: String, in dir: URL, contents: String) throws -> URL {
        let fullPath = dir.path + "/" + name
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

    /// Raw directory listing reading the actual on-disk byte sequences so
    /// byte-level NFC/NFD comparisons are meaningful.
    private func onDiskNames(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
}
