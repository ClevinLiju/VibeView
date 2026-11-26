import Foundation
import MolCore

// Structural check of a Gaussian input file (generated or edited by hand) before it is run.
// Gaussian reads its input as sections that each end at a blank line: Link 0 + route, title, charge/multiplicity +
// molecule, then optional sections (Z-matrix variables, connectivity, ModRedundant, basis, ...). The usual ways an
// input "has no atoms" for Gaussian:
//   - the title section is missing, so the charge line is read as the title and the atoms as the charge line
//     ("End of file in ZSymb");
//   - the molecule (or the last section) is not followed by a blank line ("End of file in ZSymb");
//   - Geom=Connectivity without a connectivity section ("End of file reading connectivity").
// The installed program can add its own limits (32-bit G09W fails right after Link 1 with %mem of 1.7 GB or more).

/// One problem found in an input file.
public struct InputIssue: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable { case error, warning }
    public var severity: Severity
    /// 1-based line in the input (after CRLF normalisation), nil for whole-file problems.
    public var line: Int?
    public var message: String
    /// True when `GaussianInputCheck.repair` fixes it.
    public var fixable: Bool
    public init(severity: Severity, line: Int?, message: String, fixable: Bool = false) {
        self.severity = severity; self.line = line; self.message = message; self.fixable = fixable
    }
}

/// What the installed Gaussian can do, as far as the input is concerned.
public struct GaussianInstallProfile: Sendable, Equatable {
    /// Display name, e.g. "Gaussian 09W (32-bit)".
    public var name: String
    /// Largest %mem that works, in MB (nil = no known limit).
    public var maxMemoryMB: Int?
    /// False for builds older than G09 rev. D.01 (no def2 basis set names, no EmpiricalDispersion=GD3/GD3BJ).
    public var hasDef2AndGD3: Bool

    public init(name: String, maxMemoryMB: Int? = nil, hasDef2AndGD3: Bool = true) {
        self.name = name; self.maxMemoryMB = maxMemoryMB; self.hasDef2AndGD3 = hasDef2AndGD3
    }

    /// 32-bit Gaussian runs out of address space: 1600 MB works with G09W A.02, 1700 MB fails in Link 1.
    public static let memoryLimit32BitMB = 1500

    /// Profile from what is known about the executable: its name ("g09", "g16"), whether it's a 32-bit image and
    /// the year it was linked.
    public static func detect(executableName: String, is32Bit: Bool, linkYear: Int?) -> GaussianInstallProfile {
        let stem = (executableName as NSString).deletingPathExtension.lowercased()
        let family = stem.hasPrefix("g09") ? "Gaussian 09" : stem.hasPrefix("g03") ? "Gaussian 03" : stem.hasPrefix("g16") ? "Gaussian 16" : "Gaussian"
        // G09 D.01 (2013) added GD3/GD3BJ and the def2 names; G16 has them all.
        let old = family == "Gaussian 03" || (family == "Gaussian 09" && (linkYear ?? 2013) < 2013)
        return GaussianInstallProfile(name: family + (is32Bit ? " (32-bit)" : ""), maxMemoryMB: is32Bit ? memoryLimit32BitMB : nil,
                                      hasDef2AndGD3: !old)
    }

    /// Ahlrichs basis names that older builds know, for the def2 names they don't. Gaussian's SVP is def-SVP, which
    /// is the same as def2-SVP for H-Kr; its QZVP is def2-QZVP; its TZVP is the older def-TZVP.
    public static let olderBasisNames: [String: (name: String, note: String)] = [
        "def2svp": ("SVP", "Gaussian's SVP (def-SVP, identical to def2-SVP for H-Kr)"),
        "def2tzvp": ("TZVP", "Gaussian's TZVP (the older def-TZVP, slightly smaller than def2-TZVP)"),
        "def2qzvp": ("QZVP", "Gaussian's QZVP (which is def2-QZVP)"),
    ]

    /// Changes `spec` so that this build can run it: %mem lowered to what a 32-bit build can allocate; on builds
    /// before G09 rev. D.01, def2 basis names replaced by the older Ahlrichs names and EmpiricalDispersion dropped.
    /// Returns one note per change, and a note for what can't be adapted (the job would stop with a syntax error).
    public func adapt(_ spec: inout CalcSpec) -> [String] {
        guard spec.program == .gaussian else { return [] }
        var notes: [String] = []
        if let cap = maxMemoryMB, spec.memoryMB > cap {
            notes.append("Memory lowered from \(spec.memoryMB) MB to \(cap) MB: \(name) can't allocate more (it stops right after Link 1).")
            spec.memoryMB = cap
        }
        guard !hasDef2AndGD3 else { return notes }
        let key = spec.basis.lowercased().replacingOccurrences(of: "-", with: "")
        if key.hasPrefix("def2") {
            if let alt = Self.olderBasisNames[key] {
                notes.append("\(spec.basis) replaced by \(alt.note): \(name) builds before rev. D.01 don't know the def2 names.")
                spec.basis = alt.name
            } else {
                notes.append("\(name) builds before rev. D.01 don't know \(spec.basis): the job will stop with a syntax error. Use def2-SVP, def2-TZVP, def2-QZVP or a Pople basis.")
            }
        }
        if let d = spec.dispersion, d != .d4 {
            notes.append("Dispersion correction (\(d == .d3bj ? "GD3BJ" : "GD3")) left out: \(name) builds before rev. D.01 have no EmpiricalDispersion keyword. wB97X-D and B97-D include dispersion.")
            spec.dispersion = nil
        }
        return notes
    }
}

public enum GaussianInputCheck {
    /// Problems in `text`, in file order. Errors stop Gaussian; warnings may not.
    public static func check(_ text: String, profile: GaussianInstallProfile? = nil) -> [InputIssue] {
        analyse(normalizedLines(text), profile: profile).map(\.issue)
    }

    /// `text` with the fixable problems repaired (missing title section, missing blank line at the end of a
    /// section, %mem above the program's limit), and a description of each fix. Line endings become "\n".
    public static func repair(_ text: String, profile: GaussianInstallProfile? = nil) -> (text: String, fixes: [String]) {
        var lines = normalizedLines(text)
        var fixes: [String] = []
        for _ in 0..<12 {
            guard let f = analyse(lines, profile: profile).first(where: { $0.fix != nil }), let fix = f.fix else { break }
            switch fix {
            case .insert(let at, let new): lines.insert(contentsOf: new, at: at)
            case .replace(let at, let new): lines[at] = new
            }
            fixes.append(f.issue.message)
        }
        return (lines.joined(separator: "\n"), fixes)
    }

    /// The memory of a %mem value in MB ("4GB", "500MW", "16000000" words), nil when it can't be read.
    public static func memoryMB(_ value: String) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = v.prefix { $0.isNumber || $0 == "." }
        guard let n = Double(digits), n >= 0 else { return nil }
        let unit = v.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let mb = 1024.0 * 1024.0
        let bytes: Double
        switch unit {
        case "", "W": bytes = n * 8
        case "KB": bytes = n * 1024
        case "MB": bytes = n * mb
        case "GB": bytes = n * mb * 1024
        case "TB": bytes = n * mb * 1024 * 1024
        case "KW": bytes = n * 8 * 1024
        case "MW": bytes = n * 8 * mb
        case "GW": bytes = n * 8 * mb * 1024
        case "TW": bytes = n * 8 * mb * 1024 * 1024
        default: return nil
        }
        return bytes / mb
    }

    /// Why a Gaussian job stopped, from its output file: Gaussian's message before "Error termination", or a note
    /// when the output ends after the header or after Link 1. Nil when the output shows no failure.
    public static func failureReason(output text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("Normal termination") }) && !lines.contains(where: { $0.hasPrefix("Error termination") }) { return nil }
        // Route / input syntax errors: "QPErr --- A syntax error was detected in the input line." then the line and a "'" marker.
        if let q = lines.firstIndex(where: { $0.hasPrefix("QPErr") }), q + 2 < lines.count {
            let raw = text.split(whereSeparator: \.isNewline).map(String.init)
            if let rq = raw.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("QPErr") }), rq + 2 < raw.count,
               let col = raw[rq + 2].firstIndex(of: "'").map({ raw[rq + 2].distance(from: raw[rq + 2].startIndex, to: $0) }) {
                let l = Array(raw[rq + 1])
                var a = min(col, max(0, l.count - 1)), b = a
                while a > 0, l[a - 1] != " " { a -= 1 }
                while b < l.count, l[b] != " " { b += 1 }
                let word = String(l[a..<b]).trimmingCharacters(in: .whitespaces)
                if !word.isEmpty { return "the route has a keyword this Gaussian doesn't know: syntax error at '\(word)'" }
            }
            return "syntax error in the route section"
        }
        if let k = lines.firstIndex(where: { $0.hasPrefix("Error termination") }) {
            let msg = lines[..<k].filter { !$0.isEmpty && !$0.hasPrefix("Error termination") }.suffix(2)
            let link = lines[k].components(separatedBy: " in ").dropFirst().first?.components(separatedBy: " at ").first
            return (msg.isEmpty ? "error termination" : msg.joined(separator: " ")) + (link.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")
        }
        if !lines.contains(where: { $0.hasPrefix("Gaussian 09:") || $0.hasPrefix("Gaussian 16:") || $0.contains("Revision") }),
           lines.contains(where: { $0.hasPrefix("Entering Gaussian System") }) {
            return "Gaussian stopped before Link 1 printed anything (it could not start or could not open its files)"
        }
        if let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("Leave Link    1") || last.hasPrefix("Leave Link 1") {
            return "Gaussian stopped right after Link 1 (32-bit Gaussian 09W does this when %mem is more than it can allocate)"
        }
        return nil
    }

    // MARK: - analysis

    private enum Fix { case insert(Int, [String]), replace(Int, String) }
    private struct Found { var issue: InputIssue; var fix: Fix? }
    private typealias Report = (InputIssue.Severity, Int?, String, Fix?) -> Void

    /// One section: lines up to (not including) the blank line that ends it.
    private struct Section {
        var start: Int            // index of the first line
        var lines: [String]
        var terminated: Bool      // a blank line follows
        var end: Int { start + lines.count }   // index of the terminating blank line (or of the end of the input)
    }

    static func normalizedLines(_ text: String) -> [String] {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return splitLines(t).map(String.init)
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func fields(_ s: String) -> [String] {
        var t = s
        if let b = t.firstIndex(of: "!") { t = String(t[..<b]) }
        return t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
    }

    private static func isNumber(_ s: String) -> Bool {
        Double(s.replacingOccurrences(of: "D", with: "E").replacingOccurrences(of: "d", with: "e")) != nil
    }

    private static func isChargeMultiplicityLine(_ s: String) -> Bool {
        let f = fields(s)
        return f.count >= 2 && f.count % 2 == 0 && f.allSatisfy { Int($0) != nil }
    }

    /// Atomic number of an atom label: "C", "C1", "C-CA-0.1", "C(Fragment=1)", "6", "Bq", "X" (0 for dummies / ghosts).
    static func elementOf(_ label: String) -> Int? {
        var l = Substring(label)
        if let p = l.firstIndex(where: { $0 == "(" || $0 == "-" }) { l = l[..<p] }
        if let z = Int(l) { return z >= 0 && z <= 118 ? z : nil }
        let letters = String(l.prefix { $0.isLetter })
        let rest = l.dropFirst(letters.count)
        guard !letters.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "_" }) else { return nil }
        if letters.lowercased() == "bq" { return 0 }
        if letters.count == 1, letters.uppercased() == "X" { return 0 }
        guard letters.count <= 2 else { return nil }
        return IOElements.atomicNumber(label: letters)
    }

    /// An atom row: element label, then nothing (first Z-matrix row) or numbers / variable names.
    private static func looksLikeAtomLine(_ s: String, needCoordinates: Bool = false) -> Bool {
        let f = fields(s)
        guard let first = f.first, elementOf(first) != nil else { return false }
        if Int(first) != nil && f.count < 4 { return false }
        let nums = f.dropFirst().filter(isNumber).count
        return needCoordinates ? nums >= 3 : (f.count == 1 || nums >= 1)
    }

    private static func sections(_ lines: [String], from: Int, to: Int) -> [Section] {
        var out: [Section] = []
        var i = from
        while i < to {
            var cur: [String] = []
            let start = i
            while i < to, !isBlank(lines[i]) { cur.append(lines[i]); i += 1 }
            let terminated = i < to
            out.append(Section(start: start, lines: cur, terminated: terminated))
            if terminated { i += 1 }   // the blank line
        }
        return out
    }

    private static let knownLink0: Set<String> = ["chk", "oldchk", "mem", "nproc", "nprocs", "nprocshared", "nprocl", "cpu",
                                                  "lindaworkers", "rwf", "int", "d2e", "kjob", "save", "nosave", "subst",
                                                  "debug", "gpucpu", "scr", "errorsave", "nosaveall", "saveall"]

    private static func analyse(_ lines: [String], profile: GaussianInstallProfile?) -> [Found] {
        var out: [Found] = []
        let report: Report = { sev, line, msg, fix in
            out.append(Found(issue: InputIssue(severity: sev, line: line.map { $0 + 1 }, message: msg, fixable: fix != nil), fix: fix))
        }
        guard let lastContent = lines.lastIndex(where: { !isBlank($0) }) else {
            report(.error, nil, "the input is empty", nil); return out
        }
        // splitLines yields one "" after a final "\n": that is the end of the last line, not a blank line.
        let count = lines.last == "" ? lines.count - 1 : lines.count
        var starts = [0]
        for k in 0..<count where lines[k].trimmingCharacters(in: .whitespaces).lowercased() == "--link1--" { starts.append(k + 1) }
        for (n, s) in starts.enumerated() {
            let e = n + 1 < starts.count ? starts[n + 1] - 1 : count
            let step = starts.count > 1 ? "step \(n + 1): " : ""
            analyseStep(lines, s..<max(s, e), profile: profile) { report($0, $1, step + $2, $3) }
        }
        // The file must end with a blank line after the last section.
        let trailingBlanks = count - 1 - lastContent
        if trailingBlanks < 1, !out.contains(where: { $0.issue.line == lastContent + 1 && $0.fix != nil }) {
            report(.error, lastContent, "the input must end with a blank line (Gaussian stops with \"End of file\" otherwise)",
                   .insert(lastContent + 1, lines.last == "" ? [""] : ["", ""]))
        }
        return out
    }

    private static func analyseStep(_ lines: [String], _ r: Range<Int>, profile: GaussianInstallProfile?, _ report: Report) {
        var i = r.lowerBound
        // A blank line inserted at the very end needs a second "" (the last line's own newline).
        func blankAfter(_ end: Int) -> [String] { end >= lines.count ? ["", ""] : [""] }
        while i < r.upperBound, isBlank(lines[i]) { i += 1 }
        guard i < r.upperBound else { report(.error, r.lowerBound, "the job step is empty", nil); return }
        if i > r.lowerBound { report(.warning, r.lowerBound, "blank line before the Link 0 / route section", nil) }
        // Link 0 lines, then the route (one or more lines starting with '#', ending at a blank line).
        func trimmed(_ k: Int) -> String { lines[k].trimmingCharacters(in: .whitespaces) }
        while i < r.upperBound, trimmed(i).hasPrefix("%") || trimmed(i).hasPrefix("!") {
            let l = trimmed(i)
            if l.hasPrefix("%") {
                var body = String(l.dropFirst())
                if let b = body.firstIndex(of: "!") { body = String(body[..<b]) }
                let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let key = (parts.first ?? "").lowercased()
                let value = parts.count > 1 ? parts[1] : ""
                if !knownLink0.contains(key) { report(.warning, i, "unknown Link 0 command '%\(key)'", nil) }
                if key == "mem" {
                    if let mb = memoryMB(value) {
                        if let p = profile, let cap = p.maxMemoryMB, mb > Double(cap) {
                            report(.error, i, "%mem=\(value) is more than \(p.name) can allocate (it stops right after Link 1); use at most \(cap)MB",
                                   .replace(i, "%mem=\(cap)MB"))
                        }
                    } else { report(.error, i, "can't read the memory amount in '%mem=\(value)'", nil) }
                }
                if ["nproc", "nprocs", "nprocshared"].contains(key), (Int(value) ?? 0) < 1 {
                    report(.error, i, "%\(key) needs a positive number of processors", nil)
                }
            }
            i += 1
        }
        guard i < r.upperBound, trimmed(i).hasPrefix("#") else {
            report(.error, min(i, r.upperBound - 1), "missing route section: expected a line starting with '#' after the Link 0 lines", nil); return
        }
        let secs = sections(lines, from: i, to: r.upperBound)
        let routeSec = secs[0]
        if let k = routeSec.lines.firstIndex(where: { isChargeMultiplicityLine($0) || looksLikeAtomLine($0, needCoordinates: true) }) {
            report(.error, routeSec.start + k, "the route section must end with a blank line (this line looks like part of the title or the molecule)", nil)
        }
        let route = GaussianRoute(parsing: routeSec.lines.joined(separator: "\n"))
        if let p = profile, !p.hasDef2AndGD3 {
            let words = routeSec.lines.joined(separator: " ").lowercased()
            // Both stop G09 A.02 in Link 1 with "QPErr --- A syntax error" / "An ambiguous keyword".
            if words.contains("def2") {
                report(.error, routeSec.start, "\(p.name) builds before rev. D.01 don't know the def2 basis set names (syntax error in Link 1); use SVP, TZVP, QZVP or a Pople basis", nil)
            }
            if words.contains("empiricaldispersion") || words.contains("gd3") {
                report(.error, routeSec.start, "\(p.name) builds before rev. D.01 have no EmpiricalDispersion keyword (syntax error in Link 1); use wB97XD or B97D for built-in dispersion", nil)
            }
        }
        guard routeSec.terminated else { report(.error, routeSec.end - 1, "the input ends after the route section", nil); return }
        if route.readsEverythingFromCheckpoint { return }   // Geom=AllCheck: no title / charge / molecule
        guard secs.count >= 2 else { report(.error, routeSec.end, "missing title section", nil); return }
        // Title: one section of free text (may be empty). If it starts with a charge line followed by atoms, it's missing.
        let title = secs[1]
        if title.lines.count >= 2, isChargeMultiplicityLine(title.lines[0]), looksLikeAtomLine(title.lines[1]) {
            report(.error, title.start, "the title section is missing: Gaussian would read this charge/multiplicity line as the title and find no atoms",
                   .insert(title.start, ["Title Card Required", ""]))
            return
        }
        guard title.terminated, secs.count >= 3, let cmLine = secs[2].lines.first else {
            report(.error, title.end, "missing charge and multiplicity line after the title", nil)
            return
        }
        let molSec = secs[2]
        let cmFields = fields(cmLine)
        let cms = cmFields.compactMap { Int($0) }
        if cms.count != cmFields.count || cms.count < 2 || cms.count % 2 != 0 {
            report(.error, molSec.start, "expected 'charge multiplicity' (e.g. '0 1') but found '\(cmLine.trimmingCharacters(in: .whitespaces))'", nil)
            return
        }
        if stride(from: 1, to: cms.count, by: 2).contains(where: { cms[$0] < 1 }) { report(.error, molSec.start, "multiplicity must be 1 or more", nil) }
        if route.readsGeometryFromCheckpoint {
            if molSec.lines.count > 1 {
                report(.warning, molSec.start + 1, "Geom=Check reads the geometry from the checkpoint; these lines are read as the next section", nil)
            }
            if !molSec.terminated {
                report(.error, molSec.end - 1, "the charge/multiplicity line must be followed by a blank line", .insert(molSec.end, blankAfter(molSec.end)))
            }
            return
        }
        // Molecule rows (Cartesian or Z-matrix), possibly followed by "Variables:" in the same section.
        var rows: [(Int, String)] = []
        var zmatrix = false
        for (k, l) in molSec.lines.enumerated().dropFirst() {
            let low = l.trimmingCharacters(in: .whitespaces).lowercased()
            if low.hasPrefix("variables") || low.hasPrefix("constants") { zmatrix = true; break }
            rows.append((molSec.start + k, l))
        }
        if rows.isEmpty {
            report(.error, molSec.start, "no atoms after the charge/multiplicity line (the molecule specification is empty)", nil)
            return
        }
        var electrons = 0, known = true
        for (n, (ln, l)) in rows.enumerated() {
            let f = fields(l)
            guard let label = f.first else { continue }
            guard let z = elementOf(label) else {
                report(.error, ln, "'\(label)' is not an element symbol or atomic number", nil); known = false; continue
            }
            electrons += z
            if (n == 0 && f.count == 1) || f.count == 3 || f.dropFirst().contains(where: { !isNumber($0) && !["H", "M", "L"].contains($0.uppercased()) }) {
                zmatrix = true
            }
        }
        if known {
            let ne = electrons - cms[0]
            if ne < 0 { report(.error, molSec.start, "charge \(cms[0]) is larger than the nuclear charge \(electrons)", nil) }
            else if (ne + cms[1] - 1) % 2 != 0 {
                report(.error, molSec.start, "charge \(cms[0]) and multiplicity \(cms[1]) are impossible with \(ne) electrons", nil)
            }
        }
        guard molSec.terminated else {
            report(.error, molSec.end - 1, "the molecule specification must be followed by a blank line (Gaussian stops with \"End of file in ZSymb\")",
                   .insert(molSec.end, blankAfter(molSec.end)))
            return
        }
        // Z-matrix variables / constants sections.
        var next = 3
        while zmatrix, next < secs.count, let f = secs[next].lines.first {
            let low = f.trimmingCharacters(in: .whitespaces).lowercased()
            let isVar = low.hasPrefix("variables") || low.hasPrefix("constants") || secs[next].lines.allSatisfy { l in
                let t = fields(l.replacingOccurrences(of: "=", with: " "))
                return t.count >= 2 && (t[0].first?.isLetter ?? false) && isNumber(t[1]) && (t[0].count > 1 || t[1].contains("."))
            }
            guard isVar else { break }
            if !secs[next].terminated {
                report(.error, secs[next].end - 1, "the variables section must be followed by a blank line", .insert(secs[next].end, blankAfter(secs[next].end))); return
            }
            next += 1
        }
        checkTrailing(secs, from: next, rows: rows.count, route: route, lineCount: lines.count, report)
    }

    /// Connectivity and ModRedundant sections after the molecule.
    private static func checkTrailing(_ secs: [Section], from: Int, rows n: Int, route: GaussianRoute, lineCount: Int, _ report: Report) {
        var next = from
        let endLine = secs.last?.end
        func connectivityProblems(_ s: Section) -> [(Int, String)] {
            var out: [(Int, String)] = []
            for (k, l) in s.lines.enumerated() {
                let f = fields(l)
                guard let a = f.first.flatMap({ Int($0) }) else { out.append((s.start + k, "connectivity lines start with an atom number")); continue }
                if a < 1 || a > n { out.append((s.start + k, "connectivity atom \(a) is out of range 1-\(n)")) }
                if f.count % 2 == 0 { out.append((s.start + k, "connectivity line \(a) needs 'atom bond-order' pairs")); continue }
                for j in stride(from: 1, to: f.count - 1, by: 2) {
                    if Int(f[j]).map({ $0 < 1 || $0 > n }) ?? true {
                        out.append((s.start + k, "connectivity line \(a): '\(f[j])' is not an atom number 1-\(n)"))
                    }
                    if !isNumber(f[j + 1]) { out.append((s.start + k, "connectivity line \(a): bond order '\(f[j + 1])' is not a number")) }
                }
            }
            return out
        }
        if route.readsConnectivity {
            guard next < secs.count, !secs[next].lines.isEmpty else {
                report(.error, endLine, "Geom=Connectivity is in the route but the connectivity section is missing (Gaussian stops with \"End of file reading connectivity\")", nil)
                return
            }
            let c = secs[next]
            for (ln, m) in connectivityProblems(c) { report(.error, ln, m, nil) }
            if c.lines.count != n { report(.warning, c.start, "the connectivity section has \(c.lines.count) lines for \(n) atoms (one line per atom is expected)", nil) }
            if !c.terminated { report(.error, c.end - 1, "the connectivity section must be followed by a blank line", .insert(c.end, c.end >= lineCount ? ["", ""] : [""])); return }
            next += 1
        } else if next < secs.count, secs[next].lines.count == n, connectivityProblems(secs[next]).isEmpty,
                  secs[next].lines.first.flatMap({ fields($0).first }) == "1" {
            report(route.readsModRedundant ? .error : .warning, secs[next].start,
                   route.readsModRedundant
                    ? "this looks like a connectivity section but the route has no Geom=Connectivity: Gaussian reads it as ModRedundant input"
                    : "this looks like a connectivity section but the route has no Geom=Connectivity, so Gaussian ignores it", nil)
            next += 1
        }
        // Opt=ModRedundant with no section after the molecule is fine (G09 reads an empty one at the end of the file).
    }
}
