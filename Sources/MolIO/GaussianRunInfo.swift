import Foundation
import MolCore

// Calculation setup recovered from a Gaussian log: the route section(s) (joined across wrapped lines),
// Link 0 resources, charge/multiplicity, basis-function and electron counts, and run times.
// Multi-step (--Link1--) logs accumulate job types and wall times. Anything not printed stays nil.

/// Small text helpers shared by the Gaussian / Q-Chem / xtb run-info extractors.
enum RunInfoUtil {
    /// Display form of a basis-set name: "6-31g(d)" -> "6-31G(d)", "def2-svp" -> "def2-SVP", "cc-pvtz" -> "cc-pVTZ".
    static func basisDisplay(_ raw: String) -> String {
        let l = raw.lowercased()
        if l == "gen" { return "Gen" }
        if l == "genecp" { return "GenECP" }
        if l.hasPrefix("def2") || l.hasPrefix("ma-def2") || l.hasPrefix("x2c") {
            guard let i = l.firstIndex(where: { $0 == "2" }) else { return raw }
            let head = l[l.startIndex...i]
            return head + l[l.index(after: i)...].uppercased()
        }
        if let r = l.range(of: "cc-pv") {
            let pre = l[l.startIndex..<r.lowerBound] + "cc-pV"
            return pre + l[r.upperBound...].uppercased()
        }
        // Upper-case everything outside parentheses ("6-31G(d,p)").
        var out = "", depth = 0
        for ch in l {
            if ch == "(" { depth += 1 }
            out += depth > 0 ? String(ch) : String(ch).uppercased()
            if ch == ")" { depth = max(0, depth - 1) }
        }
        return out
    }

    /// "0 days  0 hours  1 minutes 23.4 seconds." or "0 d, 0 h, 0 min, 0.5 sec" -> seconds.
    static func duration(_ s: String) -> Double? {
        let p = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
        var total = 0.0, found = false
        for (i, w0) in p.enumerated() where i > 0 {
            guard let v = Double(p[i - 1]) else { continue }
            var w = w0.lowercased()
            while w.hasSuffix(".") { w.removeLast() }
            switch w {
            case "d", "day", "days": total += v * 86400; found = true
            case "h", "hr", "hrs", "hour", "hours": total += v * 3600; found = true
            case "m", "min", "mins", "minute", "minutes": total += v * 60; found = true
            case "s", "sec", "secs", "second", "seconds": total += v; found = true
            case "msec": total += v / 1000; found = true
            default: break
            }
        }
        return found ? total : nil
    }

    /// First integer found in `s` after `label` (case-insensitive), skipping ':' '|' '=' and spaces.
    static func intAfter(_ label: String, in s: String) -> Int? {
        guard let r = s.range(of: label, options: .caseInsensitive) else { return nil }
        for t in s[r.upperBound...].split(whereSeparator: { " :|=\t".contains($0) }) {
            if let v = Int(t) { return v }
            return nil
        }
        return nil
    }

    /// Append `s` unless already present.
    static func addUnique(_ arr: inout [String], _ s: String) { if !arr.contains(s) { arr.append(s) } }
}

extension GaussianLog {
    /// Calculation setup for a whole Gaussian log (all Link1 steps).
    public static func runInfo(text: String) -> CalculationInfo {
        // splitLines: "\r\n" is ONE Character in Swift, so splitting on "\n" would not split CRLF text.
        let lines = splitLines(text).map(String.init)
        var info = CalculationInfo()

        // Link 0 commands ("%nprocshared=4", "%mem=8GB").
        var cores: Int?, memBytes: Double?
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("%"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[t.index(after: t.startIndex)..<eq].lowercased()
            let val = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (key == "nprocshared" || key == "nproc"), cores == nil { cores = Int(val) }
            if key == "mem", memBytes == nil { memBytes = memoryBytes(val) }
        }
        info.cores = cores
        if let b = memBytes { info.memoryPerCoreMB = Int(b / 1_048_576.0 / Double(max(1, cores ?? 1))) }

        // Route sections.
        var routes: [String] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-----"), i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                var parts: [String] = []
                var j = i + 1
                while j < lines.count {
                    let u = lines[j].trimmingCharacters(in: .whitespaces)
                    if u.hasPrefix("-----") || u.isEmpty { break }
                    parts.append(u); j += 1
                }
                var joined = ""
                for p in parts {
                    if let last = joined.last, ",(=/".contains(last) { joined += p } else if joined.isEmpty { joined = p } else { joined += " " + p }
                }
                routes.append(joined)
                i = j
            }
            i += 1
        }
        info.keywords = routes

        // A ModRedundant section containing an "S" (scan) line.
        var hasScanLine = false
        for (k, l) in lines.enumerated() where l.contains("ModRedundant input section has been read") {
            for m in lines[(k + 1)..<min(lines.count, k + 25)] {
                let tk = m.split(separator: " ")
                if tk.count >= 3, tk.contains("S"), let f = tk.first, f.count == 1, "XBADLT".contains(f) { hasScanLine = true }
            }
        }

        var scrfSeen = false
        var prefix = ""
        for (idx, r) in routes.enumerated() {
            let p = parseRoute(r, hasScanLine: hasScanLine)
            if info.method == nil, let m = p.method { info.method = m; info.basisSet = p.basis; prefix = p.prefix }
            if info.basisSet == nil { info.basisSet = p.basis }
            if info.dispersion == nil { info.dispersion = p.dispersion }
            if info.integrationGrid == nil { info.integrationGrid = p.grid }
            if !scrfSeen, let s = p.scrf { info.solvationModel = s.model; info.solvent = s.solvent; scrfSeen = true }
            for j in p.jobs { RunInfoUtil.addUnique(&info.jobTypes, j) }
        }
        if info.jobTypes.isEmpty, !routes.isEmpty { info.jobTypes = ["Single point"] }

        // Charge/multiplicity, counts.
        for l in lines {
            if info.charge == nil, let r = l.range(of: "Charge =") {
                let tk = l[r.upperBound...].split(separator: " ")
                if tk.count >= 3, tk[1] == "Multiplicity", tk[2] == "=" || tk[2].hasPrefix("="), let c = Int(tk[0]) {
                    info.charge = c
                    info.multiplicity = tk.count >= 4 ? Int(tk[3]) : nil
                } else if tk.count >= 3, tk[1] == "Multiplicity", let c = Int(tk[0]) {
                    info.charge = c
                }
            }
            if info.basisFunctions == nil {
                if let r = l.range(of: "NBasis="), let v = Int(l[r.upperBound...].split(separator: " ").first ?? "") { info.basisFunctions = v }
                else if l.contains(" basis functions,") {
                    let tk = l.split(separator: " ")
                    if let k = tk.firstIndex(where: { $0 == "basis" }), k > 0, let v = Int(tk[k - 1]) { info.basisFunctions = v }
                }
            }
            if info.electrons == nil, l.contains("alpha electrons"), l.contains("beta electrons") {
                let nums = l.split(separator: " ").compactMap { Int($0) }
                if nums.count >= 2 { info.electrons = nums[0] + nums[1] }
            }
        }

        // Reference and method family from the route method, the multiplicity and SCF Done.
        if let m = info.method {
            let base = classify(m)
            info.methodFamily = base.family
            if base.family == "DFT" || base.family == "HF" || base.family == "MP2" || base.family == "Coupled cluster" {
                var ref = prefix                                 // "", "R", "U", "RO"
                if ref.isEmpty { ref = (info.multiplicity ?? 1) > 1 ? "U" : "R" }
                if let scf = lines.first(where: { $0.contains("SCF Done:") }), let o = scf.range(of: "E("),
                   let c = scf[o.upperBound...].firstIndex(of: ")") {
                    let tag = String(scf[o.upperBound..<c]).uppercased()
                    for pre in ["RO", "U", "R"] where tag.hasPrefix(pre) && tag.count > pre.count { ref = pre; break }
                }
                let ks = base.family == "DFT"
                info.reference = ref + (ks ? "KS" : "HF")
                if ref == "RO" { info.reference = ks ? "ROKS" : "ROHF" }
            }
            info.method = base.display
        }

        // Wall time: sum "Elapsed time:" over all steps.
        var wall = 0.0, haveWall = false
        for l in lines {
            if let r = l.range(of: "Elapsed time:"), let s = RunInfoUtil.duration(String(l[r.upperBound...])) { wall += s; haveWall = true }
        }
        if haveWall { info.wallTimeSeconds = wall }
        return info
    }

    // MARK: memory

    /// "8GB" / "1000MB" / "500MW" / plain word count -> bytes. GB=1024^3 bytes; Gaussian words are 8 bytes.
    static func memoryBytes(_ v: String) -> Double? {
        let u = v.uppercased().trimmingCharacters(in: .whitespaces)
        let digits = u.prefix(while: { $0.isNumber || $0 == "." })
        guard let n = Double(digits) else { return nil }
        let unit = u.dropFirst(digits.count)
        let k = 1024.0
        switch unit {
        case "", "W": return n * 8
        case "KB": return n * k
        case "MB": return n * k * k
        case "GB": return n * k * k * k
        case "TB": return n * k * k * k * k
        case "KW": return n * 8 * k
        case "MW": return n * 8 * k * k
        case "GW": return n * 8 * k * k * k
        default: return nil
        }
    }

    // MARK: method classification

    /// Strip a clear U/RO/R prefix; return display name, family and the stripped prefix.
    static func splitMethod(_ raw: String) -> (name: String, prefix: String) {
        let u = raw.uppercased()
        if GaussianRoute.knownMethods.contains(u) { return (raw, "") }
        for pre in ["RO", "U", "R"] where u.hasPrefix(pre) {
            let rest = String(u.dropFirst(pre.count))
            if GaussianRoute.knownMethods.contains(rest) || GaussianRoute.isKnownMethod(rest) { return (String(raw.dropFirst(pre.count)), pre) }
        }
        return (raw, "")
    }

    static func classify(_ method: String) -> (display: String, family: String?) {
        let u = method.uppercased()
        let display = u == "HF" ? "HF" : (u.hasPrefix("WB97") || u.hasPrefix("CAM") ? method.uppercased().replacingOccurrences(of: "WB97", with: "wB97") : method.uppercased())
        let semi: Set<String> = ["AM1", "PM3", "PM3MM", "PM6", "PM7", "PM6D3", "CNDO", "INDO", "MNDO", "ZINDO", "DFTB"]
        var family: String?
        if u == "HF" { family = "HF" }
        else if u.hasPrefix("MP2") { family = "MP2" }
        else if u.hasPrefix("MP") { family = "Perturbation theory" }
        else if u.hasPrefix("CCSD") || u == "CCD" || u.hasPrefix("QCISD") { family = "Coupled cluster" }
        else if semi.contains(u) { family = "Semiempirical" }
        else if u == "UFF" || u == "DREIDING" || u == "AMBER" { family = "Molecular mechanics" }
        else if u.hasPrefix("CASSCF") { family = "Multireference" }
        else if u.hasPrefix("CBS") || ["G1", "G2", "G3", "G4", "W1U", "W1BD"].contains(u) { family = "Composite" }
        else if ["CIS", "CID", "CISD", "SAC-CI"].contains(u) { family = "CI" }
        else if GaussianRoute.isKnownMethod(u) { family = "DFT" }
        return (display, family)
    }

    // MARK: route parsing

    struct RouteParse {
        var method: String?, basis: String?, prefix = "", dispersion: String?, grid: String?
        var scrf: (model: String?, solvent: String?)?
        var jobs: [String] = []
    }

    /// Split a route at top-level whitespace (and commas outside parentheses).
    static func routeTokens(_ route: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        for ch in route {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if depth == 0, ch == " " || ch == "\t" || ch == "," {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// "(a,b=c)" or "=(a,b)" or "=a" -> ["a","b=c"] (lower-case).
    static func optionList(_ s: String) -> [String] {
        var body = s
        if body.hasPrefix("=") { body.removeFirst() }
        if body.hasPrefix("("), body.hasSuffix(")") { body = String(body.dropFirst().dropLast()) }
        var out: [String] = [], cur = "", depth = 0
        for ch in body {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if depth == 0, ch == "," || ch == " " { if !cur.isEmpty { out.append(cur.lowercased()); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out
    }

    static func parseRoute(_ route: String, hasScanLine: Bool) -> RouteParse {
        var p = RouteParse()
        var toks = routeTokens(route)
        if let f = toks.first, f.hasPrefix("#") {
            var rest = String(f.dropFirst())
            if let c = rest.first, "PNTpnt".contains(c) { rest.removeFirst() }
            if rest.isEmpty { toks.removeFirst() } else { toks[0] = rest }
        }
        let basisPrefixes = ["STO-", "3-21", "6-31", "6-311", "DEF2", "CC-P", "AUG-CC", "LANL", "SDD", "CEP", "MIDI", "SV", "TZV", "QZV", "GEN"]
        for t in toks {
            // name = text before '=' or '(' ; a "/" before any of those marks method/basis.
            let stop = t.firstIndex(where: { $0 == "=" || $0 == "(" }) ?? t.endIndex
            let name = t[t.startIndex..<stop].lowercased()
            let slash = t.firstIndex(of: "/")
            if let s = slash, !t[..<s].contains("=") {
                var m = String(t[..<s]); var b = String(t[t.index(after: s)...])
                if m.isEmpty { continue }
                if let o = m.firstIndex(of: "("), m.uppercased().hasPrefix("ONIOM") { _ = o; continue }
                if p.method == nil {
                    if m.uppercased().hasPrefix("TD-") { m = String(m.dropFirst(3)) }
                    let sp = splitMethod(m)
                    p.method = sp.name; p.prefix = sp.prefix
                    if b.lowercased().hasSuffix("/auto") { b = String(b.dropLast(5)) }
                    p.basis = b.isEmpty ? nil : RunInfoUtil.basisDisplay(b)
                }
                continue
            }
            switch name {
            case "opt", "optimize":
                let o = optionList(String(t[stop...]))
                if o.contains("ts") || o.contains("qst2") || o.contains("qst3") { p.jobs.append("Transition state") }
                else if o.contains("modredundant") || o.contains("modred"), hasScanLine { p.jobs.append("Scan") }
                else { p.jobs.append("Optimization") }
            case "freq", "frequency": p.jobs.append("Frequencies")
            case "td", "td-dft":
                let low = String(t[stop...]).lowercased()
                var n = 3
                if let r = low.range(of: "nstates=") {
                    let d = low[r.upperBound...].prefix(while: { $0.isNumber })
                    if let v = Int(d) { n = v }
                }
                p.jobs.append("TD-DFT (\(n) states)")
            case "scan": p.jobs.append("Scan")
            case "irc", "ircmax": p.jobs.append("IRC")
            case "nmr": p.jobs.append("NMR")
            case "force": p.jobs.append("Gradient")
            case "sp": p.jobs.append("Single point")
            case "scrf":
                var model: String?, solvent: String?
                var check = false
                for o in optionList(String(t[stop...])) {
                    if o.hasPrefix("solvent=") { solvent = String(o.dropFirst(8)) }
                    else if o == "smd" { model = "SMD" } else if o == "cpcm" { model = "CPCM" }
                    else if o == "pcm" || o == "iefpcm" || o == "ipcm" { model = "PCM" }
                    else if o == "check" || o == "read" { check = true }
                }
                if !(check && model == nil && solvent == nil) {
                    p.scrf = (model ?? "PCM", solvent ?? "water")
                }
            case "empiricaldispersion", "emp":
                let o = optionList(String(t[stop...])).first ?? ""
                switch o {
                case "gd3bj": p.dispersion = "D3BJ"
                case "gd3": p.dispersion = "D3"
                case "gd2": p.dispersion = "D2"
                case "pfd": p.dispersion = "PFD"
                default: break
                }
            case "int", "integral":
                for o in optionList(String(t[stop...])) {
                    let g = o.hasPrefix("grid=") ? String(o.dropFirst(5)) : o
                    switch g {
                    case "ultrafine": p.grid = "UltraFine"
                    case "superfine": p.grid = "SuperFine"
                    case "fine": p.grid = "Fine"
                    case "coarse": p.grid = "Coarse"
                    default: if o.hasPrefix("grid="), !g.isEmpty { p.grid = g }
                    }
                }
            default:
                // Bare method / basis tokens ("hf", "6-31g(d)") when no method/basis token was seen.
                let up = t.uppercased()
                if p.method == nil, stop == t.endIndex, GaussianRoute.isKnownMethod(up) {
                    let sp = splitMethod(t); p.method = sp.name; p.prefix = sp.prefix
                } else if p.basis == nil, basisPrefixes.contains(where: { up.hasPrefix($0) }), !t.contains("=") {
                    p.basis = RunInfoUtil.basisDisplay(t)
                }
            }
        }
        return p
    }
}
