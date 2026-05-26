import Foundation

public extension String {
    /// True if this string's UTF-8 bytes are NOT already in NFC form —
    /// i.e., a real NFC normalisation pass would produce different
    /// bytes on disk.
    ///
    /// Swift's `String ==` collapses canonically-equivalent strings,
    /// so the obvious check
    /// `self != precomposedStringWithCanonicalMapping` always returns
    /// `false` even on truly decomposed input. Comparing the UTF-8
    /// byte sequences is the only way to see the underlying encoding
    /// difference. Verified against on-disk Hangul filenames written
    /// by Python's `unicodedata.normalize('NFD', …)` round-trip —
    /// `==` reported equal, `utf8.elementsEqual` reported different.
    ///
    /// Used to gate the "Normalize Filename to NFC" context-menu
    /// item and the drag-out auto-normalisation path.
    var isDecomposedRelativeToNFC: Bool {
        let nfc = precomposedStringWithCanonicalMapping
        return !utf8.elementsEqual(nfc.utf8)
    }
}
