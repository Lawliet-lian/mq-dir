import XCTest
@testable import mqdirCore

/// Pure unit coverage for the multi-select range math extracted out of
/// `FolderBrowserViewModel`. No filesystem, no view, no view mode — the
/// caller supplies the already-ordered visible row IDs.
///
/// These tests pin two documented historical bugs the extraction had to
/// preserve the *fixes* for:
///   1. Shift-extend grows from the fixed anchor, not from the last extend.
///   2. Shift+arrow steps the cursor (so a held Shift+↓ keeps growing) rather
///      than re-deriving `anchor + 1` and capping at two rows.
final class SelectionModelTests: XCTestCase {

    // `FileEntry.ID` is `URL`. Build a stable ordered list of row IDs.
    private func rows(_ count: Int) -> [FileEntry.ID] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/row\($0)") }
    }

    private func id(_ index: Int) -> FileEntry.ID {
        URL(fileURLWithPath: "/tmp/row\(index)")
    }

    // MARK: replace / toggle basics

    func testReplaceSetsSingleSelectionAndBothEndpoints() {
        var model = SelectionModel()
        model.replace(with: id(3))
        XCTAssertEqual(model.selectedIDs, [id(3)])
        XCTAssertEqual(model.anchor, id(3))
        XCTAssertEqual(model.cursor, id(3))
    }

    func testReplaceCollapsesAnExistingMultiSelection() {
        var model = SelectionModel(selectedIDs: [id(1), id(2), id(3)], anchor: id(1), cursor: id(3))
        model.replace(with: id(5))
        XCTAssertEqual(model.selectedIDs, [id(5)])
        XCTAssertEqual(model.anchor, id(5))
        XCTAssertEqual(model.cursor, id(5))
    }

    func testToggleAddsAbsentRowAndReseatsEndpoints() {
        var model = SelectionModel(selectedIDs: [id(1)], anchor: id(0), cursor: id(0))
        model.toggle(id(4))
        XCTAssertEqual(model.selectedIDs, [id(1), id(4)])
        XCTAssertEqual(model.anchor, id(4))
        XCTAssertEqual(model.cursor, id(4))
    }

    func testToggleRemovesPresentRowButStillReseatsEndpointsOntoIt() {
        // The VM reseats anchor/cursor onto the just-clicked row even on a
        // remove — pinning that exact behaviour.
        var model = SelectionModel(selectedIDs: [id(1), id(4)], anchor: id(1), cursor: id(1))
        model.toggle(id(4))
        XCTAssertEqual(model.selectedIDs, [id(1)])
        XCTAssertEqual(model.anchor, id(4))
        XCTAssertEqual(model.cursor, id(4))
    }

    // MARK: Shift-extend

    func testShiftExtendSelectsContiguousRange() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(2))            // click row 2
        model.extend(to: id(5), in: r)        // shift-click row 5
        XCTAssertEqual(model.selectedIDs, Set([2, 3, 4, 5].map(id)))
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(5))
    }

    func testShiftExtendGrowsFromAnchorNotFromLastExtend() {
        // Documented bug: a second, farther shift-click must grow from the
        // ORIGINAL anchor (row 2), producing 2…8 — not 5…8.
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(2))
        model.extend(to: id(5), in: r)
        model.extend(to: id(8), in: r)
        XCTAssertEqual(model.selectedIDs, Set([2, 3, 4, 5, 6, 7, 8].map(id)))
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(8))
    }

    func testShiftExtendFlipsDirectionAcrossTheAnchor() {
        // After 2…5, a shift-click on row 0 flips below the anchor → 0…2.
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(2))
        model.extend(to: id(5), in: r)
        model.extend(to: id(0), in: r)
        XCTAssertEqual(model.selectedIDs, Set([0, 1, 2].map(id)))
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(0))
    }

    func testExtendWithNoAnchorFallsBackToReplace() {
        let r = rows(10)
        var model = SelectionModel()           // no anchor
        model.extend(to: id(4), in: r)
        XCTAssertEqual(model.selectedIDs, [id(4)])
        XCTAssertEqual(model.anchor, id(4))
        XCTAssertEqual(model.cursor, id(4))
    }

    func testExtendWhenAnchorMissingFromRowsFallsBackToReplace() {
        // The anchored row was deleted on a reload, so it's no longer in the
        // ordered rows. The VM degraded this to a plain replace on the target
        // — pin exactly that.
        let r = rows(5)
        var model = SelectionModel(selectedIDs: [id(99)], anchor: id(99), cursor: id(99))
        model.extend(to: id(2), in: r)
        XCTAssertEqual(model.selectedIDs, [id(2)])
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(2))
    }

    func testExtendWhenTargetMissingFromRowsFallsBackToReplace() {
        let r = rows(5)
        var model = SelectionModel()
        model.replace(with: id(1))
        model.extend(to: id(99), in: r)        // target not present
        XCTAssertEqual(model.selectedIDs, [id(99)])
        XCTAssertEqual(model.anchor, id(99))
        XCTAssertEqual(model.cursor, id(99))
    }

    // MARK: moveSelection — from single selection

    func testMoveDownFromSingleSelectionStepsOneRow() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(3))
        model.move(by: 1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(4)])
        XCTAssertEqual(model.anchor, id(4))
        XCTAssertEqual(model.cursor, id(4))
    }

    func testMoveUpFromSingleSelectionStepsOneRow() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(3))
        model.move(by: -1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(2)])
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(2))
    }

    // MARK: moveSelection — no prior selection (Finder convention)

    func testMoveDownWithNoSelectionLandsOnFirstRow() {
        let r = rows(10)
        var model = SelectionModel()
        model.move(by: 1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(0)])
        XCTAssertEqual(model.anchor, id(0))
        XCTAssertEqual(model.cursor, id(0))
    }

    func testMoveUpWithNoSelectionLandsOnLastRow() {
        let r = rows(10)
        var model = SelectionModel()
        model.move(by: -1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(9)])
        XCTAssertEqual(model.anchor, id(9))
        XCTAssertEqual(model.cursor, id(9))
    }

    func testMoveWithSelectionWhoseRowsAreAllMissingLandsOnEdge() {
        // Selection set is non-empty but its members aren't in `rows`
        // (post-reload stale IDs). Pivot fails AND `selectedIDs.first` fails,
        // so it falls through to the edge-landing branch.
        let r = rows(10)
        var model = SelectionModel(selectedIDs: [id(99)], anchor: id(99), cursor: id(99))
        model.move(by: 1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(0)])
        XCTAssertEqual(model.anchor, id(0))
        XCTAssertEqual(model.cursor, id(0))
    }

    // MARK: moveSelection — edge clamping

    func testMoveUpAtTopRowClampsInPlace() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(0))
        model.move(by: -1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(0)])
        XCTAssertEqual(model.cursor, id(0))
    }

    func testMoveDownAtBottomRowClampsInPlace() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(9))
        model.move(by: 1, extending: false, in: r)
        XCTAssertEqual(model.selectedIDs, [id(9)])
        XCTAssertEqual(model.cursor, id(9))
    }

    func testMoveOnEmptyRowsIsNoOp() {
        var model = SelectionModel(selectedIDs: [id(1)], anchor: id(1), cursor: id(1))
        let before = model
        model.move(by: 1, extending: false, in: [])
        XCTAssertEqual(model, before)
    }

    // MARK: moveSelection — extending (Shift held)

    func testShiftMoveDownExtendsFromAnchorAndKeepsGrowing() {
        // Pin the documented fix: each Shift+↓ steps the CURSOR, so a held
        // Shift+↓ keeps growing the range instead of capping at two rows.
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(2))                       // anchor=2, cursor=2
        model.move(by: 1, extending: true, in: r)        // → 2…3, cursor 3
        XCTAssertEqual(model.selectedIDs, Set([2, 3].map(id)))
        XCTAssertEqual(model.cursor, id(3))

        model.move(by: 1, extending: true, in: r)        // → 2…4, cursor 4
        XCTAssertEqual(model.selectedIDs, Set([2, 3, 4].map(id)))
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(4))
    }

    func testShiftMoveUpAcrossAnchorShrinksThenFlips() {
        let r = rows(10)
        var model = SelectionModel()
        model.replace(with: id(2))
        model.move(by: 1, extending: true, in: r)        // 2…3
        model.move(by: -1, extending: true, in: r)       // cursor 3→2 ⇒ 2…2
        XCTAssertEqual(model.selectedIDs, [id(2)])
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(2))

        model.move(by: -1, extending: true, in: r)       // cursor 2→1 ⇒ 1…2
        XCTAssertEqual(model.selectedIDs, Set([1, 2].map(id)))
        XCTAssertEqual(model.anchor, id(2))
        XCTAssertEqual(model.cursor, id(1))
    }

    func testShiftMoveExtendingWithAnchorMissingDegradesToReplace() {
        // anchor was deleted, but cursor is still a live row. Pivot resolves
        // off the cursor, but the `extending && anchor present` guard fails,
        // so the move degrades to a plain replace on the destination — the
        // VM's exact fall-through.
        let r = rows(10)
        var model = SelectionModel(selectedIDs: [id(3)], anchor: id(99), cursor: id(3))
        model.move(by: 1, extending: true, in: r)
        XCTAssertEqual(model.selectedIDs, [id(4)])
        XCTAssertEqual(model.anchor, id(4))
        XCTAssertEqual(model.cursor, id(4))
    }

    // MARK: selectAll / clear

    func testSelectAllSelectsEveryRowAndSpansEndpoints() {
        let r = rows(6)
        var model = SelectionModel()
        model.selectAll(in: r)
        XCTAssertEqual(model.selectedIDs, Set(r))
        XCTAssertEqual(model.anchor, id(0))
        XCTAssertEqual(model.cursor, id(5))
    }

    func testSelectAllOnEmptyRowsLeavesStateUntouched() {
        var model = SelectionModel(selectedIDs: [id(1)], anchor: id(1), cursor: id(1))
        let before = model
        model.selectAll(in: [])
        XCTAssertEqual(model, before)
    }

    func testClearWipesSelectionAndEndpoints() {
        var model = SelectionModel(selectedIDs: [id(1), id(2)], anchor: id(1), cursor: id(2))
        let changed = model.clear()
        XCTAssertTrue(changed)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertNil(model.anchor)
        XCTAssertNil(model.cursor)
    }

    func testClearOnEmptySelectionReportsNoChange() {
        var model = SelectionModel()
        XCTAssertFalse(model.clear())
    }
}
