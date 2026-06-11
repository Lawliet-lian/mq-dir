import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Listing & extraction

/// One row in a `.zip` archive's table of contents — what `unzip -Z -1`
/// emits, one path per line. Directories carry a trailing `/`; everything
/// else is a file. We don't store sizes here because `-Z -1` doesn't
/// emit them; the header line under `ZipPreviewView` covers the
/// archive-level summary instead.
struct ZipEntry: Identifiable, Hashable {
    let path: String

    var id: String { path }
    var isDirectory: Bool { path.hasSuffix("/") }

    /// Last component of the path. Used as the display label so deeply
    /// nested rows don't blow out the narrow preview pane.
    var displayName: String {
        let trimmed = isDirectory ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Indent depth in the listing — one step per `/` segment. Directories
    /// at the same level as a file render at the same depth.
    var depth: Int {
        let stripped = isDirectory ? String(path.dropLast()) : path
        return max(0, stripped.split(separator: "/").count - 1)
    }
}

/// Wraps `/usr/bin/unzip` for read-only previewing — listing and
/// single-entry extraction. Both paths drain the stdout pipe in
/// chunks so a large entry doesn't block on a full pipe buffer; the
/// extract path caps at `extractCap` so a 5 GB zip doesn't try to
/// land in memory and the preview pane gives up gracefully instead.
enum ZipPreviewService {
    static let extractCap = 16 * 1024 * 1024

    /// One archive table of contents. Resolves on a utility-priority
    /// detached task so the main actor never blocks on the unzip
    /// invocation.
    static func list(archive: URL) async throws -> [ZipEntry] {
        let data = try await runUnzip(arguments: ["-Z", "-1", archive.path], cap: nil)
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { ZipEntry(path: String($0)) }
    }

    /// Stdout bytes of a single entry inside `archive`. `truncated`
    /// flips when the entry exceeds `extractCap`; callers can then
    /// surface a "too big to preview" hint instead of trying to render
    /// a partial file.
    struct ExtractionResult {
        let data: Data
        let truncated: Bool
    }

    static func extract(archive: URL, entry: String) async throws -> ExtractionResult {
        // `entry` is passed to `unzip -p` as a match pattern. We do NOT
        // use `--` to terminate option parsing because Info-ZIP doesn't
        // honor it — a leading `-` is still read as an option flag.
        // Instead `literalZipPattern` glob-escapes the name so it can
        // only match itself (see helper for the leading-dash trick).
        let data = try await runUnzip(
            arguments: ["-p", archive.path, literalZipPattern(entry)],
            cap: extractCap
        )
        return ExtractionResult(data: data, truncated: data.count >= extractCap)
    }

    /// Turn a literal archive entry name into an Info-ZIP match pattern
    /// that only ever matches itself. Info-ZIP treats `*`, `?`, `[`, `]`
    /// in the pattern as glob metacharacters and a leading `-` as an
    /// option flag (and `--` is NOT respected as an end-of-options
    /// sentinel). We neutralize each metacharacter by wrapping it in a
    /// single-character class (`[*]`, `[?]`, `[[]`, `[]]`), which Info-ZIP
    /// matches literally. A leading dash gets the same treatment (`-x`
    /// → `[-]x`) so the name can never be parsed as an option.
    static func literalZipPattern(_ entry: String) -> String {
        var result = ""
        result.reserveCapacity(entry.count + 4)
        for (index, char) in entry.enumerated() {
            switch char {
            case "*", "?", "[", "]":
                result.append("[")
                result.append(char)
                result.append("]")
            case "-" where index == 0:
                // Leading dash → option flag risk; escape as a class.
                result.append("[-]")
            default:
                result.append(char)
            }
        }
        return result
    }

    /// Process invocation shared between list/extract. Pulls stdout
    /// in `availableData` chunks until the process closes its end of
    /// the pipe, optionally discarding bytes past `cap` so a multi-GB
    /// extraction never balloons memory while still draining the
    /// pipe so unzip can finish. stderr is drained concurrently on a
    /// background thread so a chatty error stream past the ~64 KB pipe
    /// buffer can't deadlock the child against our stdout read. Task
    /// cancellation (rapid selection changes) terminates the child so
    /// abandoned invocations don't leave unzip running.
    private static func runUnzip(arguments: [String], cap: Int?) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try process.run()

                // Drain stderr concurrently on its own thread. If unzip
                // writes more than the pipe buffer (~64 KB) to stderr,
                // reading it only after waitUntilExit() would deadlock:
                // the child blocks writing stderr while we block reading
                // stdout. A background drain keeps both pipes flowing.
                let errHandle = stderr.fileHandleForReading
                let errBox = ErrDataBox()
                let errThread = Thread {
                    errBox.data = (try? errHandle.readToEnd()) ?? Data()
                }
                errThread.start()

                var collected = Data()
                let handle = stdout.fileHandleForReading
                while true {
                    if Task.isCancelled {
                        // Abandoned by a newer selection — kill the child
                        // so it doesn't keep churning through a huge zip.
                        process.terminate()
                        break
                    }
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if let cap, collected.count >= cap {
                        // Cap reached — keep reading to drain the pipe so
                        // the child process can exit, but drop the bytes
                        // on the floor.
                        continue
                    }
                    if let cap, collected.count + chunk.count > cap {
                        collected.append(chunk.prefix(cap - collected.count))
                    } else {
                        collected.append(chunk)
                    }
                }

                process.waitUntilExit()
                // stderr is small in the success path; wait for the drain
                // thread so the error summary below is complete.
                while errThread.isExecuting { usleep(1_000) }

                if Task.isCancelled {
                    throw CancellationError()
                }

                guard process.terminationStatus == 0 else {
                    let errData = errBox.data
                    let trimmed = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let summary = trimmed.isEmpty
                        ? "exit \(process.terminationStatus)"
                        : trimmed
                    throw NSError(
                        domain: "mq-dir.zip-preview",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: summary]
                    )
                }
                return collected
            }.value
        } onCancel: {
            // Fires the moment the surrounding Task is cancelled, even if
            // the stdout read loop is parked in a blocking `availableData`.
            if process.isRunning { process.terminate() }
        }
    }

    /// Box so the stderr drain thread can hand its bytes back to the
    /// reader. `@unchecked Sendable` is safe: the writer thread finishes
    /// (joined via `isExecuting`) before any reader touches `data`.
    private final class ErrDataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Best-effort sweep of leftover PDF-preview temp directories from a
    /// prior run that crashed or was force-quit before `cleanupPDFTemp`
    /// ran. Called once from `AppDelegate.applicationDidFinishLaunching`;
    /// matches the `mq-dir-zip-preview-*` naming used by
    /// `ZipPreviewView.decodedContent`.
    static func sweepLeftoverTempDirs() {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let contents = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for dir in contents where dir.lastPathComponent.hasPrefix("mq-dir-zip-preview-") {
            try? fm.removeItem(at: dir)
        }
    }
}

// MARK: - Preview view

/// Right-side preview pane for a selected `.zip`. Top half is a
/// scrollable listing of the archive's contents (one row per
/// `ZipEntry`, indented by depth). Bottom half is a context-sensitive
/// preview of the selected entry: text/Markdown for source code &
/// docs, NSImage for images, PDFKit for embedded PDFs. Anything we
/// can't decode in-memory falls back to a "Use Extract to view"
/// hint — the existing ditto/tar context-menu action stays the
/// escape hatch.
struct ZipPreviewView: View {
    let url: URL

    @State private var entries: [ZipEntry] = []
    @State private var listError: String?
    @State private var loadingList = false
    @State private var selected: ZipEntry?
    @State private var content: ZipPreviewContent = .idle
    /// PDF preview needs a real file URL because `PDFDocument(url:)`
    /// and `PDFView` won't render in-memory data without first
    /// landing it on disk; the temp file is recreated per selection
    /// and cleaned up when the view goes away.
    @State private var pdfTempURL: URL?

    var body: some View {
        VSplitView {
            listing
                .frame(minHeight: 120)
            previewArea
                .frame(minHeight: 80)
        }
        .task(id: url) { await reloadListing() }
        .onChange(of: selected) { _, new in
            Task { await loadContent(for: new) }
        }
        .onDisappear { cleanupPDFTemp() }
    }

    // MARK: Listing

    private var listing: some View {
        Group {
            if loadingList {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listError {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18))
                        .foregroundStyle(.orange)
                    Text("Couldn't read archive")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.label)
                    Text(listError)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.labelSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("Empty archive")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.labelTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // SwiftUI's `List(selection:)` does not reliably
                // respond to clicks inside a SwiftUI macOS host —
                // the rest of the app uses ScrollView+ForEach+Button
                // for the same reason. Mirror that pattern so a tap
                // actually flips `selected`.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            zipRow(entry)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.Color.paneBg)
            }
        }
    }

    private func zipRow(_ entry: ZipEntry) -> some View {
        let isSelected = selected == entry
        return HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(entry.depth) * 12)
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .white : Theme.Color.labelSecondary)
            Text(entry.displayName)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : Theme.Color.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Theme.Color.selection : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        // Mirror the BrowserPaneView row pattern — `Button(...).buttonStyle(.plain)`
        // does not reliably receive clicks inside SwiftUI scroll hosts on
        // macOS, so the rest of the app uses onTapGesture on a content-shape
        // background. Keep the same convention here.
        .onTapGesture {
            selected = entry
        }
    }

    // MARK: Preview area

    @ViewBuilder
    private var previewArea: some View {
        switch content {
        case .idle:
            placeholder("Select an entry to preview")
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let string, let truncated):
            ScrollView {
                Text(string)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Color.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Theme.Color.paneBg)
            .overlay(alignment: .topTrailing) {
                if truncated {
                    truncationBadge
                        .padding(8)
                }
            }
        case .image(let image):
            ZStack {
                Theme.Color.paneBg
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            }
        case .pdf(let url):
            PDFPreview(url: url)
        case .directory:
            placeholder("Folder — pick a file inside to preview")
        case .unsupported(let summary):
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Color.labelTertiary)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Text("Use Extract from the right-click menu to open it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.labelTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text("Couldn't extract entry")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.label)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var truncationBadge: some View {
        Text("Truncated at \(ZipPreviewService.extractCap / (1024 * 1024)) MB")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.Color.accent.opacity(0.85), in: Capsule())
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.labelTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaders

    private func reloadListing() async {
        loadingList = true
        listError = nil
        selected = nil
        content = .idle
        cleanupPDFTemp()
        do {
            let result = try await ZipPreviewService.list(archive: url)
            // Auto-select the first non-directory entry so the bottom
            // half of the pane shows a real preview the moment the
            // user clicks the .zip — otherwise we'd render the
            // "Select an entry to preview" placeholder until they
            // hunt for a row, which reads as broken UX.
            let firstFile = result.first(where: { !$0.isDirectory })
            await MainActor.run {
                self.entries = result
                self.loadingList = false
                self.selected = firstFile
            }
        } catch {
            await MainActor.run {
                self.entries = []
                self.listError = error.localizedDescription
                self.loadingList = false
            }
        }
    }

    private func loadContent(for entry: ZipEntry?) async {
        cleanupPDFTemp()
        guard let entry else { content = .idle; return }
        if entry.isDirectory {
            await MainActor.run { self.content = .directory }
            return
        }
        await MainActor.run { self.content = .loading }
        do {
            let result = try await ZipPreviewService.extract(archive: url, entry: entry.path)
            // `decodedContent` runs on the main actor so the PDF branch can
            // assign `pdfTempURL` synchronously before returning — see the
            // race note in `decodedContent`.
            let resolved = await MainActor.run {
                decodedContent(for: entry, data: result.data, truncated: result.truncated)
            }
            await MainActor.run { self.content = resolved }
        } catch {
            await MainActor.run { self.content = .error(error.localizedDescription) }
        }
    }

    /// Map raw extracted bytes onto a renderable preview shape.
    /// Image / PDF / text are decoded inline; everything else falls
    /// through to the Extract hint so the user knows the next step.
    /// Runs on the main actor so the PDF branch can mutate the
    /// `pdfTempURL` @State synchronously and ordered against
    /// `cleanupPDFTemp`.
    @MainActor
    private func decodedContent(
        for entry: ZipEntry,
        data: Data,
        truncated: Bool
    ) -> ZipPreviewContent {
        let ext = (entry.path as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext), let image = NSImage(data: data) {
            return .image(image)
        }
        if ext == "pdf" {
            // PDFKit is happiest with a file URL on disk. Drop the
            // bytes into a temp file scoped to this preview view so
            // teardown can reliably clean it up.
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mq-dir-zip-preview-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let tempURL = tempDir.appendingPathComponent(entry.displayName.isEmpty ? "preview.pdf" : entry.displayName)
                try data.write(to: tempURL)
                // Replace any previous temp dir synchronously on the main
                // actor. Doing this via a detached `Task { @MainActor }`
                // previously let rapid PDF→PDF selections interleave with
                // `cleanupPDFTemp`, leaking the directory we were about to
                // overwrite. Clean up the specific dir we're replacing.
                if let previous = pdfTempURL, previous != tempURL {
                    try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
                }
                pdfTempURL = tempURL
                return .pdf(tempURL)
            } catch {
                return .error(error.localizedDescription)
            }
        }
        if let text = String(data: data, encoding: .utf8), looksLikeText(text) {
            return .text(text, truncated: truncated)
        }
        return .unsupported(summary: "No in-pane preview for \(ext.isEmpty ? "this entry" : ".\(ext)") files.")
    }

    /// Crude binary detector — if more than 1% of the sampled bytes
    /// are NUL or non-printable controls, treat as binary and skip
    /// the text path. Avoids dumping an executable's bytes into the
    /// monospace pane just because UTF-8 happened to decode it.
    private func looksLikeText(_ string: String) -> Bool {
        if string.isEmpty { return false }
        let sample = string.prefix(4_000)
        var bad = 0
        for scalar in sample.unicodeScalars {
            if scalar == "\0" { return false }
            if scalar.value < 0x20,
               scalar != "\n", scalar != "\r", scalar != "\t" {
                bad += 1
            }
        }
        // Cross-multiply instead of `bad < count / 100`: integer
        // division truncates to 0 for samples under 100 scalars, which
        // would misclassify every short text file as binary. `bad * 100
        // < count` keeps the same 1%-bad threshold without the divisor
        // collapsing on small inputs.
        return bad * 100 < sample.unicodeScalars.count
    }

    private func cleanupPDFTemp() {
        guard let url = pdfTempURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        pdfTempURL = nil
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "ico"
    ]
}

/// Discriminated union of every preview shape the bottom half of
/// `ZipPreviewView` can show. SwiftUI's `switch` on enum cases keeps
/// the conditional rendering tree simpler than carrying separate
/// optional state variables for each branch.
enum ZipPreviewContent: Equatable {
    case idle
    case loading
    case directory
    case text(String, truncated: Bool)
    case image(NSImage)
    case pdf(URL)
    case unsupported(summary: String)
    case error(String)
}
