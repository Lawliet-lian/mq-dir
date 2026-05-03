import Foundation

/// How a tab renders its current folder.
///
/// `list` keeps the existing four-column flat list (Name / Modified / Size /
/// Kind), the M0 default and what every existing tab gets at restore.
/// `tree` switches to a single-column hierarchical view with disclosure
/// triangles — VS Code Explorer-style — for users who want to see their
/// folder structure at a glance and keep multiple branches expanded at
/// once. View mode is per-tab so two tabs on the same folder can render
/// it differently without interfering.
enum PaneViewMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case list
    case tree

    var id: Self { self }
}
