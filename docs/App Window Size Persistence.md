# App Window Size Persistence

> **Workspace:** /Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir

---

**User**

这个app现在点击mac交通信号灯的关闭按钮,再从dock栏唤起后,窗口的大小会恢复原来的大小,下次重新唤起能否保留上次的大小

**Assistant**

我来分析一下这个窗口大小记忆的问题。首先让我探索一下当前项目中窗口管理的相关代码。

我来帮你查找窗口大小、位置、关闭、重新打开相关的代码。先了解项目结构并搜索相关关键词。

找到了关键文件。现在让我深入阅读核心文件，包括 AppDelegate、主应用入口、主窗口视图以及持久化服务。

接下来补充查看 WorkspaceManager、MenuCommands、AppNotifications、ZipPreview 以及设置视图中的窗口相关代码。

现在我已经收集了所有相关代码的完整信息。以下是关于窗口大小、位置、关闭、重新打开相关代码的详细分析报告：

---

## 窗口相关代码完整分析报告

### 1. 应用入口与 WindowGroup 定义

**文件：** `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/mqdirApp.swift`

#### 核心实现（第 47-81 行）：
```swift
var body: some Scene {
    WindowGroup("mq-dir") {
        MainWindowView(...)
            .frame(minWidth: 900, minHeight: 600)   // 窗口最小尺寸约束
            .preferredColorScheme(...)
    }
    .windowResizability(.contentMinSize)              // 窗口可调整大小策略
    .commands {
        MenuCommands(workspace: workspace)            // 菜单命令（含窗口相关）
    }

    Settings { ... }                                  // 设置窗口（⌘,）
}
```

**关键点：**
- 主窗口使用 SwiftUI 的 `WindowGroup` 场景，最小尺寸为 900 x 600
- `.windowResizability(.contentMinSize)` 表示窗口可调整大小，但受内容最小尺寸约束
- 视图通过 `.id(项目ID + 语言)` 作为重建标识——项目切换或语言切换时整个窗口视图会被销毁重建

---

### 2. AppDelegate 实现

**文件：** `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppDelegate.swift`

该文件较为精简，实现了三个方法：

| 方法 | 作用 |
|------|------|
| `applicationDidFinishLaunching` | 启动时清理之前崩溃遗留的 PDF/ZIP 预览临时目录 |
| `application(_:open:)` | 处理外部 URL 打开请求（目前为 M0 阶段，尚未实现路由） |
| `applicationSupportsSecureRestorableState` | **返回 `true`——启用安全可恢复状态机制**，这是 macOS 原生窗口位置/大小恢复的基础声明 |

---

### 3. 窗口最小尺寸与内部控件尺寸

#### 3.1 窗口级最小尺寸
- **位置：** `mqdirApp.swift` 第 65 行
- **值：** `minWidth: 900, minHeight: 600`

#### 3.2 分栏（Pane）最小宽度
- **位置：** `MainWindowView.swift` 第 583 行
- **常量：** `resizablePaneMinWidth = CGFloat(260)`
- **应用：** twoH 和 four 布局中的可拖拽分栏通过 `resizablePaneItem` 包装，最小宽度限制为 260

#### 3.3 侧边栏（Sidebar）宽度
- **位置：** `MainWindowView.swift` 第 183 行
- **设置页默认宽度来源：** `workspace.settings.sidebarDefaultWidth`（可配置，范围 0-280）
- **硬上限：** `maxWidth: 280`
- **启动初始宽度桥接：** 通过 `SidebarInitialWidthBridge`（第 771-908 行）实现

#### 3.4 设置窗口尺寸
- **位置：** `SettingsView.swift` 第 129 行
- **固定尺寸：** `width: 460, height: 620`

---

### 4. 侧边栏初始宽度与分栏控制（AppKit 桥接）

**文件：** `MainWindowView.swift` 第 763-908 行

这是窗口内部尺寸控制最核心的 AppKit 桥接代码，包含三个关键类型：

#### 4.1 `SidebarInitialWidthBridge`（NSViewRepresentable）
- 挂在 SwiftUI `HSplitView` 内部的零尺寸 NSView
- 等视图真正接入 AppKit 层级后，向上找到宿主 `NSSplitView`
- **只在窗口首次出现时调用一次** `setPosition(_:ofDividerAt:)` 设置左侧栏默认宽度
- 后续保留用户原生拖拽行为，不再强制覆盖

#### 4.2 `SidebarSplitController`（@MainActor ObservableObject）
```
关键功能：
├─ isCollapsed          当前侧边栏是否收起
├─ lastExpandedWidth    用户上次展开时的非零宽度
├─ attach()             绑定 NSSplitView 并监听 didResizeSubviewsNotification
├─ toggleSidebar()      点击工具栏按钮收起/展开（展开时恢复上次宽度或默认宽度）
└─ apply(width:)        直接设置分割线位置（范围 0-280）
```

#### 4.3 `SidebarInitialWidthNSView`（NSView 子类）
- 在 `viewDidMoveToWindow` 和 `viewDidMoveToSuperview` 时尝试应用初始宽度
- 通过 `enclosingSplitView()` 向上遍历父视图链找到 `NSSplitView`
- 找到后只执行一次，然后置位 `hasApplied = true`

---

### 5. 窗口关闭时的持久化流程

#### 5.1 应用终止通知链
**文件：** `mqdirApp.swift` 第 26-32 行
- 监听系统 `NSApplication.willTerminateNotification`
- 转发为内部通知 `.mqdirAppWillTerminate`

**文件：** `MainWindowView.swift` 第 1130-1134 行（GlobalNotifications）
- 接收 `.mqdirAppWillTerminate` 后调用 `saveSynchronously()`

#### 5.2 同步保存方法
**文件：** `MainWindowView.swift` 第 254-260 行
```swift
@MainActor
private func saveSynchronously() {
    let state = snapshot()                             // 采集当前窗口状态
    workspace.updateActive { $0.state = state }       // 更新活动项目
    workspace.setFavorites(sidebar.favorites)         // 保存收藏夹
    workspace.saveSynchronously()                     // 直接写磁盘（跳过 debounce）
}
```

#### 5.3 平时的防抖保存
**文件：** `MainWindowView.swift` 第 237-250 行（`scheduleSave`）
- 每个 pane VM 的 `objectWillChange`、layout、focusedPaneIndex、sidebar 变化都会触发
- 通过 `lastScheduledState` 做值相等比较，避免无变化的重复保存
- WorkspaceManager 内部有 500ms debounce（`WorkspaceManager.swift` 第 229-234 行）

---

### 6. 持久化状态结构（窗口内容的重新打开依据）

**文件：** `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mqdirCore/PersistenceService.swift`

#### 6.1 WindowState（第 215-268 行）—— 每个项目的窗口状态
```swift
struct WindowState {
    var layout: PaneLayout           // 单栏/双栏水平/双栏垂直/四栏
    var focusedPaneIndex: Int        // 当前聚焦的 pane 索引（0-3）
    var panes: [PaneState]           // 固定 4 个 pane，布局缩小时保留离屏 pane 状态
}
```

#### 6.2 PaneState（第 129-167 行）—— 每个分栏的状态
```swift
struct PaneState {
    var tabs: [TabState]             // 标签列表
    var activeTabIndex: Int          // 当前活动标签索引
}
```

#### 6.3 TabState（第 53-124 行）—— 每个标签的状态
```swift
struct TabState {
    var folderBookmark: Data?        // 当前文件夹（安全范围书签）
    var sortKey / sortAscending      // 排序方式
    var includeHidden                // 是否显示隐藏文件
    var columnWidths: PaneColumnWidths
    var selectedURLPaths: [String]   // 选中项路径
    var viewMode: PaneViewMode       // 列表视图/树视图
    var expandedPaths: [String]      // 树视图展开路径
    var previewVisible: Bool         // 预览面板是否打开
    var foldersOnTop: Bool           // 文件夹是否置顶
}
```

#### 6.4 WorkspaceState（第 426-527 行）—— 全局持久化结构
```swift
struct WorkspaceState {
    var favorites: [Favorite]           // 跨项目侧边栏收藏
    var favoritesSeeded: Bool           // 是否已注入初始 6 个 Home 子目录
    var activeProjectID: UUID           // 当前活动项目（决定 MainWindowView 的重建）
    var projects: [Project]             // 项目列表（每个项目携带自己的 WindowState）
    var settings: WorkspaceSettings     // 全局设置（颜色/语言/侧边栏默认宽度/快捷键）
}
```

#### 6.5 Project（第 274-284 行）
```swift
struct Project {
    var id: UUID
    var name: String
    var state: WindowState              // 项目独立的窗口布局快照
}
```

**说明：** 项目切换时，MainWindowView 通过 `.id(activeProjectID)` 触发 SwiftUI 销毁旧视图、创建新视图，从而加载新项目的 `WindowState` 完成"重新打开"。

---

### 7. 关闭与重新打开（Tab 级）

**文件：** `MenuCommands.swift` + `AppNotifications.swift`

#### 7.1 菜单命令定义（AppCommand enum）
- `.closeTab` —— 关闭活动标签（快捷键 ⌘W）
- `.reopenClosedTab` —— 重新打开已关闭标签（快捷键 ⌘⇧T）
- `.newTab` —— 新建标签（快捷键 ⌘T）

#### 7.2 TabNotifications（MainWindowView.swift 第 1084-1114 行）
```swift
case .closeTab:         focusedPaneVM.closeActive()
case .reopenClosedTab:  focusedPaneVM.reopenClosed()
case .newTab:           focusedPaneVM.newTab()
case .nextTab:          focusedPaneVM.nextTab()
case .previousTab:      focusedPaneVM.prevTab()
case .selectTab(index): focusedPaneVM.selectTab(at: index)
case .openURLInNewTab:  focusedPaneVM.newTab(folderURL: url)
```

#### 7.3 新窗口（Window 级）
- **位置：** `MenuCommands.swift` 第 25 行
- **状态：** 目前是 stub（`stub("File → New Window")`），尚未实现真正的多窗口
- 注释写的是 "M0 stub"

---

### 8. 持久化文件读写（PersistenceService）

**文件：** `PersistenceService.swift`

#### 8.1 文件位置
- 生产环境：`~/Library/Application Support/com.mqdir.app/state.json`
- 文件权限：写完后收紧为 `0o600`（仅所有者可读可写），因为包含安全范围书签

#### 8.2 加载（`loadState`，第 584-593 行）
- 文件不存在 → 返回 `nil`（视为首次启动）
- JSON 解码失败 → 备份原文件为 `state.corrupt-<timestamp>.json`，然后返回 `nil`

#### 8.3 保存（`saveState`，第 632-650 行）
- 原子写入（`.atomic` 选项）
- JSON 格式：pretty-printed + sorted-keys

---

### 9. 相关文件总览表

| 绝对路径 | 关键职责 |
|----------|----------|
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/mqdirApp.swift` | WindowGroup 定义、最小尺寸、终止通知转发 |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppDelegate.swift` | 应用生命周期、安全可恢复状态声明（`true`） |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift` | 主窗口布局、侧边栏 NSSplitView 桥接、快照采集、终止时同步保存 |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/WorkspaceManager.swift` | 项目切换（触发窗口重建）、防抖保存、侧边栏默认宽度持久化 API |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mqdirCore/PersistenceService.swift` | WindowState/Project/TabState 等持久化结构、state.json 读写、损坏文件备份 |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/Menus/MenuCommands.swift` | 关闭/重开标签、新建标签、分栏聚焦等菜单命令（新窗口目前为 stub） |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppNotifications.swift` | AppCommand 枚举（含 closeTab/reopenClosedTab 等）、终止通知名定义 |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/SettingsView.swift` | 设置窗口固定尺寸、侧边栏默认宽度配置（Stepper） |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/PreviewPanel.swift` | 预览面板（内部分栏，非独立 NSWindow） |
| `/Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/ZipPreview.swift` | ZIP 预览（内部子面板，AppDelegate 启动时清理其遗留临时目录） |

---

### 总结

- **窗口大小：** 通过 SwiftUI `WindowGroup` 的 `.frame(minWidth:minHeight:)` 设置最小尺寸（900x600）；内部 pane 最小宽度 260、侧边栏最大 280 且启动默认宽度可在设置页中配置
- **窗口位置：** 当前代码中**没有显式持久化窗口的 frame/position**，依赖 macOS 原生 `NSWindow` 的自动 frame 保存（AppDelegate 声明了 `applicationSupportsSecureRestorableState = true`）
- **关闭：** 应用即将终止时，通过 `willTerminateNotification` → `.mqdirAppWillTerminate` → `saveSynchronously()` 完成磁盘落盘；平时通过 500ms debounce 防抖增量保存
- **重新打开：** 通过 `WorkspaceManager.loadState()` 恢复 `WindowState`（布局、pane、tabs、选中项），并在项目切换时通过 `.id` 触发 SwiftUI 视图重建加载对应项目状态。多窗口（New Window）功能目前是 stub，尚未实现真正的多 `NSWindow` 管理。

现在我已经充分了解了代码结构。让我分析一下问题原因并给出方案。

## 问题分析

当前窗口大小不被保留的根本原因：

1. **SwiftUI `WindowGroup` 的行为差异**：点击交通灯的「关闭」按钮（红色）时，执行的是**关闭窗口**操作（而非退出应用）。从 Dock 重新唤起时，SwiftUI 会创建一个新的窗口实例，而不会自动恢复之前的 frame。

2. **缺少窗口 frame 的持久化**：当前的 `WorkspaceSettings` [PersistenceService.swift:318-356](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mqdirCore/PersistenceService.swift#L318-L356) 中只保存了颜色、语言、侧边栏默认宽度、快捷键、韩文规范化等设置，**没有存储窗口的大小和位置（frame）**。

3. **原生机制未充分利用**：虽然 `AppDelegate` 声明了 `applicationSupportsSecureRestorableState = true`，但 SwiftUI 的 `WindowGroup` 没有自动为窗口设置 `frameAutosaveName`，也没有手动监听窗口尺寸变化进行保存。

---

## 可选方案（等待您确认后再修改代码）

### ✅ 方案 A：手动持久化窗口 frame（推荐，可控性最强）

**思路**：完全由我们自己控制窗口 frame 的读写，统一存入 `state.json`。

**修改点**：
1. **`PersistenceService.swift`**：在 `WorkspaceSettings` 中新增 `windowFrame: CGRect?` 字段（存储 origin 和 size）。
2. **`MainWindowView.swift`**：新增一个类似 `SidebarInitialWidthBridge` 的 AppKit 桥接组件（比如叫 `WindowFrameBridge`），负责：
   - 窗口首次出现时，如果 `settings.windowFrame` 有值，则调用 `NSWindow.setFrame(_:display:)` 应用。
   - 监听 `NSWindow.didResizeNotification` 和 `NSWindow.didMoveNotification`，实时更新 `workspace.settings.windowFrame`（带防抖，避免频繁写入）。
   - 监听 `NSWindow.willCloseNotification`，关闭前最后保存一次（防止用户拖拽后立即关闭，防抖还没触发就关了）。
3. **最小尺寸保护**：恢复 frame 时校验宽高不低于 900×600（与 [mqdirApp.swift:65](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/mqdirApp.swift#L65) 的 `minWidth/minHeight` 一致）。
4. **屏幕可见性保护**：恢复时检查 frame 是否还在当前任一屏幕的可见区域内（比如用户之前接了外接显示器，现在拔掉了），如果不在则回退到系统默认位置。

**优点**：
- 与项目其他状态（侧边栏宽度、布局等）统一持久化在 `state.json`，数据自洽。
- 完全可控，能处理边缘情况（外接显示器拔出、尺寸过小等）。
- 未来支持多窗口时可以扩展为按窗口 ID 分别保存。

---

### 方案 B：使用 `NSWindow.setFrameAutosaveName` 系统机制

**思路**：通过 AppKit 桥接拿到 `NSWindow` 实例，调用 `window.setFrameAutosaveName("MQDirMainWindow")`，让 macOS 自动在 `UserDefaults` 中保存和恢复 frame。

**修改点**：
1. **`MainWindowView.swift`**：新增轻量桥接，在 `viewDidMoveToWindow` 时设置 `frameAutosaveName`。
2. 代码量极少，几乎只有几行。

**缺点**：
- 数据存在 `UserDefaults`（键名类似 `NSWindow Frame MQDirMainWindow`），与我们的 `state.json` 分离，备份/迁移时可能漏掉。
- 没有屏幕可见性、最小尺寸等兜底校验（系统自己处理，但行为不如手动可控）。
- 多窗口时扩展性一般。

---

### 方案 C：组合方案（A 为主，B 兜底）

在实现方案 A 的同时，也调用 `setFrameAutosaveName` 作为兜底。万一 `state.json` 损坏或首次从旧版本升级，系统机制还能顶上。

---

## 我的建议

推荐 **方案 A**。理由：
- 与你们现有的「侧边栏默认宽度手动持久化、分栏宽度手动桥接」的架构风格一致。
- 数据统一存 `state.json`，备份/迁移时不会散落在 `UserDefaults`。
- 可以优雅地处理「外接显示器拔出后窗口不在屏幕上」的边缘情况。

---

请确认使用哪个方案（A / B / C），确认后我再动手改代码。如果选择方案 A，我还会在恢复时加上屏幕可见性和最小尺寸的保护逻辑。

---

**User**

一般钉钉微信这种点击关闭用的是哪个方案

**Assistant**

这是个很好的问题！我来对比分析一下钉钉、微信这类应用的实际做法，以及对你的 mq-dir 文件管理器的借鉴意义。

---

## 钉钉、微信（macOS 版）的真实行为

### 1. 「点击关闭按钮」到底做了什么？

**钉钉、微信、QQ、飞书**这类 IM 应用，点击红色交通灯后：
- ❌ **不是真正关闭窗口**（窗口实例没有销毁）
- ✅ **只是隐藏窗口**（`orderOut:` 或 `isHidden = true`）
- 窗口对象还在内存里，frame 位置、大小、甚至聊天滚动位置**原封不动保留**

然后你从 Dock 点图标重新打开时：
- 只是把同一个窗口 `makeKeyAndOrderFront(nil)` 再显示出来
- 所以大小、位置**看起来是"保留"了**，其实是因为窗口压根就没销毁

这是 macOS 上**常驻后台类应用**（IM、音乐播放器、菜单条应用）的标准模式。而 Finder、Safari、Xcode 这类「工具/内容类应用」点击关闭才是真正关闭窗口。

---

### 2. 那它们用了哪种持久化方案？

答案是 **B（系统 autosave）为主 + A（自建持久化）为辅** 的组合：

| 组件 | 实现方式 |
|------|----------|
| **窗口大小/位置** | 用系统原生 `NSWindow.setFrameAutosaveName("WeChatMainWindow")`，系统自动存 UserDefaults |
| **安全可恢复状态** | 启用 `applicationSupportsSecureRestorableState`（你已经开了） |
| **其他状态（聊天记录、当前会话）** | 存在自己的数据库里（不依赖 frame autosave） |
| **关闭行为覆盖** | 重写 `windowShouldClose(_:)` 返回 `false`，改为隐藏窗口 |

它们的 `UserDefaults` 里会有类似这样的键：
```
"NSWindow Frame WeChatMainWindow" = "400 200 1200 800 0 0 2560 1415"
```
这就是 macOS 原生 frame 持久化格式。

---

## 对你的 mq-dir 的建议

mq-dir 是**文件管理器**，属于「工具/内容类应用」，行为应该对齐 **Finder**，而不是微信：

| 需求 | 建议 |
|------|------|
| 点击关闭（红圈） | **真正关闭窗口**（和 Finder 一致），不建议隐藏 |
| 从 Dock 重新唤起 | **恢复上次的大小和位置**（这就是你现在要做的） |
| 持久化方案 | 用**组合方案 C**（A + B 双重保险） |

---

## 方案 C 具体设计（A + B 组合）

```
启动/窗口重建时：
  ├─ 优先级 1：先读 state.json 的 windowFrame（自己存的）
  │    └─ 校验：宽 ≥ 900 / 高 ≥ 600 / 且在屏幕上 → 应用
  │    └─ 不满足 → 回退优先级 2
  ├─ 优先级 2：读系统 NSWindow Frame UserDefaults
  │    └─ 有值且合法 → 应用
  └─ 优先级 3：都没有 → 系统默认位置

窗口尺寸变化时（拖拽结束/移动结束）：
  ├─ 同时写入：
  │   ├─ state.json.windowFrame（方案 A，防抖 300ms）
  │   └─ 靠系统 autosave 自动存 UserDefaults（方案 B，免费拿）
  └─ 窗口 willClose 时立即写 state.json（防止防抖没触发）
```

**为什么这样组合最好：**
- 🔒 **state.json 是 Single Source of Truth**：备份、迁移、换电脑时，只要拷 `state.json` 就能带走所有状态（包括窗口大小）
- 🛟 **系统 autosave 做兜底**：万一 state.json 损坏，或者用户从旧版本升级，系统那一份还能顶上
- 🚀 恢复顺序：先信自己存的，再信系统的，体验最一致

---

如果你确认要用**方案 C**，我就开始动手改代码。

另外补充一个可选项：要不要也像微信那样，**让点击红圈只是隐藏窗口而不关闭**？这样从 Dock 唤起体验会更"秒开"，但行为就和 Finder 不一致了。你是文件管理器，我建议还是保持 Finder 风格（真关闭 + 恢复大小），但最终由你决定。

---

