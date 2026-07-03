import Cocoa
import ApplicationServices

// Chromium-based apps (Electron apps, Chrome-family browsers) ship with their
// accessibility tree disabled: until an assistive client announces itself, the
// web content is exposed as an empty stub, so an AX scan only finds the native
// window chrome (traffic lights, toolbar). VoiceOver announces itself by
// setting AXEnhancedUserInterface on the app element; Electron additionally
// supports the side-effect-free AXManualAccessibility flag for exactly this.
// Chromium may drop the tree again after a period without AX API usage, so the
// flag is (cheaply) re-applied on every app activation and every scan.
@MainActor
final class AXTreeEnabler {
    static let shared = AXTreeEnabler()
    private init() {}

    private var observer: NSObjectProtocol?

    enum ChromiumKind {
        case none
        case electron   // honors AXManualAccessibility
        case browser    // Chrome family: only honors AXEnhancedUserInterface
    }

    // Chromium browsers detected by bundle id (no Electron/CEF framework folder).
    private let chromiumBrowserPrefixes = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",   // Arc
    ]

    // Enable for the current frontmost app and every app activated from now
    // on, so the tree is usually already built when hints are requested.
    func start() {
        if let app = NSWorkspace.shared.frontmostApplication {
            enable(for: app)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor in AXTreeEnabler.shared.enable(for: app) }
        }
    }

    func enable(for app: NSRunningApplication) {
        let kind = chromiumKind(of: app)
        guard kind != .none else { return }
        let pid = app.processIdentifier
        // AXUIElementSetAttributeValue is blocking IPC into the target app —
        // keep it off the main thread in case that app is hung.
        DispatchQueue.global(qos: .userInitiated).async {
            let el = AXUIElementCreateApplication(pid)
            // Electron forks (QQNT etc.) may compile out AXManualAccessibility,
            // so also set the generic Chromium flag; unsupported ones just error.
            if kind == .electron {
                AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // Web-content app with a lazily-built, sparse AX tree.
    func isChromiumFamily(_ app: NSRunningApplication) -> Bool {
        chromiumKind(of: app) != .none
    }

    func chromiumKind(of app: NSRunningApplication) -> ChromiumKind {
        if let url = app.bundleURL,
           let entries = try? FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent("Contents/Frameworks").path) {
            if entries.contains("Electron Framework.framework") {
                return .electron
            }
            if entries.contains("Chromium Embedded Framework.framework") {
                return .browser
            }
            // Renamed Electron forks (QQ ships "QQNT.framework") still keep
            // the Chromium helper-app layout in Contents/Frameworks.
            if entries.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) {
                return .electron
            }
        }
        if let bid = app.bundleIdentifier,
           chromiumBrowserPrefixes.contains(where: { bid.hasPrefix($0) }) {
            return .browser
        }
        return .none
    }
}
