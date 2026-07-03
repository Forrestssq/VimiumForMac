import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestAccessibilityPermission()
        setupGlobalEventTap()
        MainActor.assumeIsolated { AXTreeEnabler.shared.start() }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "VimHint")
            btn.image?.isTemplate = true
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "VimHint  —  double ⌘ to activate", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        // Block current app
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? bid
            let item = NSMenuItem(title: "Block \"\(name)\"", action: #selector(blockCurrentApp), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // Blocked apps submenu
        let blocked = BlockedApps.shared.all()
        if !blocked.isEmpty {
            let sub = NSMenu(title: "Blocked Apps")
            for bid in blocked {
                let label = bid.components(separatedBy: ".").last ?? bid
                let item = NSMenuItem(title: "✓ \(label)", action: #selector(unblockApp(_:)), keyEquivalent: "")
                item.representedObject = bid
                item.target = self
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Blocked Apps", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        if !CGPreflightScreenCaptureAccess() {
            let warn = NSMenuItem(
                title: "⚠️ Screen Recording off — visual detection disabled",
                action: #selector(openScreenRecordingSettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        let dump = NSMenuItem(title: "Debug: Dump AX Tree of Frontmost App", action: #selector(dumpAXTree), keyEquivalent: "")
        dump.target = self
        menu.addItem(dump)

        menu.addItem(.separator())

        // Launch at Login toggle
        let launchEnabled = SMAppService.mainApp.status == .enabled
        let loginItem = NSMenuItem(
            title: launchEnabled ? "✓ Launch at Login" : "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VimHint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func blockCurrentApp() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier else { return }
        BlockedApps.shared.add(bid)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("LaunchAtLogin: \(error)")
        }
        rebuildMenu()
    }

    @objc private func unblockApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        BlockedApps.shared.remove(bid)
        rebuildMenu()
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // Writes the raw AX tree (all roles, not just interactable ones) of the
    // frontmost app to the Desktop — for diagnosing apps with odd AX exposure.
    // Clicking a status-bar menu doesn't change the frontmost app.
    @objc private func dumpAXTree() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let header = "app: \(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "")] pid \(pid)"
        Task.detached(priority: .userInitiated) {
            var lines = [header]
            func str(_ el: AXUIElement, _ attr: String) -> String {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
                return (ref as? String) ?? ""
            }
            func walk(_ el: AXUIElement, _ depth: Int) {
                guard depth < 35, lines.count < 5000 else { return }
                let role = str(el, kAXRoleAttribute as String)
                let title = str(el, kAXTitleAttribute as String)
                let desc = str(el, kAXDescriptionAttribute as String)

                var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
                var frameStr = ""
                if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let p = posRef, let s = sizeRef {
                    var pt = CGPoint.zero; var sz = CGSize.zero
                    if AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) {
                        frameStr = " (\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height)))"
                    }
                }

                var actionsRef: CFArray?
                let actions = AXUIElementCopyActionNames(el, &actionsRef) == .success
                    ? ((actionsRef as? [String]) ?? []).joined(separator: ",") : ""

                let indent = String(repeating: "  ", count: depth)
                var line = "\(indent)\(role.isEmpty ? "?" : role)\(frameStr)"
                if !title.isEmpty { line += " title=\"\(title)\"" }
                if !desc.isEmpty { line += " desc=\"\(desc)\"" }
                if !actions.isEmpty { line += " actions=[\(actions)]" }
                lines.append(line)

                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { return }
                for c in children { walk(c, depth + 1) }
            }
            walk(AXUIElementCreateApplication(pid), 0)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/VimHint-AXDump.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Permissions

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // Without screen recording, MLScanner captures an empty desktop and
        // visual detection silently finds nothing (the only coverage for
        // apps with no AX tree, e.g. WeChat).
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - CGEventTap (handles BOTH the activation hotkey AND hint-mode key intercept)

    private var lastCommandDownTime: TimeInterval = 0
    private let doubleTapThreshold: TimeInterval  = 0.35
    private var consumeNextCommandUp = false

    private func setupGlobalEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                return Unmanaged<AppDelegate>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handleCGEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            showAccessibilityAlert()
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // ── Mouse click while hints are visible → dismiss and let click through ──
        if type == .leftMouseDown || type == .rightMouseDown {
            MainActor.assumeIsolated {
                if HintEngine.shared.isActive { HintEngine.shared.deactivate() }
            }
            return Unmanaged.passRetained(event)
        }

        // ── Hint-mode key interception ──────────────────────────────────────
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // The CGEventTap source is attached to the main run loop (see setupGlobalEventTap),
            // so this callback already executes on the main thread.
            // MainActor.assumeIsolated lets us call @MainActor code without a dispatch.
            let consumed = MainActor.assumeIsolated {
                // Only swallow keys once the overlay is actually on screen;
                // while a scan is still pending, typing must pass through.
                guard HintEngine.shared.isActive, HintEngine.shared.isShowingOverlay else { return false }
                HintEngine.shared.processKeyCode(code)
                return true
            }
            if consumed { return nil }
        }

        // ── Double-tap ⌘ to activate ────────────────────────────────────────
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

        let keyCode   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags     = event.flags
        let isCmdKey  = keyCode == 55 || keyCode == 54

        // Consume the ⌘ UP that immediately follows the activating DOWN.
        // Without this, the menu tracking loop receives an "orphan" ⌘ UP
        // (no matching DOWN because we consumed it) and interprets that as
        // a canceled keyboard shortcut, dismissing any open menu.
        if isCmdKey && !flags.contains(.maskCommand) && consumeNextCommandUp {
            consumeNextCommandUp = false
            return nil
        }

        guard isCmdKey && flags.contains(.maskCommand) else {
            return Unmanaged.passRetained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCommandDownTime < doubleTapThreshold {
            lastCommandDownTime = 0
            consumeNextCommandUp = true  // consume the upcoming ⌘ UP too
            DispatchQueue.main.async {
                Task { @MainActor in await HintEngine.shared.activate() }
            }
            return nil  // consume the activating ⌘ DOWN
        } else {
            lastCommandDownTime = now
        }
        return Unmanaged.passRetained(event)
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText     = "VimHint needs Accessibility permission"
            a.informativeText = "Open System Settings → Privacy & Security → Accessibility and enable VimHint, then restart."
            a.addButton(withTitle: "Open System Settings")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
}
