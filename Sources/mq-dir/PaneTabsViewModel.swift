import Combine
import Foundation

/// Owns the ordered list of tabs for one pane plus the active index.
///
/// Each tab is a `FolderBrowserViewModel` — what used to be the entire
/// pane VM is now the per-tab VM. This wrapper handles tab lifecycle (new,
/// close, duplicate, reorder, reopen) and forwards each contained tab's
/// `objectWillChange` to its own publisher so `MainWindowView`'s debounced
/// save runs whenever any state in any tab changes.
@MainActor
final class PaneTabsViewModel: ObservableObject {
    @Published var tabs: [FolderBrowserViewModel]
    @Published var activeIndex: Int

    /// LIFO of recently-closed tabs so ⌘⇧T can put them back. Capped at 10
    /// because nobody actually undoes farther than that and unbounded growth
    /// would just bloat the persisted state if we ever serialized it.
    private var closedTabStack: [TabState] = []
    private static let closedTabCapacity = 10

    private var tabSubscriptions: [AnyCancellable] = []

    init(state: PaneState) {
        let restored = state.tabs.isEmpty
            ? [FolderBrowserViewModel()]
            : state.tabs.map { FolderBrowserViewModel(state: $0) }
        self.tabs = restored
        self.activeIndex = max(0, min(state.activeTabIndex, restored.count - 1))
        wireTabs()
    }

    /// Convenience accessor — body code never indexes `tabs[activeIndex]`
    /// directly so an out-of-range index can't crash the UI. The clamp on
    /// every mutation keeps this safe in practice.
    var activeTab: FolderBrowserViewModel {
        tabs[max(0, min(activeIndex, tabs.count - 1))]
    }

    // MARK: Lifecycle

    /// Append a new empty tab and switch to it. The tab opens in the empty
    /// "No folder" state so the user can pick a folder via the existing
    /// CTA — same UX as a new pane in the Finder.
    func newTab(folderURL: URL? = nil) {
        let tab = FolderBrowserViewModel()
        if let folderURL {
            tab.openFolder(folderURL)
        }
        tabs.append(tab)
        activeIndex = tabs.count - 1
        wireTabs()
    }

    /// Close the active tab. With one tab left the slot is replaced with a
    /// fresh empty tab (Safari convention) so the pane is never empty —
    /// otherwise the layout would have nothing to render and the toolbar
    /// would lose its breadcrumb anchor.
    func closeActive() {
        closeTab(at: activeIndex)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        pushClosed(tabs[index])
        tabs.remove(at: index)

        if tabs.isEmpty {
            tabs = [FolderBrowserViewModel()]
            activeIndex = 0
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
        wireTabs()
    }

    /// Reopen the most recently closed tab. No-op when the stack is empty.
    /// The restored tab is appended at the end and made active.
    func reopenClosed() {
        guard let state = closedTabStack.popLast() else { return }
        let tab = FolderBrowserViewModel(state: state)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        wireTabs()
    }

    func duplicate(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let copy = FolderBrowserViewModel(state: tabs[index].tabSnapshot())
        tabs.insert(copy, at: index + 1)
        activeIndex = index + 1
        wireTabs()
    }

    func closeOthers(keep index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keeper = tabs[index]
        for tab in tabs where tab !== keeper {
            pushClosed(tab)
        }
        tabs = [keeper]
        activeIndex = 0
        wireTabs()
    }

    func closeToTheRight(of index: Int) {
        guard tabs.indices.contains(index), index + 1 < tabs.count else { return }
        for tab in tabs[(index + 1)...] {
            pushClosed(tab)
        }
        tabs.removeSubrange((index + 1)...)
        if activeIndex > index { activeIndex = index }
        wireTabs()
    }

    // MARK: Selection

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
    }

    func nextTab() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex + 1) % tabs.count
    }

    func prevTab() {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex - 1 + tabs.count) % tabs.count
    }

    // MARK: Reorder

    func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source) else { return }
        let dest = max(0, min(destination, tabs.count))
        if dest == source || dest == source + 1 { return }
        let item = tabs.remove(at: source)
        let insertAt = source < dest ? dest - 1 : dest
        tabs.insert(item, at: insertAt)

        // Recompute active index so the same tab stays selected after reorder.
        if activeIndex == source {
            activeIndex = insertAt
        } else if source < activeIndex && insertAt >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex && insertAt <= activeIndex {
            activeIndex += 1
        }
        wireTabs()
    }

    // MARK: Persistence

    func snapshot() -> PaneState {
        PaneState(
            tabs: tabs.map { $0.tabSnapshot() },
            activeTabIndex: activeIndex
        )
    }

    // MARK: Private

    private func pushClosed(_ tab: FolderBrowserViewModel) {
        // Don't bother stacking truly-empty tabs — reopening one would just
        // produce an indistinguishable blank slot.
        let snap = tab.tabSnapshot()
        guard snap.folderBookmark != nil else { return }
        closedTabStack.append(snap)
        if closedTabStack.count > Self.closedTabCapacity {
            closedTabStack.removeFirst(closedTabStack.count - Self.closedTabCapacity)
        }
    }

    /// Forward every tab's `objectWillChange` to ours. Rebuilds the whole
    /// subscription set on each mutation; cheap for the small N (≤ ~10) of
    /// tabs a sane user keeps open.
    private func wireTabs() {
        tabSubscriptions.removeAll()
        for tab in tabs {
            tab.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &tabSubscriptions)
        }
    }
}
