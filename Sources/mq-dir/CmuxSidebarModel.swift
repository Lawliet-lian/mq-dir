import Foundation

/// State for the sidebar's CMUX section. Manual sync only — the user
/// presses the refresh button in the section header to pull the latest
/// workspace list from the cmux Unix socket.
///
/// Available state is decoupled from the synced workspace list so a
/// failed or in-flight refresh doesn't blank out what was previously
/// shown. The "available" flag also gates section visibility — when
/// cmux isn't installed the sidebar omits the section entirely instead
/// of showing an error.
@MainActor
final class CmuxSidebarModel: ObservableObject {
    @Published private(set) var workspaces: [CmuxWorkspace] = []
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncDate: Date?
    /// `true` when a `cmux` binary is detectable on this machine. Read
    /// once at construction; we don't re-probe because installing cmux
    /// during an mq-dir session is a strange enough flow that requiring
    /// a relaunch is fine.
    let cmuxAvailable: Bool

    init() {
        self.cmuxAvailable = CmuxClient.locateBinary() != nil
    }

    /// Pull the latest workspace list from cmux. No-op when cmux isn't
    /// installed (the section is hidden anyway). Errors land on
    /// `lastError` so the UI can surface a one-line hint without
    /// modal alerts.
    func sync() async {
        guard cmuxAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            // Run the shell-out off the main actor — `Process.waitUntilExit`
            // blocks until cmux finishes responding, which on a cold socket
            // can take 100s of ms.
            let fetched = try await Task.detached(priority: .userInitiated) {
                try CmuxClient.listWorkspaces()
            }.value
            self.workspaces = fetched
            self.lastError = nil
            self.lastSyncDate = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
