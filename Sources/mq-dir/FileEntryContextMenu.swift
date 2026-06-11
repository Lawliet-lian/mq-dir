import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-click menu shared by the list view (BrowserPaneView) and the tree
/// view (TreeFileListView). Lifts the menu beyond the v0.1.0-alpha "Open /
/// Reveal in Finder" pair to a Finder-parity set: Open With submenu, Get
/// Info, Copy / Copy Path, Duplicate, and Move to Trash.
///
/// `targets` is whatever the caller decided the action should operate on —
/// in list view that's the multi-selection if the right-clicked row is part
/// of it, otherwise just the clicked row. `primaryName` drives the singular
/// "Copy 'foo.txt'" label so the user can see what the action will hit.
struct FileEntryContextMenu: View {
    let viewModel: FolderBrowserViewModel
    let targets: [FileEntry]
    let primaryName: String
    /// Resolved via `@EnvironmentObject` so the menu's Rename row
    /// always reflects the user's current shortcut override (Settings
    /// → Shortcuts → Rename). The app injects this at the
    /// `WindowGroup` level in `mqdirApp.swift`.
    @EnvironmentObject private var workspace: WorkspaceManager

    private var count: Int { targets.count }

    /// "Open With" only makes sense for plain files — Finder still shows it
    /// for folders but with terminal/etc. options that don't carry over to
    /// a folder browser, so we hide it for any selection that includes a
    /// directory.
    private var allFiles: Bool { !targets.contains(where: \.isDirectory) }

    /// True if any target's filename is in decomposed (NFD) form, so
    /// the "Normalize Filename to NFC" menu item is worth showing.
    /// Uses byte-level comparison because Swift's `String ==`
    /// collapses canonically-equivalent strings — see
    /// `String.isDecomposedRelativeToNFC`.
    private var anyNeedsNFCNormalization: Bool {
        targets.contains { $0.name.isDecomposedRelativeToNFC }
    }

    /// True when `entry` lives at or below the current folder root, so
    /// "Reveal in Tree" has somewhere to scroll to. Search hits in deeper
    /// folders are the headline case; a direct child qualifies too (the
    /// reveal just selects + scrolls without expanding anything). An entry
    /// outside the root (stale result) is excluded so the action never
    /// no-ops silently.
    private func canRevealInTree(_ entry: FileEntry) -> Bool {
        guard let root = viewModel.folderURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let entryPath = entry.url.standardizedFileURL.path
        return entryPath == rootPath || entryPath.hasPrefix(rootPath + "/")
    }

    /// Union of every Finder colour label currently applied across the
    /// menu's targets. Drives the filled-circle indicator next to each
    /// colour in the Tags submenu so the user can see, at a glance,
    /// which colours their selection already carries. Multi-select
    /// shows a colour as "applied" if *any* row has it — clicking still
    /// toggles per-file, so an already-applied colour is removed from
    /// rows that have it and added to rows that don't.
    private var appliedColours: Set<Int> {
        var seen: Set<Int> = []
        for target in targets {
            for colour in target.tagColors where (1...7).contains(colour) {
                seen.insert(colour)
            }
        }
        return seen
    }

    var body: some View {
        Button(count > 1 ? "Open \(count) Items" : "Open") {
            targets.forEach { viewModel.open($0) }
        }

        if allFiles, let firstURL = targets.first?.url {
            let apps = applicationURLs(for: firstURL)
            Menu("Open With") {
                ForEach(apps, id: \.self) { app in
                    Button(applicationName(for: app)) {
                        openEntries(targets, with: app)
                    }
                }
                if !apps.isEmpty { Divider() }
                Button("Other\u{2026}") { chooseAndOpenWith(targets) }
            }
        }

        Divider()

        Button(count > 1 ? "Get Info (\(count))" : "Get Info") {
            showGetInfo(for: targets)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }

        // "Reveal in Tree" surfaces a single entry in tree mode with its
        // ancestors expanded — most useful for a deep recursive-search hit,
        // whose row otherwise only shows a subtitle path. Single-target only
        // (revealing N scattered hits at once has no coherent scroll target);
        // shown whenever the entry sits below the current folder root.
        if count == 1, let target = targets.first, canRevealInTree(target) {
            Button("Reveal in Tree") {
                viewModel.revealInTree(target)
            }
        }

        // Folders carry no size until walked on demand. Show the action only
        // when the selection actually contains a directory — for an all-files
        // selection every size is already known and the item would be inert.
        if FolderBrowserViewModel.canCalculateSize(targets) {
            Button(count > 1 ? "Calculate Size (\(count))" : "Calculate Size") {
                viewModel.calculateSize(targets)
            }
        }

        Divider()

        Menu("Tags") {
            ForEach(TagColor.allLabels, id: \.self) { label in
                Button {
                    viewModel.toggleColorTag(label, on: targets)
                } label: {
                    // `Label` with an `Image(nsImage:)` icon is the
                    // only path that survives SwiftUI's NSMenuItem
                    // conversion with full colour — SF Symbols inside
                    // a Menu Button get template-rendered and lose
                    // any `.foregroundStyle` we set on them.
                    Label {
                        Text(TagColor.displayName(forLabel: label)
                             + (appliedColours.contains(label) ? "  ✓" : ""))
                    } icon: {
                        Image(nsImage: Self.swatchImage(
                            forLabel: label,
                            filled: appliedColours.contains(label)
                        ))
                    }
                }
            }
            Divider()
            Button("Clear Tags") {
                viewModel.toggleColorTag(0, on: targets)
            }
            .disabled(appliedColours.isEmpty)
        }

        Divider()

        Button(count > 1 ? "Copy \(count) Items" : "Copy \u{201C}\(primaryName)\u{201D}") {
            copyToPasteboard(targets)
        }
        Button("Copy Path") {
            copyPathsToPasteboard(targets)
        }

        Divider()

        Button(count > 1 ? "Duplicate \(count) Items" : "Duplicate") {
            viewModel.duplicate(targets, normalizeHangul: workspace.workspace.settings.normalizeHangulOnDragOut)
        }
        if count == 1, let target = targets.first {
            // Rename only makes sense for a single row at a time —
            // multi-rename is its own UX and lives elsewhere.
            Button("Rename") { viewModel.beginRename(target) }
                .keyboardShortcut(workspace.workspace.settings.binding(for: .rename))
        }
        if anyNeedsNFCNormalization {
            Button(count > 1 ? "Normalize \(count) Filenames to NFC" : "Normalize Filename to NFC") {
                viewModel.normalizeFilenamesToNFC(targets)
            }
        }
        Button(count > 1 ? "Move \(count) Items to Trash" : "Move to Trash") {
            viewModel.moveToTrash(targets)
        }
        Button(count > 1 ? "Delete \(count) Items Immediately\u{2026}" : "Delete Immediately\u{2026}") {
            viewModel.permanentlyDelete(targets)
        }

        Divider()
        Button(compressLabel(for: targets)) {
            viewModel.compress(targets)
        }
        if FolderBrowserViewModel.canExtract(targets) {
            Button(count > 1 ? "Extract \(count) Archives" : "Extract") {
                viewModel.extractArchives(targets)
            }
        }
    }

    /// Finder-style label for the Compress action: single selection
    /// uses the item name in quotes, multi-selection shows the count.
    private func compressLabel(for entries: [FileEntry]) -> String {
        if entries.count == 1, let only = entries.first {
            return "Compress \u{201C}\(only.name)\u{201D}"
        }
        return "Compress \(entries.count) Items"
    }

    // MARK: Open With

    /// LaunchServices' list of apps that claim to open this URL. The first
    /// one is the system default (the same app a double-click would use).
    private func applicationURLs(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    /// Display name for an app bundle, falling back through the standard
    /// Info.plist keys that Finder itself uses before resorting to the
    /// bundle's filename.
    private func applicationName(for appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return name
        }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    private func openEntries(_ entries: [FileEntry], with appURL: URL) {
        let urls = entries.map(\.url)
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// "Other…" branch — let the user pick any .app under /Applications,
    /// then route the selection through the same `open(_:with:)` path the
    /// suggested apps use.
    private func chooseAndOpenWith(_ entries: [FileEntry]) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        openEntries(entries, with: app)
    }

    // MARK: Get Info

    /// Pop Finder's standard Info window for each selected item. Driving
    /// Finder via AppleScript piggybacks on the system-blessed inspector
    /// without rebuilding it here. `try ... end try` swallows per-item
    /// errors so one inaccessible file doesn't sink the whole batch.
    private func showGetInfo(for entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        let aliases = entries
            .map { "POSIX file \"\($0.url.path)\" as alias" }
            .joined(separator: ", ")
        let source = """
        tell application "Finder"
            activate
            repeat with f in {\(aliases)}
                try
                    open information window of f
                end try
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write(
                Data("[mq-dir Get Info] \(error)\n".utf8)
            )
        }
    }

    // MARK: Pasteboard

    /// Standard "Copy" — writes file URLs to the pasteboard so a Cmd+V in
    /// Finder pastes the actual files (not the path strings). Matches what
    /// Finder's own Edit > Copy does.
    private func copyToPasteboard(_ entries: [FileEntry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let nsurls = entries.map { $0.url as NSURL }
        pb.writeObjects(nsurls)
    }

    /// Render a 12pt swatch matching the Finder colour `label`. `filled`
    /// paints a solid disc (currently-applied colour) vs an open ring
    /// (not applied). `isTemplate = false` is the load-bearing bit —
    /// NSMenu treats template images as monochrome and would otherwise
    /// strip the colour back to the system menu accent.
    private static func swatchImage(forLabel label: Int, filled: Bool) -> NSImage {
        let dim: CGFloat = 12
        let image = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(ovalIn: inset)
            if let colour = TagColor.color(forLabel: label).map(NSColor.init) {
                if filled {
                    colour.setFill()
                    path.fill()
                } else {
                    colour.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "Copy Path" — newline-joined POSIX paths. Useful for shell pasting,
    /// and the Option+Cmd+C parallel from Finder.
    private func copyPathsToPasteboard(_ entries: [FileEntry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let joined = entries.map(\.url.path).joined(separator: "\n")
        pb.setString(joined, forType: .string)
    }
}
