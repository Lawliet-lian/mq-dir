import AppKit
import SwiftUI

/// Row-leading icon view used by both the list (`BrowserPaneView`)
/// and tree (`TreeFileListView`) renders, plus the preview header.
///
/// Folders with a Finder custom icon (`Icon\r` written by Get Info)
/// render the user's chosen image via `NSWorkspace.shared.icon`.
/// Every other entry keeps the original SF Symbol + tint rendering
/// so the wider file palette stays consistent with the existing
/// minimal-icon aesthetic; switching the whole row population to
/// system icons would also lose the colour-coded extension hint
/// people rely on to scan a folder at a glance.
struct FileRowIcon: View {
    let entry: FileEntry
    /// Highlights selected rows: when the pane is focused and the
    /// row is selected the icon flips to white so it stays legible
    /// against the accent fill. The custom-icon path ignores this
    /// because the NSImage carries its own pixels.
    var isSelected: Bool = false
    var paneIsFocused: Bool = false

    var body: some View {
        if entry.isDirectory && entry.hasCustomIcon {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: FileIconStyle.symbol(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(isSelected && paneIsFocused
                                 ? Color.white
                                 : FileIconStyle.tint(for: entry))
                .frame(width: 14)
        }
    }
}
