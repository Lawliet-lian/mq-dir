import XCTest
@testable import mqdirCore

/// Decode-path coverage for `ShortcutKey` — the hand-rolled `Codable`
/// that backs persisted shortcut overrides. Pins the throw paths
/// (empty/multi-char character, out-of-range function key, unknown
/// kind) and the functionKey round-trip, so a hand-edited or
/// future-build `state.json` degrades predictably.
final class ShortcutBindingTests: XCTestCase {

    private func decodeKey(_ json: String) throws -> ShortcutKey {
        try JSONDecoder().decode(ShortcutKey.self, from: Data(json.utf8))
    }

    /// An empty `character` string has no first scalar — must throw rather
    /// than produce a bindless key.
    func testEmptyCharacterStringThrows() {
        XCTAssertThrowsError(try decodeKey(#"{"kind":"character","character":""}"#),
                             "an empty character string must throw, not silently produce no key")
    }

    /// A multi-character `character` string must throw. Previously the
    /// decoder silently truncated to the first scalar ("ab" → "a"); the
    /// sanctioned tightening (`guard str.count == 1`) now rejects it,
    /// matching the rigor the functionKey range check already enforces.
    func testMultiCharacterStringThrows() {
        XCTAssertThrowsError(try decodeKey(#"{"kind":"character","character":"ab"}"#),
                             "a multi-character string must throw instead of truncating to the first char")
    }

    /// A single-character string still decodes cleanly — the tightening
    /// only rejects count != 1.
    func testSingleCharacterStringDecodes() throws {
        let key = try decodeKey(#"{"kind":"character","character":"q"}"#)
        XCTAssertEqual(key, .character("q"))
    }

    /// Function-key numbers outside 1...12 must throw (here: 0 and 13).
    func testOutOfRangeFunctionKeyThrows() {
        XCTAssertThrowsError(try decodeKey(#"{"kind":"functionKey","number":0}"#),
                             "F0 is out of the 1...12 range and must throw")
        XCTAssertThrowsError(try decodeKey(#"{"kind":"functionKey","number":13}"#),
                             "F13 is out of the 1...12 range and must throw")
    }

    /// An unrecognised `kind` discriminator must throw — the union is
    /// closed (no `.unknown` fallback) by design.
    func testUnknownKindThrows() {
        XCTAssertThrowsError(try decodeKey(#"{"kind":"joystick"}"#),
                             "an unknown ShortcutKey kind must throw, keeping the union closed")
    }

    /// Every function key F1...F12 must survive an encode → decode cycle
    /// byte-for-byte.
    func testFunctionKeyRoundTrips() throws {
        for n in 1...12 {
            let original = ShortcutKey.functionKey(n)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ShortcutKey.self, from: data)
            XCTAssertEqual(decoded, original, "F\(n) must round-trip through Codable")
        }
    }

    /// A full `ShortcutBinding` carrying a function key must round-trip,
    /// confirming the key encodes inside the binding wrapper too.
    func testFunctionKeyBindingRoundTrips() throws {
        let binding = ShortcutBinding(key: .functionKey(5), modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
    }
}
