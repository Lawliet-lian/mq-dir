import CoreServices
import Foundation

/// Wrapper around `FSEventStream` that fires `onChange` whenever the OS
/// reports filesystem activity at or below `url`. Coalesces bursts on a
/// 200 ms debounce so a recursive `cp -R` of a hundred files only
/// triggers one reload.
///
/// FSEvents' kernel-level notifications are basically free in steady
/// state — the watcher only does meaningful work when something
/// actually changes — so we keep one watcher per open tab and let
/// per-tab `reload()` calls fan out independently.
///
/// The wrapper is `@unchecked Sendable` because the C-callback hands
/// us a raw `info` pointer with no Swift isolation context; we hop
/// back to `DispatchQueue.main` before invoking `onChange`, so the
/// caller's closure always runs on the main queue.
final class DirectoryWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let debounceQueue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var pendingDebounce: DispatchWorkItem?
    private static let debounceLatency: TimeInterval = 0.2

    /// Start watching `url`. FSEvents reports the entire subtree at
    /// the kernel level — there is no "direct children only" mode at
    /// the API level — so a deeply nested write under `url` will fire
    /// `onChange` even though the flat listing the user sees doesn't
    /// change. The cost is a no-op `reload()` for those events; the
    /// alternative (filtering callback `eventPaths` against `url`'s
    /// immediate parent) is a future optimisation.
    ///
    /// `kFSEventStreamEventIdSinceNow` opts out of replaying historical
    /// events at start. `WatchRoot` lets us also receive events when
    /// `url` itself is renamed or moved, which `reload()` currently
    /// doesn't act on but costs nothing extra to subscribe to.
    ///
    /// `onChange` is always dispatched on `DispatchQueue.main` so
    /// callers can mutate `@MainActor` state without an extra hop.
    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounceQueue = DispatchQueue(label: "mq-dir.directory-watcher.\(UUID().uuidString)")

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [url.path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            DirectoryWatcher.debounceLatency,
            flags
        ) else {
            // FSEventStreamCreate returns nil on permission failures
            // or invalid paths. Drop the watcher silently — manual
            // ⌘R reload still works for the user.
            self.stream = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, debounceQueue)
        FSEventStreamStart(stream)
    }

    /// Stop the underlying stream and release it. Idempotent — the
    /// VM calls `stop()` from `deinit` and may also call it explicitly
    /// when the active folder URL changes.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Cancel any in-flight debounce so a stale event doesn't
        // fire `onChange` after the watcher has been torn down.
        pendingDebounce?.cancel()
        pendingDebounce = nil
    }

    deinit {
        stop()
    }

    /// Schedule (or reschedule) a single `onChange` after the
    /// quiet window. Called from the C callback below — runs on
    /// `debounceQueue`, never on the main queue, so the cancel/replace
    /// dance is safe without extra locking.
    fileprivate func scheduleDebouncedNotify() {
        pendingDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onChange()
            }
        }
        pendingDebounce = work
        debounceQueue.asyncAfter(deadline: .now() + DirectoryWatcher.debounceLatency, execute: work)
    }

    /// FSEvents C-callback. The `info` pointer is the unretained
    /// `DirectoryWatcher` we registered in the context above; we
    /// hand it back through `Unmanaged` and forward to the instance
    /// method without retaining (FSEvents is the lifecycle owner —
    /// we explicitly stop+release in `stop()`).
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.scheduleDebouncedNotify()
    }
}
