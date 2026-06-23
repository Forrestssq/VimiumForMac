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
                self?.selectAndClick(target)
            }
        } onDismiss: { [weak self] in
            Task { @MainActor in self?.deactivate() }
        }

        overlay = win
        win.show()
    }

    // Close overlay → restore target app → wait → click
    // The wait is important: some apps (SwiftUI/Settings) need to be
    // the active app before they process click events.
    private func selectAndClick(_ target: HintTarget) {
        overlay?.dismiss()
        overlay = nil
        isActive = false

        let app = previousApp
        previousApp = nil
        app?.activate(options: .activateIgnoringOtherApps)

        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)  // 80 ms — let app regain focus
            await MainActor.run { self.performClick(on: target) }
        }
    }

    func deactivate() {
        overlay?.dismiss()
        overlay = nil
        isActive = false
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }

    // MARK: - Click

    private func performClick(on target: HintTarget) {
        var roleRef: CFTypeRef?
        let role = (target.element.flatMap { el -> String? in
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success
                ? roleRef as? String : nil
        }) ?? ""

        // Text fields: focus rather than press
        if role == kAXTextFieldRole || role == kAXComboBoxRole {
            if let el = target.element {
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            cgClick(at: target.frame.mid)
            return
        }

        // Buttons/links: try AX press; always follow with a CGEvent click
        // so SwiftUI / Electron elements (which may silently ignore AXPress) still work.
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

    // MARK: - Hint generation (prefix-free: no hint is a prefix of another)
    //
    // With alphabet size n=9 and target count C:
    //   Reserve k letter-families as 2-char prefixes, rest as single-char hints.
    //   k = ⌈(C - n) / (n - 1)⌉
    //   Result = (n-k) single-char hints  +  k*n two-char hints  ≥ C

    private let chars = Array("ASDFGHJKL")

    private func generateHints(count: Int) -> [String] {
        let n = chars.count
        guard count > n else {
            return chars.prefix(count).map { String($0) }
        }

        let k = min(Int(ceil(Double(count - n) / Double(n - 1))), n)
        var hints: [String] = []

        // Single-char hints (use the "tail" letters, leaving "head" letters for pairs)
        for i in k..<n { hints.append(String(chars[i])) }

        // Two-char hints (head letters × all letters)
        for i in 0..<k {
            for j in 0..<n { hints.append(String(chars[i]) + String(chars[j])) }
        }

        return Array(hints.prefix(count))
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

private extension CGRect {
    var mid: CGPoint { CGPoint(x: midX, y: midY) }
}
