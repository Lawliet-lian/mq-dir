import Combine
import Foundation
import Sparkle

/// Drives Sparkle on behalf of the UI.
///
/// Sparkle's standard updater controller silently checks the appcast at the
/// configured interval; we observe the result via `SPUUpdaterDelegate` and
/// surface a single `@Published var updateAvailable` flag. The sidebar
/// renders its update button only while that flag is true; tapping it
/// re-runs `checkForUpdates(_:)` so Sparkle's stock confirm/install dialog
/// drives the actual download + relaunch.
///
/// We deliberately *don't* use a custom user driver yet — Sparkle's stock
/// dialogs already handle progress, errors, and the relaunch prompt; until
/// the UX needs diverge from "show the system flow on click", reinventing
/// that surface area is wasted work.
final class UpdateManager: NSObject, ObservableObject {
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var lastCheckDate: Date?

    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        // `startingUpdater: true` immediately schedules background checks
        // per the SUScheduledCheckInterval / SUEnableAutomaticChecks values
        // in Info.plist. Setting the delegate at construction is the only
        // way Sparkle can call back into us for "found update."
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// Manual check entry-point. Bound to the sidebar update button —
    /// triggers the standard Sparkle UI for confirm + install + relaunch.
    @MainActor
    func checkForUpdatesAndShowUI() {
        updaterController.checkForUpdates(nil)
    }

    /// Background-check entry-point — same as the timer-driven one but
    /// callable from us if we ever add a manual "Check Now" menu item.
    @MainActor
    func checkInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }
}

// MARK: - Sparkle delegate

extension UpdateManager: SPUUpdaterDelegate {
    /// Called whenever Sparkle's background check successfully finds an
    /// appcast item with a higher version than the currently-running app.
    /// We just flip the flag — the sidebar reacts and the user clicks the
    /// button when ready, no surprise modal popups.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateAvailable = true
            self.lastCheckDate = Date()
        }
    }

    /// Update was found and either dismissed by the user or installed.
    /// Either way the flag clears so the button hides.
    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            self.updateAvailable = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
            self.lastCheckDate = Date()
        }
    }
}
