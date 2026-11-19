import Foundation

/// The APKs opened lately, newest first. Kept in the app's preferences on this Mac and nowhere else.
enum Recents {
    private static let key = "recentApks"
    private static let limit = 12

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
