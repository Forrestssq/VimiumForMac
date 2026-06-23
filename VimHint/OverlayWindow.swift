import Cocoa

final class OverlayWindow: NSWindow {

    // MARK: - Stored properties (var so convenience-init can set them after super.init)

    private var targetScreen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var targets: [HintedTarget] = []
    private var hintLabels: [HintLabel] = []
    private var typedPrefix = ""
    private var onSelect:  (HintTarget) -> Void = { _ in }
    private var onDismiss: () -> Void = {}

    // MARK: - Designated init (must override NSWindow's base init to prevent ObjC runtime crash)

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
        // Init the window at the screen's frame
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.targetScreen = screen
        self.targets      = targets
        self.onSelect     = onSelect
        self.onDismiss    = onDismiss
        configure()
    }

    // MARK: - Window configuration

    private func configure() {
        backgroundColor      = NSColor(white: 0, alpha: 0.12)
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

    // MARK: - Label construction
    //
    // Coordinate mapping:
    //   All element frames are in Quartz screen coords (y=0 at top of primary screen, y↓).
    //   FlippedView has isFlipped=true → (0,0) at top-left, y increases downward.
    //   For the primary screen, quartzY == flippedViewY.
    //   For secondary screens, subtract the screen's Quartz top offset.

    private func buildLabels(in root: NSView) {
        let primaryH = NSScreen.screens[0].frame.height
        // Top of our screen in Quartz coords
        let screenQuartzTop = primaryH - targetScreen.frame.maxY

        for target in targets {
            let f = target.target.frame  // Quartz coords

            let viewX = f.minX - targetScreen.frame.minX
            let viewY = f.minY - screenQuartzTop
            // Size label to exactly fit the hint text, not the element width
            let labelW = CGFloat(target.hint.count * 9 + 10)  // ~9px/char + 10px padding

            let label = HintLabel(frame: CGRect(x: viewX, y: viewY, width: labelW, height: 20), hint: target.hint)
            root.addSubview(label)
            hintLabels.append(label)
        }
    }

    // MARK: - Lifecycle

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        KeyHandler.shared.onCharacter = { [weak self] ch in
            DispatchQueue.main.async { self?.appendTyped(ch) }
        }
        KeyHandler.shared.onBackspace = { [weak self] in
            DispatchQueue.main.async { self?.deleteLastTyped() }
        }
        KeyHandler.shared.onEscape = { [weak self] in
            DispatchQueue.main.async { self?.onDismiss() }
        }
        KeyHandler.shared.startCapturing()
    }

    func dismiss() {
        KeyHandler.shared.stopCapturing()
        KeyHandler.shared.onCharacter = nil
        KeyHandler.shared.onBackspace = nil
        KeyHandler.shared.onEscape    = nil
        close()
    }

    // MARK: - Filtering

    private func appendTyped(_ chars: String) {
        typedPrefix += chars
        applyFilter()
    }

    private func deleteLastTyped() {
        guard !typedPrefix.isEmpty else { return }
        typedPrefix.removeLast()
        applyFilter()
    }

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

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - FlippedView

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
