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
    ]

    func scan(pid: pid_t) async -> [AXResult] {
        await Task.detached(priority: .userInitiated) { [self] in
            var results: [AXResult] = []
            let app = AXUIElementCreateApplication(pid)
            traverse(element: app, results: &results, depth: 0)
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

        // Always recurse into children
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
        // AXValue is a CFType; force-cast is safe after the copy succeeds
        guard AXValueGetValue(posVal  as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize,  &size) else { return nil }

        // AX position is already in Quartz screen coordinates (top-left origin)
        return CGRect(origin: pos, size: size)
    }
}
