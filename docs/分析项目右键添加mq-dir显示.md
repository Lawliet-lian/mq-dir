# 分析项目右键添加mq-dir显示

> **Workspace:** /Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir

---

**User**

分析一下这个项目,如果要在右键中添加一个在mq-dir中显示方便吗

**Assistant**

我来分析一下这个项目的结构，看看在 Finder 右键菜单中添加"在 mq-dir 中显示"功能的可行性。

好的，我已经完成了对项目的分析。下面给出详细的**可行性评估和实施方案**，暂时不动代码，等你确认后再改。

---

## 📊 项目现状评估

### 1. 现有基础条件（对集成很有利）

项目已经具备了**外部调用所需的内部导航能力**，只缺把外部请求接进来的入口：

| 已有能力 | 位置 | 说明 |
|---------|------|------|
| 外部 URL 接收占位 | [AppDelegate.swift#L13-L15](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppDelegate.swift#L13-L15) | `application(_:open:)` 方法已声明，但注释写的是 M0 留空、M1 再实现 |
| 文件夹导航核心 | [FolderBrowserViewModel.openFolder](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/FolderBrowserViewModel.swift#L603-L609) | 完整的目录切换逻辑（含后退栈、沙盒书签） |
| 新标签页打开命令 | [AppCommand.openURLInNewTab](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppNotifications.swift#L65) | 已有的跨组件通知机制，可直接复用 |
| 构建配置 | [project.yml](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/project.yml) | XcodeGen 管理，改配置很方便 |

**当前缺少的**：
- ❌ 没有注册 URL Scheme（Info.plist 里无 `CFBundleURLTypes`）
- ❌ 没有注册系统 Services（无 `NSServices` 配置）
- ❌ `application(_:open:)` 是空实现

---

## 🎯 三种 Finder 右键集成方案对比

### 方案 A：Finder Sync Extension（⭐️ 最完美体验）

**效果**：右键菜单**直接出现在 Finder 顶层**，和「在访达中打开」平级，体验最接近原生。

**实现复杂度**：高
- 需要新增一个 **App Extension Target**（FinderSync 类型），改 `project.yml` 加 target
- 扩展和主 App 之间需要 **App Group** 通信（或通过 Mach port / XPC）
- 沙盒环境下文件权限的传递需要处理 security-scoped bookmark
- 需要额外的 code sign 配置（扩展有自己的 bundle ID）

**工作量预估**：约 3-5 天（含调试权限和通信）

---

### 方案 B：NSServices 系统服务（⭐️⭐️ 推荐平衡方案）

**效果**：右键菜单 → **「服务」子菜单** 里出现「在 mq-dir 中显示」，位置稍深但完全原生，无需用户折腾。

**实现复杂度**：低
- **不需要新增 target**，只改主 App
- `Info.plist` 里加 `NSServices` 配置（声明接收文件/文件夹 URL）
- 实现 `NSApplicationDelegate` 的 Services 处理方法，或者用 `handleOpenURL`
- 系统级服务，安装 App 后自动生效

**工作量预估**：约 0.5-1 天

---

### 方案 C：URL Scheme + Automator 手动配置（⭐️⭐️⭐️ 最快见效）

**效果**：先实现 `mqdir://` URL Scheme，然后**用户可以**在 Automator/Shortcuts 中自行配置右键动作调用该 Scheme。

**实现复杂度**：极低
- 只注册 URL Scheme + 实现 `application(_:open:)`
- 用户侧需要手动在 Automator 创建 Quick Action（可以给用户写好 workflow 文件导入）

**工作量预估**：约 2-3 小时（主 App 侧）

---

## 📋 推荐的分步实施路线（按性价比排序）

### 第一步：实现 URL Scheme + open handler（基础中的基础，必做）
不管后面选哪个方案，这一步都需要做，而且做完立刻能用（Terminal 里 `open mqdir:///Users/xxx/Downloads` 就能跳）：

1. 在 `project.yml` 的 `info.properties` 中添加 `CFBundleURLTypes`，注册 `mqdir` scheme
2. 实现 [AppDelegate.application(_:open:)](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppDelegate.swift#L13-L15)：
   - 解析传入的 URL（支持 `mqdir://` 前缀，也支持直接传 `file://` URL）
   - 如果是文件：取父目录，post `AppCommand.openURLInNewTab(url: 父目录)` 并选中该文件
   - 如果是文件夹：直接 post `AppCommand.openURLInNewTab(url:)`
3. 如果主窗口未启动，需确保调用时会先激活 App（`NSApp.activate(ignoringOtherApps: true)`）

### 第二步（可选但推荐）：追加 NSServices 配置
在第一步基础上，加 NSServices 声明，用户立刻就能在右键「服务」里看到入口：

1. 在 Info.plist 添加 `NSServices` 数组，Service 接收 `public.file-url` 类型
2. Service 的入口可以复用第一步的 URL 处理逻辑，或者直接接 `application(_:openFile:)`

### 第三步（可选，追求完美时做）：Finder Sync Extension
如果「服务」子菜单的位置你觉得太深，再做这个方案。

---

## ⚠️ 几个需要确认的产品决策

1. **打开策略**：右键选中的路径应该：
   - 🅰️ 在当前**聚焦窗格**的当前标签页直接跳转（替换当前目录）
   - 🅱️ 在当前聚焦窗格的**新标签页**打开（保留原标签）— 我个人更推荐这个，符合 Cmd-click 新建标签页的现有习惯
   - 🅲️ 总是新建一个窗口（Project）打开

2. **选中文件时的行为**：
   - 右键点文件「在 mq-dir 中显示」：打开**父目录**，并且**选中该文件**（需要扩展 AppCommand 传 selectionPaths）
   - 右键点文件夹：直接打开该文件夹

3. **多文件选中时**：
   - 打开公共父目录，选中所有传入文件
   - 还是每个文件各开一个标签页（不推荐，太乱）

---

你觉得以上分析如何？选哪个方案，以及打开策略倾向哪种，告诉我后我就开始动手改代码。

---

**User**

现在点击顶部是弹出一个选择框,我想点击顶部能直接输入地址进行访问,类似与windows资源管理器那种,然后这个弹框用单独一个按钮来触发,你分析一下实现可能性

**Assistant**

好的，我来分析一下当前顶部地址栏的实现，以及把它改成 Windows 资源管理器那种「点击直接编辑 + 单独按钮弹出选择框」模式的可行性。

好的，我已经完整分析了当前代码。下面给出详细的**可行性分析和改造方案**，暂时不动代码，等你确认后再实施。

---

## 📍 现状梳理

### 当前地址栏实现

顶部面包屑在 [MainWindowView.breadcrumb](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L307-L346)，关键逻辑：

| 交互点 | 位置 | 行为 |
|-------|------|------|
| 渲染内容 | [L309-L332](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L309-L332) | 展示 `url.pathComponents` 的分段文本（chevron 分隔） |
| 点击整行 | [L344](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L344) | `.onTapGesture { focusedPane.chooseFolder() }` → **弹出 NSOpenPanel 选择框**（就是你截图里那个大弹框） |
| 复制路径按钮 | [L334](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L334) + [L354-L368](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L354-L368) | 尾部 `doc.on.doc` 图标，复制当前路径到剪贴板 |
| 右键菜单 | [L345](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L345) + [L370-L389](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L370-L389) | 含复制路径 / 在终端/cmux/访达打开 / 「打开文件夹…」(也是弹 NSOpenPanel) |

### 关键结论：**改造完全可行，复杂度中低**

项目里已经有：
- ✅ `FolderBrowserViewModel.openFolder(_:)` — 用 URL 切换目录（含沙盒书签、后退栈）
- ✅ `FolderBrowserViewModel.folderURL` — 可读当前目录
- ✅ SwiftUI 搜索框已有成熟的「点击→激活 TextField→按 Esc 退出」交互模式（见 [searchField](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L391-L470)），可以直接复用这套模式

---

## 🎯 改造方案（Windows 资源管理器风格）

### 一、新的交互形态

```
[工具栏区域]
  ← → ↑ ↺  [ 📂 Users/lawliet/Downloads 📋 ] 🔍  [布局切换...]
           ↑ 这里现在是"可切换双态"
              ├─ 静态态（默认显示）：面包屑路径（原样保留分段文本样式）
              ├─ 点击静态态 → 切换成可编辑 TextField，内容是 POSIX 全路径
              │     ├─ 按 Enter：校验路径有效 → openFolder() → 自动切回静态态
              │     ├─ 按 Esc：取消编辑，切回静态态
              │     └─ 失焦（点别处）：取消编辑，切回静态态
              └─ 📋 复制按钮保留（静态态显示）；编辑态可改为 × 清空
              
  新增一个独立的"浏览…"按钮，放在复制按钮左边（或者工具栏其他位置）：
     图标建议：folder.badge.plus 或 square.stack.3d.down.right
     点击 → 调用 chooseFolder() 弹 NSOpenPanel（就是现在点击面包屑的那个行为）
```

### 二、具体改动点（涉及 2 个文件）

#### 1. MainWindowView.swift — 主要改动

**新增状态变量（@State）**：
```swift
@State private var breadcrumbEditing: Bool = false      // 是否处于编辑态
@State private var breadcrumbDraft: String = ""         // 编辑中的路径草稿
@FocusState private var breadcrumbFocused: Bool         // 编辑框焦点控制
```

**改造 `breadcrumb` 计算属性**，分成两种显示模式：

- **静态态（breadcrumbEditing == false）**：
  - 保留现有的分段面包屑 Text + chevron（几乎原封不动）
  - 复制按钮 `breadcrumbCopyButton` 留在右侧
  - **新增一个"浏览…"按钮**（SF Symbol：`square.stack.3d.down.right` 或 `folder.badge.plus`），也放在右侧（复制按钮的左邻），点击触发 `focusedPane.chooseFolder()`
  - **整行 onTapGesture 改为**：`breadcrumbEditing = true; breadcrumbDraft = focusedPane.folderURL?.path ?? ""; DispatchQueue.main.async { breadcrumbFocused = true }`

- **编辑态（breadcrumbEditing == true）**：
  - 替换为一个 `TextField`，placeholder 用「输入路径，按 Enter 前往」
  - 绑定到 `breadcrumbDraft`
  - `.focused($breadcrumbFocused)`
  - 右侧按钮改为：一个 `×`（`xmark.circle.fill`）清空按钮（或者"取消"按钮）
  - **onKeyPress(.return)**：提交路径
  - **onKeyPress(.escape)**：取消编辑
  - **onChange(of: breadcrumbFocused)**：如果 `!focused` 则切回静态态

**新增提交路径的函数** `commitBreadcrumbDraft()`：
```swift
private func commitBreadcrumbDraft() {
    let raw = breadcrumbDraft
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    
    var isDir: ObjCBool = false
    guard !raw.isEmpty,
          FileManager.default.fileExists(atPath: raw, isDirectory: &isDir),
          isDir.boolValue else {
        // 路径不存在或不是文件夹：做什么？建议下面决策 ①
        breadcrumbFocused = false
        return
    }
    let url = URL(fileURLWithPath: raw)
    focusedPane.openFolder(url)
    breadcrumbEditing = false
}
```

**复制 / 浏览两个按钮的视觉合并**：浏览按钮 + 复制按钮可以放在 pill 的尾部，用 `Divider().frame(width:0.5, height: 12)` 视觉分隔，整体高度和当前复制按钮（18×18）一致。

#### 2. FolderBrowserViewModel.swift — 可选增强

可加一个小方法封装路径校验，避免主视图里出现太多 FileManager 逻辑（可选，非必须）：
```swift
/// 校验给定 POSIX 路径是否为可打开的存在目录；返回规范化的 URL 或 nil
func validateDirectoryPath(_ raw: String) -> URL? { ... }
```

### 三、几个需要确认的产品决策 ⚠️

| # | 决策点 | 选项 | 我推荐 |
|---|-------|------|--------|
| ① | 输入了**无效路径**（不存在 / 不是文件夹 / 无权限）按 Enter 后 | 🅰️ 弹一个小 toast 提示错误，继续保持编辑态<br>🅱️ 弹 `NSAlert` 模态报错<br>🅲 静默取消，切回静态态（无反馈，体验差） | **🅰️** 做个轻量 toast（你截图里 app 里好像还没 toast，也可以用右下角 Status Bar 临时显示红色错误文案 2 秒后消失） |
| ② | 输入路径是**文件**（不是文件夹）时 | 🅰️ 取其父目录打开，并**选中该文件**（更符合直觉，需扩展 openFolder 传 selectionPaths）<br>🅱️ 拒绝（报错"请输入文件夹路径"） | **🅰️** |
| ③ | `~` 波浪号展开 | 🅰️ 自动展开为用户 home（`NSHomeDirectory()`）<br>🅱️ 不支持 | **🅰️**，顺手支持 `~/Downloads` 这种输入 |
| ④ | "浏览…"按钮图标位置 | 🅰️ 放在面包屑 pill 内部右侧，复制按钮左边<br>🅱️ 放在工具栏外面（面包屑右边、搜索框左边），作为独立 ToolbarIconButton | **🅰️**，更紧凑，与现有复制按钮视觉统一 |
| ⑤ | 静态态面包屑的路径分段点击 | 🅰️ 保留，点中间段跳转那个祖先目录（Windows 资源管理器也是点段跳转）<br>🅱️ 整行任何位置都是"进入编辑态" | **🅰️**，现在的面包屑其实没做分段点击，可以顺便加上，体验更像 Finder |
| ⑥ | 快捷键习惯 | 🅰️ 保留现有的 `⌘O → 弹 NSOpenPanel`（File → Open Folder）<br>🅱️ 额外加一个 `⌘L`（Finder / VSCode 常用）→ 直接把焦点送进地址栏编辑态 | **都要**，⌘L 是几乎所有文件管理器和浏览器的默认地址栏快捷键，值得加 |

---

## 📋 工作量评估

| 部分 | 预估耗时 |
|------|---------|
| 地址栏双态 UI 改造（静态/编辑切换） | 2-3 小时 |
| 路径校验 + 提交逻辑（含 ~ 展开、文件选父） | 1 小时 |
| 新增浏览按钮 + 图标 + Help 文案 | 0.5 小时 |
| ⌘L 快捷键绑定到 MenuCommands | 0.5 小时 |
| 错误提示（toast 或状态栏临时错误） | 1-2 小时（看要不要做 toast 组件） |
| 分段点击跳转祖先目录（决策 ⑤） | 1 小时 |

**总工作量**：约 6-9 小时（不含测试、不含可能的 toast 组件从零搭建）

---

## 🚀 风险点与注意事项

1. **沙盒权限**：如果用户手工输入的路径在沙盒「默认可读」之外（如 Volumes 上的外挂盘），即使 fileExists 返回 true，`openFolder()` 里也可能因为没有权限而枚举失败。这时候需要走 `NSOpenPanel` 获取授权书签——但**既然我们保留了浏览按钮**，用户可以回退到那个方式；编辑态遇到权限错误就按决策 ① 提示即可。
2. **面包屑与 TextField 的高度对齐**：现有的面包屑是 minHeight 22，编辑态的 TextField 也要精准维持 22，否则切换时会"跳一下"——搜一下 [searchField](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L391-L470) 里的实现方式，照着用 `.textFieldStyle(.plain)` + 相同的 padding/frame 就行。
3. **focusedPane 切换时编辑态的处理**：用户在四栏布局下切聚焦窗格时，地址栏草稿应该重置（因为 `folderURL` 变了），建议加个 `.onChange(of: focusedPaneIndex)` 在切换窗格时把 `breadcrumbEditing = false`。

---

你觉得这套方案怎么样？确认后（尤其那 6 个产品决策告诉我选哪个），我就开始动手改代码。

---

**User**

现在这个app能根据路径直接打开地址吗

**Assistant**

**结论：内部已有跳转能力，但对外（用户可用的入口）目前还没打通。**

---

## ✅ 代码内部：可以按路径跳转（已有 API）

项目核心层已经实现了完整的按路径导航逻辑，你可以直接看这几个地方：

| 能力 | 位置 | 说明 |
|-----|------|------|
| 按 URL 切换目录（核心方法） | [FolderBrowserViewModel.openFolder](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/FolderBrowserViewModel.swift#L603-L609) | 入参就是 `URL`，内部会处理沙盒书签、后退栈。传任意存在的目录 URL 都能跳 |
| 跨组件通知跳转（新建标签页） | [AppCommand.openURLInNewTab](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppNotifications.swift#L65) + [MainWindowView 接收处理](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L1107) | 已经做了完整的通知机制，post 这个命令就能在聚焦窗格开新标签跳过去 |

换句话说，如果是在 App 内部（比如加个可编辑地址栏、或者外部 URL handler 里），只要拿到了路径 → 转成 `URL(fileURLWithPath:)` → 调上面两个接口之一，就能直接跳转，**不需要再写新的导航内核代码**。

---

## ❌ 对外入口：目前无法通过路径直接打开

目前用户侧还**没有任何方式**能直接把路径塞给 mq-dir 跳转：

### 1. URL Scheme：未注册
[Info.plist](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/Info.plist) 里没有 `CFBundleURLTypes`，所以 `open mqdir:///Users/xxx/...` 这种命令**不生效**。

### 2. 命令行/外部 `open` 调用：Handler 是空的
[AppDelegate.application(_:open:)](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/AppDelegate.swift#L13-L15) 里写了注释 `// No-op in M0; M1 will route open requests to the focused pane.` — 就是 M0 阶段**留了占位但没实现**。所以即使 Finder 右键"打开方式→mq-dir"选一个文件夹传进来，目前也是**什么都不会发生**。

### 3. 可编辑地址栏（UI）：目前没有
当前面包屑点击是直接弹 `NSOpenPanel`（见 [MainWindowView.L344](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/MainWindowView.swift#L344) 的 `.onTapGesture { focusedPane.chooseFolder() }`），没有进入编辑态的入口，所以也无法粘贴路径回车跳转。

### 4. NSServices / Finder 右键扩展：也都没注册
目前没有任何系统级服务声明。

---

## 📌 如果你想快速验证"按路径跳转"这个能力

因为内部 API 是好的，你可以用**临时的调试手段**先验证（比如在 `AppDelegate` 里随便绑个临时快捷键读剪贴板路径跳），或者等我们把上一条讨论的「可编辑地址栏 + URL Scheme」都做完，就有完整的用户入口了。

要不要我现在就把「打通外部 open 调用 + URL Scheme」这一小步先做了（只实现 `application(_:open:)` + 注册 `CFBundleURLTypes`，暂时先不做地址栏 UI）？这样你至少可以先在 Terminal 里 `open -a mq-dir /Users/xxx/Downloads` 试一下跳转对不对。

---

**User**

那如果我把访达拖到app 4格窗口的某一个窗口上,该窗口直接打开对应位置,然后访达关闭,看起来效果就像是访达拖进了某一个窗口中,这个能实现吗?

**Assistant**

好问题，我来分析一下 Finder 拖放到指定窗格这个交互的可行性。先看看项目现有的拖放机制。

好的，完整分析完成。**结论是：这个交互完全可以实现，而且大部分基础设施已经写好了，缺的只有「识别拖入的是文件夹 → 跳转」的分支判断，以及最后一步「关 Finder」的 AppleScript 调用。**

---

## 📊 现有拖放能力盘点

项目里已经有非常完整的拖放体系，可以直接复用：

| 模块 | 位置 | 作用 |
|-----|------|------|
| 拖放类型定义 & URL 解析 | [DragDropSupport.swift](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/DragDropSupport.swift) | 统一处理 `public.file-url`，已能正确解析 Finder 拖进来的文件 URL |
| 窗格背景接收拖放 | [BrowserPaneView.L1291-L1307](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/BrowserPaneView.swift#L1291-L1307) | **每个窗格独立注册**了 `.onDrop`，拖到哪一格就由哪一格的 `viewModel.acceptDrop` 处理——**按窗格识别目标这件事已经做好了** |
| 当前拖放处理逻辑 | [FolderBrowserViewModel.acceptDrop](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/FolderBrowserViewModel.swift#L1679-L1696) | 目前固定是**移动/复制文件到当前文件夹**（用 `FileOperationService.transfer`） |
| 按行拖放（放到子文件夹上） | [BrowserPaneView.L1488](file:///Users/lawliet/Documents/WorkSpace/Lawliet-lian/mq-dir/Sources/mq-dir/BrowserPaneView.swift#L1488) | 也已经实现 |

**关键点**：窗格级别的拖放目标识别是现成的——你拖到 4 格中的哪一个，就会落到那格自己的 `onDrop` closure 里。所以"拖到哪个窗口就打开在哪个窗口"这个需求**原生就满足，不需要额外写命中测试逻辑。**

---

## ✅ 改造方案（核心只需加一个分支判断）

### 改造点 1：`BrowserPaneView.L1291` 的 `.onDrop` 里先判断拖入的 URL 性质

当前代码在 `L1295-L1306` 是无条件调 `acceptDrop(... into: folder ...)` 做移动/复制。我们需要在这之前做分支：

```swift
// 伪代码示意
let urls = await DragDropSupport.resolveURLs(from: providers)

// --- 新增分支：拖入的是【单个文件夹】且用户没按 Option（不强制复制）
if urls.count == 1,
   let singleURL = urls.first,
   singleURL.hasDirectoryPath,   // 是文件夹
   !modifiers.contains(.option)  // 没按 Option，不做强制复制
{
    // CASE A: 把整个 Finder 窗口"搬进来"
    //   → 在这个窗格（被 drop 的这一格）直接跳转到该文件夹
    //   → 可选：自动关闭源 Finder 窗口
    Task { @MainActor in
        viewModel.openFolder(singleURL)
        // 可选：执行关闭 Finder 窗口的 AppleScript（见改造点 2）
    }
    return true
}

// --- 原有分支：文件 / 多文件 / 按了 Option → 执行移动或复制（保持现状）
viewModel.acceptDrop(
    urls,
    into: folder,
    copy: modifiers.contains(.option),
    normalizeHangul: normalizeHangulOnDragOut
)
```

**这里有一个产品决策点 ⚠️ ①：拖入文件夹时的默认行为**

| 选项 | 行为（没按 Option 时） | 按 Option 时 |
|-----|---------------------|------------|
| 🅰️ 推荐 | 单文件夹拖入 → **跳转**（就像你描述的效果）<br>多文件/文件拖入 → **移动** | 强制 **复制/移动**（保留旧行为） |
| 🅱️ 保守 | 所有拖入都 → **移动** | 无 |
| 🅲️ 更激进 | 拖入文件夹 → **跳转**（不管单还是多，多个就逐一开新标签） | 强制复制 |

我推荐 **🅰️**：只有「单拖一个文件夹」的情况才触发跳转，因为这最符合你描述的"把 Finder 窗口拖进来"的语义。拖多个文件夹还是按移动处理，比较不容易误操作。

---

### 改造点 2：关闭源 Finder 窗口（可选但推荐）

这一步是整个需求里**唯一有一点系统层面限制**的部分。

#### 技术上怎么做？用 AppleScript 调用 Finder

macOS 没有"拖放完成后自动关闭源窗口"的原生回调，但我们可以用 AppleScript 让 Finder 执行「关闭当前正在显示 X 路径的那个标签页/窗口」的操作。

几种实现方式对比：

| 方案 | 原理 | 效果 | 问题 |
|-----|------|------|------|
| 🅰️ AppleScript `close window 1 of application "Finder"` | 关 Finder 最前面的窗口 | 如果用户操作顺序正确（先在 Finder 开这个文件夹 → 直接拖过来），一般是对的 | **如果用户有多个 Finder 窗口堆叠**，可能关错；或者拖完用户已经点了别的 Finder 窗就关错 |
| 🅱️ AppleScript 按目标路径定位窗口然后关 | 枚举 Finder 的每个 window，拿到它的 `target` 属性，如果等于我们拖入的路径，就关掉那个窗口 | **精准关窗**，不影响其他 Finder 窗口 | 枚举有一点点开销（毫秒级），但对于一次拖放可以忽略 |
| 🅲️ AppleScript 关 Finder 标签页（更精细） | Finder 支持一个窗口多个 Tab，用 `close tab X of window Y` | 标签页级别精准关 | 逻辑稍复杂，要区分窗口和 Tab |
| 🅳️ 不关 | 跳过 AppleScript，让用户自己关 | 最稳、无副作用 | 用户体验没那么爽 |

**我的推荐**：先上 **🅱️ 按路径匹配精准关窗**（简单、精准），如果用户觉得关得不够积极再升级到更激进的策略。

#### 权限与沙盒注意事项 ⚠️ ②

如果用 AppleScript 控制 Finder，需要在 `Info.plist` 里加一条 `NSAppleEventsUsageDescription`（"mq-dir 需要控制 Finder 以在拖拽后自动关闭源窗口"之类的文案），否则 macOS 会拦截。
另外在 **Sandboxed 构建**（你项目里有 Sandboxed 配置）下需要加 Apple Event 临时例外 entitlement，或者干脆只在非沙盒版启用这个自动关闭功能。

**AppleScript 示例**（按路径匹配关窗）：
```applescript
tell application "Finder"
    set targetPath to POSIX file "/Users/xxx/Downloads" as alias
    repeat with w in windows
        try
            if (target of w) is targetPath then
                close w
            end if
        end try
    end repeat
end tell
```

用 Swift 调用就是 `NSAppleScript(source: ...)?.executeAndReturnError(nil)`。

---

## ⚠️ 其他几个需要你拍板的产品决策

| # | 决策 | 选项 | 我推荐 |
|---|-----|------|--------|
| ②（上面提过） | 自动关闭 Finder 窗口的策略 | 🅰️ 关最前面的窗口（可能关错）<br>🅱️ 按路径精准关（推荐）<br>🅳️ 不关，只跳转 | **🅱️** |
| ③ | 拖入文件夹时是 **替换当前标签页** 还是 **开新标签页** | 🅰️ `openFolder()` 直接替换（用户如果在这个窗格里已经有重要目录，会被覆盖掉；但也可以用后退栈回去）<br>🅱️ `newTab()` 开新标签（不破坏原有浏览位置，更安全）<br>🅲️ 看有没有按 Cmd：按 Cmd 开新标签，否则替换 | **🅲️**，和 Finder / 本 App 已有的 ⌘-click 开新标签 的手势对齐 |
| ④ | 如果目标窗格是**空的**（还没打开任何文件夹） | 🅰️ 正常跳转（和现在 `openFolder` 行为一致，本来就支持空窗开） | **🅰️** 不用额外分支 |
| ⑤ | 拖入的是**单个文件**（不是文件夹） | 🅰️ 保持现状：**移动/复制** 进当前目录<br>🅱️ 跳转到该文件的**父目录**并**选中**它（但这和拖放"移入"的直觉冲突，容易误） | **🅰️**，别改文件拖放的现有行为 |

---

## 📋 工作量与风险

| 部分 | 工作量 |
|------|-------|
| 在 `BrowserPaneView.onDrop` 加判断分支 + 调用 `openFolder` | **30 分钟**（非常小，因为现有基础设施全好） |
| 决策 ③ 的 Cmd-修饰键判断（`NSEvent.modifierFlags.contains(.command)`） | 5 分钟 |
| Finder 精准关窗 AppleScript + Swift 封装 + Usage Description 文案 | 1 小时 |
| 沙盒 entitlement 适配（如需要） | 30 分钟 |
| 拖入文件夹时的**视觉提示**（高亮 + 光标显示"跳转"还是"复制"） | 0.5-1 小时（SwiftUI 的 `isTargeted` 已有 binding 可以用） |

**总计：约 3 小时左右可以全部做完并测通**，属于非常划算的交互升级。

---

### 为什么这事能这么省事？
因为你项目里：
1. 每个 Pane 的 `.onDrop` **已经是按窗格独立注册的**，命中测试天然正确
2. `DragDropSupport.resolveURLs` 已经能正确拿到 Finder 拖进来的 URL
3. `FolderBrowserViewModel.openFolder` 已经处理了沙盒书签 / 后退栈 / 重载所有细节
4. 你只需要加**一个 `if urls.count == 1 && hasDirectoryPath`** 的分支就能改变行为

**技术上完全没难点，核心就是一行判断。**

---

你确认一下几个决策点（① 拖入文件夹默认行为 / ② 关 Finder 策略 / ③ 新标签还是替换），定下来我就可以开始写代码了。

---

