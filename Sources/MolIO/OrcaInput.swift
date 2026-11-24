import Foundation
import MolCore

/// ORCA input writer (from the public ORCA input syntax).
public enum OrcaInput {
    private static func f(_ v: Double) -> String { String(format: "%.8f", v) }

    public static func write(_ spec: CalcSpec) -> String {
        var out: [String] = []
        let title = spec.title.isEmpty ? spec.molecule.title : spec.title
        if !title.isEmpty { out.append("# " + title.replacingOccurrences(of: "\n", with: " ")) }

        // Method line
        var kw: [String] = []
        let m = spec.method
        let mu = m.uppercased()
        let wavefunctionOnly = mu == "HF" || mu.hasPrefix("MP2") || mu.hasPrefix("CC") || mu.hasPrefix("DLPNO") || mu.hasPrefix("RI-MP2")
        if mu == "HF" && spec.isUnrestricted { kw.append("UHF") }
        else {
            kw.append(m)
            if spec.unrestricted == true, !wavefunctionOnly, !mu.hasPrefix("U"), !CalcSpec.isBasisFree(m) { kw.append("UKS") }
        }
        if !spec.basis.isEmpty { kw.append(spec.basis) }
        switch spec.dispersion {
        case .d3zero?: kw.append("D3ZERO")
        case .d3bj?: kw.append("D3BJ")
        case .d4?: kw.append("D4")
        case nil: break
        }
        let tight = spec.tightOptimization
        switch spec.task {
        case .energy: break
        case .gradient: kw.append("EnGrad")
        case .optimize: kw.append(tight ? "TightOpt" : "Opt")
        case .frequencies: kw.append("Freq")
        case .optimizeAndFrequencies: kw.append(tight ? "TightOpt" : "Opt"); kw.append("Freq")
        case .transitionState:
            kw.append("OptTS")
            if tight { kw.append("TightOpt") }
            if spec.computeFrequenciesAfterTS { kw.append("Freq") }
        case .scan: kw.append(tight ? "TightOpt" : "Opt")
        case .irc: kw.append("IRC")
        }
        if let s = spec.solvation {
            switch s.model {
            case .smd: kw.append("CPCM")
            default: kw.append("CPCM(\(s.solvent))")
            }
        }
        kw.append(contentsOf: spec.extraKeywords)
        out.append("! " + kw.joined(separator: " "))

        if let c = spec.checkpointName, !c.isEmpty { out.append("%base \"\(c.replacingOccurrences(of: ".chk", with: ""))\"") }
        let np = max(1, spec.nprocs)
        if np > 1 { out.append("%pal nprocs \(np) end") }
        out.append("%maxcore \(max(1, spec.memoryMB / np))")
        if let td = spec.excitedStates {
            out.append("%tddft")
            out.append("  nroots \(td.roots)")
            out.append("  tda \(td.tammDancoff ? "true" : "false")")
            if td.triplets { out.append("  triplets true") }
            out.append("end")
        }
        if let s = spec.solvation, s.model == .smd {
            out.append("%cpcm")
            out.append("  smd true")
            out.append("  SMDsolvent \"\(s.solvent)\"")
            out.append("end")
        }
        var geom: [String] = []
        if spec.task == .scan, let s = spec.scan {
            let tag = ["", "", "B", "A", "D"][min(max(s.atoms.count, 0), 4)]
            geom.append("  Scan")
            geom.append("    \(tag) \(s.atoms.map(String.init).joined(separator: " ")) = \(f(s.start)), \(f(s.end)), \(s.steps)")
            geom.append("  end")
        }
        if !spec.frozenAtoms.isEmpty {
            geom.append("  Constraints")
            for a in spec.frozenAtoms { geom.append("    { C \(a) C }") }
            geom.append("  end")
        }
        if !geom.isEmpty { out.append("%geom"); out.append(contentsOf: geom); out.append("end") }
        let extra = spec.extraInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { out.append(extra) }

        out.append("* xyz \(spec.molecule.charge) \(spec.molecule.multiplicity)")
        for a in spec.molecule.atoms {
            let p = a.position
            let sym = IOElements.symbol(a.atomicNumber)
            out.append(sym + String(repeating: " ", count: max(0, 2 - sym.count)) + String(format: " %14.8f %14.8f %14.8f", p.x, p.y, p.z))
        }
        out.append("*")
        return out.joined(separator: "\n") + "\n"
    }
}

/// A `%name ... end` block of an ORCA input (raw body text, without the `%name` token and the final `end`).
public struct OrcaInputBlock: Sendable, Codable, Equatable {
    public var name: String
    public var body: String
}

/// Parsed ORCA input file: keywords, `%` blocks, geometry.
/// Supports `* xyz c m ... *`, `* xyzfile c m file`, and `* int c m ... *` (via `ZMatrix`).
/// Throws for text with no geometry block or no keyword line, or unsupported coordinate types (`gzmt`, `pdbfile`).
public struct OrcaInputFile: Sendable, Codable, Equatable {
    /// Individual keyword tokens from all "!" lines, in order (without the "!").
    public var keywords: [String] = []
    public var keywordLines: [String] = []
    public var blocks: [OrcaInputBlock] = []
    public var nprocs: Int?
    public var maxcore: Int?
    public var molecule: Molecule = Molecule()
    public var coordinateType: String = "xyz"
    public var title: String = ""

    public static func read(url: URL) throws -> OrcaInputFile {
        try parse(try readText(url), baseDirectory: url.deletingLastPathComponent())
    }

    public static func parse(_ text: String, baseDirectory: URL? = nil) throws -> OrcaInputFile {
        func fail(_ line: Int, _ m: String) -> MolIOError { .parse(format: "orca-input", line: line + 1, message: m) }
        let raw = splitLines(text)
        var r = OrcaInputFile()
        var haveGeom = false
        var i = 0
        func stripComment(_ s: Substring) -> String {
            var t = String(s)
            if let h = t.firstIndex(of: "#") { t = String(t[..<h]) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        while i < raw.count {
            let line = stripComment(raw[i])
            if line.isEmpty {
                if r.title.isEmpty, raw[i].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                    r.title = String(raw[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                i += 1; continue
            }
            if line.hasPrefix("!") {
                r.keywordLines.append(line)
                r.keywords.append(contentsOf: tokens(line.dropFirst()).map(String.init))
                i += 1; continue
            }
            if line.hasPrefix("%") {
                let first = tokens(line.dropFirst())
                guard let nameTok = first.first else { throw fail(i, "empty block name") }
                let name = String(nameTok)
                let lname = name.lowercased()
                if ["maxcore", "base", "moinp", "basis_name"].contains(lname) {
                    let rest = first.dropFirst().joined(separator: " ")
                    if lname == "maxcore" { r.maxcore = Int(rest) }
                    r.blocks.append(OrcaInputBlock(name: name, body: rest))
                    i += 1; continue
                }
                var body: [String] = [first.dropFirst().joined(separator: " ")]
                var k = i
                var closed = false
                while k < raw.count {
                    let cur = k == i ? body[0] : stripComment(raw[k])
                    if k != i { body.append(cur) }
                    if tokens(cur).last?.lowercased() == "end" {
                        // block ends if the next non-empty line starts a new top-level item (or EOF)
                        var n = k + 1
                        while n < raw.count, stripComment(raw[n]).isEmpty { n += 1 }
                        if n >= raw.count { closed = true; break }
                        let nx = stripComment(raw[n])
                        if nx.hasPrefix("%") || nx.hasPrefix("!") || nx.hasPrefix("*") { closed = true; break }
                    }
                    k += 1
                }
                guard closed else { throw fail(i, "block %\(name) is not terminated by 'end'") }
                // drop the final "end"
                var lines = body
                if var last = lines.last {
                    var t = tokens(last).map(String.init)
                    if t.last?.lowercased() == "end" { t.removeLast() }
                    last = t.joined(separator: " ")
                    lines[lines.count - 1] = last
                }
                let bodyText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                r.blocks.append(OrcaInputBlock(name: name, body: bodyText))
                if lname == "pal" {
                    let t = tokens(bodyText.replacingOccurrences(of: "\n", with: " "))
                    if let p = t.firstIndex(where: { $0.lowercased() == "nprocs" }), p + 1 < t.count { r.nprocs = Int(t[p + 1]) }
                }
                i = k + 1; continue
            }
            if line.hasPrefix("*") {
                let t = tokens(line.dropFirst())
                guard t.count >= 3, let ch = Int(t[1]), let mu = Int(t[2]) else { throw fail(i, "bad coordinate header '\(line)'") }
                let kind = t[0].lowercased()
                r.coordinateType = kind
                var mol: Molecule
                switch kind {
                case "xyzfile":
                    guard t.count >= 4 else { throw fail(i, "missing xyz file name") }
                    guard let base = baseDirectory else { throw MolIOError.unsupported("* xyzfile needs a base directory") }
                    let frames = try XYZFormat.read(url: base.appendingPathComponent(String(t[3])))
                    guard let f0 = frames.first else { throw fail(i, "empty xyz file") }
                    mol = f0
                case "xyz", "int":
                    var rows: [String] = []
                    var k = i + 1
                    var closed = false
                    while k < raw.count {
                        let s = stripComment(raw[k])
                        if s == "*" || s.lowercased() == "end" { closed = true; break }
                        if !s.isEmpty { rows.append(s) }
                        k += 1
                    }
                    guard closed else { throw fail(i, "coordinate block not terminated by '*'") }
                    if kind == "xyz" {
                        var atoms: [Atom] = []
                        for (n, s) in rows.enumerated() {
                            let c = tokens(s)
                            guard c.count >= 4, let z = IOElements.atomicNumber(label: String(c[0])),
                                  let x = parseFortranDouble(c[1]), let y = parseFortranDouble(c[2]), let w = parseFortranDouble(c[3]) else {
                                throw fail(i + 1 + n, "bad atom line '\(s)'")
                            }
                            atoms.append(Atom(id: atoms.count, atomicNumber: z, position: Vec3(x, y, w)))
                        }
                        mol = Molecule(atoms: atoms)
                    } else {
                        var zrows: [ZMatrixRow] = []
                        for (n, s) in rows.enumerated() {
                            let c = tokens(s)
                            guard c.count >= 7, let z = IOElements.atomicNumber(label: String(c[0])),
                                  let a = Int(c[1]), let b = Int(c[2]), let d = Int(c[3]),
                                  let rv = parseFortranDouble(c[4]), let av = parseFortranDouble(c[5]), let dv = parseFortranDouble(c[6]) else {
                                throw fail(i + 1 + n, "bad internal-coordinate line '\(s)'")
                            }
                            zrows.append(ZMatrixRow(atomicNumber: z, bondAtom: a > 0 ? a - 1 : nil, bond: a > 0 ? .number(rv) : nil,
                                                    angleAtom: b > 0 ? b - 1 : nil, angle: b > 0 ? .number(av) : nil,
                                                    dihedralAtom: d > 0 ? d - 1 : nil, dihedral: d > 0 ? .number(dv) : nil))
                        }
                        do { mol = try ZMatrix(rows: zrows).molecule() }
                        catch { throw fail(i, "internal coordinates: \(error)") }
                    }
                    i = k
                default:
                    throw MolIOError.unsupported("ORCA coordinate type '\(kind)'")
                }
                mol.charge = ch; mol.multiplicity = mu
                mol.perceiveBonds()
                r.molecule = mol
                haveGeom = true
                i += 1; continue
            }
            i += 1   // unknown line (e.g. "$new_job"): ignored
        }
        guard !r.keywords.isEmpty || !r.blocks.isEmpty else { throw MolIOError.parse(format: "orca-input", line: nil, message: "no keyword line or block found") }
        guard haveGeom, !r.molecule.atoms.isEmpty else { throw MolIOError.parse(format: "orca-input", line: nil, message: "no coordinate block") }
        return r
    }
}
