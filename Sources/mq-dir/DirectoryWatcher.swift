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

        // Hand FSEvents a *retained* box holding a *weak* reference to
        // `self` as the context info. The stream's +1 keeps the box alive
        // (so a callback in flight on `debounceQueue` never dereferences
        // freed memory), while the watcher itself stays un-retained — so
        // the VM's "drop the reference and ARC tears it down" contract
        // (FolderBrowserViewModel relies on `deinit` → `stop()`) keeps
        // working. A callback racing teardown weak-loads either a live
        // watcher or nil, never a dangling pointer. The box retain is
        // balanced by the stream's `release` callback, invoked when the
        // stream is invalidated in `stop()`.
        let box = WatcherContextBox(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: DirectoryWatcher.contextRelease,
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
            // ⌘R reload still works for the user. No stream ever adopted
            // the context, so its `release` callback won't fire; balance
            // the `passRetained` here so the box isn't leaked.
            Unmanaged<WatcherContextBox>.fromOpaque(context.info!).release()
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
        // `FSEventStreamInvalidate` invokes the context `release` callback
        // (`contextRelease`) exactly once, balancing the `passRetained`
        // from init. `guard let stream` keeps this idempotent: a second
        // `stop()` (or `deinit` after an explicit `stop()`) returns early,
        // so the release never runs twice.
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

    /// FSEvents C-callback. The `info` pointer is the *retained*
    /// `WatcherContextBox` registered in the context above; the box is
    /// guaranteed alive by the stream's retain, and the watcher is
    /// weak-loaded from it — a callback racing a concurrent teardown
    /// gets nil instead of a dangling pointer. `takeUnretainedValue`
    /// because the retain is owned by the stream's context and balanced
    /// by `contextRelease` on invalidation.
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let box = Unmanaged<WatcherContextBox>.fromOpaque(info).takeUnretainedValue()
        box.watcher?.scheduleDebouncedNotify()
    }

    /// Context `release` callback. FSEvents calls this exactly once when
    /// the stream is invalidated (from `stop()`), balancing the
    /// `passRetained(box)` we set as `context.info` at init.
    private static let contextRelease: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<WatcherContextBox>.fromOpaque(info).release()
    }
}

/// Retained by the FSEvents stream context in place of the watcher
/// itself. Holding the watcher only weakly means the stream's +1 keeps
/// *this box* alive across in-flight callbacks without preventing the
/// watcher's `deinit` (which is what stops the stream — retaining the
/// watcher from its own stream context would deadlock that teardown
/// into a permanent leak). ARC weak references are thread-safe, so the
/// callback's weak-load on `debounceQueue` is race-free.
private final class WatcherContextBox {
    weak var watcher: DirectoryWatcher?
    init(_ watcher: DirectoryWatcher) { self.watcher = watcher }
}
