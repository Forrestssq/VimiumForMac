import Cocoa

final class OverlayWindow: NSWindow {

    private var targetScreen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var targets:    [HintedTarget] = []
    private var hintLabels: [HintLabel]   = []
    private var typedPrefix = ""
    private var onSelect:   (HintTarget) -> Void = { _ in }
    private var onDismiss:  () -> Void           = {}

    // MARK: - Mode

    private enum Mode { case hint; case nav(index: Int) }
    private var mode: Mode = .hint
    private var navCursor: NSView?

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
        ignoresMouseEvents   = true
        hasShadow            = false
        isReleasedWhenClosed = false

        let root = FlippedView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        contentView = root
        buildLabels(in: root)
        buildNavCursor(in: root)
    }

    private func buildNavCursor(in root: NSView) {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor  = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth  = 2.5
        v.layer?.cornerRadius = 4
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        v.isHidden = true
        root.addSubview(v)
        navCursor = v
    }

    // MARK: - Label layout
    //
    // All frames are in Quartz points (top-left of primary screen = origin, y↓).
    // FlippedView shares that orientation; subtract this screen's Quartz top-left offset.

    private func buildLabels(in root: NSView) {
        let primaryH  = NSScreen.screens[0].frame.height
        let quartzTop = primaryH - targetScreen.frame.maxY
        let quartzLeft = targetScreen.frame.minX

        for target in targets {
            let f = target.target.frame
            let labelW = CGFloat(target.hint.count * 9 + 10)
            let frame  = CGRect(x: f.minX - quartzLeft, y: f.minY - quartzTop,
                                width: labelW, height: 18)
            let label = HintLabel(frame: frame, hint: target.hint)
            root.addSubview(label)
            hintLabels.append(label)
        }
    }

    // MARK: - Lifecycle

    func show() {
        orderFrontRegardless()      // does NOT steal focus; menus stay open
    }

    func dismiss() {
        close()
    }

    // MARK: - Key handling (forwarded from AppDelegate's CGEventTap)

    private static let keyCodeToChar: [Int64: Character] = [
        0: "A", 1: "S", 2: "D", 3: "F", 5: "G",
        4: "H", 38: "J", 40: "K", 37: "L"
    ]

    func handleKeyCode(_ code: Int64) {
        switch mode {
        case .hint:         handleHintKey(code)
        case .nav(let idx): handleNavKey(code, currentIndex: idx)
        }
    }

    // MARK: - Hint mode

    private func handleHintKey(_ code: Int64) {
        switch code {
        case 53:        // Escape → exit
            onDismiss()
        case 48:        // Tab → enter nav mode near mouse
            enterNavMode(index: indexNearestMouse())
        case 51, 117:   // Delete / Forward-delete
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

    private func applyFilter() {
        for (i, label) in hintLabels.enumerated() {
            let hint = targets[i].hint
            if typedPrefix.isEmpty {
                label.isHidden = false
                label.setMatchedPrefix("")
            } else if hint.hasPrefix(typedPrefix) {
                label.isHidden = false
                label.setMatchedPrefix(typedPrefix)
                if hint == typedPrefix { onSelect(targets[i].target); return }
            } else {
                label.isHidden = true
            }
        }
    }

    // MARK: - Nav mode
    //
    // Tab (in hint mode) → enter nav mode; blue cursor highlights the selected element.
    // h/j/k/l  → move to nearest element left/down/up/right
    // d        → scroll down
    // u        → scroll up
    // Enter / Space → click selected element
    // Tab      → step to next element (wrap)
    // Escape   → exit hint mode entirely

    private func handleNavKey(_ code: Int64, currentIndex: Int) {
        switch code {
        case 53:        // Escape
            onDismiss()
        case 48:        // Tab → next element
            let next = (currentIndex + 1) % targets.count
            setNavIndex(next)
        case 36, 49:    // Return / Space → click
            onSelect(targets[currentIndex].target)
        case 4:         // H → left
            moveNav(from: currentIndex, dx: -1, dy:  0)
        case 38:        // J → down
            moveNav(from: currentIndex, dx:  0, dy:  1)
        case 40:        // K → up
            moveNav(from: currentIndex, dx:  0, dy: -1)
        case 37:        // L → right
            moveNav(from: currentIndex, dx:  1, dy:  0)
        case 2:         // D → scroll down  (negative = content moves up)
            sendScroll(wheel1: -150)
        case 32:        // U → scroll up
            sendScroll(wheel1:  150)
        default:
            break
        }
    }

    private func enterNavMode(index: Int) {
        let i = targets.isEmpty ? 0 : min(index, targets.count - 1)
        mode = .nav(index: i)
        for label in hintLabels { label.isHidden = true }
        navCursor?.isHidden = false
        if !targets.isEmpty { placeNavCursor(at: i) }
    }

    private func setNavIndex(_ i: Int) {
        mode = .nav(index: i)
        placeNavCursor(at: i)
    }

    private func placeNavCursor(at index: Int) {
        guard index < targets.count, let cursor = navCursor else { return }
        let f = targets[index].target.frame
        let primaryH   = NSScreen.screens[0].frame.height
        let quartzTop  = primaryH - targetScreen.frame.maxY
        let quartzLeft = targetScreen.frame.minX
        cursor.frame = CGRect(
            x: f.minX - quartzLeft - 3, y: f.minY - quartzTop - 3,
            width: f.width + 6, height: f.height + 6
        )
    }

    // Find nearest element strictly in direction (dx, dy).
    // Score = primary-axis distance + 0.3 × perpendicular distance.
    private func moveNav(from idx: Int, dx: Int, dy: Int) {
        guard !targets.isEmpty else { return }
        let cur = targets[idx].target.frame
        let cx = cur.midX, cy = cur.midY

        var bestIdx: Int? = nil
        var bestScore: CGFloat = .infinity

        for (i, t) in targets.enumerated() {
            guard i != idx else { continue }
            let f  = t.target.frame
            let tx = f.midX - cx
            let ty = f.midY - cy

            let primary: CGFloat
            let perp: CGFloat
            if dx != 0 {
                primary = CGFloat(dx) * tx
                perp    = abs(ty)
            } else {
                primary = CGFloat(dy) * ty
                perp    = abs(tx)
            }
            guard primary > 4 else { continue }    // must be in the right half-space

            let score = primary + 0.3 * perp
            if score < bestScore { bestScore = score; bestIdx = i }
        }

        if let next = bestIdx { setNavIndex(next) }
    }

    // Element whose center is closest to the current mouse position.
    private func indexNearestMouse() -> Int {
        guard !targets.isEmpty else { return 0 }
        let mouse  = NSEvent.mouseLocation     // NSScreen coords (y up from bottom)
        let ph     = NSScreen.screens[0].frame.height
        let qMouse = CGPoint(x: mouse.x, y: ph - mouse.y)  // → Quartz coords

        return targets.indices.min(by: { a, b in
            let fa = targets[a].target.frame, fb = targets[b].target.frame
            let da = hypot(fa.midX - qMouse.x, fa.midY - qMouse.y)
            let db = hypot(fb.midX - qMouse.x, fb.midY - qMouse.y)
            return da < db
        }) ?? 0
    }

    private func sendScroll(wheel1: Int32) {
        let src = CGEventSource(stateID: .hidSystemState)
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                        wheelCount: 1, wheel1: wheel1, wheel2: 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }

    // MARK: - NSWindow overrides

    override var canBecomeKey:  Bool { false }   // no focus steal; menus stay open
    override var canBecomeMain: Bool { false }
}

// MARK: -

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
