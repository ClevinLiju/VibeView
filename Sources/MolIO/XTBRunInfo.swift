import Foundation
import MolCore

// Calculation setup recovered from an xtb output: GFN level, solvation (ALPB/GBSA/CPCM-X), version-independent
// counts from the setup block, job types and the final wall time. Only what is printed is filled in.

extension XTBOutput {
    public static func runInfo(lines: [String]) -> CalculationInfo {
        var info = CalculationInfo()
        let text = lines.joined(separator: "\n")

        // "program call : xtb coord --opt --gfn 2 --alpb water"
        var call: String?
        for l in lines {
            if let r = l.range(of: "program call"), let c = l[r.upperBound...].firstIndex(of: ":") {
                call = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces); break
            }
        }
        let args = (call ?? "").split(separator: " ").map(String.init)
        func arg(after flag: String) -> String? {
            guard let k = args.firstIndex(where: { $0.lowercased() == flag }), k + 1 < args.count,
                  !args[k + 1].hasPrefix("-") || Double(args[k + 1]) != nil else { return nil }   // "--chrg -1" is a value
            return args[k + 1]
        }
        if let c = call { info.keywords = [c] }

        // GFN level.
        var gfn: String?
        let up = text.uppercased()
        for name in ["GFN2-XTB", "GFN1-XTB", "GFN0-XTB", "GFN-FF", "GFNFF"] where up.contains(name) {
            gfn = name == "GFN-FF" || name == "GFNFF" ? "GFN-FF" : "GFN" + String(name.dropFirst(3).prefix(1)) + "-xTB"
            break
        }
        if gfn == nil {
            if args.contains(where: { $0.lowercased() == "--gfnff" }) { gfn = "GFN-FF" }
            else if let n = arg(after: "--gfn") { gfn = "GFN\(n)-xTB" }
            else if let a = args.first(where: { $0.lowercased().hasPrefix("--gfn") && $0.count == 6 }), let d = a.last, d.isNumber { gfn = "GFN\(d)-xTB" }
        }
        if let g = gfn { info.method = g; info.methodFamily = g == "GFN-FF" ? "Force field" : "Semiempirical" }

        // Solvation.
        for l in lines {
            let t = l.trimmingCharacters(in: CharacterSet(charactersIn: " \t*:|"))
            if info.solvationModel == nil, t.lowercased().hasPrefix("solvation model") {
                let v = t.drop(while: { $0 != ":" }).dropFirst()
                let val = v.isEmpty ? (t.split(separator: " ").dropFirst(2).first.map(String.init) ?? "") : v.trimmingCharacters(in: .whitespaces)
                if !val.isEmpty { info.solvationModel = val.uppercased() }
            }
            if info.solvent == nil, t.hasPrefix("Solvent "), !t.lowercased().hasPrefix("solvent accessible") {
                let tk = t.split(whereSeparator: { $0 == " " || $0 == ":" })
                if tk.count >= 2 { info.solvent = String(tk[1]) }
            }
            if info.dielectric == nil, t.hasPrefix("Dielectric constant"), let v = t.split(separator: " ").last.flatMap({ Double($0) }) { info.dielectric = v }
        }
        if info.solvationModel == nil {
            for (flag, model) in [("--alpb", "ALPB"), ("--gbsa", "GBSA"), ("--cosmo", "COSMO"), ("--cpcmx", "CPCM-X")] {
                if args.contains(where: { $0.lowercased() == flag }) { info.solvationModel = model; info.solvent = info.solvent ?? arg(after: flag); break }
            }
        }

        // Counts / state from the setup table or call options.
        for l in lines {
            if info.electrons == nil, let v = RunInfoUtil.intAfter("# electrons", in: l) ?? RunInfoUtil.intAfter("number of electrons", in: l) { info.electrons = v }
            if info.basisFunctions == nil, let v = RunInfoUtil.intAfter("# basis functions", in: l) ?? RunInfoUtil.intAfter("# atomic orbitals", in: l)
                ?? RunInfoUtil.intAfter("number of atomic orbitals", in: l) { info.basisFunctions = v }
            if info.charge == nil, let v = RunInfoUtil.intAfter("net charge", in: l) { info.charge = v }
            if info.multiplicity == nil, let v = RunInfoUtil.intAfter("unpaired electrons", in: l) { info.multiplicity = v + 1 }
            let low = l.lowercased()
            if info.cores == nil, low.contains("omp threads") || low.contains("openmp threads") || low.contains("parallel threads") {
                for t in l.split(whereSeparator: { " :|=*".contains($0) }) { if let v = Int(t) { info.cores = v; break } }
            }
        }
        if info.charge == nil, let c = arg(after: "--chrg").flatMap({ Int($0) }) { info.charge = c }
        if info.multiplicity == nil, let u = arg(after: "--uhf").flatMap({ Int($0) }) { info.multiplicity = u + 1 }

        // Job types.
        let lowText = text.lowercased()
        let wantsOpt = args.contains(where: { ["--opt", "--ohess", "--ohess", "--optimize"].contains($0.lowercased()) }) || text.contains("GEOMETRY OPTIMIZATION")
            || text.contains("ANCopt")
        let wantsHess = args.contains(where: { ["--hess", "--ohess", "--bhess"].contains($0.lowercased()) }) || lowText.contains("frequency printout")
            || lowText.contains(":: zero point energy") || lowText.contains("projected vibrational frequencies")
        if wantsOpt { info.jobTypes.append("Optimization") }
        if wantsHess { info.jobTypes.append("Frequencies") }
        if args.contains(where: { $0.lowercased() == "--md" }) { info.jobTypes.append("Molecular dynamics") }
        if args.contains(where: { $0.lowercased() == "--scan" }) { info.jobTypes.append("Scan") }
        if info.jobTypes.isEmpty { info.jobTypes = ["Single point"] }

        // Wall time: last "* wall-time:" line.
        for l in lines.reversed() {
            if let r = l.range(of: "wall-time:"), let s = RunInfoUtil.duration(String(l[r.upperBound...])) { info.wallTimeSeconds = s; break }
        }
        return info
    }
}
