import Foundation
import MolCore

// Calculation setup recovered from an ORCA output: the echoed input ("|  1> ! B3LYP def2-SVP Opt"),
// the "Your calculation utilizes ..." banners, and the SCF SETTINGS block. Only what the output states
// is filled in. Works on truncated logs: anything not reached stays nil.

extension OrcaOutput {
    public static func runInfo(text: String, inputLines: [String], keywordLines: [String]) -> CalculationInfo {
        var info = CalculationInfo()
        info.keywords = keywordLines

        // Keyword tokens from every "!" line, upper-cased for matching but kept in original spelling.
        let tokens: [String] = keywordLines.flatMap { line in
            line.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        var blocks = OrcaInputBlocks(lines: inputLines)

        // Method: first token that names a known method; composite "-3c" methods carry their basis.
        for t in tokens {
            let u = t.uppercased()
            if let fam = OrcaKeywords.methodFamily(u) {
                // "! UHF STO-3G" is the HF method with a UHF reference.
                info.method = fam == "HF" ? "HF" : t
                info.methodFamily = fam
                if fam == "HF", u != "HF" { info.reference = u }
                break
            }
        }
        // Basis: ORCA states it explicitly; fall back to a basis-looking keyword.
        info.basisSet = firstMatch(text, prefix: "Your calculation utilizes the basis:")
            ?? tokens.first(where: { OrcaKeywords.isBasis($0.uppercased()) })
        if let aux = tokens.first(where: { let u = $0.uppercased(); return u.hasPrefix("DEF2/") || u.hasSuffix("/C") || u.hasSuffix("/J") || u.hasSuffix("/JK") || u == "AUTOAUX" }) {
            info.auxiliaryBasis = aux
        } else if text.contains("Assigning Def2/J") {
            info.auxiliaryBasis = "def2/J"
        }
        info.dispersion = tokens.first(where: { ["D3BJ", "D3ZERO", "D3", "D4", "D2", "D3TZ"].contains($0.uppercased()) })
            .map { $0.uppercased() == "D3" ? "D3" : $0.uppercased() }
        for t in tokens {
            let u = t.uppercased()
            if ["RIJCOSX", "RIJK", "RIJONX", "RI", "NORI", "COSX"].contains(u) || u.hasPrefix("DLPNO") && !info.approximations.contains("DLPNO") {
                info.approximations.append(u.hasPrefix("DLPNO") ? "DLPNO" : t)
            }
        }
        if let g = tokens.first(where: { let u = $0.uppercased(); return u.hasPrefix("DEFGRID") || u.hasPrefix("GRID") }) {
            info.integrationGrid = g
        }

        // Job types in a natural order.
        let up = Set(tokens.map { $0.uppercased() })
        if up.contains("OPTTS") { info.jobTypes.append("Transition-state search") }
        else if up.contains(where: { ["OPT", "TIGHTOPT", "VERYTIGHTOPT", "LOOSEOPT", "COPT", "ZOPT"].contains($0) }) {
            info.jobTypes.append(blocks.has("geom", containing: "scan") ? "Relaxed scan" : "Optimization")
        }
        if up.contains("IRC") { info.jobTypes.append("IRC") }
        if up.contains("FREQ") || up.contains("NUMFREQ") { info.jobTypes.append("Frequencies") }
        if up.contains("NMR") { info.jobTypes.append("NMR") }
        if up.contains("MD") { info.jobTypes.append("Molecular dynamics") }
        if let td = blocks.block("tddft") ?? blocks.block("cis") {
            let roots = td.compactMap { l -> Int? in
                let p = l.lowercased().split(separator: " ")
                guard let i = p.firstIndex(of: "nroots"), i + 1 < p.count else { return nil }
                return Int(p[i + 1])
            }.first
            info.jobTypes.append(roots.map { "TD-DFT (\($0) roots)" } ?? "TD-DFT")
        }
        if info.jobTypes.isEmpty { info.jobTypes.append(up.contains("ENGRAD") ? "Gradient" : "Single point") }

        // Solvation: keyword CPCM(water)/SMD(water) or the %cpcm block, confirmed by ORCA's banners.
        for t in tokens {
            let u = t.uppercased()
            for model in ["CPCM", "SMD", "CPCMC", "ALPB", "COSMO", "GBSA"] where u == model || u.hasPrefix(model + "(") {
                info.solvationModel = model == "CPCMC" ? "CPCM" : model
                if let o = t.firstIndex(of: "("), let c = t.lastIndex(of: ")"), o < c {
                    info.solvent = String(t[t.index(after: o)..<c])
                }
            }
        }
        if let cp = blocks.block("cpcm") {
            for l in cp {
                let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard p.count >= 2 else { continue }
                switch p[0].lowercased() {
                case "smd" where p[1].lowercased() == "true": info.solvationModel = "SMD"
                case "smdsolvent", "solvent": info.solvent = p[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "epsilon": info.dielectric = Double(p[1])
                default: break
                }
            }
        }
        if text.contains("utilizes the SMD solvation module") { info.solvationModel = "SMD" }
        if info.solvationModel != nil, info.dielectric == nil, let e = settingValue(text, label: "Epsilon") {
            info.dielectric = Double(e)
        }

        // SCF SETTINGS block.
        if let x = settingValue(text, label: "Exchange Functional") { info.exchangeFunctional = x }
        if let c = settingValue(text, label: "Correlation Functional") { info.correlationFunctional = c }
        if text.contains("Hybrid DFT is turned on"), let f = settingValue(text, label: "Fraction HF Exchange") { info.exactExchange = Double(f) }
        let isDFT = text.contains("Density Functional     Method")
        if let h = settingValue(text, label: "Hartree-Fock type") {
            info.reference = isDFT ? (h == "RHF" ? "RKS" : h == "UHF" ? "UKS" : h == "ROHF" ? "ROKS" : h) : h
        }
        if info.method == nil {
            if isDFT, let x = info.exchangeFunctional {
                info.method = [x, info.correlationFunctional].compactMap { $0 }.joined(separator: "/")
                info.methodFamily = "DFT"
            } else if text.contains("Hartree-Fock(GTOs)") {
                info.method = "HF"; info.methodFamily = "HF"
            }
        }
        info.charge = settingValue(text, label: "Total Charge").flatMap { Int($0) }
        info.multiplicity = settingValue(text, label: "Multiplicity").flatMap { Int($0) }
        info.electrons = settingValue(text, label: "Number of Electrons").flatMap { Int($0) }
        info.basisFunctions = settingValue(text, label: "Basis Dimension").flatMap { Int($0) }
            ?? dottedValue(text, label: "Number of basis functions").flatMap { Int($0) }

        // Resources.
        if let pal = blocks.block("pal") {
            for l in pal {
                let p = l.lowercased().split(separator: " ")
                if let i = p.firstIndex(of: "nprocs"), i + 1 < p.count { info.cores = Int(p[i + 1]) }
            }
        }
        if info.cores == nil, let t = tokens.first(where: { $0.uppercased().hasPrefix("PAL") }) { info.cores = Int(t.dropFirst(3)) }
        for l in inputLines {
            let p = l.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
            if p.count >= 2, p[0] == "%maxcore" { info.memoryPerCoreMB = Int(p[1]) }
        }
        info.wallTimeSeconds = totalRunTime(text)
        return info
    }

    // MARK: helpers

    /// Text after `prefix` on its line, trimmed.
    private static func firstMatch(_ text: String, prefix: String) -> String? {
        guard let r = text.range(of: prefix) else { return nil }
        let rest = text[r.upperBound...].prefix(while: { !$0.isNewline })
        let v = rest.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// Value of an SCF SETTINGS row: " Total Charge           Charge          ....    0" → "0".
    /// The first token after the "...." separator.
    static func settingValue(_ text: String, label: String) -> String? {
        var search = text[...]
        while let r = search.range(of: label) {
            let line = search[r.upperBound...].prefix(while: { !$0.isNewline })
            search = search[r.upperBound...]
            if let sep = line.range(of: "....") ?? line.range(of: "...") {
                let v = line[sep.upperBound...].drop(while: { $0 == "." || $0 == " " })
                if let tok = v.split(separator: " ").first { return String(tok) }
            }
        }
        return nil
    }

    /// "Number of basis functions                   ...     38" → "38".
    private static func dottedValue(_ text: String, label: String) -> String? { settingValue(text, label: label) }

    /// "TOTAL RUN TIME: 0 days 0 hours 0 minutes 57 seconds 742 msec" → 57.742.
    public static func totalRunTime(_ text: String) -> Double? {
        guard let r = text.range(of: "TOTAL RUN TIME:", options: .backwards) else { return nil }
        let line = text[r.upperBound...].prefix(while: { !$0.isNewline })
        let p = line.split(whereSeparator: { $0.isWhitespace })
        var s = 0.0, found = false
        for (i, w) in p.enumerated() where i > 0 {
            guard let v = Double(p[i - 1]) else { continue }
            switch w.lowercased() {
            case "days", "day": s += v * 86400; found = true
            case "hours", "hour": s += v * 3600; found = true
            case "minutes", "minute": s += v * 60; found = true
            case "seconds", "second": s += v; found = true
            case "msec": s += v / 1000; found = true
            default: break
            }
        }
        return found ? s : nil
    }
}

/// The %blocks of an ORCA input, keyed by lower-cased name ("pal", "tddft", "cpcm", "geom").
struct OrcaInputBlocks {
    private var blocks: [String: [String]] = [:]

    init(lines: [String]) {
        var current: String?
        var body: [String] = []
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if current == nil, l.hasPrefix("%") {
                let parts = l.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
                guard let name = parts.first?.lowercased() else { continue }
                let rest = parts.dropFirst().joined(separator: " ")
                if name == "maxcore" { continue }                       // one-liner, not a block
                if rest.lowercased().hasSuffix(" end") || rest.lowercased() == "end" {   // "%pal nprocs 4 end"
                    blocks[name, default: []].append(String(rest.dropLast(3)).trimmingCharacters(in: .whitespaces))
                    continue
                }
                current = name; body = rest.isEmpty ? [] : [rest]
            } else if let c = current {
                if l.lowercased() == "end" { blocks[c, default: []] += body; current = nil; body = [] }
                else { body.append(l) }
            }
        }
        if let c = current { blocks[c, default: []] += body }
    }

    func block(_ name: String) -> [String]? { blocks[name] }

    func has(_ name: String, containing word: String) -> Bool {
        blocks[name]?.contains(where: { $0.lowercased().contains(word) }) ?? false
    }
}

/// Recognizers for ORCA "!" keywords.
enum OrcaKeywords {
    private static let dft: Set<String> = [
        "B3LYP", "B3LYP/G", "PBE0", "PBE", "BP86", "BLYP", "TPSS", "TPSSH", "TPSS0", "M06", "M06-2X", "M062X", "M06L",
        "M06-L", "REVPBE", "REVPBE0", "B97", "B97-D", "B97-D3", "B97M-V", "B97M-D3BJ", "B97M-D4", "SCAN", "R2SCAN", "R2SCAN0",
        "R2SCANH", "WB97", "WB97X", "WB97X-D3", "WB97X-D4", "WB97X-V", "WB97M-V", "WB97M-D3BJ", "WB97X-D3BJ",
        "CAM-B3LYP", "LC-BLYP", "LC-PBE", "B2PLYP", "B2GP-PLYP", "DSD-BLYP", "DSD-PBEP86", "PWPB95", "BHANDHLYP",
        "PW91", "OLYP", "X3LYP", "O3LYP", "B1LYP", "PW6B95", "MN15", "MN15L", "LDA", "VWN", "BHLYP", "HSE06"]
    private static let composite: Set<String> = ["R2SCAN-3C", "B97-3C", "PBEH-3C", "HF-3C", "WB97X-3C", "B3LYP-3C"]
    private static let semi: Set<String> = ["XTB", "XTB1", "XTB2", "GFN-XTB", "GFN1-XTB", "GFN2-XTB", "GFN0-XTB", "GFN-FF",
                                            "AM1", "PM3", "MNDO", "ZINDO/S", "NATIVE-GFN2-XTB"]

    static func methodFamily(_ u: String) -> String? {
        if composite.contains(u) { return "Composite" }
        if dft.contains(u) { return "DFT" }
        if semi.contains(u) { return "Semiempirical" }
        if u == "HF" || u == "RHF" || u == "UHF" || u == "ROHF" { return "HF" }
        if u.contains("CCSD") || u.contains("QCISD") { return "Coupled cluster" }
        if u.contains("MP2") || u.contains("SCS-MP2") { return "MP2" }
        if u.hasPrefix("CASSCF") || u.hasPrefix("NEVPT2") { return "Multireference" }
        return nil
    }

    static func isBasis(_ u: String) -> Bool {
        if u.contains("/") { return false }                              // aux bases like def2/J
        return u.hasPrefix("DEF2-") || u.hasPrefix("MA-DEF2-") || u.hasPrefix("CC-P") || u.hasPrefix("AUG-CC-P")
            || u.hasPrefix("6-31") || u.hasPrefix("6-311") || u.hasPrefix("3-21") || u.hasPrefix("STO-")
            || u.hasPrefix("DEF-") || u.hasPrefix("PCSEG") || u.hasPrefix("AUG-PCSEG") || u.hasPrefix("SVP")
            || u.hasPrefix("TZVP") || u.hasPrefix("ANO-") || u.hasPrefix("SARC") || u.hasPrefix("X2C-")
    }
}
