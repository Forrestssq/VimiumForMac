import Cocoa
import ApplicationServices

// MARK: - Domain types

struct HintTarget {
    let frame: CGRect           // Quartz screen coordinates (top-left origin)
    let element: AXUIElement?   // nil for ML-only detections
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
    private var isActive = false

    func activate() async {
        guard !isActive else { return }
        isActive = true

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            isActive = false
            return
        }
        previousApp = frontApp

        let screen = screenForApp(frontApp)

        // Parallel scan
        async let axTask = AXScanner.shared.scan(pid: frontApp.processIdentifier)
        async let mlTask = MLScanner.shared.scan(screen: screen)

        let (axResults, mlBoxes) = await (axTask, mlTask)

        // Build merged target list
        var targets: [HintTarget] = axResults.map {
            HintTarget(frame: $0.frame, element: $0.element, source: .ax)
        }

        for box in mlBoxes {
            let overlapsAX = axResults.contains { iou(box, $0.frame) > 0.5 }
            if !overlapsAX {
                targets.append(HintTarget(frame: box, element: nil, source: .ml))
            }
        }

        guard !targets.isEmpty else { isActive = false; return }

        let hints = generateHints(count: targets.count)
        let hinted = zip(hints, targets).map { HintedTarget(hint: $0, target: $1) }

        let win = OverlayWindow(screen: screen, targets: hinted) { [weak self] target in
            Task { @MainActor in
                self?.performClick(on: target)
                self?.deactivate()
            }
        } onDismiss: { [weak self] in
            Task { @MainActor in self?.deactivate() }
        }

        overlay = win
        win.show()
    }

    func deactivate() {
        overlay?.dismiss()
        overlay = nil
        isActive = false
        // Restore focus to the app that was frontmost before hint mode
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }

    // MARK: - Click

    private func performClick(on target: HintTarget) {
        // Try AX press first
        if let el = target.element {
            if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return }
        }

        // Fallback: synthesize mouse click at element centre
        let centre = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,   mouseCursorPosition: centre, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Hint generation ("ASDFGHJKL")

    private let chars = Array("ASDFGHJKL")

    private func generateHints(count: Int) -> [String] {
        var result: [String] = []
        var len = 1
        while result.count < count {
            result += combos(length: len)
            len += 1
        }
        return Array(result.prefix(count))
    }

    private func combos(length: Int) -> [String] {
        guard length > 0 else { return [""] }
        if length == 1 { return chars.map { String($0) } }
        return chars.flatMap { c in combos(length: length - 1).map { String(c) + $0 } }
    }

    // MARK: - Helpers

    private func screenForApp(_ app: NSRunningApplication) -> NSScreen {
        // Use the screen that contains the app's focused window
        guard let pid = Optional(app.processIdentifier) else { return NSScreen.main ?? NSScreen.screens[0] }
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winEl = winRef {
            var posRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
               let posVal = posRef {
                var pos = CGPoint.zero
                AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
                // pos is in Quartz coords; find which NSScreen contains it
                let quartzPt = pos
                for screen in NSScreen.screens {
                    let sqr = quartzToNSScreen(CGRect(origin: quartzPt, size: .zero), primaryHeight: NSScreen.screens[0].frame.height)
                    if screen.frame.contains(sqr.origin) { return screen }
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func quartzToNSScreen(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia / ua : 0
    }
}
