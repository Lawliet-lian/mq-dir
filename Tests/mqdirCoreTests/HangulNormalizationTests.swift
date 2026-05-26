import XCTest
@testable import mqdirCore

/// Tests for the `String.isDecomposedRelativeToNFC` detection
/// helper. The interesting bit is that Swift's `String ==` collapses
/// canonically-equivalent strings, so a NFD/NFC pair compares equal
/// even though their UTF-8 bytes differ — the previous v1
/// implementation used `==` as its NFD detector and silently
/// reported every NFD filename as already-normalised, which made
/// the right-click menu item never show and the drag-out
/// auto-normalisation a no-op.
final class HangulNormalizationTests: XCTestCase {

    func testNFCHangulIsNotFlaggedAsDecomposed() {
        // String literals in Swift source are NFC by default.
        XCTAssertFalse("안녕".isDecomposedRelativeToNFC,
                       "a composed Hangul string must not register as decomposed")
        XCTAssertFalse("클라이언트A_보고서.md".isDecomposedRelativeToNFC,
                       "mixed Hangul + ASCII in NFC must not register as decomposed")
    }

    func testNFDHangulIsFlaggedAsDecomposed() {
        let nfd = "안녕".decomposedStringWithCanonicalMapping
        XCTAssertTrue(nfd.isDecomposedRelativeToNFC,
                      "a decomposed Hangul string must register as decomposed despite Swift's String == treating it as equal to the NFC form")
    }

    func testAsciiIsNotFlaggedAsDecomposed() {
        XCTAssertFalse("english_file.txt".isDecomposedRelativeToNFC)
        XCTAssertFalse("".isDecomposedRelativeToNFC,
                       "an empty string has no decomposition difference")
    }

    func testSwiftEqualityIsNormalisationAware() {
        // This is the canary that justifies the helper's existence:
        // if some future Swift release changes `==` to be
        // byte-strict, the helper's docstring needs revisiting.
        let nfd = "안녕".decomposedStringWithCanonicalMapping
        let nfc = "안녕".precomposedStringWithCanonicalMapping
        XCTAssertEqual(nfd, nfc,
                       "Swift String == must be normalisation-aware for the helper's premise to hold")
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8),
                          "underlying UTF-8 bytes must actually differ")
    }
}
