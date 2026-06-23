import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestAccessibilityPermission()
        setupGlobalHotkey()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "VimHint")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "VimHint  —  double ⌘ to activate", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VimHint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Permissions

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Global Hotkey (CGEventTap)

    // Double-tap Command detection
    private var lastCommandDownTime: TimeInterval = 0
    private let doubleTapThreshold: TimeInterval = 0.35

    private func setupGlobalHotkey() {
        // flagsChanged fires on every modifier key press/release
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleCGEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            print("VimHint: CGEvent tap creation failed — grant Accessibility in System Settings.")
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // keyCode 55 = left ⌘, 54 = right ⌘
        // Only react on key-DOWN (flags contain .maskCommand)
        guard (keyCode == 55 || keyCode == 54) && flags.contains(.maskCommand) else {
            return Unmanaged.passRetained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCommandDownTime < doubleTapThreshold {
            lastCommandDownTime = 0
            DispatchQueue.main.async {
                Task { @MainActor in
                    await HintEngine.shared.activate()
                }
            }
        } else {
            lastCommandDownTime = now
        }

        return Unmanaged.passRetained(event) // never consume ⌘ — other apps still need it
    }
}
