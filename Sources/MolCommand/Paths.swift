import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Path helpers for commands.
public enum CommandPaths {
    /// Resolves `s` to a standardized file URL: `~` / `~/x` expand to the home directory,
    /// absolute paths are kept, relative paths are taken relative to `cwd`; `.`/`..` are collapsed.
    public static func resolve(_ s: String, cwd: URL) -> URL {
        var p = s
        if p == "~" || p.hasPrefix("~/") {
            p = NSHomeDirectory() + p.dropFirst(1)
        }
        let url: URL
        if p.hasPrefix("/") { url = URL(fileURLWithPath: p) }
        else { url = URL(fileURLWithPath: cwd.path).appendingPathComponent(p) }
        return url.standardizedFileURL
    }

    /// True if the last path component contains `*`, `?` or `[`.
    public static func hasWildcard(_ s: String) -> Bool {
        let last = s.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return last.contains { "*?[".contains($0) }
    }

    /// Expands a glob in the LAST path component (fnmatch syntax); the directory part must be literal.
    /// Names starting with "." only match patterns that start with ".". Results are sorted by path.
    /// Without wildcards returns `[resolve(s)]` (existing or not).
    public static func expand(_ s: String, cwd: URL) -> [URL] {
        guard hasWildcard(s) else { return [resolve(s, cwd: cwd)] }
        let full = resolve(s, cwd: cwd)
        let pattern = full.lastPathComponent
        let dir = full.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { fnmatch(pattern, $0, FNM_PERIOD) == 0 }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }
}
