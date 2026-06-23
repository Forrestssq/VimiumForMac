# VimiumForMac

A system-wide Vimium-style hint overlay for macOS. Double-tap ⌘ to overlay letter hints on every clickable UI element — type the hint to click it, no mouse needed.

Works on **all apps** including native AppKit, SwiftUI, and Electron-based apps (Claude, VS Code, Slack, etc.).

---

## Features

- **Hint mode** — double-tap ⌘ to show yellow letter hints on every button, link, toggle, menu item, sidebar item, text field, etc. Type the hint to click.
- **Nav mode** — press `Tab` in hint mode to switch to keyboard navigation: `h/j/k/l` moves a blue cursor to the nearest element left/down/up/right; `Enter` clicks it; `d/u` scrolls.
- **Backspace** to delete a typed character and widen the filter.
- **Escape** or mouse click anywhere to dismiss.
- **Menu-aware** — open a menu bar menu, then double-tap ⌘; the menu stays open and hints appear on the menu items.
- **Sub-window aware** — only scans the focused window (Settings panels, sheets, dialogs), not the whole app behind it.
- **Dual detection**: Accessibility API for native apps + YOLO11m CoreML model for Electron/web apps.
- **Blocked apps** — exclude specific apps from hint mode via the status bar menu.
- **Launch at Login** — one-click toggle in the status bar menu.

---

## Requirements

- macOS 13 Ventura or later
- Accessibility permission (prompted on first launch)

---

## Installation

1. Download the latest release or build from source (see below).
2. Move `VimHint.app` to `/Applications`.
3. Launch the app — a keyboard icon appears in the menu bar.
4. When prompted, grant **Accessibility** permission in  
   System Settings → Privacy & Security → Accessibility.
5. Optionally enable **Launch at Login** from the menu bar icon.

---

## Usage

| Action | Key |
|--------|-----|
| Activate hint mode | Double-tap ⌘ |
| Type a hint | `A` `S` `D` `F` `G` `H` `J` `K` `L` |
| Delete last typed character | `Backspace` |
| Enter nav mode | `Tab` (while hints are visible) |
| Navigate in nav mode | `h` `j` `k` `l` |
| Click selected element (nav mode) | `Enter` or `Space` |
| Next element (nav mode) | `Tab` |
| Scroll down / up (nav mode) | `d` / `u` |
| Dismiss | `Esc` or mouse click |

Hints use only the home-row keys `ASDFGHJKL`. Short hints (1–2 chars) appear when there are few elements; longer hints are generated automatically for dense UIs.

---

## How It Works

### Element detection

Two methods run in parallel every time hint mode activates:

**1. Accessibility API (AX)**  
Traverses the focused window's accessibility tree to find interactive elements: buttons, links, checkboxes, text fields, menu items, sidebar rows, tabs, toggles, and more. Returns results in ~20 ms.

**2. CoreML / YOLO11m**  
Takes a screenshot of the current screen and runs the bundled `model.mlpackage` (YOLO11m, fine-tuned for UI icons) to detect clickable elements that the AX tree misses — common in Electron and web-rendered apps. Returns results in ~50 ms.

Results are merged and deduplicated (IOU-based). AX elements get their accessible action triggered on click; ML-only elements receive a synthetic mouse click at their center.

### Hint generation

Hints are generated with a BFS prefix-free algorithm over the 9 home-row keys. No hint is ever a prefix of another, so typing a character either narrows the filter or immediately triggers a click when the hint is complete.

### Key interception

A `CGEventTap` at `.headInsertEventTap` intercepts:
- `flagsChanged` — detects the double-tap ⌘ hotkey without stealing app focus
- `keyDown` — routes hint/nav key presses while the overlay is active
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
- Build & Run (`⌘R`).
- The app is **not sandboxed** (required for CGEventTap and cross-process Accessibility).

The CoreML model is compiled at runtime on first launch and cached in  
`~/Library/Application Support/VimHint/Models/model.mlmodelc`.

---

## Known Limitations

- **Electron / web apps** — Accessibility metadata is limited; the ML model compensates but may miss some elements. Detection quality depends on how closely the UI resembles the model's training data.
- **Sandboxed apps** — Some system apps restrict Accessibility access; hints may be incomplete.
- **Context menus** — Right-click context menus can be navigated with hint mode, but the double-tap ⌘ hotkey may cause context menus to close on some apps before hints appear.
- **Launch at Login** — Requires the app to run from `/Applications`, not from Xcode's build output.

---

## Project Structure

```
VimHint/
├── main.swift              # App bootstrap
├── AppDelegate.swift       # Status bar, CGEventTap, blocked apps, login item
├── HintEngine.swift        # Orchestration: scan → generate hints → show overlay
├── AXScanner.swift         # Accessibility tree traversal
├── MLScanner.swift         # CoreML YOLO11m inference + NMS
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
