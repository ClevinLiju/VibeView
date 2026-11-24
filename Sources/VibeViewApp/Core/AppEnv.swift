import Foundation

/// Environment switches for developer hooks. Each `VIBEVIEW_<NAME>` variable is read first; the older
/// `VIBEVIEW_<NAME>` spelling keeps working so existing scripts don't break.
enum AppEnv {
    static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["VIBEVIEW_" + name], !v.isEmpty { return v }
        if let v = env["VIBEVIEW_" + name], !v.isEmpty { return v }
        return nil
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
