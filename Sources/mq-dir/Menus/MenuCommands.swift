import AppKit
import SwiftUI

/// 便捷宏：从主 bundle 读取本地化字符串
private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

struct MenuCommands: Commands {
    @ObservedObject var workspace: WorkspaceManager

    /// Resolved binding for a customisable action — user override
    /// from `WorkspaceSettings`, falling back to the default. Used
    /// by every menu item whose shortcut is exposed in Settings →
    /// Shortcuts so the menu re-attaches when the user remaps.
    private func binding(_ action: ShortcutAction) -> ShortcutBinding {
        workspace.workspace.settings.binding(for: action)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("mqdir.menu.file.newWindow")) { stub("File → New Window") }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("mqdir.menu.file.newTab")) { post(.newTab) }
                .keyboardShortcut(binding(.newTab))
            Divider()
            Button(L("mqdir.menu.file.openFolder")) { post(.openFolder) }
                .keyboardShortcut(binding(.openFolder))
            Button(L("mqdir.menu.file.openSelected")) { post(.openSelected) }
                .keyboardShortcut(.return, modifiers: [])
            Button(L("mqdir.menu.file.closeTab")) { post(.closeTab) }
                .keyboardShortcut(binding(.closeTab))
            Button(L("mqdir.menu.file.reopenClosedTab")) { post(.reopenClosedTab) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // ⌘⇧R is now Edit → Rename (Eagle convention). Reveal in
            // Finder loses its shortcut and lives on the right-click
            // menu + the menu bar entry; the alternative would be
            // double-binding ⌘⇧R, which silently breaks unrelated
            // menu shortcut routing on macOS.
            Button(L("mqdir.menu.file.revealInFinder")) { post(.revealSelected) }
                .keyboardShortcut(binding(.revealInFinder))
            Divider()
            Button(L("mqdir.menu.file.addToFavorites")) { post(.addCurrentFolderToFavorites) }
                .keyboardShortcut(binding(.addToFavorites))
        }

        // Replace the system pasteboard group entirely so file-level
        // Copy/Paste/Delete and Select All actually run on the focused
        // pane's selection. Each item routes to a `mqdir*` notification
        // when the first responder isn't a text view; if a TextField
        // (search box, inline rename) IS the first responder we
        // forward to its native AppKit action so the user's expected
        // text-Cmd+C / Cmd+V / Cmd+A still works there.
        CommandGroup(replacing: .pasteboard) {
            Button(L("mqdir.menu.edit.cut")) { dispatch(text: #selector(NSText.cut(_:)), file: .cut) }
                .keyboardShortcut("x", modifiers: .command)
            Button(L("mqdir.menu.edit.copy")) { dispatch(text: #selector(NSText.copy(_:)), file: .copy) }
                .keyboardShortcut("c", modifiers: .command)
            Button(L("mqdir.menu.edit.paste")) { dispatch(text: #selector(NSText.paste(_:)), file: .paste) }
                .keyboardShortcut("v", modifiers: .command)
            // ⌘⌫ matches Finder's "Move to Trash". The dispatch helper
            // forwards plain Delete (text-edit selector) when a TextField
            // is the first responder, but ⌘⌫ in a TextField is rare on
            // macOS and harmlessly invokes NSText.delete(_:) on a
            // selected range.
            Button(L("mqdir.menu.edit.moveToTrash")) { dispatch(text: #selector(NSText.delete(_:)), file: .delete) }
                .keyboardShortcut(binding(.moveToTrash))
            // Permanent delete bypasses the trash — confirmed via
            // NSAlert in the focused pane's view model.
            Button(L("mqdir.menu.edit.deleteImmediately")) { post(.permanentDelete) }
                .keyboardShortcut(binding(.deleteImmediately))
            Divider()
            Button(L("mqdir.menu.edit.selectAll")) { dispatch(text: #selector(NSText.selectAll(_:)), file: .selectAll) }
                .keyboardShortcut("a", modifiers: .command)
        }

        // File-selection actions tucked into the Edit menu just below
        // the pasteboard group. Eagle / Finder parity for the shortcuts
        // power users hit reflexively.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L("mqdir.menu.edit.openWithDefaultApp")) { post(.openWithDefaultApp) }
                .keyboardShortcut(binding(.openWithDefaultApp))
            Button(L("mqdir.menu.edit.duplicate")) { post(.duplicate) }
                .keyboardShortcut(binding(.duplicate))
            Divider()
            Button(L("mqdir.menu.edit.copyFilePath")) { post(.copyFilePaths) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button(L("mqdir.menu.edit.copyFolderPath")) { post(.copyFolderPath) }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button(L("mqdir.menu.edit.copyName")) { post(.copyName) }
            Divider()
            Button(L("mqdir.menu.edit.rename")) { post(.rename) }
                .keyboardShortcut(binding(.rename))
        }

        CommandGroup(after: .textEditing) {
            Button(L("mqdir.menu.view.find")) { post(.focusSearch) }
                .keyboardShortcut(binding(.find))
            Button(L("mqdir.menu.view.showPreview")) { post(.togglePreview) }
                .keyboardShortcut(binding(.togglePreview))
        }

        CommandGroup(after: .toolbar) {
            Button(L("mqdir.menu.view.back")) { post(.goBack) }
                .keyboardShortcut(binding(.back))
            Button(L("mqdir.menu.view.forward")) { post(.goForward) }
                .keyboardShortcut(binding(.forward))
            Button(L("mqdir.menu.view.reload")) { post(.reload) }
                .keyboardShortcut(binding(.reload))
            Button(L("mqdir.menu.view.parentFolder")) { post(.parentFolder) }
                .keyboardShortcut(binding(.parentFolder))
            Button(L("mqdir.menu.view.toggleHiddenFiles")) { post(.toggleHiddenFiles) }
                .keyboardShortcut(binding(.toggleHiddenFiles))
            Divider()
            // As List / As Tree intentionally have no keyboard shortcut:
            // ⌥⌘1–4 are claimed by Window → Focus Pane and view-mode
            // toggling is rare enough to live on the menu and the
            // toolbar's segmented control.
            Button(L("mqdir.menu.view.asList")) { post(.setViewModeList) }
            Button(L("mqdir.menu.view.asTree")) { post(.setViewModeTree) }
        }

        // Tab navigation lives under the standard Window menu, matching
        // Safari/Finder where ⌘⇧[ ⌘⇧] move between tabs and ⌘1…⌘9 jump
        // to a specific one. We attach `after: .windowArrangement` so it
        // appears below the system "Bring All to Front" entry.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button(L("mqdir.menu.window.showNextTab")) { post(.nextTab) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button(L("mqdir.menu.window.showPreviousTab")) { post(.previousTab) }
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
            Divider()
            // ⌥⌘1–4 move keyboard focus between the four panes in the
            // current layout. Indices outside the active layout's pane
            // count are silently dropped by MainWindowView.
            focusPaneButton(index: 0, key: "1")
            focusPaneButton(index: 1, key: "2")
            focusPaneButton(index: 2, key: "3")
            focusPaneButton(index: 3, key: "4")
        }

        CommandGroup(replacing: .help) {
            Link(L("mqdir.app.github"),
                 destination: URL(string: "https://github.com/h5nam/mq-dir")!)
        }
    }

    private func selectTabButton(index: Int, key: KeyEquivalent) -> some View {
        Button(L("mqdir.menu.window.selectTab", index + 1)) {
            post(.selectTab(index: index))
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    private func focusPaneButton(index: Int, key: KeyEquivalent) -> some View {
        Button(L("mqdir.menu.window.focusPane", index + 1)) {
            post(.focusPane(index: index))
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
    }

    private func stub(_ label: String) {
        FileHandle.standardError.write(Data("[mq-dir M0 stub] \(label)\n".utf8))
    }

    private func post(_ command: AppCommand) {
        command.post()
    }

    /// Edit-menu dispatcher. Only forward to the system text selector
    /// when the focused responder is genuinely editing text — i.e. the
    /// NSTextField field editor that powers the search box, inline
    /// rename, etc. A plain `responder is NSText` check used to fire
    /// here too, but `QLPreviewView` installs its own read-only
    /// NSTextView as first responder once it appears, so ⌘C on a
    /// .docx (or any non-markdown file with a text-rendered Quick
    /// Look preview) was silently sent to that view as a no-op
    /// instead of running our file-level copy. `isFieldEditor` is
    /// the load-bearing filter — only true for the field editor an
    /// NSTextField installs while the user is typing.
    private func dispatch(text selector: Selector, file command: AppCommand) {
        let responder = NSApp.keyWindow?.firstResponder
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            NSApp.sendAction(selector, to: responder, from: nil)
        } else {
            post(command)
        }
    }
}
