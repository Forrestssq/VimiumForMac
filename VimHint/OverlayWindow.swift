import Cocoa

final class OverlayWindow: NSWindow {

    private var targetScreen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var targets:   [HintedTarget] = []
    private var hintLabels:[HintLabel]    = []
    private var typedPrefix = ""
    private var onSelect:  (HintTarget) -> Void = { _ in }
    private var onDismiss: () -> Void           = {}

    // MARK: - Designated init (required to prevent ObjC runtime crash)

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    // MARK: - Convenience init

    convenience init(
        screen: NSScreen,
        targets: [HintedTarget],
        onSelect:  @escaping (HintTarget) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.targetScreen = screen
        self.targets      = targets
        self.onSelect     = onSelect
        self.onDismiss    = onDismiss
        configure()
    }

    // MARK: - Setup

    private func configure() {
        backgroundColor      = NSColor(white: 0, alpha: 0.10)
        isOpaque             = false
        level                = .screenSaver
        collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents   = true   // keyboard-driven; mouse passes through
        hasShadow            = false
        isReleasedWhenClosed = false

        let root = FlippedView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        contentView = root
        buildLabels(in: root)
    }

    // MARK: - Label layout
    //
    // All element frames are in Quartz points (top-left of primary screen = origin, y↓).
    // FlippedView (isFlipped=true) shares the same orientation.
    // For our screen: subtract the screen's Quartz top-left offset.

    private func buildLabels(in root: NSView) {
        let primaryH     = NSScreen.screens[0].frame.height
        let quartzTop    = primaryH - targetScreen.frame.maxY   // Quartz Y of this screen's top
        let quartzLeft   = targetScreen.frame.minX              // Quartz X = NSScreen X

        for target in targets {
            let f = target.target.frame   // Quartz absolute coords

            let viewX = f.minX - quartzLeft
            let viewY = f.minY - quartzTop

            // Label sized to hint text only (compact)
            let labelW = CGFloat(target.hint.count * 9 + 10)
            let frame  = CGRect(x: viewX, y: viewY, width: labelW, height: 18)

            let label = HintLabel(frame: frame, hint: target.hint)
            root.addSubview(label)
            hintLabels.append(label)
        }
    }

    // MARK: - Lifecycle

    func show() {
        // Use orderFront — do NOT make VimHint the active app so menus stay open.
        // Key events are captured by AppDelegate's CGEventTap instead.
        orderFrontRegardless()
    }

    func dismiss() {
        close()
    }

    // MARK: - Key handling (called from AppDelegate's CGEventTap)

    private static let keyCodeToChar: [Int64: Character] = [
        0: "A", 1: "S", 2: "D", 3: "F", 5: "G",
        4: "H", 38: "J", 40: "K", 37: "L"
    ]

    func handleKeyCode(_ code: Int64) {
        switch code {
        case 53:                                          // Escape
            onDismiss()
        case 51, 117:                                     // Delete / Forward-delete
            if !typedPrefix.isEmpty {
                typedPrefix.removeLast()
                applyFilter()
            }
        default:
            if let ch = Self.keyCodeToChar[code] {
                typedPrefix.append(ch)
                applyFilter()
            }
        }
    }

    // MARK: - Filtering

    private func applyFilter() {
        for (i, label) in hintLabels.enumerated() {
            let hint = targets[i].hint

            if typedPrefix.isEmpty {
                label.isHidden = false
                label.setMatchedPrefix("")
            } else if hint.hasPrefix(typedPrefix) {
                label.isHidden = false
                label.setMatchedPrefix(typedPrefix)

                if hint == typedPrefix {
                    onSelect(targets[i].target)
                    return
                }
            } else {
                label.isHidden = true
            }
        }
    }

    // MARK: - NSWindow overrides

    override var canBecomeKey:  Bool { false }   // intentionally not key — menus stay open
    override var canBecomeMain: Bool { false }
}

// MARK: - Helpers

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
