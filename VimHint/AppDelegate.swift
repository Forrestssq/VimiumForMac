import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestAccessibilityPermission()
        setupGlobalEventTap()
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
        menu.addItem(NSMenuItem(title: "Quit VimHint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func blockCurrentApp() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier else { return }
        BlockedApps.shared.add(bid)
        rebuildMenu()
    }

    @objc private func unblockApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        BlockedApps.shared.remove(bid)
        rebuildMenu()
    }

    // MARK: - Permissions

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - CGEventTap (handles BOTH the activation hotkey AND hint-mode key intercept)

    private var lastCommandDownTime: TimeInterval = 0
    private let doubleTapThreshold: TimeInterval  = 0.35

    private func setupGlobalEventTap() {
        // Listen to both flagsChanged (double-⌘ detection) and keyDown (hint-mode interception)
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)

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
        // ── Hint-mode key interception ──────────────────────────────────────
        if type == .keyDown {
            var consumed = false
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            DispatchQueue.main.sync {
                if HintEngine.shared.isActive {
                    HintEngine.shared.processKeyCode(code)
                    consumed = true
                }
            }
            if consumed { return nil }
        }

        // ── Double-tap ⌘ to activate ────────────────────────────────────────
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags
        guard (keyCode == 55 || keyCode == 54) && flags.contains(.maskCommand) else {
            return Unmanaged.passRetained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCommandDownTime < doubleTapThreshold {
            lastCommandDownTime = 0
            DispatchQueue.main.async {
                Task { @MainActor in await HintEngine.shared.activate() }
            }
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
