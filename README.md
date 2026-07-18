# VimiumForMac

A system-wide Vimium-style hint overlay for macOS. Double-tap ⌘ to overlay letter hints on every clickable UI element — type the hint to click it, no mouse needed.

Works on **all apps**: native AppKit/SwiftUI apps, Electron apps (Claude, VS Code, Slack, QQ, Obsidian, …), Chromium-family browsers, and even apps with custom-rendered UIs that expose almost no accessibility metadata (WeChat).

**[中文说明](#vimiumformac-中文)** ↓ scroll down for the Chinese version.

---

## Features

- **Hint mode** — double-tap ⌘ to show yellow letter hints on every button, link, toggle, menu item, sidebar item, text field, etc. Type the hint to click.
- **Nav mode** — press `Tab` in hint mode to switch to keyboard navigation: `h/j/k/l` moves a blue cursor to the nearest element left/down/up/right; `Enter` clicks it; `d/u` scrolls.
- **Jump to input** — press `gi` in hint mode to focus the window's text input (the compose box in chat apps) and start typing immediately.
- **Backspace** to delete a typed character and widen the filter.
- **Escape** or mouse click anywhere to dismiss.
- **Menu-aware** — open a menu bar menu, then double-tap ⌘; the menu stays open and hints appear on the menu items.
- **Sub-window aware** — only scans the focused window (Settings panels, sheets, dialogs), not the whole app behind it.
- **Electron/Chromium-aware** — actively enables the accessibility tree in Electron and Chromium-based apps instead of relying on it happening to already be on, and understands unlabeled `<div>`-based UIs (see [How It Works](#how-it-works)).
- **Triple detection**: Accessibility API for native/web apps, a YOLO11m CoreML model for visual icon detection, and OCR text detection as a last resort for apps with no accessibility tree at all.
- **Blocked apps** — exclude specific apps from hint mode via the status bar menu.
- **Launch at Login** — one-click toggle in the status bar menu.

---

## Requirements

- macOS 13 Ventura or later
- Accessibility permission (prompted on first launch)
- Screen Recording permission (prompted on first launch — powers the visual/OCR detection fallback)

---

## Installation

1. Download the latest release or build from source (see below).
2. Move `VimHint.app` to `/Applications`.
3. Launch the app — a keyboard icon appears in the menu bar.
4. When prompted, grant **Accessibility** and **Screen Recording** permission in
   System Settings → Privacy & Security.
5. Optionally enable **Launch at Login** from the menu bar icon.

> Permissions are tied to the app's code signature. If you build from source with an unstable (ad-hoc) signature, macOS treats every rebuild as a new app and re-prompts for permissions each time — set a `DEVELOPMENT_TEAM` in the Xcode project to avoid this (see [Building from Source](#building-from-source)).

---

## Usage

| Action | Key |
|--------|-----|
| Activate hint mode | Double-tap ⌘ |
| Type a hint | `A` `S` `D` `F` `H` `J` `K` `L` |
| Delete last typed character | `Backspace` |
| Jump to text input | `g` `i` (while hints are visible) |
| Enter nav mode | `Tab` (while hints are visible) |
| Navigate in nav mode | `h` `j` `k` `l` |
| Click selected element (nav mode) | `Enter` or `Space` |
| Next element (nav mode) | `Tab` |
| Scroll down / up (nav mode) | `d` / `u` |
| Dismiss | `Esc` or mouse click |

Hints use only the home-row keys `ASDFHJKL` (`g` is reserved as the prefix for command sequences like `gi`). Short hints (1–2 chars) appear when there are few elements; longer hints are generated automatically for dense UIs.

---

## How It Works

### Element detection

Detection runs in layers, cheapest and most reliable first, escalating only when a window needs it.

**1. Accessibility API (AX)**
Traverses the focused window's accessibility tree to find interactive elements: buttons, links, checkboxes, text fields, menu items, sidebar rows, tabs, toggles, and more. A single batched IPC call per element (`AXUIElementCopyMultipleAttributeValues`) fetches role, children, position, size, and enabled state together, and subtrees fully outside the window are pruned during the walk — both keep scans fast even on deeply nested web UIs.

**2. Electron/Chromium tree enabling**
Chromium-based apps (Electron and its private forks, plus Chromium browsers) keep their accessibility tree disabled until an assistive client announces itself — without this, a scan only sees native window chrome (traffic-light buttons). `AXTreeEnabler` detects these apps (by bundled framework, or by the Chromium `Helper (Renderer).app` process layout for renamed forks like QQ's `QQNT.framework`) and proactively sets `AXManualAccessibility` / `AXEnhancedUserInterface` on launch and on every app switch, so the tree is already built by the time you invoke hint mode. It also recognizes UI built from unlabeled `<div>`s (common in Electron apps like Obsidian): generic roles carrying an `AXPress` action count as clickable.

**3. CoreML / YOLO11m**
Takes a screenshot of the current screen and runs the bundled `model.mlpackage` (YOLO11m, fine-tuned for UI icons) to detect clickable elements the AX tree misses. The confidence cutoff adapts to how well AX covered the window — a near-empty AX result accepts lower-confidence detections so vision can carry more of the coverage.

**4. OCR text fallback**
Some apps (WeChat's custom-rendered UI) expose essentially nothing to the accessibility API beyond the traffic-light buttons. When AX finds almost no elements, Vision's text recognizer (Chinese + English) detects text blocks on screen as a last-resort hint source — nearly everything clickable in such UIs is, or sits under, a piece of text.

Results from all layers are merged and deduplicated (IOU-based). AX elements trigger their accessible `AXPress` action on click, falling back to a synthetic mouse click only if that fails; ML/OCR-only elements always receive a synthetic click at their center.

### Hint generation

Hints are generated with a BFS prefix-free algorithm over 8 home-row keys. No hint is ever a prefix of another, so typing a character either narrows the filter or immediately triggers a click when the hint is complete.

### Key interception

A `CGEventTap` at `.headInsertEventTap` intercepts:
- `flagsChanged` — detects the double-tap ⌘ hotkey without stealing app focus
- `keyDown` — routes hint/nav key presses while the overlay is visible (keys pass through untouched while a scan is still pending, so nothing is swallowed before hints appear)
- `leftMouseDown` / `rightMouseDown` — dismisses hints on click

The overlay window uses `orderFrontRegardless()` (never `makeKeyAndOrderFront`) so VimHint never becomes the active app and menus remain open.

---

## Building from Source

Requirements: Xcode 15+, macOS 13 SDK, the CoreML model at `weights/icon_detect/model.mlpackage`.

```bash
git clone https://github.com/Forrestssq/VimiumForMac.git
cd VimiumForMac
open VimHint.xcodeproj
```

- Select the **VimHint** scheme and **My Mac** destination.
- Set `DEVELOPMENT_TEAM` in the project's build settings to your Apple Developer team so builds get a stable signature — otherwise macOS re-prompts for Accessibility/Screen Recording permission on every rebuild.
- Build & Run (`⌘R`), or build a Release archive and copy it to `/Applications` for day-to-day use (Xcode's debug build output is not suitable for `Launch at Login`).
- The app is **not sandboxed** (required for CGEventTap and cross-process Accessibility).

The CoreML model is compiled at runtime on first launch and cached in
`~/Library/Application Support/VimHint/Models/model.mlmodelc`.

### Debugging accessibility issues

The status bar menu has a **"Debug: Dump AX Tree of Frontmost App"** item — it writes the complete raw accessibility tree (every role, frame, and action, not just the ones VimHint hints) of whatever app is currently frontmost to `~/Desktop/VimHint-AXDump.txt`. Useful when a specific app under-detects and you want to see exactly what it exposes.

---

## Known Limitations

- **Custom-rendered UIs** (e.g. WeChat) expose no accessibility tree at all; detection falls back entirely to visual/OCR methods, which is slower (extra ~300–500 ms) and can miss icon-only controls with no text.
- **Electron/web apps** — even with the tree enabled, some elements may still be missed if the model or OCR doesn't recognize them; detection quality depends on how closely the UI resembles the model's training data.
- **Sandboxed apps** — some system apps restrict Accessibility access; hints may be incomplete.
- **Context menus** — right-click context menus can be navigated with hint mode, but the double-tap ⌘ hotkey may cause context menus to close on some apps before hints appear.
- **Launch at Login** — requires the app to run from `/Applications`, not from Xcode's build output.

---

## Project Structure

```
VimHint/
├── main.swift              # App bootstrap
├── AppDelegate.swift       # Status bar, CGEventTap, blocked apps, login item, permission checks
├── HintEngine.swift        # Orchestration: scan → generate hints → show overlay
├── AXScanner.swift         # Accessibility tree traversal (native + web-content modes)
├── AXTreeEnabler.swift     # Enables the AX tree in Electron/Chromium-family apps
├── MLScanner.swift         # CoreML YOLO11m inference, NMS, and OCR text fallback
├── OverlayWindow.swift     # Transparent fullscreen overlay, hint + nav modes
├── HintLabel.swift         # Yellow rounded-rect hint labels
├── BlockedApps.swift       # Persist blocked bundle IDs in UserDefaults
├── KeyHandler.swift        # (stub — key handling is in AppDelegate's CGEventTap)
├── Info.plist              # LSUIElement=YES, usage descriptions
└── VimHint.entitlements    # app-sandbox=false
```

---

## License

MIT

---
---

# VimiumForMac（中文）

一个系统级、Vimium 风格的 macOS 提示覆盖层。双击 ⌘ 键，在每个可点击的界面元素上叠加字母提示——输入提示字符即可点击，全程无需鼠标。

适用于**所有应用**：原生 AppKit/SwiftUI 应用、Electron 应用（Claude、VS Code、Slack、QQ、Obsidian 等）、Chromium 系浏览器，甚至是那些几乎不暴露任何辅助功能信息的自绘 UI 应用（比如微信）。

---

## 功能特性

- **提示模式** — 双击 ⌘ 键，在每个按钮、链接、开关、菜单项、侧边栏项、文本框等元素上显示黄色字母提示，输入提示字符即可点击。
- **导航模式** — 提示模式下按 `Tab` 切换到键盘导航：`h/j/k/l` 将蓝色光标移动到左/下/上/右最近的元素；`Enter` 点击；`d/u` 滚动。
- **跳转输入框** — 提示模式下按 `gi`，自动聚焦窗口中的文本输入框（聊天应用中即消息输入框），可立即开始打字。
- **Backspace** 删除已输入字符，扩大过滤范围。
- **Escape** 或点击鼠标任意位置退出。
- **感知菜单** — 打开菜单栏菜单后双击 ⌘，菜单会保持打开状态，并在菜单项上显示提示。
- **感知子窗口** — 只扫描当前聚焦的窗口（设置面板、弹出表单、对话框），不会扫描背后的整个应用。
- **感知 Electron/Chromium** — 主动点亮 Electron 和 Chromium 系应用的辅助功能树，而不是依赖它"碰巧已经开启"；同时能识别由无标签 `<div>` 构成的界面（详见[工作原理](#工作原理)）。
- **三重识别机制**：辅助功能 API（原生/网页应用）+ YOLO11m CoreML 视觉图标识别 + OCR 文字识别（作为完全没有辅助功能树的应用的最后兜底）。
- **黑名单应用** — 通过状态栏菜单排除特定应用不进入提示模式。
- **开机自启** — 状态栏菜单里一键切换。

---

## 系统要求

- macOS 13 Ventura 或更高版本
- 辅助功能权限（首次启动时会提示）
- 屏幕录制权限（首次启动时会提示 —— 为视觉/OCR 兜底识别提供支持）

---

## 安装

1. 下载最新发布版，或从源码构建（见下文）。
2. 将 `VimHint.app` 移动到 `/Applications`。
3. 启动应用 —— 菜单栏会出现一个键盘图标。
4. 按提示，在「系统设置 → 隐私与安全性」中授予**辅助功能**和**屏幕录制**权限。
5. 可选：在菜单栏图标里开启**开机自启**。

> 权限是绑定在应用的代码签名上的。如果你用不稳定的（ad-hoc）签名从源码构建，macOS 会把每次重新构建都当成一个新应用，每次都要求重新授权 —— 在 Xcode 工程里设置好 `DEVELOPMENT_TEAM` 即可避免（见[从源码构建](#从源码构建)）。

---

## 使用方法

| 操作 | 按键 |
|------|------|
| 激活提示模式 | 双击 ⌘ |
| 输入提示字符 | `A` `S` `D` `F` `H` `J` `K` `L` |
| 删除最后输入的字符 | `Backspace` |
| 跳转到输入框 | `g` `i`（提示可见时） |
| 进入导航模式 | `Tab`（提示可见时） |
| 导航模式下移动 | `h` `j` `k` `l` |
| 点击选中元素（导航模式） | `Enter` 或 `Space` |
| 下一个元素（导航模式） | `Tab` |
| 向下 / 向上滚动（导航模式） | `d` / `u` |
| 退出 | `Esc` 或点击鼠标 |

提示字符只使用主排键 `ASDFHJKL`（`g` 保留作 `gi` 等命令序列的前缀键）。元素较少时会生成 1–2 位的短提示；界面元素密集时会自动生成更长的提示。

---

## 工作原理

### 元素识别

识别分层进行，优先使用最快、最可靠的方式，只有在窗口确实需要时才升级到下一层。

**1. 辅助功能 API（AX）**
遍历当前聚焦窗口的辅助功能树，找出按钮、链接、复选框、文本框、菜单项、侧边栏行、标签页、开关等可交互元素。每个元素只用一次批量 IPC 调用（`AXUIElementCopyMultipleAttributeValues`）同时取回角色、子元素、位置、大小和启用状态；遍历过程中完全在窗口外的子树会被直接剪枝——这两点让即便是嵌套很深的网页界面也能快速扫描完。

**2. Electron/Chromium 树点亮**
基于 Chromium 的应用（Electron 及其私有分支，以及 Chromium 系浏览器）在有辅助工具主动声明自己之前，会一直保持辅助功能树关闭的状态——不做处理的话，扫描只能看到原生窗口框架（红绿灯按钮）。`AXTreeEnabler` 会识别这类应用（通过内置框架名称，或者通过 Chromium 特有的 `Helper (Renderer).app` 进程结构来识别改过名的分支，比如 QQ 的 `QQNT.framework`），在启动时和每次应用切换时主动设置 `AXManualAccessibility` / `AXEnhancedUserInterface`，这样你调用提示模式的时候树早就建好了。它同时能识别由无标签 `<div>` 构成的界面（Obsidian 这类 Electron 应用很常见）：带有 `AXPress` 动作的通用角色也会被算作可点击。

**3. CoreML / YOLO11m**
对当前屏幕截图，运行内置的 `model.mlpackage`（针对 UI 图标微调过的 YOLO11m）来识别辅助功能树漏掉的可点击元素。置信度阈值会根据辅助功能树对该窗口的覆盖程度自适应调整——辅助功能结果接近空白时，会放宽阈值接受置信度较低的识别结果，让视觉识别承担更多覆盖。

**4. OCR 文字兜底**
有些应用（比如微信的自绘 UI）除了红绿灯按钮之外，几乎不向辅助功能 API 暴露任何东西。当辅助功能几乎识别不到元素时，Vision 的文字识别（中英双语）会把屏幕上的文字块作为最后的提示来源——这类界面里几乎所有能点的东西要么本身是文字，要么下面就压着一段文字。

各层识别结果会合并并去重（基于 IOU）。辅助功能元素点击时会触发它自身的 `AXPress` 动作，只有失败时才退回到模拟鼠标点击；纯视觉/OCR 识别出的元素则始终使用模拟点击，点在其中心位置。

### 提示生成

提示字符基于 8 个主排键，用 BFS 前缀无关算法生成——任何一个提示都不会是另一个提示的前缀，所以输入一个字符要么缩小过滤范围，要么在提示完整时立即触发点击。

### 按键拦截

一个挂载在 `.headInsertEventTap` 的 `CGEventTap` 拦截以下事件：
- `flagsChanged` — 检测双击 ⌘ 快捷键，同时不抢占应用焦点
- `keyDown` — 提示叠加层可见时，转发提示/导航按键（扫描仍在进行、提示还未出现时，按键会原样放行，不会被吞掉）
- `leftMouseDown` / `rightMouseDown` — 点击鼠标时关闭提示

覆盖层窗口使用 `orderFrontRegardless()`（绝不使用 `makeKeyAndOrderFront`），因此 VimHint 永远不会成为当前活跃应用，菜单也能保持打开状态。

---

## 从源码构建

依赖：Xcode 15+、macOS 13 SDK、位于 `weights/icon_detect/model.mlpackage` 的 CoreML 模型。

```bash
git clone https://github.com/Forrestssq/VimiumForMac.git
cd VimiumForMac
open VimHint.xcodeproj
```

- 选择 **VimHint** scheme 和 **My Mac** 目标。
- 在工程构建设置里把 `DEVELOPMENT_TEAM` 设为你的 Apple Developer 团队，让每次构建的签名保持稳定——否则每次重新构建 macOS 都会重新要求辅助功能/屏幕录制权限。
- 构建并运行（`⌘R`），或者构建 Release 版本并拷贝到 `/Applications` 做日常使用（Xcode 的调试构建产物不适合用于开机自启）。
- 应用**未启用沙盒**（CGEventTap 和跨进程辅助功能访问都要求关闭沙盒）。

CoreML 模型会在首次启动时运行期编译，并缓存在
`~/Library/Application Support/VimHint/Models/model.mlmodelc`。

### 调试辅助功能问题

状态栏菜单里有一个 **"Debug: Dump AX Tree of Frontmost App"** 选项——它会把当前前台应用完整的原始辅助功能树（所有角色、坐标、动作，不只是 VimHint 能识别的那部分）写入 `~/Desktop/VimHint-AXDump.txt`。当某个应用识别效果不佳、需要看看它到底暴露了什么结构时很有用。

---

## 已知局限

- **自绘 UI 应用**（比如微信）完全不暴露辅助功能树，识别完全依赖视觉/OCR 兜底，速度更慢（多耗时约 300–500 毫秒），且可能漏掉没有文字的纯图标控件。
- **Electron/网页应用** —— 即使辅助功能树已点亮，模型或 OCR 仍可能识别不到部分元素；识别质量取决于界面与模型训练数据的相似程度。
- **沙盒应用** —— 部分系统应用限制辅助功能访问，提示可能不完整。
- **右键菜单** —— 右键菜单可以用提示模式导航，但在部分应用上，双击 ⌘ 快捷键可能会在提示出现前导致右键菜单关闭。
- **开机自启** —— 要求应用从 `/Applications` 运行，而非 Xcode 的构建产物目录。

---

## 项目结构

```
VimHint/
├── main.swift              # 应用入口
├── AppDelegate.swift       # 状态栏、CGEventTap、黑名单应用、开机自启、权限检查
├── HintEngine.swift        # 编排逻辑：扫描 → 生成提示 → 显示覆盖层
├── AXScanner.swift         # 辅助功能树遍历（原生模式 + 网页内容模式）
├── AXTreeEnabler.swift     # 点亮 Electron/Chromium 系应用的辅助功能树
├── MLScanner.swift         # CoreML YOLO11m 推理、NMS、OCR 文字兜底
├── OverlayWindow.swift     # 透明全屏覆盖层，提示模式 + 导航模式
├── HintLabel.swift         # 黄色圆角矩形提示标签
├── BlockedApps.swift       # 在 UserDefaults 中持久化黑名单 bundle ID
├── KeyHandler.swift        # （占位 —— 实际按键处理在 AppDelegate 的 CGEventTap 中）
├── Info.plist              # LSUIElement=YES，用途说明文案
└── VimHint.entitlements    # app-sandbox=false
```

---

## 许可证

MIT
