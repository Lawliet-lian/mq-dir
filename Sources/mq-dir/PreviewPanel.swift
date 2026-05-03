import AppKit
import MarkdownUI
import QuickLookUI
import SwiftUI

/// Right-side preview panel for the focused tab.
///
/// Three render paths, picked by selection state:
///   1. No selection / multi-selection / folder → custom summary view.
///   2. Markdown file (.md / .markdown / .mdown) → MarkdownUI for proper
///      GFM rendering (headings, lists, tables, code-with-highlight, …).
///   3. Anything else → `QLPreviewView`, which inherits the system Quick
///      Look generators (images, PDF, code, video, audio, office docs, …).
///
/// The panel is per-tab; toggling it persists in `FolderBrowserViewModel`
/// and is replayed on restart through `TabState.previewVisible`.
struct PreviewPanel: View {
    @ObservedObject var viewModel: FolderBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.separator)
            content
        }
        .background(Theme.Color.paneBg)
    }

    // MARK: Header (file name + size/modified)

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            if let entry = focusedEntry {
                Image(systemName: FileIconStyle.symbol(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(FileIconStyle.tint(for: entry))
                    .frame(width: 14)
                Text(entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("—")
                    .foregroundStyle(Theme.Color.labelTertiary)
                Text(metadataLine(for: entry))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.labelSecondary)
            } else {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.labelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.paneHeaderHeight)
    }

    private func metadataLine(for entry: FileEntry) -> String {
        let date = Self.dateFormatter.string(from: entry.modificationDate ?? Date())
        if let bytes = entry.size {
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \(date)"
        }
        return date
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let selectedEntries = currentlySelectedEntries

        if selectedEntries.isEmpty {
            emptyState("Select a file to preview")
        } else if selectedEntries.count > 1 {
            multiSelectionSummary(selectedEntries)
        } else if let entry = selectedEntries.first {
            if entry.isDirectory {
                folderSummary(entry)
            } else if isMarkdown(entry.url) {
                markdownView(for: entry.url)
            } else {
                QuickLookPreview(url: entry.url)
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "eye.slash")
                .font(.system(size: 22))
                .foregroundStyle(Theme.Color.labelTertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.labelTertiary)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func multiSelectionSummary(_ entries: [FileEntry]) -> some View {
        let totalSize = entries.compactMap(\.size).reduce(0, +)
        return VStack(spacing: 6) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 22))
                .foregroundStyle(Theme.Color.labelSecondary)
            Text("\(entries.count) items selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.label)
            Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.labelSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderSummary(_ entry: FileEntry) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.accent.opacity(0.85))
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.url.path)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.labelTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Largest markdown file we'll render in-pane. Past this we fall back
    /// to Quick Look so a multi-MB log dumped with a `.md` extension can't
    /// freeze the main actor or push the app into a memory blow-up.
    private static let markdownMaxBytes: Int = 2_000_000

    @ViewBuilder
    private func markdownView(for url: URL) -> some View {
        // Reading the file synchronously is fine for the preview pane —
        // MD files are small (KB range), and the user actively chose to
        // view this file. Cap at 2 MB so a hostile or accidentally-huge
        // .md doesn't OOM the app; oversize files defer to Quick Look.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if size <= Self.markdownMaxBytes,
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            ScrollView {
                Markdown(text)
                    .markdownTheme(.gitHub)
                    .markdownTextStyle {
                        FontSize(13)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            QuickLookPreview(url: url)
        }
    }

    // MARK: Selection helpers

    /// All entries currently selected in the focused tab.
    private var currentlySelectedEntries: [FileEntry] {
        let visible = viewModel.visibleEntries
        let allEntries = visible.isEmpty ? viewModel.entries : visible
        let bySelection = allEntries.filter { viewModel.selection.contains($0.id) }
        return bySelection
    }

    /// Single-pick used by the header. Mirrors `currentlySelectedEntries`
    /// but returns nil when nothing — or multiple things — are selected.
    private var focusedEntry: FileEntry? {
        let entries = currentlySelectedEntries
        return entries.count == 1 ? entries.first : nil
    }

    private func isMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mdown"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Quick Look bridge

/// Wraps `QLPreviewView` so SwiftUI can swap in any URL the system has a
/// generator for. Using `.compact` style keeps it borderless and lets the
/// surrounding pane chrome own framing.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // QLPreviewView doesn't notice an unchanged URL, so this is a no-op
        // for the common case; only updates when SwiftUI re-runs with a
        // genuinely different URL.
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as NSURL
        }
    }
}
