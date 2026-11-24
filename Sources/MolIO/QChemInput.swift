import Foundation
import MolCore

// Q-Chem input writer / reader, written from the public Q-Chem manual input format
// ($molecule, $rem, $opt, $scan, $solvent, $pcm, $smx sections, "@@@" job separator, "read" geometry).
// Q-Chem is not installed here, so layouts are from the documentation, not from program output.

fileprivate func qcPad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

public enum QChemInput {
    public static func write(_ spec: CalcSpec) -> String {
        var jobs: [String] = []
        func molBlock(read: Bool) -> String {
            if read { return "$molecule\nread\n$end\n" }
            var s = "$molecule\n\(spec.charge) \(spec.multiplicity)\n"
            for a in spec.molecule.atoms {
                s += qcPad(IOElements.symbol(a.atomicNumber), 3) + String(format: " %14.8f %14.8f %14.8f\n",
                            a.position.x, a.position.y, a.position.z)
            }
            return s + "$end\n"
        }
        func rem(_ jobType: String, excited: Bool, optionsForOpt: Bool) -> String {
            var r: [(String, String)] = [("JOBTYPE", jobType), ("METHOD", spec.method.lowercased())]
            if !spec.basis.isEmpty { r.append(("BASIS", spec.basis)) }
            switch spec.dispersion {
            case .d3bj: r.append(("DFT_D", "D3_BJ"))
            case .d3zero: r.append(("DFT_D", "D3_ZERO"))
            case .d4: r.append(("DFT_D", "D4"))
            case .none: break
            }
            if spec.isUnrestricted { r.append(("UNRESTRICTED", "true")) }
            if let sv = spec.solvation {
                r.append(("SOLVENT_METHOD", sv.model == .smd ? "SMD" : "PCM"))
            }
            r.append(("MEM_TOTAL", String(spec.memoryMB)))
            if optionsForOpt && spec.tightOptimization {
                r.append(("GEOM_OPT_TOL_GRADIENT", "15")); r.append(("GEOM_OPT_TOL_DISPLACEMENT", "60"))
                r.append(("GEOM_OPT_TOL_ENERGY", "5"))
            }
            if excited, let es = spec.excitedStates {
                r.append(("CIS_N_ROOTS", String(es.roots)))
                if es.triplets { r.append(("CIS_TRIPLETS", "true")) }
                if !es.tammDancoff { r.append(("RPA", "true")) }
            }
            var s = "$rem\n" + r.map { qcPad($0.0, 26) + " " + $0.1 }.joined(separator: "\n") + "\n"
            for k in spec.extraKeywords { s += k + "\n" }
            return s + "$end\n"
        }
        func solvent() -> String {
            guard let sv = spec.solvation else { return "" }
            switch sv.model {
            case .smd: return "\n$smx\nsolvent \(sv.solvent)\n$end\n"
            case .cpcm: return "\n$pcm\ntheory cpcm\n$end\n\n$solvent\nSolventName \(sv.solvent)\n$end\n"
            default: return "\n$pcm\ntheory iefpcm\n$end\n\n$solvent\nSolventName \(sv.solvent)\n$end\n"
            }
        }
        func optSection() -> String {
            guard !spec.frozenAtoms.isEmpty else { return "" }
            return "\n$opt\nFIXED\n" + spec.frozenAtoms.sorted().map { "  \($0 + 1) XYZ" }.joined(separator: "\n") + "\nENDFIXED\n$end\n"
        }
        func job(_ jobType: String, read: Bool, excited: Bool, opt: Bool, extra: String = "") -> String {
            var s = ""
            if !spec.title.isEmpty && jobs.isEmpty && !read { s += "$comment\n\(spec.title)\n$end\n\n" }
            s += molBlock(read: read) + "\n" + rem(jobType, excited: excited, optionsForOpt: opt) + solvent()
            if opt { s += optSection() }
            s += extra
            let x = spec.extraInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !x.isEmpty && !read { s += "\n" + x + "\n" }
            return s
        }
        let hasES = spec.excitedStates != nil
        switch spec.task {
        case .energy: jobs.append(job("sp", read: false, excited: hasES, opt: false))
        case .gradient: jobs.append(job("force", read: false, excited: hasES, opt: false))
        case .frequencies: jobs.append(job("freq", read: false, excited: hasES, opt: false))
        case .optimize: jobs.append(job("opt", read: false, excited: hasES, opt: true))
        case .optimizeAndFrequencies, .transitionState:
            let ts = spec.task == .transitionState
            jobs.append(job(ts ? "ts" : "opt", read: false, excited: false, opt: true))
            if !ts || spec.computeFrequenciesAfterTS { jobs.append(job("freq", read: true, excited: false, opt: false)) }
            if hasES { jobs.append(job("sp", read: true, excited: true, opt: false)) }
        case .scan:
            var extra = ""
            if let sc = spec.scan {
                let tag = ["", "", "stre", "bend", "tors"][min(max(sc.atoms.count, 0), 4)]
                let ids = sc.atoms.map { String($0 + 1) }.joined(separator: " ")
                extra = "\n$scan\n\(tag) \(ids) " + String(format: "%.6g %.6g %.6g", sc.start, sc.end, sc.stepSize) + "\n$end\n"
            }
            jobs.append(job("pes_scan", read: false, excited: hasES, opt: true, extra: extra))
        case .irc: jobs.append(job("rpath", read: false, excited: false, opt: false))
        }
        return jobs.joined(separator: "\n@@@\n\n")
    }
}

// MARK: - Reader

public struct QChemInputFile: Sendable {
    public struct Job: Sendable {
        /// Molecule of this job (Angstrom). For `read` jobs this is the previous job's molecule (when known).
        public var molecule: Molecule?
        public var readsGeometry: Bool = false
        /// $rem entries, keys upper-cased, values as written.
        public var rem: [String: String] = [:]
        /// Every other section (lower-cased name -> raw body without the $name/$end lines).
        public var sections: [String: String] = [:]
        public var jobType: String { (rem["JOBTYPE"] ?? "sp").lowercased() }
    }
    public var jobs: [Job] = []

    static func fail(_ line: Int?, _ m: String) -> MolIOError { .parse(format: "Q-Chem input", line: line, message: m) }

    public static func read(url: URL) throws -> QChemInputFile { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> QChemInputFile {
        var chunks: [[(Int, Substring)]] = [[]]
        for (n, l) in splitLines(text).enumerated() {
            if l.trimmingCharacters(in: .whitespaces) == "@@@" { chunks.append([]) } else { chunks[chunks.count - 1].append((n + 1, l)) }
        }
        var file = QChemInputFile()
        var previous: Molecule? = nil
        for chunk in chunks {
            if chunk.allSatisfy({ $0.1.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            var job = Job()
            var i = 0
            var sawMolecule = false, sawRem = false
            while i < chunk.count {
                let (ln, raw) = chunk[i]
                let t = raw.trimmingCharacters(in: .whitespaces)
                i += 1
                if t.isEmpty || t.hasPrefix("!") || t.hasPrefix("#") { continue }
                guard t.hasPrefix("$") else { throw fail(ln, "text outside any $section: '\(t)'") }
                let name = t.dropFirst().lowercased()
                guard name != "end" else { throw fail(ln, "stray $end") }
                var body: [(Int, Substring)] = []
                var closed = false
                while i < chunk.count {
                    let (bl, br) = chunk[i]; i += 1
                    if br.trimmingCharacters(in: .whitespaces).lowercased() == "$end" { closed = true; break }
                    body.append((bl, br))
                }
                guard closed else { throw fail(ln, "section $\(name) has no $end") }
                switch name {
                case "molecule":
                    sawMolecule = true
                    job.molecule = try parseMolecule(body, readFlag: &job.readsGeometry, previous: previous)
                case "rem":
                    sawRem = true
                    for (rl, r) in body {
                        var s = r.trimmingCharacters(in: .whitespaces)
                        if let c = s.firstIndex(of: "!") { s = String(s[..<c]).trimmingCharacters(in: .whitespaces) }
                        if s.isEmpty { continue }
                        let tk = tokens(s.replacingOccurrences(of: "=", with: " "))
                        guard let key = tk.first else { continue }
                        guard tk.count >= 2 else { throw fail(rl, "$rem keyword '\(key)' has no value") }
                        job.rem[key.uppercased()] = tk.dropFirst().joined(separator: " ")
                    }
                default:
                    job.sections[String(name)] = body.map { String($0.1) }.joined(separator: "\n")
                }
            }
            guard sawMolecule else { throw fail(nil, "job has no $molecule section") }
            guard sawRem else { throw fail(nil, "job has no $rem section") }
            previous = job.molecule ?? previous
            file.jobs.append(job)
        }
        guard !file.jobs.isEmpty else { throw fail(nil, "no jobs found") }
        return file
    }

    private static func parseMolecule(_ body: [(Int, Substring)], readFlag: inout Bool, previous: Molecule?) throws -> Molecule? {
        let lines = body.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { throw fail(nil, "empty $molecule section") }
        let ft = tokens(first.1)
        if ft.count == 1 && ft[0].lowercased() == "read" { readFlag = true; return previous }
        guard ft.count == 2, let q = Int(ft[0]), let m = Int(ft[1]), m >= 1 else {
            throw fail(first.0, "$molecule must start with 'charge multiplicity' or 'read'")
        }
        var mol = Molecule(atoms: [], bonds: [], charge: q, multiplicity: m, title: "")
        for (ln, raw) in lines.dropFirst() {
            let tk = tokens(raw)
            if tk.first == "--" { throw MolIOError.unsupported("Q-Chem fragment molecules") }
            guard tk.count >= 4, let x = parseFortranDouble(tk[1]), let y = parseFortranDouble(tk[2]), let z = parseFortranDouble(tk[3]),
                  let zn = IOElements.atomicNumber(label: String(tk[0])) else {
                throw fail(ln, "unsupported or malformed atom line (Z-matrix input is not supported)")
            }
            mol.atoms.append(Atom(id: mol.atoms.count, atomicNumber: zn, position: Vec3(x, y, z)))
        }
        guard !mol.atoms.isEmpty else { throw fail(first.0, "$molecule has no atoms") }
        return mol
    }
}
