import SwiftUI
import AppKit

// Theme tokens. Dark mode keeps the Claude Design prototype's hex
// palette verbatim. Light mode falls back to the macOS system
// dynamic colours (NSColor.windowBackgroundColor, .labelColor,
// .controlAccentColor, …) so the app renders correctly when the
// user picks Light or Match System in Preferences without us
// having to design a full light palette this round. A dedicated
// light palette can land later by replacing the `light:` arguments
// without touching call sites.

enum Theme {
    enum Color {
        static let windowBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  .hex(0x1d, 0x1d, 0x1f),
                light: .windowBackgroundColor
            )
        )
        static let paneBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  .hex(0x1d, 0x1d, 0x1f),
                light: .windowBackgroundColor
            )
        )
        static let toolbarBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  .hex(0x28, 0x28, 0x2a, alpha: 0.92),
                light: .windowBackgroundColor
            )
        )
        static let sidebarBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  .hex(0x1e, 0x1e, 0x20, alpha: 0.92),
                light: .controlBackgroundColor
            )
        )
        static let tabBarBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  NSColor.black.withAlphaComponent(0.18),
                light: NSColor.black.withAlphaComponent(0.04)
            )
        )
        static let columnHeaderBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  NSColor.black.withAlphaComponent(0.12),
                light: NSColor.black.withAlphaComponent(0.03)
            )
        )
        static let statusBarBg = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  .hex(0x1c, 0x1c, 0x1e, alpha: 0.95),
                light: .windowBackgroundColor
            )
        )
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        static let separatorFaint = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  NSColor.white.withAlphaComponent(0.05),
                light: NSColor.black.withAlphaComponent(0.04)
            )
        )
        static let label = SwiftUI.Color(nsColor: .labelColor)
        static let labelSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        static let labelTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let accent = SwiftUI.Color(nsColor: .controlAccentColor)
        static let selection = SwiftUI.Color(nsColor: .controlAccentColor)
        static let selectionInactive = SwiftUI.Color(
            nsColor: .unemphasizedSelectedContentBackgroundColor
        )
        static let rowHover = SwiftUI.Color(
            nsColor: .dynamic(
                dark:  NSColor.white.withAlphaComponent(0.03),
                light: NSColor.black.withAlphaComponent(0.03)
            )
        )
    }

    enum Metrics {
        static let toolbarHeight: CGFloat       = 38   // compact, Xcode-like
        static let tabBarHeight: CGFloat        = 26
        static let paneHeaderHeight: CGFloat    = 20
        static let columnHeaderHeight: CGFloat  = 22
        static let rowHeight: CGFloat           = 22
        static let statusBarHeight: CGFloat     = 24
        static let sidebarWidth: CGFloat        = 184
        static let focusBorderWidth: CGFloat    = 2
    }

    enum Font {
        static let body          = SwiftUI.Font.system(size: 13)
        static let secondary     = SwiftUI.Font.system(size: 11)
        static let columnHeader  = SwiftUI.Font.system(size: 11, weight: .medium)
        static let sidebarItem   = SwiftUI.Font.system(size: 12)
        static let sidebarHeader = SwiftUI.Font.system(size: 10, weight: .bold)
        static let tab           = SwiftUI.Font.system(size: 11)
        static let breadcrumb    = SwiftUI.Font.system(size: 12)
    }
}

// MARK: - NSColor helpers

private extension NSColor {
    /// Build a dynamic NSColor that resolves to `dark` under
    /// `.darkAqua` / `.vibrantDark` appearances and to `light` under
    /// `.aqua` / `.vibrantLight`. Used by Theme.Color tokens so a
    /// single static can serve both modes without per-View
    /// `@Environment(\.colorScheme)` plumbing.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let resolved = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            return resolved == .darkAqua ? dark : light
        }
    }

    /// Convenience for the prototype's hex literals that already live
    /// in this file — keeps the call sites readable instead of
    /// repeating `red: 0x1d/255, green: …`.
    static func hex(_ r: Int, _ g: Int, _ b: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: alpha
        )
    }
}
