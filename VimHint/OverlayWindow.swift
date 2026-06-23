import Cocoa

final class OverlayWindow: NSWindow {
    private let targetScreen: NSScreen
    private var targets: [HintedTarget]
    private var hintLabels: [HintLabel] = []
    private var typedPrefix = ""
    private let onSelect:  (HintTarget) -> Void
    private let onDismiss: () -> Void

    // MARK: - Init

    init(
        screen: NSScreen,
        targets: [HintedTarget],
        onSelect:  @escaping (HintTarget) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.targetScreen = screen
        self.targets   = targets
        self.onSelect  = onSelect
        self.onDismiss = onDismiss

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        backgroundColor    = NSColor(white: 0, alpha: 0.12)
        isOpaque           = false
        level              = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true   // hints are keyboard-driven; mouse passes through
        hasShadow          = false
        isReleasedWhenClosed = false

        let root = FlippedView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView = root

        buildLabels(in: root)
    }

    // MARK: - Label construction

    // Coordinate mapping:
    //   screen.frame uses NSScreen coords (y=0 at bottom of primary screen, increases up).
    //   FlippedView has isFlipped=true → y=0 at top of view, increases down.
    //   Quartz screen coords: y=0 at top of primary screen, increases down.
    //
    //   For the primary screen: quartzY == flippedViewY (they share the same top-left origin).
    //   For a secondary screen offset by NSScreen.minX/minY we subtract that offset.

    private func buildLabels(in root: NSView) {
        let primaryH = NSScreen.screens[0].frame.height

        for target in targets {
            let f = target.target.frame  // Quartz coords

            // Convert Quartz origin to FlippedView-local coords
            let viewX = f.minX - targetScreen.frame.minX
            // Quartz top of this screen = primaryH - targetScreen.frame.maxY
            let screenQuartzTop = primaryH - targetScreen.frame.maxY
            let viewY = f.minY - screenQuartzTop

            // Size the label to fit two-letter hints
            let labelW: CGFloat = max(f.width < 20 ? 26 : min(f.width, 80), 26)
            let labelFrame = CGRect(x: viewX, y: viewY, width: labelW, height: 22)

            let label = HintLabel(frame: labelFrame, hint: target.hint)
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

    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Helpers

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

