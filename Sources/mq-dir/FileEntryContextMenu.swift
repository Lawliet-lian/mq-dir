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

    private var count: Int { targets.count }

    /// "Open With" only makes sense for plain files — Finder still shows it
    /// for folders but with terminal/etc. options that don't carry over to
    /// a folder browser, so we hide it for any selection that includes a
    /// directory.
    private var allFiles: Bool { !targets.contains(where: \.isDirectory) }

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

        Divider()

        Button(count > 1 ? "Copy \(count) Items" : "Copy \u{201C}\(primaryName)\u{201D}") {
            copyToPasteboard(targets)
        }
        Button("Copy Path") {
            copyPathsToPasteboard(targets)
        }

        Divider()

        Button(count > 1 ? "Duplicate \(count) Items" : "Duplicate") {
            viewModel.duplicate(targets)
        }
        Button(count > 1 ? "Move \(count) Items to Trash" : "Move to Trash") {
            viewModel.moveToTrash(targets)
        }
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

    /// "Copy Path" — newline-joined POSIX paths. Useful for shell pasting,
    /// and the Option+Cmd+C parallel from Finder.
    private func copyPathsToPasteboard(_ entries: [FileEntry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let joined = entries.map(\.url.path).joined(separator: "\n")
        pb.setString(joined, forType: .string)
    }
}
