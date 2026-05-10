import SwiftUI

extension ColorSchemeOption {
    /// Map the persisted preference onto SwiftUI's `.preferredColorScheme`.
    /// `.system` becomes `nil` so the modifier becomes a no-op and macOS's
    /// own Appearance setting wins.
    var preferred: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    /// Display label for the Settings picker.
    var label: String {
        switch self {
        case .system: "Match System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }
}

/// macOS Settings scene contents. Bound directly to `WorkspaceManager`
/// so the picker drives `setColorScheme(_:)` and the preview reflects
/// the saved preference. The window is small and stateless on purpose
/// — Phase 3 only ships theme; future settings (keyboard customizer,
/// archive handler) will land here as additional `Form` sections.
struct SettingsView: View {
    @ObservedObject var workspace: WorkspaceManager

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(ColorSchemeOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Match System follows macOS's Appearance setting.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 220)
    }

    /// Binding that round-trips through `WorkspaceManager.setColorScheme`
    /// instead of a raw KVO mutation, so the change debounces through the
    /// standard 500 ms save path and the rest of the app sees the
    /// `@Published workspace` update.
    private var appearanceBinding: Binding<ColorSchemeOption> {
        Binding(
            get: { workspace.workspace.settings.colorScheme },
            set: { workspace.setColorScheme($0) }
        )
    }
}
