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
    func scan(root: AXUIElement) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            traverse(element: root, results: &results, depth: 0)
            return results
        }.value
    }

    // Single-app scan, optionally restricted to elements inside `bounds`.
    func scan(pid: pid_t, bounds: CGRect? = nil) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            let app = AXUIElementCreateApplication(pid)
            traverse(element: app, results: &results, depth: 0)
            if let b = bounds {
                results = results.filter { b.intersects($0.frame) }
            }
            return results
        }.value
    }

    // MARK: - Traversal

    private func traverse(element: AXUIElement, results: inout [AXResult], depth: Int) {
        guard depth < 25 else { return }

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)

        if roleResult == .success, let role = roleRef as? String, interactableRoles.contains(role) {
            if isEnabled(element), let frame = quartzFrame(element), !frame.isEmpty {
                results.append(AXResult(frame: frame, element: element))
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            traverse(element: child, results: &results, depth: depth + 1)
        }
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref) == .success,
              let val = ref as? Bool else { return true }
        return val
    }

    private func quartzFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }

        var pos  = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal  as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize,  &size) else { return nil }

        return CGRect(origin: pos, size: size)
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
