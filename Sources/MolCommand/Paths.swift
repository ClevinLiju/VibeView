import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Path helpers for commands.
public enum CommandPaths {
    /// The user's home directory. Windows: `%USERPROFILE%` (then `%HOMEDRIVE%%HOMEPATH%`), elsewhere `NSHomeDirectory()`.
    public static var homeDirectory: String {
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        if let p = env["USERPROFILE"], !p.isEmpty { return p }
        if let d = env["HOMEDRIVE"], let p = env["HOMEPATH"], !d.isEmpty, !p.isEmpty { return d + p }
        #endif
        return NSHomeDirectory()
    }

    /// Resolves `s` to a standardized file URL: `~` / `~/x` expand to the home directory,
    /// absolute paths are kept, relative paths are taken relative to `cwd`; `.`/`..` are collapsed.
    /// On Windows `\` and `/` are both separators, `~\x` works too, and absolute means a drive path
    /// (`C:\x`, `C:/x`), a UNC path (`\\server\share\x`) or a rooted path (`\x`, taken on `cwd`'s drive).
    public static func resolve(_ s: String, cwd: URL) -> URL {
        #if os(Windows)
        return resolveWindows(s, cwd: cwd)
        #else
        var p = s
        if p == "~" || p.hasPrefix("~/") {
            p = NSHomeDirectory() + p.dropFirst(1)
        }
        let url: URL
        if p.hasPrefix("/") { url = URL(fileURLWithPath: p) }
        else { url = URL(fileURLWithPath: cwd.path).appendingPathComponent(p) }
        return url.standardizedFileURL
        #endif
    }

    /// True if the last path component contains `*`, `?` or `[`.
    public static func hasWildcard(_ s: String) -> Bool {
        let last = s.split(omittingEmptySubsequences: true, whereSeparator: isSeparator).last.map(String.init) ?? ""
        return last.contains { "*?[".contains($0) }
    }

    /// Expands a glob in the LAST path component (fnmatch syntax); the directory part must be literal.
    /// Names starting with "." only match patterns that start with ".". Results are sorted by path.
    /// Without wildcards returns `[resolve(s)]` (existing or not). Matching is case-insensitive on Windows.
    public static func expand(_ s: String, cwd: URL) -> [URL] {
        guard hasWildcard(s) else { return [resolve(s, cwd: cwd)] }
        let full = resolve(s, cwd: cwd)
        let pattern = full.lastPathComponent
        let dir = full.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { globMatch(pattern, $0) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Internals

    static func isSeparator(_ c: Character) -> Bool {
        #if os(Windows)
        return c == "/" || c == "\\"
        #else
        return c == "/"
        #endif
    }

    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return fnmatch(pattern, name, FNM_PERIOD) == 0
        #else
        return portableGlobMatch(pattern, name, caseInsensitive: true)
        #endif
    }

    /// fnmatch(3)-style matcher with FNM_PERIOD semantics (`*`, `?`, `[...]`, `[!...]`, ranges, `\` escape
    /// only when it precedes a glob metacharacter). Used where libc's fnmatch is unavailable (Windows).
    static func portableGlobMatch(_ pattern: String, _ name: String, caseInsensitive: Bool) -> Bool {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let n = Array(caseInsensitive ? name.lowercased() : name)
        // FNM_PERIOD: a leading "." must be matched by a literal "." in the pattern.
        if n.first == ".", p.first != "." { return false }

        // Matches a bracket expression starting at p[pi] ("["); returns (matched, index after "]") or nil if malformed.
        func bracket(_ pi: Int, _ c: Character) -> (Bool, Int)? {
            var i = pi + 1
            var negate = false
            if i < p.count, p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
            var matched = false
            var first = true
            while i < p.count {
                if p[i] == "]" && !first { return (matched != negate, i + 1) }
                first = false
                var lo = p[i]
                if lo == "\\", i + 1 < p.count { i += 1; lo = p[i] }
                if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                    var hi = p[i + 2]
                    var skip = 3
                    if hi == "\\", i + 3 < p.count { hi = p[i + 3]; skip = 4 }
                    if lo <= c && c <= hi { matched = true }
                    i += skip
                } else {
                    if c == lo { matched = true }
                    i += 1
                }
            }
            return nil
        }

        func match(_ pi: Int, _ ni: Int) -> Bool {
            var pi = pi, ni = ni
            while pi < p.count {
                let pc = p[pi]
                switch pc {
                case "*":
                    while pi < p.count, p[pi] == "*" { pi += 1 }
                    if pi == p.count { return true }
                    var k = ni
                    while k <= n.count {
                        if match(pi, k) { return true }
                        k += 1
                    }
                    return false
                case "?":
                    if ni >= n.count { return false }
                    pi += 1; ni += 1
                case "[":
                    if ni >= n.count { return false }
                    if let (ok, next) = bracket(pi, n[ni]) {
                        if !ok { return false }
                        pi = next; ni += 1
                    } else {
                        // malformed bracket: treat "[" literally
                        if n[ni] != "[" { return false }
                        pi += 1; ni += 1
                    }
                default:
                    var lit = pc
                    if pc == "\\", pi + 1 < p.count, "*?[]\\".contains(p[pi + 1]) { pi += 1; lit = p[pi] }
                    if ni >= n.count || n[ni] != lit { return false }
                    pi += 1; ni += 1
                }
            }
            return ni == n.count
        }
        return match(0, 0)
    }

    #if os(Windows)
    /// True for `C:` / `c:` prefixes.
    static func hasDriveLetter(_ p: String) -> Bool {
        let c = Array(p.prefix(2))
        return c.count == 2 && c[1] == ":" && c[0].isASCII && c[0].isLetter
    }

    /// The drive (`C:`) of a file URL, if any.
    static func drive(of url: URL) -> String? {
        var path = url.path
        if path.hasPrefix("/") && hasDriveLetter(String(path.dropFirst())) { path.removeFirst() }
        return hasDriveLetter(path) ? String(path.prefix(2)) : nil
    }

    static func resolveWindows(_ s: String, cwd: URL) -> URL {
        var p = s
        if p == "~" || p.hasPrefix("~/") || p.hasPrefix("~\\") {
            p = homeDirectory + p.dropFirst(1)
        }
        let url: URL
        if p.hasPrefix("\\\\") || p.hasPrefix("//") {
            // UNC: \\server\share\rest
            url = URL(fileURLWithPath: p.replacingOccurrences(of: "/", with: "\\"))
        } else if hasDriveLetter(p) {
            let rest = p.dropFirst(2)
            if rest.isEmpty || !(rest.first == "\\" || rest.first == "/") {
                // "C:" or drive-relative "C:foo": interpret relative to that drive's root.
                url = URL(fileURLWithPath: String(p.prefix(2)) + "\\" + rest)
            } else {
                url = URL(fileURLWithPath: p)
            }
        } else if p.hasPrefix("\\") || p.hasPrefix("/") {
            // Rooted without a drive: use the working directory's drive.
            if let d = drive(of: cwd) { url = URL(fileURLWithPath: d + p) }
            else { url = URL(fileURLWithPath: p) }
        } else {
            let rel = p.replacingOccurrences(of: "\\", with: "/")
            url = URL(fileURLWithPath: cwd.path, isDirectory: true).appendingPathComponent(rel)
        }
        return url.standardizedFileURL
    }
    #endif
}
