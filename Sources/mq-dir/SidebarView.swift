import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @Binding var selectedURL: URL?
    let onSelect: (URL) -> Void

    /// Whichever favorite is currently being inline-renamed. Cleared on
    /// commit (Enter) or cancel (Esc / focus loss with empty input).
    @State private var editingID: Favorite.ID?
    /// Working draft for the rename TextField. Mirrored to a focus
    /// state so we can autoselect on entry.
    @State private var editingDraft: String = ""
    @FocusState private var renameFocused: Favorite.ID?

    /// Drop highlights: section-level for "drop into Favorites", row-level
    /// for "insert before this row." Only one is active at a time.
    @State private var sectionDropTargeted = false
    @State private var rowDropTargetedID: Favorite.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                favoritesSection
                    .padding(.bottom, 8)

                section("Locations") {
                    ForEach(SidebarItem.locations) { item in
                        locationRow(item)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Color.sidebarBg)
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Favorites")

            if viewModel.favorites.isEmpty {
                emptyFavoritesHint
            } else {
                ForEach(viewModel.favorites) { favorite in
                    favoriteRow(favorite)
                }
            }
        }
        // Whole-section drop zone so users can drop a folder anywhere in
        // the Favorites area (not just on an existing row) to append.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(sectionDropTargeted ? Theme.Color.accent.opacity(0.10) : .clear)
                .padding(.horizontal, 6)
        )
        .onDrop(
            of: DragDropSupport.acceptedDropTypes,
            isTargeted: $sectionDropTargeted
        ) { providers in
            handleDrop(providers: providers, before: nil)
            return true
        }
    }

    private var emptyFavoritesHint: some View {
        Text("Drag folders here to add")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Color.labelTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func favoriteRow(_ favorite: Favorite) -> some View {
        let resolved = viewModel.resolveURL(favorite)
        let isActive = resolved != nil && selectedURL == resolved
        let isStale = resolved == nil
        let isEditing = editingID == favorite.id
        let isDropTarget = rowDropTargetedID == favorite.id

        let row = HStack(spacing: 6) {
            iconView(for: resolved)
                .frame(width: 14)
                .opacity(isStale ? 0.4 : 1)
            if isEditing {
                TextField("", text: $editingDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Color.label)
                    .focused($renameFocused, equals: favorite.id)
                    .onSubmit { commitRename(favorite.id) }
                    .onKeyPress(.escape) {
                        cancelRename()
                        return .handled
                    }
            } else {
                Text(favorite.label)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(isStale ? Theme.Color.labelTertiary : Theme.Color.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, isActive ? 10 : 14)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(rowBackground(isActive: isActive, isDropTarget: isDropTarget))
        .overlay(alignment: .top) {
            // Insertion indicator when reordering / dropping a folder
            // before this row. The bar visually replaces the section
            // highlight while a row-level drop is active.
            if isDropTarget {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .help(isStale ? (favorite.fallbackPath ?? "Folder unavailable") : (resolved?.path ?? favorite.label))
        .onTapGesture {
            guard !isEditing else { return }
            if let url = resolved {
                selectedURL = url
                onSelect(url)
            }
        }
        .contextMenu {
            Button("Rename") { startRename(favorite) }
                .disabled(isStale)
            Button("Remove from Sidebar", role: .destructive) {
                viewModel.remove(favorite.id)
            }
        }

        // Row is both a drag SOURCE (reorder) and a drop TARGET (reorder
        // OR external folder add at this insertion point).
        row
            .onDrag {
                NSItemProvider(
                    object: favorite.id.uuidString as NSString
                )
            }
            .onDrop(
                of: DragDropSupport.acceptedDropTypes + [UTType.plainText.identifier],
                isTargeted: Binding(
                    get: { rowDropTargetedID == favorite.id },
                    set: { rowDropTargetedID = $0 ? favorite.id : nil }
                )
            ) { providers in
                handleDrop(providers: providers, before: favorite.id)
                return true
            }
    }

    private func iconView(for url: URL?) -> some View {
        Group {
            if let url {
                // NSWorkspace returns the actual Finder icon (custom icon,
                // tag color, sync overlay). Falls back to the generic
                // folder symbol when something goes wrong.
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.labelTertiary)
            }
        }
    }

    private func rowBackground(isActive: Bool, isDropTarget: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isActive ? Color.white.opacity(0.06) : Color.clear)
            .padding(.horizontal, isActive ? 6 : 0)
    }

    // MARK: Locations (unchanged from the static list)

    @ViewBuilder
    private func locationRow(_ item: SidebarItem) -> some View {
        let isActive = selectedURL == item.url

        Button {
            selectedURL = item.url
            onSelect(item.url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(width: 14)
                Text(item.label)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Color.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, isActive ? 10 : 14)
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.white.opacity(0.06) : Color.clear)
                    .padding(.horizontal, isActive ? 6 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Section chrome

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            content()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Font.sidebarHeader)
            .tracking(0.5)
            .foregroundStyle(Theme.Color.labelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    // MARK: Rename flow

    private func startRename(_ favorite: Favorite) {
        editingID = favorite.id
        editingDraft = favorite.label
        DispatchQueue.main.async { renameFocused = favorite.id }
    }

    private func commitRename(_ id: Favorite.ID) {
        viewModel.rename(id, to: editingDraft)
        cancelRename()
    }

    private func cancelRename() {
        editingID = nil
        editingDraft = ""
        renameFocused = nil
    }

    // MARK: Drop dispatch

    /// Routes incoming drops. Plain-text payloads are treated as a favorite
    /// reorder (the dragged row's UUID); file URLs are treated as a new
    /// favorite to add at the given insertion point.
    private func handleDrop(providers: [NSItemProvider], before targetID: Favorite.ID?) {
        // Try internal reorder first — if any provider has plain text,
        // assume it's our UUID payload and skip the file-URL path.
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let str = obj as? String,
                      let uuid = UUID(uuidString: str)
                else { return }
                Task { @MainActor in
                    viewModel.move(sourceID: uuid, before: targetID)
                }
            }
            return
        }

        // External folder drop → resolve URLs and append (or insert before
        // `targetID` once added; we always append here for simplicity, then
        // reorder so the newest entry lands at the requested slot).
        Task {
            let urls = await DragDropSupport.resolveURLs(from: providers)
            await MainActor.run {
                for url in urls {
                    viewModel.add(url: url)
                    if let targetID,
                       let newest = viewModel.favorites.last,
                       newest.id != targetID
                    {
                        viewModel.move(sourceID: newest.id, before: targetID)
                    }
                }
            }
        }
    }
}

// MARK: Hardcoded location items

struct SidebarItem: Identifiable {
    let id = UUID()
    let label: String
    let url: URL

    init(_ label: String, _ url: URL) {
        self.label = label
        self.url = url
    }

    static var locations: [SidebarItem] {
        [
            SidebarItem("Macintosh HD", URL(fileURLWithPath: "/")),
            SidebarItem("Applications", URL(fileURLWithPath: "/Applications")),
        ]
    }
}
