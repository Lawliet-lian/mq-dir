// Feedback channel webhook URL (Discord). The committed value is `nil`
// so the public source tree never carries the credential and CI builds
// don't break. Maintainers running release builds inject the real URL
// in their local copy of this file and use
//
//     git update-index --skip-worktree Sources/mq-dir/FeedbackSecrets.swift
//
// to keep their override out of `git status` / accidental commits.
// When `discordWebhookURL` is nil the in-app Send Feedback sheet
// reports a "feedback channel not configured" error.
enum FeedbackSecrets {
    static let discordWebhookURL: String? = nil
}
