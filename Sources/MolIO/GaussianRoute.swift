import Foundation

/// Implicit-solvent request parsed from SCRF=(...).
public struct GaussianSolvation: Sendable, Codable, Equatable {
    public var model: String?          // "PCM", "SMD", "CPCM", ... (nil = program default)
    public var solvent: String?        // "Water", ...
    public var options: [String] = []  // other raw options ("Read", "Dipole", ...)
    public init(model: String? = nil, solvent: String? = nil, options: [String] = []) {
        self.model = model; self.solvent = solvent; self.options = options
    }
    /// Keyword text, e.g. "SCRF=(SMD,Solvent=Water)".
    public var text: String {
        var parts: [String] = []
        if let m = model { parts.append(m) }
        if let s = solvent { parts.append("Solvent=\(s)") }
        parts.append(contentsOf: options)
        if parts.isEmpty { return "SCRF" }
        return parts.count == 1 ? "SCRF=\(parts[0])" : "SCRF=(\(parts.joined(separator: ",")))"
    }
}

/// A parsed route section ("#P B3LYP/6-31G(d) Opt Freq ...").
public struct GaussianRoute: Sendable, Codable, Equatable {
    public var printLevel: String = "#"      // "#", "#P", "#N", "#T"
    public var method: String = ""           // "B3LYP", "ONIOM(B3LYP/6-31G(d):UFF)"
    public var basis: String? = nil          // "6-31+G(d,p)", "Gen"
    public var jobTypes: [String] = []       // "Opt(ModRedundant,CalcFC)", "Freq", "TD(NStates=6)", ...
    public var keywords: [String] = []       // other keywords with options, verbatim
    public var solvation: GaussianSolvation? = nil

    public init(printLevel: String = "#", method: String = "", basis: String? = nil, jobTypes: [String] = [],
                keywords: [String] = [], solvation: GaussianSolvation? = nil) {
        self.printLevel = printLevel; self.method = method; self.basis = basis
        self.jobTypes = jobTypes; self.keywords = keywords; self.solvation = solvation
    }

    static let jobTypeNames: Set<String> = [
        "opt", "optimize", "freq", "frequency", "td", "scan", "irc", "ircmax", "sp", "force", "polar",
        "stable", "admp", "bomd", "eet", "nmr", "volume", "cphf", "gradient",
    ]

    static let knownMethods: Set<String> = [
        "HF", "B3LYP", "B3PW91", "B3P86", "BLYP", "BP86", "BPW91", "B97D", "B97D3", "B97-D", "PBE", "PBEPBE", "PBE1PBE",
        "PBE0", "M06", "M062X", "M06L", "M06HF", "M05", "M052X", "WB97XD", "WB97X", "WB97", "CAM-B3LYP", "LC-WPBE",
        "HSEH1PBE", "TPSS", "TPSSTPSS", "TPSSH", "B2PLYP", "MPW1PW91", "MP2", "MP3", "MP4", "MP4(SDQ)", "MP5", "CCSD",
        "CCSD(T)", "CCD", "CID", "CISD", "QCISD", "QCISD(T)", "CASSCF", "CBS-QB3", "CBS-4M", "G1", "G2", "G3", "G4",
        "W1U", "W1BD", "AM1", "PM3", "PM3MM", "PM6", "PM7", "PM6D3", "CNDO", "INDO", "MNDO", "ZINDO", "UFF", "DREIDING",
        "AMBER", "SVWN", "SVWN5", "B1B95", "BHANDHLYP", "BHANDH", "DFTB", "EDF1", "EDF2", "LSDA", "XALPHA", "B3LYP5",
        "MPW1K", "MPWPW91", "OLYP", "O3LYP", "X3LYP", "TD-B3LYP", "SAC-CI", "CIS", "STO-3G",
    ]

    static func isKnownMethod(_ piece: String) -> Bool {
        var u = piece.uppercased()
        if knownMethods.contains(u) { return true }
        if let p = u.firstIndex(of: "(") , knownMethods.contains(String(u[..<p])) { return true }
        for pre in ["RO", "U", "R"] where u.hasPrefix(pre) {
            u.removeFirst(pre.count)
            if knownMethods.contains(u) { return true }
            if let p = u.firstIndex(of: "("), knownMethods.contains(String(u[..<p])) { return true }
            return false
        }
        return false
    }

    /// Split keyword text into (name, option list) for "=X", "=(X,Y)" and "(X,Y)" forms.
    static func splitKeyword(_ piece: String) -> (name: String, options: [String]) {
        guard let idx = piece.firstIndex(where: { $0 == "=" || $0 == "(" }) else { return (piece, []) }
        let name = String(piece[..<idx])
        var rest = piece[idx...]
        if rest.hasPrefix("=") { rest = rest.dropFirst() }
        if rest.hasPrefix("("), rest.hasSuffix(")"), Self.parenSpansAll(rest) { rest = rest.dropFirst().dropLast() }
        return (name, splitTopLevel(rest, separators: [","]).filter { !$0.isEmpty })
    }

    private static func parenSpansAll(_ s: Substring) -> Bool {
        var depth = 0
        for (k, c) in s.enumerated() {
            if c == "(" { depth += 1 } else if c == ")" {
                depth -= 1
                if depth == 0 && k != s.count - 1 { return false }
            }
        }
        return depth == 0
    }

    /// Split at depth-0 separators (parentheses respected). Whitespace is only a separator when listed.
    static func splitTopLevel<S: StringProtocol>(_ s: S, separators: Set<Character>) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        for c in s {
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if depth == 0 && separators.contains(c) { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out
    }

    /// Parse route text. `text` may contain several lines (joined with spaces), mixed case, "!" comments.
    public init(parsing text: String) {
        // Join lines, drop comments.
        var joined = ""
        for l in splitLines(text) {
            var s = l
            if let b = s.firstIndex(of: "!") { s = s[..<b] }
            joined += s + " "
        }
        var body = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        var level = "#"
        if body.hasPrefix("#") {
            body.removeFirst()
            if let f = body.first, "PpNnTt".contains(f) {
                let after = body.dropFirst().first
                if after == nil || after == " " || after == "\t" { level = "#" + String(f).uppercased(); body.removeFirst() }
            }
        }
        self.printLevel = level
        // Pieces: whitespace separated at depth 0, whitespace inside parentheses removed.
        var pieces: [String] = []
        var cur = "", depth = 0
        for c in body {
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if c.isWhitespace {
                if depth > 0 { continue }
                if !cur.isEmpty { pieces.append(cur); cur = "" }
            } else { cur.append(c) }
        }
        if !cur.isEmpty { pieces.append(cur) }
        // Glue "opt = (a,b)", "opt (a,b)", "opt= x".
        var glued: [String] = []
        for p in pieces {
            if let last = glued.last, last.hasSuffix("=") || p.hasPrefix("=") || (p.hasPrefix("(") && !last.contains("/")) {
                glued[glued.count - 1] = last + p
            } else { glued.append(p) }
        }
        var haveMethod = false
        for p in glued {
            let (name, opts) = Self.splitKeyword(p)
            let lname = name.lowercased()
            if !haveMethod, lname.hasPrefix("oniom") {
                method = p; haveMethod = true
            } else if !haveMethod, let slash = Self.splitTopLevel(p, separators: ["/"]).first, slash.count < p.count {
                let parts = Self.splitTopLevel(p, separators: ["/"])
                method = parts[0]
                let b = parts.dropFirst().joined(separator: "/")
                basis = b.isEmpty ? nil : b
                haveMethod = true
            } else if !haveMethod && Self.isKnownMethod(p) {
                method = p; haveMethod = true
            } else if lname == "scrf" {
                var s = GaussianSolvation()
                let models: Set<String> = ["pcm", "cpcm", "iefpcm", "ipcm", "smd", "dipole", "onsager", "scipcm", "ief-pcm", "c-pcm"]
                for o in opts {
                    let lo = o.lowercased()
                    if lo.hasPrefix("solvent="), s.solvent == nil { s.solvent = String(o.dropFirst(8)) }
                    else if models.contains(lo), s.model == nil { s.model = o }
                    else { s.options.append(o) }
                }
                if solvation == nil { solvation = s } else { keywords.append(p) }
            } else if Self.jobTypeNames.contains(lname) {
                jobTypes.append(p)
            } else {
                keywords.append(p)
            }
        }
    }

    /// Route as one line of text.
    public var text: String {
        var parts: [String] = []
        if !method.isEmpty { parts.append(basis.map { "\(method)/\($0)" } ?? method) }
        else if let b = basis { parts.append("/\(b)") }
        parts.append(contentsOf: jobTypes)
        parts.append(contentsOf: keywords)
        if let s = solvation { parts.append(s.text) }
        return printLevel + (parts.isEmpty ? "" : " " + parts.joined(separator: " "))
    }

    // MARK: queries

    /// Options of a keyword (case-insensitive name), nil when the keyword is absent.
    public func options(of keyword: String) -> [String]? {
        let k = keyword.lowercased()
        for p in jobTypes + keywords {
            let (n, o) = Self.splitKeyword(p)
            if n.lowercased() == k { return o }
        }
        if k == "scrf", let s = solvation { return [s.model, s.solvent.map { "Solvent=\($0)" }].compactMap { $0 } + s.options }
        return nil
    }

    public func hasKeyword(_ keyword: String) -> Bool { options(of: keyword) != nil }

    /// True when option `option` of `keyword` is present (case-insensitive; also matches "name=value" by name).
    public func hasOption(_ option: String, of keyword: String) -> Bool {
        guard let o = options(of: keyword) else { return false }
        let t = option.lowercased()
        return o.contains { $0.lowercased() == t || $0.lowercased().hasPrefix(t + "=") }
    }

    var geomOptions: [String] { (options(of: "geom") ?? options(of: "geometry") ?? []).map { $0.lowercased() } }
    /// Geom=Check: geometry from the checkpoint file (title and charge/multiplicity still present).
    public var readsGeometryFromCheckpoint: Bool { geomOptions.contains("check") || geomOptions.contains("allcheck") }
    /// Geom=AllCheck: geometry, title and charge/multiplicity from the checkpoint file.
    public var readsEverythingFromCheckpoint: Bool { geomOptions.contains("allcheck") }
    public var readsConnectivity: Bool { geomOptions.contains("connectivity") }
    public var readsModRedundant: Bool {
        let o = (options(of: "opt") ?? options(of: "optimize") ?? []).map { $0.lowercased() }
        return o.contains("modredundant") || o.contains("addredundant") || geomOptions.contains("modredundant") || geomOptions.contains("addredundant")
    }
}
