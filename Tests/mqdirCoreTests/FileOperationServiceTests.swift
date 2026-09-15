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

    // MARK: - safeReplaceItem Tests

    /// 场景：copy + replace 成功路径。
    /// 验证：(1) 目标内容变成新文件内容 (2) 源文件保留 (3) backup 目录存在且含旧内容
    func testSafeReplace_copySuccess_returnsRecordAndKeepsBackup() throws {
        let dst = try makeDirectory("dst")
        let destFile = dst.appendingPathComponent("a.txt")
        try Data("old-content".utf8).write(to: destFile)
        let src = try writeFile("a.txt", contents: "new-content")

        let record = try FileOperationService.safeReplaceItem(
            from: src,
            to: destFile,
            move: false
        )

        // 目标内容应为新内容
        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "new-content")
        // 源保留（copy 语义）
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "new-content")
        // backup 存在且含旧内容
        let backup = record.replacedOriginalBackup
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old-content")
        // backup 目录名是 .mqdir_replace_backup_ 开头（目标目录的隐藏子目录）
        XCTAssertTrue(backup.deletingLastPathComponent().lastPathComponent.hasPrefix(".mqdir_replace_backup_"))
    }

    /// 场景：move + replace。成功后 source 消失。
    func testSafeReplace_moveSuccess_sourceIsRemoved() throws {
        let dst = try makeDirectory("dst")
        let destFile = dst.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: destFile)
        let src = try writeFile("a.txt", contents: "new")

        _ = try FileOperationService.safeReplaceItem(from: src, to: destFile, move: true)

        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "move 语义下源应消失")
    }

    /// 场景：目标不存在 → 抛错，不做任何事。
    func testSafeReplace_destinationMissing_throws() {
        let src = tempDirectory.appendingPathComponent("ghost-src.txt")
        let dst = tempDirectory.appendingPathComponent("ghost-dst.txt")
        // 两个都不存在
        XCTAssertThrowsError(
            try FileOperationService.safeReplaceItem(from: src, to: dst, move: false)
        )
    }

    /// 场景：写入新文件失败（构造不可写的 source URL 模拟 copyItem 失败）。
    /// 验证：旧目标文件自动回滚，内容为原来的旧内容，备份目录被清理。
    func testSafeReplace_writeFailure_rollsBackOldDestination() throws {
        let dstDir = try makeDirectory("dst")
        let destFile = dstDir.appendingPathComponent("a.txt")
        try Data("important-old".utf8).write(to: destFile)
        // 构造一个不存在的 source —— copyItem 必然抛错
        let missingSrc = tempDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).txt")

        XCTAssertThrowsError(
            try FileOperationService.safeReplaceItem(from: missingSrc, to: destFile, move: false)
        )

        // 关键：旧目标没丢，内容还是 old
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "important-old")
        // 目标目录下没有残留的 .mqdir_replace_backup_ 目录
        let contents = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".mqdir_replace_backup_") },
                       "回滚后不应残留备份目录")
    }

    /// 场景：替换整个文件夹（含内部多个子文件）。
    func testSafeReplace_folderReplace_worksRecursively() throws {
        let dstDir = try makeDirectory("dst")
        // 旧目标文件夹
        let oldFolder = dstDir.appendingPathComponent("MyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("old-a".utf8).write(to: oldFolder.appendingPathComponent("a.txt"))
        try Data("old-b".utf8).write(to: oldFolder.appendingPathComponent("b.txt"))

        // 新源文件夹
        let newFolder = try makeDirectory("MyFolder-src")
        try Data("new-a".utf8).write(to: newFolder.appendingPathComponent("a.txt"))
        try Data("new-c".utf8).write(to: newFolder.appendingPathComponent("c.txt"))

        let record = try FileOperationService.safeReplaceItem(
            from: newFolder,
            to: oldFolder,
            move: false
        )

        // 替换后的目标文件夹内容：有 a.txt(新) + c.txt；没有 old 的 b.txt
        let aContent = try String(contentsOf: oldFolder.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(aContent, "new-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("c.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("b.txt").path))
        // backup 里有旧文件夹的 a.txt 和 b.txt
        let backupFolder = record.replacedOriginalBackup
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupFolder.appendingPathComponent("b.txt").path))
        let backupA = try String(contentsOf: backupFolder.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(backupA, "old-a")
    }

    // MARK: - transfer with CollisionPolicy Tests

    /// 无冲突时：回调 never called，直接传。
    func testTransferPolicy_noCollision_bypassesCallback() throws {
        let dst = try makeDirectory("dst")
        let src1 = try writeFile("a.txt", contents: "1")
        let src2 = try writeFile("b.txt", contents: "2")

        var callbackCount = 0
        let result = FileOperationService.transfer(
            [src1, src2],
            into: dst,
            move: false,
            onCollision: { _, _ in
                callbackCount += 1
                return (.keepBoth, false)
            }
        )

        XCTAssertEqual(callbackCount, 0, "无冲突不应触发回调")
        XCTAssertEqual(result.successes.count, 2)
        XCTAssertTrue(result.replaceRecords.isEmpty)
        XCTAssertFalse(result.userStopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
    }

    /// .ask + 返回 keepBoth → 生成 " 2"。
    func testTransferPolicy_ask_keepBoth() throws {
        let dst = try makeDirectory("dst")
        try Data("old".utf8).write(to: dst.appendingPathComponent("a.txt"))
        let src = try writeFile("a.txt", contents: "new")

        var callbackCount = 0
        let result = FileOperationService.transfer(
            [src],
            into: dst,
            move: false,
            onCollision: { _, _ in
                callbackCount += 1
                return (.keepBoth, false)
            }
        )

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertTrue(result.replaceRecords.isEmpty)
        // 原目标保留（old）
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        // 生成 a 2.txt (new)
        let destCopy = dst.appendingPathComponent("a 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destCopy.path))
        XCTAssertEqual(try String(contentsOf: destCopy, encoding: .utf8), "new")
        XCTAssertEqual(result.successes.first?.destination.lastPathComponent, "a 2.txt")
    }

    /// .ask + 返回 replace → 内容替换，replaceRecords 有值，原旧文件备份存在。
    func testTransferPolicy_ask_replace() throws {
        let dst = try makeDirectory("dst")
        let destFile = dst.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: destFile)
        let src = try writeFile("a.txt", contents: "new")

        let result = FileOperationService.transfer(
            [src],
            into: dst,
            move: false,
            onCollision: { _, _ in (.replace, false) }
        )

        XCTAssertEqual(result.replaceRecords.count, 1)
        XCTAssertEqual(result.successes.count, 1)
        // 目标变新
        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "new")
        // 备份里是旧
        let backup = try XCTUnwrap(result.replaceRecords.first?.replacedOriginalBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
    }

    /// .ask + 返回 stop → 终止整批，后续不处理，userStopped=true；前面已成功的保留。
    func testTransferPolicy_ask_stop_terminatesEntireBatch() throws {
        let dst = try makeDirectory("dst")
        // 文件 1：不冲突 → 成功
        let src1 = try writeFile("ok.txt", contents: "ok")
        // 文件 2：冲突，用户选 STOP
        try Data("old".utf8).write(to: dst.appendingPathComponent("bad.txt"))
        let src2 = try writeFile("bad.txt", contents: "new-bad")
        // 文件 3：不冲突，但应被 STOP 阻止
        let src3 = try writeFile("never.txt", contents: "never")

        let result = FileOperationService.transfer(
            [src1, src2, src3],
            into: dst,
            move: false,
            onCollision: { s, _ in
                // 只有 bad.txt 会冲突；回调到 bad 时返回 stop
                XCTAssertEqual(s.lastPathComponent, "bad.txt")
                return (.stop, false)
            }
        )

        XCTAssertTrue(result.userStopped)
        // 第一个成功了，后面的都没处理
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(result.successes.first?.source.lastPathComponent, "ok.txt")
        // never.txt 没被复制
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("never.txt").path))
        // bad.txt 还是 old 内容
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("bad.txt"), encoding: .utf8), "old")
    }

    /// 第一次 .ask 返回 keepBoth + applyToAll=true，后续冲突直接 keepBoth，不再回调。
    /// 中间穿插一个不冲突的文件（验证「应用到全部」只对后续冲突生效，不会干扰无冲突文件）。
    func testTransferPolicy_applyKeepBoth() throws {
        let dst = try makeDirectory("dst")
        // 预种冲突 1、2、3
        try Data("old-1".utf8).write(to: dst.appendingPathComponent("c1.txt"))
        try Data("old-2".utf8).write(to: dst.appendingPathComponent("c2.txt"))
        try Data("old-3".utf8).write(to: dst.appendingPathComponent("c3.txt"))

        let srcs = [
            try writeFile("c1.txt", contents: "new-1"),
            try writeFile("noconflict.txt", contents: "nc"), // 无冲突
            try writeFile("c2.txt", contents: "new-2"),
            try writeFile("c3.txt", contents: "new-3"),
        ]

        var callbackCount = 0
        let result = FileOperationService.transfer(
            srcs,
            into: dst,
            move: false,
            onCollision: { s, _ in
                callbackCount += 1
                // 只应回调一次（c1）
                XCTAssertEqual(s.lastPathComponent, "c1.txt", "只应在第一个冲突回调")
                return (.keepBoth, true) // 应用到全部
            }
        )

        XCTAssertEqual(callbackCount, 1, "勾选应用到全部后，后续冲突不再回调")
        XCTAssertEqual(result.successes.count, 4)
        XCTAssertTrue(result.replaceRecords.isEmpty)
        // 生成 c1 2.txt / c2 2.txt / c3 2.txt
        for n in ["c1 2.txt", "c2 2.txt", "c3 2.txt"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: dst.appendingPathComponent(n).path),
                "期望存在 \(n)"
            )
        }
        // 原始冲突文件保持 old 内容
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("c1.txt"), encoding: .utf8), "old-1")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("c2.txt"), encoding: .utf8), "old-2")
    }

    /// 第一次 .ask 返回 replace + applyToAll=true → 后续冲突直接 replace。
    func testTransferPolicy_applyReplace() throws {
        let dst = try makeDirectory("dst")
        let destPaths = (1...3).map { dst.appendingPathComponent("f\($0).txt") }
        try Data("old-1".utf8).write(to: destPaths[0])
        try Data("old-2".utf8).write(to: destPaths[1])
        try Data("old-3".utf8).write(to: destPaths[2])

        let srcs = [
            try writeFile("f1.txt", contents: "new-1"),
            try writeFile("f2.txt", contents: "new-2"),
            try writeFile("f3.txt", contents: "new-3"),
        ]

        var callbackCount = 0
        let result = FileOperationService.transfer(
            srcs,
            into: dst,
            move: false,
            onCollision: { _, _ in
                callbackCount += 1
                return (.replace, true)
            }
        )

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(result.replaceRecords.count, 3, "3 个冲突都走了 replace")
        for (idx, dp) in destPaths.enumerated() {
            XCTAssertEqual(
                try String(contentsOf: dp, encoding: .utf8),
                "new-\(idx + 1)",
                "f\(idx + 1).txt 内容应为 new"
            )
        }
    }

    /// 一次 transfer：混合「无冲突 + keepBoth + replace」，确认 successes 包含全部条目，
    /// replaceRecords 只含 replace 的项，且二者数量匹配。
    func testTransferPolicy_mixedBatch_successesAndReplaceRecordsMatch() throws {
        let dst = try makeDirectory("dst")
        try Data("old".utf8).write(to: dst.appendingPathComponent("r.txt")) // replace 目标
        try Data("old".utf8).write(to: dst.appendingPathComponent("k.txt")) // keepBoth 目标

        var decisions: [String: FileOperationService.CollisionDecision] = [
            "r.txt": .replace,
            "k.txt": .keepBoth,
        ]

        let srcs = [
            try writeFile("plain.txt", contents: "p"),   // 无冲突
            try writeFile("r.txt", contents: "new-r"),   // 冲突 → replace
            try writeFile("k.txt", contents: "new-k"),   // 冲突 → keepBoth
        ]

        let result = FileOperationService.transfer(
            srcs,
            into: dst,
            move: false,
            onCollision: { s, _ in (decisions[s.lastPathComponent] ?? .keepBoth, false) }
        )

        XCTAssertEqual(result.successes.count, 3, "3 个文件全部成功")
        XCTAssertEqual(result.replaceRecords.count, 1, "只有 1 个是 replace")
        XCTAssertEqual(result.replaceRecords.first?.source.lastPathComponent, "r.txt")
        // k.txt → 生成 k 2.txt，原 k.txt 仍是 old
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("k.txt"), encoding: .utf8), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("k 2.txt").path))
        // r.txt → 已被替换成 new-r
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("r.txt"), encoding: .utf8), "new-r")
        // plain.txt 正常
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("plain.txt").path))
    }

    /// initialPolicy 直接设为 .applyReplace → 全程不回调，遇到冲突直接 replace。
    func testTransferPolicy_initialApplyReplace_noCallback() throws {
        let dst = try makeDirectory("dst")
        try Data("old".utf8).write(to: dst.appendingPathComponent("a.txt"))
        let src = try writeFile("a.txt", contents: "new")

        var callbackCalled = false
        let result = FileOperationService.transfer(
            [src],
            into: dst,
            move: false,
            initialPolicy: .applyReplace,
            onCollision: { _, _ in
                callbackCalled = true
                return (.stop, false)
            }
        )

        XCTAssertFalse(callbackCalled, "initialPolicy 为 applyReplace 时不应调用回调")
        XCTAssertEqual(result.replaceRecords.count, 1)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "new")
    }

    /// 原有 duplicate / 旧 transfer 行为必须保持不变 —— 确保这次改动没有误伤。
    func testOldTransferAndDuplicate_stillWork() throws {
        // 旧 transfer：冲突自动生成 2
        let dst = try makeDirectory("dst")
        try Data("old".utf8).write(to: dst.appendingPathComponent("x.txt"))
        let srcT = try writeFile("x.txt", contents: "new")
        let r1 = FileOperationService.transfer([srcT], into: dst, move: false)
        XCTAssertTrue(r1.replaceRecords.isEmpty, "旧 transfer 不会用 replaceRecords")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("x 2.txt").path))

        // duplicate：Cmd+D 风格自动生成 2
        let srcD = try writeFile("dupme.png", contents: "d")
        let r2 = FileOperationService.duplicate([srcD])
        XCTAssertTrue(r2.replaceRecords.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("dupme 2.png").path))
    }
}
