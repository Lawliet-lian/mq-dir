import SwiftUI

/// Map a Finder colour-label index (`URLResourceKey.labelNumberKey`,
/// 0-7) to its display colour. The order mirrors macOS Finder's
/// label palette as it has shipped since Mavericks; values outside
/// 1-7 (including the explicit "no label" 0) collapse to `nil` so
/// callers can hide the dot rather than render a placeholder.
///
/// This is a name-free mapping on purpose: `tagNamesKey` returns
/// localised strings ("Red" vs "빨강"), so matching by name would
/// miss any non-English system. The labelNumber survives
/// localisation untouched.
enum TagColor {
    /// Ordered list of the seven Finder colour labels in the same order
    /// Finder's own tag picker uses (Red → Gray). The tag picker submenu
    /// iterates this so the menu always shows all seven, in a familiar
    /// order, regardless of which subset the file currently carries.
    static let allLabels: [Int] = [6, 7, 5, 2, 4, 3, 1]

    static func color(forLabel index: Int) -> Color? {
        switch index {
        case 1: return .gray
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return nil
        }
    }

    /// Convenience for views that already carry a `FileEntry` —
    /// skips the index plumbing at the call site.
    static func color(for entry: FileEntry) -> Color? {
        color(forLabel: entry.labelNumber)
    }

    /// Locale-aware display name for the standard Finder colour `label`.
    /// Used as the tag-name string written to `_kMDItemUserTags` when
    /// the user picks a colour from the context-menu Tags submenu, so
    /// the value mq-dir stores matches what a Korean (or English) user
    /// would have seen if they'd tagged the file in Finder instead.
    /// Custom Finder tag-renames (e.g. user renamed "Red" to "긴급")
    /// aren't honoured — public API for the user's customised palette
    /// doesn't exist, so we stick with the system defaults.
    static func displayName(forLabel label: Int) -> String {
        let isKorean = Locale.current.language.languageCode?.identifier == "ko"
        if isKorean {
            switch label {
            case 1: return "회색"
            case 2: return "초록"
            case 3: return "보라"
            case 4: return "파랑"
            case 5: return "노랑"
            case 6: return "빨강"
            case 7: return "주황"
            default: return ""
            }
        } else {
            switch label {
            case 1: return "Gray"
            case 2: return "Green"
            case 3: return "Purple"
            case 4: return "Blue"
            case 5: return "Yellow"
            case 6: return "Red"
            case 7: return "Orange"
            default: return ""
            }
        }
    }
}

/// Compact swatches rendered next to file names for every Finder
/// colour tag a row carries. ~7 pt diameter so a single swatch sits
/// inline; multi-coloured rows stack horizontally with a 2 pt gap,
/// matching Finder's column-view treatment. Renders nothing when no
/// tag has a colour assigned — uncoloured custom tags still surface
/// through the tooltip so the user can see they exist.
struct TagDotView: View {
    let entry: FileEntry

    var body: some View {
        let swatches = colouredSwatches
        if !swatches.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
            }
            .help(entry.tagNames.joined(separator: ", "))
        }
    }

    /// Resolve every per-tag colour the row carries, in declaration
    /// order, deduplicating consecutive same-colour entries so two
    /// "Red"-tagged rows don't show two identical dots. Falls back to
    /// `labelNumber` when `tagColors` is empty — covers entries that
    /// somehow lack the parsed xattr but still carry a primary label.
    private var colouredSwatches: [Color] {
        let indices: [Int]
        if entry.tagColors.isEmpty {
            indices = entry.labelNumber > 0 ? [entry.labelNumber] : []
        } else {
            indices = entry.tagColors
        }
        var seen = Set<Int>()
        var colours: [Color] = []
        for index in indices {
            guard index > 0, seen.insert(index).inserted,
                  let colour = TagColor.color(forLabel: index)
            else { continue }
            colours.append(colour)
        }
        return colours
    }
}

/// Lightweight projection used by the sidebar's "Tags" section —
/// one entry per unique tag *name* observed in a folder, paired
/// with the colour-label index from that name's own xattr entry.
struct TagSummary: Hashable, Identifiable {
    let name: String
    let labelNumber: Int
    var id: String { name }
}

extension Sequence where Element == FileEntry {
    /// Walk the sequence, collecting unique tag names in first-
    /// appearance order. The swatch index comes from `tagColors`
    /// (parsed from the per-tag xattr) so a tag like "Red"
    /// appearing as a row's second tag still gets its real swatch
    /// instead of dropping to zero like the old labelNumber-only
    /// path used to.
    func uniqueTagSummaries() -> [TagSummary] {
        var seen = Set<String>()
        var result: [TagSummary] = []
        for entry in self {
            for (offset, name) in entry.tagNames.enumerated() {
                guard seen.insert(name).inserted else { continue }
                let label: Int
                if offset < entry.tagColors.count {
                    label = entry.tagColors[offset]
                } else if offset == 0 {
                    label = entry.labelNumber
                } else {
                    label = 0
                }
                result.append(TagSummary(name: name, labelNumber: label))
            }
        }
        return result
    }
}
