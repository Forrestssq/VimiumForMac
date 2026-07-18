import Cocoa
import ApplicationServices

struct AXResult {
    let frame: CGRect       // Quartz screen coordinates (top-left origin)
    let element: AXUIElement
}

final class AXScanner {
    static let shared = AXScanner()
    private init() {}

    private let interactableRoles: Set<String> = [
        kAXButtonRole,          // "AXButton"
        "AXLink",               // kAXLinkRole — not bridged as Swift constant
        kAXMenuItemRole,
        kAXCheckBoxRole,
        kAXRadioButtonRole,
        kAXTextFieldRole,
        kAXPopUpButtonRole,
        kAXComboBoxRole,
        "AXMenuButton",
        "AXDisclosureTriangle",
        "AXTabGroup",
        "AXTab",
        "AXSegmentedControl",
        "AXColorWell",
        // Sidebar / list / outline items:
        // NSOutlineView rows (Finder sidebar, Xcode navigator, source lists)
        // and NSTableView rows/cells (SwiftUI NavigationSplitView sidebars)
        "AXRow",
        "AXCell",
    ]

    // Web content maps unlabeled clickable <div>/<span>/icons to these generic
    // roles (Obsidian's ribbon, tabs, and file explorer are all divs). They
    // count as interactable only when Chromium reports an AXPress action.
    private let webPressRoles: Set<String> = [
        "AXGroup", "AXImage", "AXStaticText", "AXUnknown",
    ]

    // Atomic controls: nothing inside them is separately clickable, so their
    // subtrees are skipped entirely (a big saving in dense web trees).
    private let atomicRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole,
        kAXTextFieldRole, kAXPopUpButtonRole, kAXComboBoxRole,
        "AXMenuButton", "AXDisclosureTriangle", "AXTab", "AXColorWell",
    ]

    // Text-input roles for the "gi" jump-to-input feature. Chromium maps
    // <input> to AXTextField and <textarea>/contenteditable to AXTextArea.
    private let textInputRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    // One IPC round-trip per element instead of one per attribute.
    private static let batchAttributes = [
        kAXRoleAttribute, kAXChildrenAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
    ] as CFArray

    // Scan every regular app whose elements fall on `screen`, in parallel.
    func scanAllApps(on screen: NSScreen) async -> [AXResult] {
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
            }
        }
        let bounds = quartzBounds(of: screen)
        return await withTaskGroup(of: [AXResult].self) { group in
            for app in apps {
                let pid = app.processIdentifier
                group.addTask { [self] in await scan(pid: pid, bounds: bounds) }
            }
            var all: [AXResult] = []
            for await r in group { all.append(contentsOf: r) }
            return all
        }
    }

    // Scan from an arbitrary AX root element (e.g. a focused window element).
    // `webContent: true` (Electron/Chromium apps) additionally hints generic
    // roles carrying an AXPress action and traverses the deeper DOM nesting.
    // `bounds` (the window frame) prunes scrolled-out subtrees during the walk.
    func scan(root: AXUIElement, webContent: Bool = false, bounds: CGRect? = nil) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            traverse(element: root, results: &results, depth: 0, webContent: webContent, bounds: bounds)
            return results
        }.value
    }

    // Single-app scan, optionally restricted to elements inside `bounds`.
    func scan(pid: pid_t, bounds: CGRect? = nil) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            let app = AXUIElementCreateApplication(pid)
            traverse(element: app, results: &results, depth: 0, bounds: bounds)
            return results
        }.value
    }

    // Collect only text-input elements under `root` (for the "gi" feature).
    func scanTextInputs(root: AXUIElement, webContent: Bool = false, bounds: CGRect? = nil) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            traverseTextInputs(element: root, results: &results, depth: 0,
                               webContent: webContent, bounds: bounds)
            return results
        }.value
    }

    // MARK: - Traversal

    private func traverse(element: AXUIElement, results: inout [AXResult], depth: Int,
                          webContent: Bool = false, bounds: CGRect? = nil) {
        guard depth < (webContent ? 45 : 25), results.count < 600 else { return }

        // Fetch role, children, position, size, and enabled in a single IPC
        // round-trip — the target app services these on its main thread, so
        // round-trips are the dominant scan cost.
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
                element, Self.batchAttributes, AXCopyMultipleAttributeOptions(), &valuesRef) == .success,
              let values = valuesRef as? [AnyObject], values.count == 5 else { return }

        let role     = values[0] as? String
        let children = values[1] as? [AXUIElement] ?? []
        let frame    = quartzFrame(position: values[2], size: values[3])
        let enabled  = (values[4] as? Bool) ?? true

        // Prune subtrees that lie entirely outside the window — web trees
        // report scrolled-out content (e.g. chat history) at off-window
        // coordinates, and none of it can be hinted anyway.
        if let b = bounds, let f = frame, f.width > 1, f.height > 1, !b.intersects(f) {
            return
        }

        var descend = true
        if let role {
            if interactableRoles.contains(role) {
                if enabled, let f = frame, !f.isEmpty {
                    results.append(AXResult(frame: f, element: element))
                    // Nothing inside an atomic control is separately clickable.
                    if atomicRoles.contains(role) { descend = false }
                }
            } else if webContent, webPressRoles.contains(role),
                      let f = frame, !f.isEmpty,
                      // Size cap keeps whole-pane clickable containers out —
                      // they would swallow their inner icons in deduplication.
                      f.width <= 600, f.height <= 120,
                      hasPressAction(element) {
                results.append(AXResult(frame: f, element: element))
            }
        }

        guard descend else { return }
        for child in children {
            traverse(element: child, results: &results, depth: depth + 1,
                     webContent: webContent, bounds: bounds)
        }
    }

    private func traverseTextInputs(element: AXUIElement, results: inout [AXResult], depth: Int,
                                    webContent: Bool, bounds: CGRect?) {
        guard depth < (webContent ? 45 : 25), results.count < 50 else { return }

        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
                element, Self.batchAttributes, AXCopyMultipleAttributeOptions(), &valuesRef) == .success,
              let values = valuesRef as? [AnyObject], values.count == 5 else { return }

        let role     = values[0] as? String
        let children = values[1] as? [AXUIElement] ?? []
        let frame    = quartzFrame(position: values[2], size: values[3])
        let enabled  = (values[4] as? Bool) ?? true

        if let b = bounds, let f = frame, f.width > 1, f.height > 1, !b.intersects(f) {
            return
        }

        if let role, textInputRoles.contains(role), enabled, let f = frame, !f.isEmpty {
            results.append(AXResult(frame: f, element: element))
            return  // text inputs are atomic — nothing inside is a separate input
        }
        for child in children {
            traverseTextInputs(element: child, results: &results, depth: depth + 1,
                               webContent: webContent, bounds: bounds)
        }
    }

    private func hasPressAction(_ element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    // Decode the batched AXValue position/size pair (error placeholders from
    // AXUIElementCopyMultipleAttributeValues fail the type checks and yield nil).
    private func quartzFrame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var pos  = CGPoint.zero
        var sz   = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &pos),
              AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    // Convert NSScreen frame (bottom-left origin) → Quartz bounds (top-left origin)
    private func quartzBounds(of screen: NSScreen) -> CGRect {
        let ph = NSScreen.screens[0].frame.height
        return CGRect(
            x: screen.frame.minX,
            y: ph - screen.frame.maxY,
            width:  screen.frame.width,
            height: screen.frame.height
        )
    }
}
