import Cocoa

/// Captures keyboard input system-wide during hint mode.
/// Uses both a local monitor (when overlay is key window) and a global monitor (fallback).
final class KeyHandler {
    static let shared = KeyHandler()
    private init() {}

    private var localMonitor:  Any?
    private var globalMonitor: Any?

    var onCharacter: ((String) -> Void)?
    var onEscape:    (() -> Void)?
    var onBackspace: (() -> Void)?

    func startCapturing() {
        let mask: NSEvent.EventTypeMask = [.keyDown]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
            return nil  // consume — prevent forwarding to other responders
        }

        // Global monitor is read-only (can't consume), but lets us react even if focus slips
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
        }
    }

    func stopCapturing() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func process(_ event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            onEscape?()
        case 51, 117:  // Delete / Forward-delete
            onBackspace?()
        default:
            guard let chars = event.charactersIgnoringModifiers?.uppercased() else { return }
            let valid = chars.filter { "ASDFGHJKL".contains($0) }
            if !valid.isEmpty { onCharacter?(valid) }
        }
    }
}
