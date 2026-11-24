import Foundation
import MolCore

// Calculation setup recovered from a Q-Chem output: the echoed $rem / $molecule / $solvent / $smx / $pcm
// blocks of every job, plus electron / basis-function counts and "Total job time".

extension QChemOutput {
    public static func runInfo(lines rawLines: [Substring]) -> CalculationInfo {
        let lines = rawLines.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        var info = CalculationInfo()

        var rems: [[String: String]] = []
        var solvent: String?, dielectric: Double?, smxSolvent: String?, pcmTheory: String?
        var charge: Int?, mult: Int?
        var echoed: [String] = []

        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            let low = t.lowercased()
            if low.hasPrefix("$") && !low.hasPrefix("$end") {
                let name = String(low.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")
                var body: [String] = []
                var j = i + 1
                while j < lines.count {
                    let u = lines[j].trimmingCharacters(in: .whitespaces)
                    if u.lowercased().hasPrefix("$end") { break }
                    if u.lowercased().hasPrefix("$") && u.lowercased() != "$end" && name != "" && !u.isEmpty && body.count > 400 { break }
                    body.append(u); j += 1
                }
                switch name {
                case "rem":
                    var d: [String: String] = [:]
                    for b in body {
                        let c = b.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? b
                        let p = c.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                        if p.count >= 2 { d[p[0].lowercased()] = p[1...].joined(separator: " ") }
                    }
                    if !d.isEmpty { rems.append(d); echoed.append(contentsOf: body) }
                case "molecule":
                    if charge == nil, let f = body.first(where: { !$0.isEmpty }) {
                        let p = f.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                        if p.count >= 2, let c = Int(p[0]), let m = Int(p[1]) { charge = c; mult = m }
                    }
                case "solvent":
                    for b in body {
                        let p = b.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                        guard p.count >= 2 else { continue }
                        switch p[0].lowercased() {
                        case "solventname": solvent = p[1]
                        case "dielectric": dielectric = Double(p[1])
                        default: break
                        }
                    }
                case "smx":
                    for b in body {
                        let p = b.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                        if p.count >= 2, p[0].lowercased() == "solvent" { smxSolvent = p[1] }
                    }
                case "pcm":
                    for b in body {
                        let p = b.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                        if p.count >= 2, p[0].lowercased() == "theory" { pcmTheory = p[1].lowercased() }
                    }
                default: break
                }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }

        info.keywords = echoed
        info.charge = charge; info.multiplicity = mult
        if let f = rems.first {
            let m = (f["method"] ?? f["exchange"])
            if let m = m {
                let u = m.uppercased()
                info.method = u
                info.methodFamily = Self.family(u, fromExchange: f["method"] == nil)
            }
            info.basisSet = f["basis"].map { RunInfoUtil.basisDisplay($0) }
            if let a = f["aux_basis"] ?? f["auxiliary_basis"] { info.auxiliaryBasis = RunInfoUtil.basisDisplay(a) }
            if let d = f["dft_d"] { info.dispersion = Self.dispersion(d) }
            let unres = ["true", "1", "yes"].contains((f["unrestricted"] ?? "").lowercased())
            let isU = unres || (mult ?? 1) > 1
            if info.methodFamily == "DFT" { info.reference = isU ? "UKS" : "RKS" }
            else if let fam = info.methodFamily, ["HF", "MP2", "Coupled cluster"].contains(fam) { info.reference = isU ? "UHF" : "RHF" }
            if let g = f["xc_grid"] { info.integrationGrid = g }
            // Solvation: SOLVENT_METHOD with SOLVENT_NAME / $solvent / $smx.
            if let sm = f["solvent_method"]?.lowercased(), sm != "none" {
                switch sm {
                case "smd": info.solvationModel = "SMD"
                case "cpcm": info.solvationModel = "CPCM"
                case "isosvp", "cosmo": info.solvationModel = sm.uppercased()
                default: // "pcm": the $pcm theory picks CPCM vs the IEF-PCM default
                    info.solvationModel = pcmTheory == "cpcm" ? "CPCM" : "PCM"
                }
                info.solvent = f["solvent_name"] ?? smxSolvent ?? solvent
                info.dielectric = f["solvent_dielectric"].flatMap { Double($0) } ?? dielectric
            }
            if let mem = f["mem_total"].flatMap({ Int($0) }) { _ = mem }  // total job memory: per-core split unknown
        }

        // Job types across all jobs, in order.
        for r in rems {
            let jt = (r["jobtype"] ?? "sp").lowercased()
            switch jt {
            case "opt", "optimization": RunInfoUtil.addUnique(&info.jobTypes, "Optimization")
            case "ts": RunInfoUtil.addUnique(&info.jobTypes, "Transition state")
            case "freq", "frequency": RunInfoUtil.addUnique(&info.jobTypes, "Frequencies")
            case "force": RunInfoUtil.addUnique(&info.jobTypes, "Gradient")
            case "rpath": RunInfoUtil.addUnique(&info.jobTypes, "IRC")
            case "nmr": RunInfoUtil.addUnique(&info.jobTypes, "NMR")
            case "pes_scan": RunInfoUtil.addUnique(&info.jobTypes, "Scan")
            case "aimd": RunInfoUtil.addUnique(&info.jobTypes, "Molecular dynamics")
            default: RunInfoUtil.addUnique(&info.jobTypes, "Single point")
            }
            if let n = r["cis_n_roots"].flatMap({ Int($0) }) ?? r["cis_n_roots"].flatMap({ Int($0.split(separator: " ").first ?? "") }) {
                RunInfoUtil.addUnique(&info.jobTypes, "TD-DFT (\(n) roots)")
            }
        }

        // Counts and time.
        var wall = 0.0, haveWall = false
        for l in lines {
            if info.electrons == nil, l.contains("alpha and"), l.contains("beta electrons") {
                let nums = l.split(separator: " ").compactMap { Int($0) }
                if nums.count >= 2 { info.electrons = nums[0] + nums[1] }
            }
            if info.basisFunctions == nil, l.contains("basis functions") {
                let tk = l.split(separator: " ")
                if let k = tk.firstIndex(where: { $0 == "basis" }), k > 0, let v = Int(tk[k - 1]) { info.basisFunctions = v }
            }
            if let r = l.range(of: "Total job time:") {
                let tk = l[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," })
                if let w = tk.first(where: { $0.hasSuffix("s(wall)") }), let v = Double(w.dropLast(7)) { wall += v; haveWall = true }
            }
        }
        if haveWall { info.wallTimeSeconds = wall }
        return info
    }

    private static func family(_ u: String, fromExchange: Bool) -> String? {
        if fromExchange { return "DFT" }
        if u == "HF" { return "HF" }
        if u.contains("MP2") { return "MP2" }
        if u.contains("CCSD") || u.contains("CCD") { return "Coupled cluster" }
        if u.contains("LYP") || u.contains("PBE") || u.contains("B97") || u.contains("M06") || u.contains("M05") || u.contains("TPSS")
            || u.contains("SCAN") || u.hasPrefix("B3") || u.hasPrefix("BP") || u.hasPrefix("CAM") || u.hasPrefix("LRC") || u == "SVWN"
            || u.hasPrefix("OMEGA") || u.hasPrefix("B2") || u.hasPrefix("HSE") || u.hasPrefix("REV") { return "DFT" }
        return nil
    }

    private static func dispersion(_ v: String) -> String? {
        let u = v.uppercased()
        if u.contains("D3_BJ") || u.contains("D3BJ") { return "D3BJ" }
        if u.hasPrefix("D3") { return "D3" }
        if u.hasPrefix("D4") { return "D4" }
        if u.hasPrefix("D2") || u == "EMPIRICAL_GRIMME" { return "D2" }
        if u == "FALSE" || u == "NONE" || u == "0" { return nil }
        return u
    }
}
