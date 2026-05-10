import Foundation

/// The 10 actions exposed to the Settings → Shortcuts customiser.
/// Each carries a stable `rawValue` so persisted overrides survive
/// case reorders. Adding a new customisable shortcut here drives
/// both `WorkspaceSettings.shortcutOverrides` and the Settings UI
/// row generator without touching either call site.
public enum ShortcutAction: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    case moveToTrash
    case deleteImmediately
    case newTab
    case closeTab
    case reload
    case find
    case openFolder
    case parentFolder
    case togglePreview
    case addToFavorites

    /// Human-readable label rendered in the Settings list.
    public var label: String {
        switch self {
        case .moveToTrash:       return "Move to Trash"
        case .deleteImmediately: return "Delete Immediately"
        case .newTab:            return "New Tab"
        case .closeTab:          return "Close Tab"
        case .reload:            return "Reload"
        case .find:              return "Find"
        case .openFolder:        return "Open Folder"
        case .parentFolder:      return "Parent Folder"
        case .togglePreview:     return "Show Preview"
        case .addToFavorites:    return "Add to Favorites"
        }
    }

    /// Out-of-the-box binding for this action — what the menu shows
    /// when the user has not overridden it. Source of truth for the
    /// "Restore Defaults" button in Settings.
    public var defaultBinding: ShortcutBinding {
        switch self {
        case .moveToTrash:       return ShortcutBinding(key: .delete,  modifiers: .command)
        case .deleteImmediately: return ShortcutBinding(key: .delete,  modifiers: [.command, .option])
        case .newTab:            return ShortcutBinding(key: .character("t"), modifiers: .command)
        case .closeTab:          return ShortcutBinding(key: .character("w"), modifiers: .command)
        case .reload:            return ShortcutBinding(key: .character("r"), modifiers: .command)
        case .find:              return ShortcutBinding(key: .character("f"), modifiers: .command)
        case .openFolder:        return ShortcutBinding(key: .character("o"), modifiers: .command)
        case .parentFolder:      return ShortcutBinding(key: .upArrow, modifiers: .command)
        case .togglePreview:     return ShortcutBinding(key: .character("p"), modifiers: [.command, .shift])
        case .addToFavorites:    return ShortcutBinding(key: .character("d"), modifiers: .command)
        }
    }
}

/// Modifier flags carried by a `ShortcutBinding`. Mirrors SwiftUI's
/// `EventModifiers` but lives in mqdirCore so persisted bindings
/// don't drag SwiftUI into the headless test target. The raw values
/// are stable and chosen to overlap with `EventModifiers.rawValue`
/// where possible, but we serialise via the `Codable` synthesised
/// names rather than the raw bitmask so a future enum reorder in
/// SwiftUI can't shift our persisted bytes.
public struct ShortcutModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// The key half of a `ShortcutBinding`. `character` covers letter /
/// digit / punctuation keys typed straight off the keyboard;
/// `delete` / `return` / `escape` / `tab` / `upArrow` / `downArrow`
/// / `leftArrow` / `rightArrow` are the named keys SwiftUI exposes
/// through `KeyEquivalent`. Keeping the union closed (no
/// `.unknown` fallback) means the matcher in mq-dir can produce a
/// non-optional `KeyboardShortcut`.
public enum ShortcutKey: Codable, Sendable, Hashable {
    case character(Character)
    case delete
    case `return`
    case escape
    case tab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow

    private enum CodingKeys: String, CodingKey { case kind, character }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "character":
            let str = try c.decode(String.self, forKey: .character)
            guard let first = str.first else {
                throw DecodingError.dataCorruptedError(
                    forKey: .character,
                    in: c,
                    debugDescription: "ShortcutKey.character decoded with empty string"
                )
            }
            self = .character(first)
        case "delete":     self = .delete
        case "return":     self = .return
        case "escape":     self = .escape
        case "tab":        self = .tab
        case "upArrow":    self = .upArrow
        case "downArrow":  self = .downArrow
        case "leftArrow":  self = .leftArrow
        case "rightArrow": self = .rightArrow
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown ShortcutKey kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .character(let ch):
            try c.encode("character", forKey: .kind)
            try c.encode(String(ch), forKey: .character)
        case .delete:     try c.encode("delete", forKey: .kind)
        case .return:     try c.encode("return", forKey: .kind)
        case .escape:     try c.encode("escape", forKey: .kind)
        case .tab:        try c.encode("tab", forKey: .kind)
        case .upArrow:    try c.encode("upArrow", forKey: .kind)
        case .downArrow:  try c.encode("downArrow", forKey: .kind)
        case .leftArrow:  try c.encode("leftArrow", forKey: .kind)
        case .rightArrow: try c.encode("rightArrow", forKey: .kind)
        }
    }
}

/// A user-customisable keyboard shortcut. mqdirCore owns the
/// representation; mq-dir's UI layer maps `ShortcutBinding` to
/// `SwiftUI.KeyboardShortcut` for menu attachment and to a
/// human-readable display string ("⌘⌫", "⌥⌘1") for the Settings
/// row label.
public struct ShortcutBinding: Codable, Equatable, Sendable, Hashable {
    public var key: ShortcutKey
    public var modifiers: ShortcutModifiers

    public init(key: ShortcutKey, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
