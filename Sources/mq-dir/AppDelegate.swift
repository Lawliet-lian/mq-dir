import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clean up PDF-preview temp dirs orphaned by a crash or
        // force-quit in a previous run (normal teardown removes them
        // in `cleanupPDFTemp`, but nothing else reclaims strays).
        Task.detached(priority: .background) {
            ZipPreviewService.sweepLeftoverTempDirs()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // No-op in M0; M1 will route open requests to the focused pane.
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
