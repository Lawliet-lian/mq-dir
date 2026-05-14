import AppKit
import SwiftUI

extension ShortcutKey {
    /// SwiftUI `KeyEquivalent` for this key. The named cases map
    /// 1:1 onto SwiftUI's pre-defined equivalents; `character`
    /// wraps the user's typed key directly.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let ch): return KeyEquivalent(ch)
        case .delete:            return .delete
        case .return:            return .return
        case .escape:            return .escape
        case .tab:               return .tab
        case .upArrow:           return .upArrow
        case .downArrow:         return .downArrow
        case .leftArrow:         return .leftArrow
        case .rightArrow:        return .rightArrow
        case .functionKey(let n):
            // AppKit's NSF<N>FunctionKey constants start at 0xF704
            // (F1) and run contiguously through F12 at 0xF70F. Wrap
            // that scalar in a `KeyEquivalent` so SwiftUI's
            // `.keyboardShortcut` registers the menu item exactly
            // the way an explicit ⌘F-with-shift would have done.
            let scalar = UnicodeScalar(0xF703 + n)!
            return KeyEquivalent(Character(scalar))
        }
    }

    /// Glyph used in the Settings row preview. Mirrors what macOS
    /// renders in the menu bar (⌫, ↩, ⎋, ⇥, ↑, ↓, ←, →) so the
    /// user sees exactly the symbol they'll see at the menu site.
    var displayGlyph: String {
        switch self {
        case .character(let ch):
            // Letter keys render in upper case in macOS menus
            // ("⌘W", not "⌘w") regardless of how the user typed
            // them. Non-letters pass through unchanged.
            let str = String(ch)
            return ch.isLetter ? str.uppercased() : str
        case .delete:     return "\u{232B}"   // ⌫
        case .return:     return "\u{21A9}"   // ↩
        case .escape:     return "\u{238B}"   // ⎋
        case .tab:        return "\u{21E5}"   // ⇥
        case .upArrow:    return "\u{2191}"   // ↑
        case .downArrow:  return "\u{2193}"   // ↓
        case .leftArrow:  return "\u{2190}"   // ←
        case .rightArrow: return "\u{2192}"   // →
        case .functionKey(let n): return "F\(n)"
        }
    }
}

extension ShortcutModifiers {
    /// SwiftUI `EventModifiers` for this set. The two enums are
    /// not the same type but the bit pattern carries the same
    /// meaning, so the conversion just iterates the four flags.
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift)   { result.insert(.shift) }
        if contains(.option)  { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    /// macOS modifier glyph string, in the order Apple uses in the
    /// menu bar (⌃⌥⇧⌘). Returned together so callers can append
    /// the key glyph directly: `modifierGlyphs + key.displayGlyph`.
    var displayGlyphs: String {
        var s = ""
        if contains(.control) { s += "\u{2303}" }  // ⌃
        if contains(.option)  { s += "\u{2325}" }  // ⌥
        if contains(.shift)   { s += "\u{21E7}" }  // ⇧
        if contains(.command) { s += "\u{2318}" }  // ⌘
        return s
    }

    /// Build a `ShortcutModifiers` from an AppKit `NSEvent`'s
    /// `modifierFlags`. Used by the Settings capture flow so a
    /// keyDown event's flags map straight onto a persistable
    /// binding.
    init(eventFlags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.command) { result.insert(.command) }
        if eventFlags.contains(.shift)   { result.insert(.shift) }
        if eventFlags.contains(.option)  { result.insert(.option) }
        if eventFlags.contains(.control) { result.insert(.control) }
        self = result
    }
}

extension ShortcutBinding {
    /// Combined ⌃⌥⇧⌘<key> string for the Settings preview.
    var displayString: String {
        modifiers.displayGlyphs + key.displayGlyph
    }
}

extension View {
    /// Attach `binding` as the receiver's keyboard shortcut. Wraps
    /// the SwiftUI form so the menu builder reads as a single line:
    /// `Button("...") { ... }.keyboardShortcut(binding)`.
    func keyboardShortcut(_ binding: ShortcutBinding) -> some View {
        self.keyboardShortcut(binding.key.keyEquivalent, modifiers: binding.modifiers.eventModifiers)
    }
}
