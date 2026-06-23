import Foundation

/// Persists a list of bundle IDs that VimHint will skip.
final class BlockedApps {
    static let shared = BlockedApps()
    private let key = "VimHintBlockedBundleIDs"
    private init() {}

    func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isBlocked(_ bundleID: String) -> Bool {
        all().contains(bundleID)
    }

    func add(_ bundleID: String) {
        var list = all()
        if !list.contains(bundleID) { list.append(bundleID) }
        UserDefaults.standard.set(list, forKey: key)
    }

    func remove(_ bundleID: String) {
        UserDefaults.standard.set(all().filter { $0 != bundleID }, forKey: key)
    }
}
