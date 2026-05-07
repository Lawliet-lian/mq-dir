import AppKit
import SwiftUI

struct MenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { stub("File → New Window") }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { post(.mqdirNewTabRequested) }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Open Folder...") { post(.mqdirOpenFolderRequested) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Selected") { post(.mqdirOpenSelectedRequested) }
                .keyboardShortcut(.return, modifiers: [])
            Button("Close Tab") { post(.mqdirCloseTabRequested) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { post(.mqdirReopenClosedTabRequested) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Reveal in Finder") { post(.mqdirRevealSelectedRequested) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Add to Favorites") { post(.mqdirAddCurrentFolderToFavoritesRequested) }
                .keyboardShortcut("d", modifiers: .command)
        }

        // Replace the system pasteboard group entirely so file-level
        // Copy/Paste/Delete and Select All actually run on the focused
        // pane's selection. Each item routes to a `mqdir*` notification
        // when the first responder isn't a text view; if a TextField
        // (search box, inline rename) IS the first responder we
        // forward to its native AppKit action so the user's expected
        // text-Cmd+C / Cmd+V / Cmd+A still works there.
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") { dispatch(text: #selector(NSText.copy(_:)), file: .mqdirCopyRequested) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { dispatch(text: #selector(NSText.paste(_:)), file: .mqdirPasteRequested) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Delete") { dispatch(text: #selector(NSText.delete(_:)), file: .mqdirDeleteRequested) }
                .keyboardShortcut(.delete, modifiers: [])
            Divider()
            Button("Select All") { dispatch(text: #selector(NSText.selectAll(_:)), file: .mqdirSelectAllRequested) }
                .keyboardShortcut("a", modifiers: .command)
        }

        // File-selection actions tucked into the Edit menu just below
        // the pasteboard group. Eagle / Finder parity for the shortcuts
        // power users hit reflexively.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Open with Default App") { post(.mqdirOpenWithDefaultAppRequested) }
                .keyboardShortcut(.return, modifiers: .shift)
            Button("Duplicate") { post(.mqdirDuplicateRequested) }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Copy File Path") { post(.mqdirCopyFilePathsRequested) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy Folder Path") { post(.mqdirCopyFolderPathRequested) }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("Copy Name") { post(.mqdirCopyNameRequested) }
            Divider()
            Button("Rename") { post(.mqdirRenameRequested) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") { post(.mqdirFocusSearchRequested) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Show Preview") { post(.mqdirTogglePreviewRequested) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Back") { post(.mqdirGoBackRequested) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { post(.mqdirGoForwardRequested) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Reload") { post(.mqdirReloadRequested) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Parent Folder") { post(.mqdirParentFolderRequested) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Toggle Hidden Files") { post(.mqdirToggleHiddenFilesRequested) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("As List") { post(.mqdirSetViewModeListRequested) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("As Tree") { post(.mqdirSetViewModeTreeRequested) }
                .keyboardShortcut("2", modifiers: [.command, .option])
        }

        // Tab navigation lives under the standard Window menu, matching
        // Safari/Finder where ⌘⇧[ ⌘⇧] move between tabs and ⌘1…⌘9 jump
        // to a specific one. We attach `after: .windowArrangement` so it
        // appears below the system "Bring All to Front" entry.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Show Next Tab") { post(.mqdirNextTabRequested) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { post(.mqdirPreviousTabRequested) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            selectTabButton(index: 0, key: "1")
            selectTabButton(index: 1, key: "2")
            selectTabButton(index: 2, key: "3")
            selectTabButton(index: 3, key: "4")
            selectTabButton(index: 4, key: "5")
            selectTabButton(index: 5, key: "6")
            selectTabButton(index: 6, key: "7")
            selectTabButton(index: 7, key: "8")
            selectTabButton(index: 8, key: "9")
        }

        CommandGroup(replacing: .help) {
            Link("mq-dir on GitHub",
                 destination: URL(string: "https://github.com/h5nam/mq-dir")!)
        }
    }

    private func selectTabButton(index: Int, key: KeyEquivalent) -> some View {
        Button("Select Tab \(index + 1)") {
            post(.mqdirSelectTabAtIndexRequested, userInfo: ["index": index])
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    private func stub(_ label: String) {
        FileHandle.standardError.write(Data("[mq-dir M0 stub] \(label)\n".utf8))
    }

    private func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Edit-menu dispatcher. If the focused responder is a text view
    /// (search field, inline rename TextField, etc.) forward to its
    /// native selector so the system text-edit behaviour wins. Anywhere
    /// else, post the file-level notification so the focused pane's
    /// view model handles the action.
    private func dispatch(text selector: Selector, file notification: Notification.Name) {
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSText {
            NSApp.sendAction(selector, to: responder, from: nil)
        } else {
            post(notification)
        }
    }
}
