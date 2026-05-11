import AppKit
import SwiftUI

@main
struct mqdirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceManager()
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var repoCallout = RepoCalloutController()

    init() {
        // Forward NSApplication's willTerminate to our internal notification
        // so MainWindowView can flush a synchronous save before exit.
        // Doing this in App.init keeps the wiring close to the lifecycle
        // that depends on it, and avoids touching AppDelegate's existing
        // M0-era responsibilities.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .mqdirAppWillTerminate, object: nil)
        }
    }

    var body: some Scene {
        WindowGroup("mq-dir") {
            // Key MainWindowView on the active project ID so a project
            // switch tears down the old pane `@StateObject`s and the new
            // instance reads its initial state from the project we're
            // moving to. Without this, swapping the active project would
            // leave the old pane VMs alive holding stale folder state.
            MainWindowView(
                workspace: workspace,
                updateManager: updateManager,
                repoCallout: repoCallout
            )
                // Drop the workspace into the environment so deep
                // descendants (e.g. `FileEntryContextMenu`) can pick
                // up customised shortcut bindings without an
                // ObservedObject parameter threaded through every
                // intermediate view.
                .environmentObject(workspace)
                .id(workspace.workspace.activeProjectID)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(workspace.workspace.settings.colorScheme.preferred)
        }
        .windowResizability(.contentMinSize)
        .commands {
            MenuCommands(workspace: workspace)
        }

        // Standard macOS Preferences window (⌘,). Phase 3 ships the
        // appearance picker; future settings — keyboard customizer,
        // archive handler — will land as additional Form sections.
        Settings {
            SettingsView(workspace: workspace)
                .preferredColorScheme(workspace.workspace.settings.colorScheme.preferred)
        }
    }
}
