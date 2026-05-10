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
}

/// Compact dot rendered next to file names when a Finder colour
/// label is set. ~7 pt diameter so it sits inline without growing
/// the row height. Renders nothing for entries without a label.
struct TagDotView: View {
    let entry: FileEntry

    var body: some View {
        if let color = TagColor.color(for: entry) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .help(entry.tagNames.joined(separator: ", "))
        }
    }
}

/// Lightweight projection used by the sidebar's "Tags" section —
/// one entry per unique tag *name* observed in a folder, paired
/// with the colour-label index of the first row that carried that
/// name. macOS attaches a single primary label per file, so a
/// row's second/third tag names land here with `labelNumber: 0`
/// (no swatch) until the user explicitly recolours them.
struct TagSummary: Hashable, Identifiable {
    let name: String
    let labelNumber: Int
    var id: String { name }
}

extension Sequence where Element == FileEntry {
    /// Walk the sequence, collecting unique tag names in first-
    /// appearance order. Pairs the leading tag of each entry with
    /// `entry.labelNumber` so the swatch beside that tag matches
    /// what Finder draws for the row.
    func uniqueTagSummaries() -> [TagSummary] {
        var seen = Set<String>()
        var result: [TagSummary] = []
        for entry in self {
            for (offset, name) in entry.tagNames.enumerated() {
                guard seen.insert(name).inserted else { continue }
                let label = offset == 0 ? entry.labelNumber : 0
                result.append(TagSummary(name: name, labelNumber: label))
            }
        }
        return result
    }
}
