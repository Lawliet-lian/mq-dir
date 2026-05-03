# mq-dir

> The native macOS file manager for AI multi-taskers. Up to four independent panes for parallel projects and agents — persistent state, native polish, no compromise.

[![status](https://img.shields.io/badge/status-pre--alpha-orange)](#status)
[![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![swift](https://img.shields.io/badge/swift-5.10-orange)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

🌐 [mqdir.com](https://mqdir.com) · 📓 [Changelog](CHANGELOG.md) · 🛠 [Contributing](CONTRIBUTING.md)

![mq-dir hero](.github/assets/readme_hero.png)

## Why

A modern coding session is half source, half artifacts: generated images, recorded demos, PDFs, screenshots from QA, exported transcripts, downloaded models, design specs. None of it lives where your code does — and Finder wasn't built for that volume or for the way agents now produce work in parallel.

mq-dir gives you up to four independent panes side by side. One per project, one per agent, one for the artifact dump. Each pane keeps its own folder, sort, scroll position, and column widths — and remembers them across launches and force-quits.

## Features

**Working today (alpha.8)**

- 🟦 **1, 2, or 4-pane layouts** — focused-pane routing, independent folder per pane.
- 💾 **Per-pane state persistence** — folder, sort, hidden-files toggle, column widths, and selection survive relaunch and `kill -9`. Bookmarks are sandbox-ready.
- 🗂 **VS Code-style sidebar** — Favorites, Locations, Tags. One-click navigation routed to the focused pane.
- 🔎 **Per-pane recursive search** — debounced, case-insensitive substring match across the current folder's subtree.
- 📁 **Standard browsing** — column sorts, hidden-files toggle, parent navigation, back/forward stacks, Reveal in Finder, drag-and-drop file moves.
- 🎨 **Native macOS look** — SwiftUI + AppKit, system theme tokens, hand-finished app icon.

**Coming next**

- ↹ Per-pane tabs and 3-pane layout (M2 wrap-up).
- 👀 Spacebar QuickLook + inline image / video / audio / PDF preview (M3).
- ⌨️ Keyboard shortcuts, settings UI, polished sidebar favorites (M6).

See [Roadmap](#roadmap) for the full picture.

## Status

**Pre-alpha.** The app builds and runs, the working set above is stable enough for daily-driving by the maintainer, but there are no signed releases yet. Expect rough edges. Track progress in [`CHANGELOG.md`](CHANGELOG.md).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel
- For building: Xcode 15+, [Homebrew](https://brew.sh)

## Install

No signed binaries yet — build from source while the project is pre-alpha.

```bash
git clone https://github.com/<owner>/mq-dir.git
cd mq-dir
Scripts/bootstrap.sh   # installs XcodeGen and the xcodes CLI
open mq-dir.xcodeproj
```

`bootstrap.sh` generates `mq-dir.xcodeproj` from `project.yml` (XcodeGen is the source of truth — the `.xcodeproj` is not checked in).

**Tests-only** (no Xcode required, just the Swift toolchain):

```bash
swift test
```

Signed and notarized release builds, plus a maintainer Homebrew tap, are scaffolded for M5 — see the [roadmap](#roadmap).

## Privacy

**No telemetry. No crash reporting. No analytics. Ever, in v1.**

mq-dir is local-only. It reads your filesystem to show it back to you and writes its own state to `~/Library/Application Support/com.mqdir.app/`. No network calls. No phone-home. No "anonymous usage stats."

If a v1.x release ever proposes opt-in crash reporting, it will land behind a config toggle defaulting to off, with the source clearly visible. Until then, the network code path simply does not exist.

## Roadmap

| Milestone | Focus | Status |
|---|---|---|
| **M0** | App shell, OSS docs, CI, signing scaffold | ✅ done |
| **M1** | Single-pane MVP — folder browsing, sorting, persistent per-folder state | ✅ done |
| **M2** | Multi-pane — 1/2/(3)/4-pane layouts, per-pane tabs, session restore | 🟡 in progress (layouts + persistence done; tabs and 3-pane pending) |
| **M3** | Embedded preview — QuickLook, inline image/video/audio/PDF | ⬜️ planned |
| **M4** | Sidebar tree — VS Code-style folder tree, lazy-loaded | 🟡 partial (sidebar shipped; tree expansion pending) |
| **M5** | Release infra — signed/notarized builds, Homebrew tap, nightly | ⬜️ scaffolded |
| **M6** | UX polish — keyboard shortcuts, in-pane search refinements, drag/drop, settings | 🟡 partial |

**Out of scope for v1:** cloud sync, archive previews, file editing, plugins, iPadOS/iOS port, localization beyond English.

## Contributing

PRs welcome. Contributions are accepted via [DCO](https://developercertificate.org/) — every commit needs a `Signed-off-by:` line. **No CLA.** See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow, [`SECURITY.md`](SECURITY.md) for vulnerability disclosure, and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

MIT — see [`LICENSE`](LICENSE).

## Acknowledgments

mq-dir's quad-pane layout is inspired by **[Q-Dir](https://www.q-dir.com/)** by SoftwareOK / Nenad Hrg, a long-running Windows file manager that made the case for multi-pane file management. mq-dir is an independent, clean-room implementation in Swift for macOS — **not affiliated with, endorsed by, or derived from Q-Dir's source code**.
