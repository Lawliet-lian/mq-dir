import XCTest
@testable import mqdirCore

final class PersistenceServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mqdir-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stateURL = tempDirectory.appendingPathComponent("state.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        stateURL = nil
    }

    // MARK: - Round trip

    func testSaveAndLoadRoundTrip() throws {
        let service = try PersistenceService(stateURL: stateURL)
        let original = sampleWorkspaceState()

        try service.saveState(original)
        let reloaded = service.loadState()

        XCTAssertEqual(reloaded, original)
    }

    /// Headline product promise check: the UI you left is the UI you return
    /// to. Constructs a *fresh* PersistenceService over the same file URL
    /// to mimic an app relaunch and asserts non-default values survive.
    func testFreshServiceLoadsPreviouslySavedState() throws {
        let writer = try PersistenceService(stateURL: stateURL)
        let original = sampleWorkspaceState()
        try writer.saveState(original)

        let reader = try PersistenceService(stateURL: stateURL)
        let loaded = reader.loadState()

        XCTAssertEqual(loaded, original)
    }

    // MARK: - Missing / corrupt files

    func testLoadReturnsNilForMissingFile() throws {
        let service = try PersistenceService(stateURL: stateURL)
        XCTAssertNil(service.loadState())
    }

    func testLoadReturnsNilForCorruptFile() throws {
        let service = try PersistenceService(stateURL: stateURL)
        try Data("not json at all".utf8).write(to: stateURL)
        XCTAssertNil(service.loadState(), "corrupt JSON must degrade to nil, not throw")
    }

    func testLoadReturnsNilForEmptyFile() throws {
        let service = try PersistenceService(stateURL: stateURL)
        try Data().write(to: stateURL)
        XCTAssertNil(service.loadState())
    }

    // MARK: - Bookmarks

    func testBookmarkRoundTripsForExistingDir() throws {
        // Create a real subdir under our temp scratch space — security-scoped
        // bookmark creation needs an openable path, and a symlinked location
        // like /tmp can fail with "Could not open() the item".
        let target = tempDirectory.appendingPathComponent("bookmarkTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let bookmark = try PersistenceService.makeBookmark(for: target)

        var tab = TabState()
        tab.folderBookmark = bookmark
        let project = Project(
            name: "BookmarkTest",
            state: WindowState(
                layout: .four,
                focusedPaneIndex: 0,
                panes: [
                    PaneState(tabs: [tab]),
                    PaneState(),
                    PaneState(),
                    PaneState()
                ]
            )
        )
        let state = WorkspaceState(
            favorites: [],
            favoritesSeeded: true,
            activeProjectID: project.id,
            projects: [project]
        )

        let service = try PersistenceService(stateURL: stateURL)
        try service.saveState(state)

        let loaded = try XCTUnwrap(service.loadState())
        let loadedBookmark = try XCTUnwrap(
            loaded.projects[0].state.panes[0].tabs[0].folderBookmark
        )
        let resolved = try XCTUnwrap(PersistenceService.resolveBookmark(loadedBookmark))

        // Compare canonical paths to neutralize /tmp ↔ /private/tmp aliasing
        // and any volume-mount canonicalization the resolver applies.
        XCTAssertEqual(
            resolved.resolvingSymlinksInPath().path,
            target.resolvingSymlinksInPath().path
        )
    }

    // MARK: - Schema migration

    /// State files written before tabs existed stored each pane as a flat
    /// `TabState` shape. Pre-projects state files were a flat `WindowState`
    /// at the top level. Both shapes need to load cleanly so users don't
    /// lose state on upgrade.
    func testLoadMigratesLegacyFlatPaneState() throws {
        let legacy = """
        {
          "favorites": [],
          "favoritesSeeded": true,
          "focusedPaneIndex": 0,
          "layout": 4,
          "panes": [
            {
              "columnWidths": { "kind": 120, "modified": 160, "size": 90 },
              "folderBookmark": null,
              "includeHidden": false,
              "selectedURLPaths": ["/legacy/path.txt"],
              "sortAscending": true,
              "sortKey": "name"
            },
            { "columnWidths": { "kind": 120, "modified": 160, "size": 90 }, "folderBookmark": null, "includeHidden": false, "selectedURLPaths": [], "sortAscending": true, "sortKey": "name" },
            { "columnWidths": { "kind": 120, "modified": 160, "size": 90 }, "folderBookmark": null, "includeHidden": false, "selectedURLPaths": [], "sortAscending": true, "sortKey": "name" },
            { "columnWidths": { "kind": 120, "modified": 160, "size": 90 }, "folderBookmark": null, "includeHidden": false, "selectedURLPaths": [], "sortAscending": true, "sortKey": "name" }
          ]
        }
        """
        try Data(legacy.utf8).write(to: stateURL)

        let loaded = try XCTUnwrap(PersistenceService(stateURL: stateURL).loadState())
        XCTAssertEqual(loaded.projects.count, 1, "legacy WindowState should wrap as a single Default project")
        XCTAssertEqual(loaded.projects[0].name, "Default")
        let panes = loaded.projects[0].state.panes
        XCTAssertEqual(panes.count, 4)
        XCTAssertEqual(panes[0].tabs.count, 1, "legacy pane should promote to a single-tab pane")
        XCTAssertEqual(panes[0].activeTabIndex, 0)
        XCTAssertEqual(panes[0].tabs[0].selectedURLPaths, ["/legacy/path.txt"],
                       "tab content should survive migration")
        XCTAssertTrue(loaded.favoritesSeeded, "seeded flag should round-trip from legacy file")
    }

    /// A workspace with a non-existent activeProjectID falls back to the
    /// first project rather than refusing to load — protects against
    /// hand-edited state.json or interrupted writes.
    func testLoadFallsBackToFirstProjectOnDanglingActiveID() throws {
        let realProject = Project(name: "Real")
        let json = """
        {
          "favorites": [],
          "favoritesSeeded": true,
          "activeProjectID": "00000000-0000-0000-0000-000000000000",
          "projects": [
            {
              "id": "\(realProject.id.uuidString)",
              "name": "Real",
              "state": {
                "layout": 4,
                "focusedPaneIndex": 0,
                "panes": [
                  { "tabs": [{}], "activeTabIndex": 0 },
                  { "tabs": [{}], "activeTabIndex": 0 },
                  { "tabs": [{}], "activeTabIndex": 0 },
                  { "tabs": [{}], "activeTabIndex": 0 }
                ]
              }
            }
          ]
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try XCTUnwrap(PersistenceService(stateURL: stateURL).loadState())
        XCTAssertEqual(loaded.activeProjectID, realProject.id,
                       "dangling activeProjectID should resolve to the first available project")
    }

    /// `foldersOnTop` was added to TabState after the v0.1.0-beta.2
    /// shipping schema. State files written by older builds must still
    /// load and default to true so the historical "directories-first"
    /// list behaviour survives the upgrade.
    func testTabStateMigratesMissingFoldersOnTopAsTrue() throws {
        let pre = """
        {
          "folderBookmark": null,
          "sortKey": "name",
          "sortAscending": true,
          "includeHidden": false,
          "columnWidths": { "kind": 120, "modified": 160, "size": 90 },
          "selectedURLPaths": ["/a/b.txt"],
          "viewMode": "list",
          "expandedPaths": [],
          "previewVisible": false
        }
        """
        let tab = try JSONDecoder().decode(TabState.self, from: Data(pre.utf8))
        XCTAssertTrue(tab.foldersOnTop,
                      "default to true on pre-foldersOnTop state.json so existing users keep folders pinned")
        XCTAssertEqual(tab.sortKey, .name)
        XCTAssertEqual(tab.selectedURLPaths, ["/a/b.txt"])
    }

    func testWorkspaceStateMigratesMissingSettingsAsSystem() throws {
        // A state.json from before Phase 3 has no `settings` key. The
        // decoder must default the workspace to `.system` so existing
        // users don't get force-flipped to dark just because the field
        // is absent.
        let pre = """
        {
          "favorites": [],
          "favoritesSeeded": true,
          "activeProjectID": "00000000-0000-0000-0000-000000000001",
          "projects": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Default",
              "state": {
                "layout": 4,
                "focusedPaneIndex": 0,
                "panes": [
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 }
                ]
              }
            }
          ]
        }
        """
        let workspace = try JSONDecoder().decode(WorkspaceState.self, from: Data(pre.utf8))
        XCTAssertEqual(workspace.settings.colorScheme, .system,
                       "missing settings field must default to .system, not .dark")
        XCTAssertEqual(workspace.projects.count, 1)
        XCTAssertEqual(workspace.activeProjectID, workspace.projects[0].id)
    }

    func testWorkspaceSettingsColorSchemeRoundTrips() throws {
        var workspace = WorkspaceState.empty
        workspace.settings.colorScheme = .light

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)

        XCTAssertEqual(decoded.settings.colorScheme, .light,
                       "an explicit .light preference must survive a save/load cycle")
    }


    func testWorkspaceSettingsDefaultShortcutOverridesAreEmpty() {
        let settings = WorkspaceSettings()
        XCTAssertTrue(settings.shortcutOverrides.isEmpty,
                      "fresh settings must carry no overrides; default bindings come from ShortcutAction")
        XCTAssertEqual(settings.binding(for: .moveToTrash),
                       ShortcutAction.moveToTrash.defaultBinding,
                       "binding(for:) must fall back to the action's default when no override is set")
    }

    func testWorkspaceSettingsShortcutOverrideRoundTrips() throws {
        var workspace = WorkspaceState.empty
        let custom = ShortcutBinding(key: .character("k"), modifiers: [.command, .control])
        workspace.settings.shortcutOverrides[.moveToTrash] = custom

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)

        XCTAssertEqual(decoded.settings.shortcutOverrides[.moveToTrash], custom,
                       "user override must survive a save/load cycle byte-for-byte")
        XCTAssertEqual(decoded.settings.binding(for: .moveToTrash), custom,
                       "binding(for:) must prefer the override over the default after restore")
    }

    func testWorkspaceSettingsShortcutOverridesUseObjectShape() throws {
        // Phase 4 expectation: shortcutOverrides serialises as a
        // JSON object keyed by action rawValue (CodingKeyRepresentable),
        // not a positional array. This is what makes hand-edited
        // state.json tractable and forward-compatible.
        var workspace = WorkspaceState.empty
        workspace.settings.shortcutOverrides[.find] = ShortcutBinding(
            key: .character("k"),
            modifiers: [.command, .shift]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(workspace)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            json.contains("\"shortcutOverrides\":{\"find\":"),
            "expected object-shape encoding (\\\"find\\\":...) but got: \(json)"
        )
    }

    func testWorkspaceSettingsSkipsUnknownShortcutActionKeys() throws {
        // Forward-compat: a state.json written by a future build
        // that ships a new ShortcutAction case must not nuke the
        // override dictionary on this older build. Known keys
        // survive; unknown keys silently skip.
        let pre = """
        {
          "favorites": [],
          "favoritesSeeded": true,
          "activeProjectID": "00000000-0000-0000-0000-000000000001",
          "projects": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Default",
              "state": {
                "layout": 4,
                "focusedPaneIndex": 0,
                "panes": [
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 }
                ]
              }
            }
          ],
          "settings": {
            "colorScheme": "dark",
            "shortcutOverrides": {
              "find": { "key": { "kind": "character", "character": "k" }, "modifiers": 1 },
              "futureUnknownAction": { "key": { "kind": "character", "character": "x" }, "modifiers": 1 }
            }
          }
        }
        """
        let workspace = try JSONDecoder().decode(WorkspaceState.self, from: Data(pre.utf8))
        XCTAssertEqual(workspace.settings.colorScheme, .dark,
                       "colorScheme must survive the unknown-key entry")
        XCTAssertEqual(
            workspace.settings.shortcutOverrides[.find],
            ShortcutBinding(key: .character("k"), modifiers: .command),
            "the known .find override must decode normally"
        )
        XCTAssertEqual(
            workspace.settings.shortcutOverrides.count,
            1,
            "the unknown action key must be skipped silently, leaving only the known override"
        )
    }

    func testWorkspaceStateMigratesMissingShortcutOverridesAsEmpty() throws {
        // A state.json from before Phase 4 has no `shortcutOverrides`
        // key — every action must still resolve via its default
        // binding.
        let pre = """
        {
          "favorites": [],
          "favoritesSeeded": true,
          "activeProjectID": "00000000-0000-0000-0000-000000000001",
          "projects": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Default",
              "state": {
                "layout": 4,
                "focusedPaneIndex": 0,
                "panes": [
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 },
                  { "tabs": [], "activeTabIndex": 0 }
                ]
              }
            }
          ],
          "settings": { "colorScheme": "system" }
        }
        """
        let workspace = try JSONDecoder().decode(WorkspaceState.self, from: Data(pre.utf8))
        XCTAssertTrue(workspace.settings.shortcutOverrides.isEmpty,
                      "missing shortcutOverrides field must default to an empty dictionary, not nil")
        XCTAssertEqual(workspace.settings.binding(for: .find),
                       ShortcutAction.find.defaultBinding,
                       "actions must resolve via default binding when no override is persisted")
    }

    // MARK: - Default-state shape

    func testEmptyWorkspaceHasOneDefaultProject() {
        let empty = WorkspaceState.empty
        XCTAssertEqual(empty.projects.count, 1)
        XCTAssertEqual(empty.projects[0].name, "Default")
        XCTAssertEqual(empty.projects[0].state.layout, .four)
        XCTAssertEqual(empty.projects[0].state.panes.count, 4)
        XCTAssertEqual(empty.activeProjectID, empty.projects[0].id)
    }

    // MARK: - Helpers

    private func sampleWorkspaceState() -> WorkspaceState {
        let project = Project(
            name: "Sample",
            state: WindowState(
                layout: .twoH,
                focusedPaneIndex: 1,
                panes: [
                    PaneState(tabs: [
                        TabState(
                            folderBookmark: Data([0x01, 0x02, 0x03]),
                            sortKey: .modified,
                            sortAscending: false,
                            includeHidden: true,
                            columnWidths: PaneColumnWidths(modified: 200, size: 100, kind: 150),
                            selectedURLPaths: ["/tmp/foo.txt", "/tmp/bar.txt"]
                        ),
                        TabState(folderBookmark: Data([0x10]))
                    ], activeTabIndex: 1),
                    PaneState(tabs: [TabState(
                        folderBookmark: nil,
                        sortKey: .size,
                        sortAscending: true,
                        includeHidden: false,
                        columnWidths: PaneColumnWidths(),
                        selectedURLPaths: []
                    )]),
                    PaneState(),
                    PaneState(),
                ]
            )
        )
        return WorkspaceState(
            favorites: [],
            favoritesSeeded: true,
            activeProjectID: project.id,
            projects: [project]
        )
    }
}
