import AppKit
import Foundation

/// Drives the small repo-link capsule that appears in the sidebar
/// footer.
///
/// Mirrors `UpdateManager`'s "quiet flag → sidebar pill" pattern: a
/// single `@Published var shouldShowPill` flips on once a small set of
/// usage gates are satisfied, and the sidebar renders a capsule whose
/// click opens the repo URL in the user's browser. Gating state lives
/// entirely in `UserDefaults` — nothing leaves the device, consistent
/// with the v1 zero-telemetry stance.
@MainActor
final class RepoCalloutController: ObservableObject {
    /// True when the active capsule should be rendered. Recomputed on
    /// every launch and after each user interaction.
    @Published private(set) var shouldShowPill: Bool = false

    /// Mirrors `hasOpenedRepo` so dependent surfaces (e.g. the Feedback
    /// success view) can hide their own redundant CTA. Kept @Published
    /// so subscribers rebuild when the flag flips during the session.
    @Published private(set) var hasOpenedRepo: Bool = false

    private let defaults: UserDefaults
    private let now: () -> Date
    private let repoURL = URL(string: "https://github.com/h5nam/mq-dir")!

    /// Once the capsule has been surfaced this session, subsequent
    /// `evaluateCallout()` calls (e.g. after a user action) skip the
    /// 30-day cooldown check — otherwise the side effect we wrote on
    /// first surfacing would immediately hide the capsule mid-session.
    private var sessionCalloutSurfaced = false

    /// Guards `recordLaunch()` so it stays a once-per-process operation
    /// even if it's called from a SwiftUI lifecycle hook that re-fires
    /// on project switches (MainWindowView is keyed on activeProjectID).
    private var hasRecordedThisProcess = false

    // Gate thresholds. Tweak together so the intent stays legible.
    private let minLaunchCount = 5
    private let minDaysSinceFirstLaunch: TimeInterval = 3 * 24 * 60 * 60
    private let cooldownAfterShown: TimeInterval = 30 * 24 * 60 * 60

    private enum Key {
        static let firstLaunchDate = "mqdir.firstLaunchDate"
        static let launchCount = "mqdir.launchCount"
        static let hasOpenedRepo = "mqdir.hasOpenedRepo"
        static let neverShowCallout = "mqdir.neverShowCallout"
        static let lastCalloutAt = "mqdir.lastCalloutAt"
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.hasOpenedRepo = defaults.bool(forKey: Key.hasOpenedRepo)
    }

    /// Called once at app startup. Seeds the first-launch date on the
    /// very first run, increments the launch counter, then re-evaluates
    /// the gate so the sidebar can react synchronously on appearance.
    /// Idempotent within a process — safe to wire to a SwiftUI hook
    /// that may fire more than once per cold launch.
    func recordLaunch() {
        guard !hasRecordedThisProcess else { return }
        hasRecordedThisProcess = true
        if defaults.object(forKey: Key.firstLaunchDate) == nil {
            defaults.set(now(), forKey: Key.firstLaunchDate)
        }
        let next = defaults.integer(forKey: Key.launchCount) + 1
        defaults.set(next, forKey: Key.launchCount)
        evaluateCallout()
    }

    /// Opens the repo in the user's default browser and records that
    /// the user has engaged with the repo. Optimistic — the capsule
    /// won't return either way (cooldown + flag), so the worst case is
    /// a missed engagement, never a repeat nag.
    func openRepo() {
        NSWorkspace.shared.open(repoURL)
        defaults.set(true, forKey: Key.hasOpenedRepo)
        defaults.set(now(), forKey: Key.lastCalloutAt)
        hasOpenedRepo = true
        evaluateCallout()
    }

    /// User chose "Don't show this again" from the capsule's context
    /// menu. Permanent — no version-bump revival, no cooldown reset.
    /// Explicit anti-nag escape hatch.
    func dismissPermanently() {
        defaults.set(true, forKey: Key.neverShowCallout)
        evaluateCallout()
    }

    /// Recomputes `shouldShowPill`. Cheap; safe to call after any state
    /// change. All conditions must be true for the capsule to appear.
    func evaluateCallout() {
        if defaults.bool(forKey: Key.hasOpenedRepo) {
            shouldShowPill = false
            return
        }
        if defaults.bool(forKey: Key.neverShowCallout) {
            shouldShowPill = false
            return
        }
        guard defaults.integer(forKey: Key.launchCount) >= minLaunchCount else {
            shouldShowPill = false
            return
        }
        guard let firstLaunch = defaults.object(forKey: Key.firstLaunchDate) as? Date,
              now().timeIntervalSince(firstLaunch) >= minDaysSinceFirstLaunch else {
            shouldShowPill = false
            return
        }
        if !sessionCalloutSurfaced,
           let lastShown = defaults.object(forKey: Key.lastCalloutAt) as? Date,
           now().timeIntervalSince(lastShown) < cooldownAfterShown {
            shouldShowPill = false
            return
        }
        if !sessionCalloutSurfaced {
            // Record that the capsule is being surfaced now so the
            // 30-day cooldown applies on the *next* launch even if the
            // user neither clicks nor dismisses this session.
            defaults.set(now(), forKey: Key.lastCalloutAt)
            sessionCalloutSurfaced = true
        }
        shouldShowPill = true
    }
}
