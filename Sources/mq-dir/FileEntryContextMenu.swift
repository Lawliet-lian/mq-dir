import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 本地化便捷函数（与其他视图保持同签名）。
// 放在文件私有作用域，避免与其他文件中的同名 L 函数冲突。
private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

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
        // 打开选中项：单项直接"Open"，多项显示具体数量
        Button(count > 1
               ? L("mqdir.context.openNItems", count)
               : L("mqdir.context.open")) {
            targets.forEach { viewModel.open($0) }
        }

        if allFiles, let firstURL = targets.first?.url {
            let apps = applicationURLs(for: firstURL)
            // 打开方式子菜单：推荐 app 列表 + 其他选择入口
            Menu(L("mqdir.context.openWith")) {
                ForEach(apps, id: \.self) { app in
                    Button(applicationName(for: app)) {
                        openEntries(targets, with: app)
                    }
                }
                if !apps.isEmpty { Divider() }
                // 其他…：弹出 NSOpenPanel 让用户任选 /Applications 下的 app
                Button(L("mqdir.context.openWithOther")) { chooseAndOpenWith(targets) }
            }
        }

        Divider()

        // 显示简介：Finder 自带的 Get Info 面板
        Button(count > 1
               ? L("mqdir.context.getInfoN", count)
               : L("mqdir.context.getInfo")) {
            showGetInfo(for: targets)
        }
        Button(L("mqdir.context.revealInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }

        // 在树形视图中显示：搜索结果快速定位到原位置（单条目才有意义）
        if count == 1, let target = targets.first, canRevealInTree(target) {
            Button(L("mqdir.context.revealInTree")) {
                viewModel.revealInTree(target)
            }
        }

        // 计算大小：目录需在树上遍历，比较耗时；选择中包含目录时才显示
        if FolderBrowserViewModel.canCalculateSize(targets) {
            Button(count > 1
                   ? L("mqdir.context.calcSizeN", count)
                   : L("mqdir.context.calcSize")) {
                viewModel.calculateSize(targets)
            }
        }

        Divider()

        // 标签子菜单：Finder 七种标准色 + 清除
        Menu(L("mqdir.context.tags")) {
            ForEach(TagColor.allLabels, id: \.self) { label in
                Button {
                    viewModel.toggleColorTag(label, on: targets)
                } label: {
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
            // 清除所有已打标签（当前没打任何标签时禁用）
            Button(L("mqdir.context.clearTags")) {
                viewModel.toggleColorTag(0, on: targets)
            }
            .disabled(appliedColours.isEmpty)
        }

        Divider()

        // 拷贝（文件 URL 到剪贴板，Finder ⌘C 兼容）
        Button(count > 1
               ? L("mqdir.context.copyItems", count)
               : L("mqdir.context.copyOne", primaryName)) {
            copyToPasteboard(targets)
        }
        // 拷贝路径（字符串，便于粘贴到终端/编辑器）
        Button(L("mqdir.context.copyPath")) {
            copyPathsToPasteboard(targets)
        }

        Divider()

        // 拷贝副本（同目录下复制一份）
        Button(count > 1
               ? L("mqdir.context.duplicateN", count)
               : L("mqdir.context.duplicate")) {
            viewModel.duplicate(targets, normalizeHangul: workspace.workspace.settings.normalizeHangulOnDragOut)
        }
        if count == 1, let target = targets.first {
            // 重命名：仅单文件时显示（多选重命名是另一个 UX 场景）
            Button(L("mqdir.context.rename")) { viewModel.beginRename(target) }
                .keyboardShortcut(workspace.workspace.settings.binding(for: .rename))
        }
        if anyNeedsNFCNormalization {
            // 韩文 NFD → NFC 规范化（选中项有分解形式文件名时显示）
            Button(count > 1
                   ? L("mqdir.context.normalizeNFCN", count)
                   : L("mqdir.context.normalizeNFC")) {
                viewModel.normalizeFilenamesToNFC(targets)
            }
        }
        // 移到废纸篓：可撤销
        Button(count > 1
               ? L("mqdir.context.moveNToTrash", count)
               : L("mqdir.context.moveToTrash")) {
            viewModel.moveToTrash(targets)
        }
        // 立即删除：不可恢复，带确认对话框
        Button(count > 1
               ? L("mqdir.context.deleteNImmediately", count)
               : L("mqdir.context.deleteImmediately")) {
            viewModel.permanentlyDelete(targets)
        }

        Divider()
        // 压缩：单文件显示"压缩 <文件名>"，多文件显示"压缩 N 项"
        Button(compressLabel(for: targets)) {
            viewModel.compress(targets)
        }
        if FolderBrowserViewModel.canExtract(targets) {
            // 解压：选中项全是已知归档格式时才显示
            Button(count > 1
                   ? L("mqdir.context.extractN", count)
                   : L("mqdir.context.extract")) {
                viewModel.extractArchives(targets)
            }
        }
    }

    // 压缩菜单项的文案：单选显示"压缩 <文件名>"，多选显示"压缩 N 项"
    private func compressLabel(for entries: [FileEntry]) -> String {
        if entries.count == 1, let only = entries.first {
            return L("mqdir.context.compressOne", only.name)
        }
        return L("mqdir.context.compressN", entries.count)
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

    // "其他…"分支：弹出 NSOpenPanel 让用户任选 /Applications 下的 .app，
    // 然后使用同样的 open(_:with:) 路径打开。
    private func chooseAndOpenWith(_ entries: [FileEntry]) {
        let panel = NSOpenPanel()
        panel.title = L("mqdir.context.chooseApp")
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
