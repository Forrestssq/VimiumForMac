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
    var isShowingOverlay: Bool { overlay != nil }

    // MARK: - Activate

    func activate() async {
        guard !isActive else { return }
        isActive = true

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            isActive = false; return
        }
        previousApp = frontApp

        if let bid = frontApp.bundleIdentifier, BlockedApps.shared.isBlocked(bid) {
            isActive = false; return
        }

        // Chromium/Electron apps don't build their AX tree until an assistive
        // client announces itself — set the flag before scanning.
        AXTreeEnabler.shared.enable(for: frontApp)

        // Resolve focused window: AX root + Quartz frame + screen
        let (axRoot, winFrame) = focusedWindowContext(for: frontApp)
        let screen = winFrame.flatMap { screenContaining($0) } ?? (NSScreen.main ?? NSScreen.screens[0])

        // For Electron/web apps (sparse AX trees), lower ML threshold for better coverage
        let isElectron = AXTreeEnabler.shared.isChromiumFamily(frontApp)
        let mlThreshold: Float = isElectron ? 0.28 : 0.38

        async let mlTask = MLScanner.shared.scan(screen: screen, threshold: mlThreshold)

        // If the flag was only just set, the app builds its AX tree
        // asynchronously — a near-empty result (window chrome only) on a
        // Chromium app means "still building", so wait briefly and rescan.
        // Two consecutive identical counts mean the tree is done and just
        // genuinely sparse, so stop early instead of burning all retries.
        var axResults = await AXScanner.shared.scan(root: axRoot, webContent: isElectron)
        if isElectron {
            var attempts = 0
            var previousCount = axResults.count
            var stableScans = 0
            while axResults.count < 10 && attempts < 4 && isActive {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard isActive else { break }   // canceled by a click mid-wait
                let (root, _) = focusedWindowContext(for: frontApp)
                axResults = await AXScanner.shared.scan(root: root, webContent: true)
                if axResults.count == previousCount {
                    stableScans += 1
                    if stableScans >= 2 { break }
                } else {
                    stableScans = 0
                    previousCount = axResults.count
                }
                attempts += 1
            }
        }
        let allMLBoxes = await mlTask

        // A mouse click during the scans deactivates via the CGEventTap;
        // don't resurrect the overlay afterwards.
        guard isActive else { return }

        // Web trees report scrolled-out elements at off-window coordinates —
        // clip AX results to the focused window like ML results are.
        if let f = winFrame {
            axResults = axResults.filter { f.intersects($0.frame) }
        }

        // Remove overlapping AX elements: sort by area descending, then drop any element
        // whose frame is ≥80% covered by an already-kept (larger) element.
        // This collapses AXRow + AXCell pairs in table/list views down to one hint per row,
        // while preserving smaller interactive widgets (buttons, toggles) inside rows.
        let axDeduped = deduplicateOverlapping(axResults)

        // Clip ML results to the focused window's bounds so background-window
        // elements don't bleed through when a sheet or Settings panel is open.
        let mlBoxes: [CGRect]
        if let f = winFrame {
            mlBoxes = allMLBoxes.filter { f.intersects($0) }
        } else {
            mlBoxes = allMLBoxes
        }

        var targets: [HintTarget] = axDeduped.map {
            HintTarget(frame: $0.frame, element: $0.element, source: .ax)
        }
        for box in mlBoxes {
            if !axResults.contains(where: { iou(box, $0.frame) > 0.5 }) {
                targets.append(HintTarget(frame: box, element: nil, source: .ml))
            }
        }

        guard !targets.isEmpty else { isActive = false; return }

        // Cap to 200 to avoid flooding the screen in unusually rich UIs
        let capped = targets.count > 200 ? Array(targets.prefix(200)) : targets
        let hints  = generateHints(count: capped.count)
        let hinted = zip(hints, capped).map { HintedTarget(hint: $0, target: $1) }

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
        // Press OR click, never both — firing both toggles switches twice.
        // Synthetic click only when the element has no working AXPress
        // (ML-detected targets, rows/cells without press actions).
        if let el = target.element,
           AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            return
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

    // MARK: - Hint generation (BFS, prefix-free)

    private let chars = Array("ASDFGHJKL")

    private func generateHints(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var queue: [String] = chars.map { String($0) }
        var result: [String] = []
        result.reserveCapacity(count)

        while result.count < count, !queue.isEmpty {
            let hint = queue.removeFirst()
            if result.count + queue.count + 1 >= count {
                result.append(hint)
            } else {
                for c in chars { queue.append(hint + String(c)) }
            }
        }
        return result
    }

    // MARK: - Window context

    // Returns the AX element to scan (focused window or app) and its Quartz frame.
    private func focusedWindowContext(for app: NSRunningApplication) -> (AXUIElement, CGRect?) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        // Prefer focused window (handles sheets, dialogs, Settings panels).
        // Fall back to main window, then the whole app element.
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, attr as CFString, &winRef) == .success,
               let winEl = winRef {
                let el = winEl as! AXUIElement
                return (el, axFrame(el))
            }
        }
        return (appEl, nil)
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var pos = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // Find the NSScreen whose frame (in NSScreen coords, bottom-left origin)
    // contains the mid-point of the given Quartz frame (top-left origin).
    private func screenContaining(_ quartzFrame: CGRect) -> NSScreen? {
        let ph = NSScreen.screens[0].frame.height
        let nsPos = CGPoint(x: quartzFrame.midX, y: ph - quartzFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(nsPos) })
    }

    // Drop elements whose frame is ≥80% covered by a larger element already in the set.
    // Processes elements largest-first so outer containers win over inner duplicates.
    private func deduplicateOverlapping(_ results: [AXResult]) -> [AXResult] {
        let sorted = results.sorted {
            ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height)
        }
        var kept: [AXResult] = []
        for r in sorted {
            let area = r.frame.width * r.frame.height
            guard area > 1 else { continue }
            let dominated = kept.contains { other in
                let inter = r.frame.intersection(other.frame)
                guard !inter.isNull else { return false }
                return (inter.width * inter.height) / area > 0.80
            }
            if !dominated { kept.append(r) }
        }
        return kept
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
