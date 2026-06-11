import Foundation

/// Pure, value-type multi-select state machine for a file pane.
///
/// Extracted out of `FolderBrowserViewModel` so the range math — which
/// carried two historical bugs (Shift-range growth capping at two rows, and
/// tree-mode picking the wrong row axis) and had zero coverage — can be
/// exercised by `swift test` without a filesystem, a view, or a view mode.
///
/// The model knows nothing about view mode, tree flattening, search filtering,
/// or row caching. Every range operation takes the *already-ordered* visible
/// rows (`[FileEntry.ID]`) the caller wants to walk — the VM supplies the
/// list-mode flat order or the tree-mode DFS flatten as appropriate. That
/// keeps this type a pure function of (state, ordered rows) → new state.
///
/// `FileEntry.ID` is `URL`, which is `Hashable & Sendable`, so the whole
/// struct is trivially `Sendable`. Access level matches `FileEntry`
/// (module-internal): the app target compiles into the same Xcode module and
/// the unit tests use `@testable import`, so `public` would only leak the
/// internal `FileEntry.ID` and buys nothing.
struct SelectionModel: Sendable, Equatable {
    /// The set of currently-selected row IDs. Set-iteration order, matching
    /// the `@Published var selection` the views bind to.
    private(set) var selectedIDs: Set<FileEntry.ID>

    /// Fixed end of an active range — set by a plain click / replace and held
    /// across Shift-extends so successive extends grow *from the anchor*.
    private(set) var anchor: FileEntry.ID?

    /// Trailing edge of an active range — Finder calls this the "cursor".
    /// Shift+arrow / Shift-click advance the cursor while the anchor stays
    /// put, so a held Shift+↓ grows the selection instead of capping at two
    /// rows (the documented bug: a single anchor-relative index would
    /// recompute `anchor + 1` every press).
    private(set) var cursor: FileEntry.ID?

    init(
        selectedIDs: Set<FileEntry.ID> = [],
        anchor: FileEntry.ID? = nil,
        cursor: FileEntry.ID? = nil
    ) {
        self.selectedIDs = selectedIDs
        self.anchor = anchor
        self.cursor = cursor
    }

    /// Collapse the selection to a single row and (re)set both endpoints to
    /// it. This is the plain-click / single-target path; every fallback in
    /// the range operations funnels back through here.
    mutating func replace(with id: FileEntry.ID) {
        selectedIDs = [id]
        anchor = id
        cursor = id
    }

    /// Cmd-click toggle: add the row if absent, remove it if present. Either
    /// way the row becomes the new anchor *and* cursor — matching the VM's
    /// original behaviour, where a toggle (even a remove) reseats both
    /// endpoints onto the just-clicked row.
    mutating func toggle(_ id: FileEntry.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchor = id
        cursor = id
    }

    /// Shift-click extend: select the contiguous range from the anchor to
    /// `id` within `orderedRows`. The anchor is held fixed (so a follow-up
    /// extend to a farther row grows from the original anchor, not from the
    /// last extend), and the cursor advances to `id`.
    ///
    /// Falls back to `replace(with: id)` when there's no anchor, or when
    /// either endpoint isn't present in `orderedRows` (e.g. the anchored row
    /// was deleted out from under the selection on a reload, or the caller
    /// passed the wrong axis for the current view mode). This mirrors the
    /// VM's exact guard.
    mutating func extend(to id: FileEntry.ID, in orderedRows: [FileEntry.ID]) {
        guard let anchor,
              let anchorIdx = orderedRows.firstIndex(of: anchor),
              let targetIdx = orderedRows.firstIndex(of: id)
        else {
            replace(with: id)
            return
        }
        let lower = min(anchorIdx, targetIdx)
        let upper = max(anchorIdx, targetIdx)
        selectedIDs = Set(orderedRows[lower...upper])
        cursor = id
    }

    /// Move the selection up (`offset < 0`) or down (`offset > 0`) by
    /// `offset` rows within `orderedRows`. With `extending: true` (Shift
    /// held) grows the range from the anchor instead of replacing it. No-op
    /// on an empty row list.
    ///
    /// Pivot rules (ported verbatim from the VM):
    /// - The keypress steps *from* the cursor when extending (keeping the
    ///   anchor fixed), or from the anchor when not — this is what un-caps
    ///   Shift+↓ growth.
    /// - When neither the pivot nor `selectedIDs.first` resolves in
    ///   `orderedRows`, there's no prior position to step from: arrow-down
    ///   lands on the first row, arrow-up on the last (Finder convention),
    ///   via a plain replace.
    /// - The destination index is clamped to `[0, count - 1]` (no wrap).
    /// - When extending but the anchor isn't present in `orderedRows`, the
    ///   extend degrades to a plain replace on the destination row — the
    ///   same fall-through the VM had.
    mutating func move(by offset: Int, extending: Bool, in orderedRows: [FileEntry.ID]) {
        guard !orderedRows.isEmpty else { return }

        let pivotID: FileEntry.ID? = extending ? (cursor ?? anchor) : anchor
        let currentIdx: Int
        if let pivot = pivotID,
           let idx = orderedRows.firstIndex(of: pivot) {
            currentIdx = idx
        } else if let firstID = selectedIDs.first,
                  let idx = orderedRows.firstIndex(of: firstID) {
            currentIdx = idx
        } else {
            // No prior selection — arrow-down lands on the first row,
            // arrow-up on the last (Finder convention).
            let target = offset >= 0 ? orderedRows.first : orderedRows.last
            guard let target else { return }
            replace(with: target)
            return
        }

        let newIdx = max(0, min(orderedRows.count - 1, currentIdx + offset))
        let target = orderedRows[newIdx]

        if extending,
           let anchor,
           let anchorIdx = orderedRows.firstIndex(of: anchor) {
            let lower = min(anchorIdx, newIdx)
            let upper = max(anchorIdx, newIdx)
            selectedIDs = Set(orderedRows[lower...upper])
            cursor = target
        } else {
            replace(with: target)
        }
    }

    /// Select every row in `orderedRows`. Anchors on the first row and puts
    /// the cursor on the last so a follow-up Shift-extend has a sensible
    /// starting point. No-op on an empty list (state is left untouched).
    mutating func selectAll(in orderedRows: [FileEntry.ID]) {
        guard !orderedRows.isEmpty else { return }
        selectedIDs = Set(orderedRows)
        anchor = orderedRows.first
        cursor = orderedRows.last
    }

    /// Wipe the selection and both endpoints. Returns `false` (a no-op
    /// signal) when there was nothing selected, so the caller can skip a
    /// redundant `@Published` write — matching the VM's `guard !selection
    /// .isEmpty` early return.
    @discardableResult
    mutating func clear() -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        selectedIDs.removeAll()
        anchor = nil
        cursor = nil
        return true
    }
}
