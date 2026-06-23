import Cocoa
import ApplicationServices

// MARK: - Domain types

struct HintTarget {
    let frame: CGRect           // Quartz screen coordinates, points (top-left origin)
    let element: AXUIElement?
    enum Source { case ax, ml }
    let source: Source
}

struct HintedTarget {
    let hint: String
    let target: HintTarget
}

// MARK: - HintEngine

@MainActor
final class HintEngine {
    static let shared = HintEngine()
    private init() {}

    private var overlay: OverlayWindow?
    private var previousApp: NSRunningApplication?
    private(set) var isActive = false   // read by AppDelegate's CGEventTap

    // MARK: - Activate

    func activate() async {
        guard !isActive else { return }
        isActive = true

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            isActive = false; return
        }
        previousApp = frontApp

        // Skip blocked apps
        if let bid = frontApp.bundleIdentifier,
           BlockedApps.shared.isBlocked(bid) {
            isActive = false; return
        }

        let screen = screenForApp(frontApp)

        // Scan ALL visible regular apps on this screen (not just the frontmost)
        // so Electron / Flutter apps are covered by both AX and ML simultaneously.
        async let axTask = AXScanner.shared.scanAllApps(on: screen)
        async let mlTask = MLScanner.shared.scan(screen: screen)
        let (axResults, mlBoxes) = await (axTask, mlTask)

        var targets: [HintTarget] = axResults.map {
            HintTarget(frame: $0.frame, element: $0.element, source: .ax)
        }
        for box in mlBoxes {
            if !axResults.contains(where: { iou(box, $0.frame) > 0.5 }) {
                targets.append(HintTarget(frame: box, element: nil, source: .ml))
            }
        }

        guard !targets.isEmpty else { isActive = false; return }

        let hints  = generateHints(count: targets.count)
        let hinted = zip(hints, targets).map { HintedTarget(hint: $0, target: $1) }

        let win = OverlayWindow(screen: screen, targets: hinted) { [weak self] target in
            Task { @MainActor in self?.selectAndClick(target) }
        } onDismiss: { [weak self] in
            Task { @MainActor in self?.deactivate() }
        }
        overlay = win
        win.show()
    }

    // MARK: - Key forwarding (called by AppDelegate's CGEventTap)

    func processKeyCode(_ code: Int64) {
        overlay?.handleKeyCode(code)
    }

    // MARK: - Click / dismiss

    private func selectAndClick(_ target: HintTarget) {
        overlay?.dismiss()
        overlay = nil
        isActive = false

        let app = previousApp
        previousApp = nil

        // Menu items: AXPress directly while menu is still open
        var roleRef: CFTypeRef?
        let role = (target.element.flatMap { el -> String? in
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success
                ? roleRef as? String : nil
        }) ?? ""

        if role == kAXMenuItemRole {
            if let el = target.element {
                AXUIElementPerformAction(el, kAXPressAction as CFString)
            }
            return
        }

        // Non-menu: restore app focus, then click
        app?.activate(options: .activateIgnoringOtherApps)
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run { self.performClick(on: target, role: role) }
        }
    }

    func deactivate() {
        overlay?.dismiss()
        overlay = nil
        isActive = false
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }

    private func performClick(on target: HintTarget, role: String) {
        if role == kAXTextFieldRole || role == kAXComboBoxRole {
            if let el = target.element {
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            cgClick(at: target.frame.mid)
            return
        }
        if let el = target.element {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
        cgClick(at: target.frame.mid)
    }

    private func cgClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let dn = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Hint generation (BFS, prefix-free, handles any count)
    //
    // Expand hints level-by-level; a candidate becomes a leaf only when the
    // remaining queue already contains enough items to reach `count`.
    // This guarantees no hint is ever a prefix of another hint.

    private let chars = Array("ASDFGHJKL")

    private func generateHints(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var queue: [String] = chars.map { String($0) }
        var result: [String] = []
        result.reserveCapacity(count)

        while result.count < count, !queue.isEmpty {
            let hint = queue.removeFirst()
            if result.count + queue.count + 1 >= count {
                // Queue is big enough without expanding — make this a leaf
                result.append(hint)
            } else {
                // Need more hints — expand this prefix into children
                for c in chars { queue.append(hint + String(c)) }
            }
        }
        return result
    }

    // MARK: - Helpers

    private func screenForApp(_ app: NSRunningApplication) -> NSScreen {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winEl = winRef {
            var posRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
               let posVal = posRef {
                var pos = CGPoint.zero
                AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
                let primaryH = NSScreen.screens[0].frame.height
                let nsPos = CGPoint(x: pos.x, y: primaryH - pos.y)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(nsPos) }) {
                    return screen
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia / ua : 0
    }
}

private extension CGRect {
    var mid: CGPoint { CGPoint(x: midX, y: midY) }
}
