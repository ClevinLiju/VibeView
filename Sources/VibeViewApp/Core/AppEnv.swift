import Foundation

/// Environment switches for developer hooks, read from `VIBEVIEW_<NAME>` variables.
enum AppEnv {
    static func value(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment["VIBEVIEW_" + name], !v.isEmpty else { return nil }
        return v
    }
    static func isSet(_ name: String) -> Bool { value(name) != nil }
}

/// The user-facing product name (module names keep their Mol* prefix).
enum AppInfo {
    static let name = "VibeView"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
