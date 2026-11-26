import Foundation
import MolCore

// xtb (Grimme group) file formats, written from the public xtb documentation. xtb is not required at build
// or test time; the test fixtures in TestData/io/xtb/ are hand-written from the documented layouts.
//
// Policy (same as the ORCA parsers): text that is not recognizable as the format throws `MolIOError`;
// a file cut inside a table/frame/block throws; a log cut cleanly between blocks parses with
// `normalTermination == false`.

// MARK: - Input (command line + xcontrol)

public enum XTBInput {
    /// Compress sorted 0-based atom indices into xtb's 1-based "1-3,5" list.
    static func atomList(_ zeroBased: [Int]) -> String {
        let s = Array(Set(zeroBased.map { $0 + 1 })).sorted()
        var parts: [String] = []
        var k = 0
        while k < s.count {
            var e = k
            while e + 1 < s.count, s[e + 1] == s[e] + 1 { e += 1 }
            parts.append(e > k ? "\(s[k])-\(s[e])" : "\(s[k])")
            k = e + 1
        }
        return parts.joined(separator: ",")
    }

    /// Command line arguments (without the executable). The first argument is the geometry file name.
    public static func arguments(for spec: CalcSpec) -> [String] {
        var a: [String] = ["input.xyz"]
        let m = spec.method.uppercased()
        if m.contains("GFN-FF") || m.contains("GFNFF") || m == "GFN-FF" { a += ["--gfnff"] }
        else if m.contains("GFN0") { a += ["--gfn", "0"] }
        else if m.contains("GFN1") { a += ["--gfn", "1"] }
        else { a += ["--gfn", "2"] }
        let tight: [String] = spec.tightOptimization ? ["tight"] : []
        switch spec.task {
        case .energy: break
        case .gradient: a.append("--grad")
        case .optimize, .scan, .transitionState, .irc: a += ["--opt"] + tight
        case .frequencies: a.append("--hess")
        case .optimizeAndFrequencies: a += ["--ohess"] + tight
        }
        a += ["--chrg", String(spec.molecule.charge), "--uhf", String(max(0, spec.molecule.multiplicity - 1))]
        if let s = spec.solvation {
            a += [s.model == .gbsa ? "--gbsa" : "--alpb", s.solvent]
        }
        a += ["-P", String(max(1, spec.nprocs))]
        if xcontrol(for: spec) != nil { a += ["--input", "xcontrol.inp"] }
        return a
    }

    /// `$fix` / `$constrain` / `$scan` control text, or nil when nothing is needed.
    public static func xcontrol(for spec: CalcSpec) -> String? {
        var lines: [String] = []
        if !spec.frozenAtoms.isEmpty {
            lines += ["$fix", "  atoms: \(atomList(spec.frozenAtoms))"]
        }
        if spec.task == .scan, let s = spec.scan {
            let ids = s.atoms.map { String($0 + 1) }.joined(separator: ",")
            let kind = ["", "", "distance", "angle", "dihedral"][min(max(s.atoms.count, 0), 4)]
            lines += ["$constrain", "  force constant=0.5", "  \(kind): \(ids),auto",
                      "$scan", "  1: \(String(format: "%g", s.start)), \(String(format: "%g", s.end)), \(s.steps)"]
        }
        if lines.isEmpty { return nil }
        return (lines + ["$end"]).joined(separator: "\n") + "\n"
    }
}

// MARK: - Shared small helpers

private func xtbFail(_ fmt: String, _ line: Int?, _ msg: String) -> MolIOError { .parse(format: fmt, line: line.map { $0 + 1 }, message: msg) }

/// First number after `key` in a comment/summary line ("energy: -5.07 gnorm: 0.01").
private func xtbValue(after key: String, in line: String) -> Double? {
    guard let r = line.range(of: key) else { return nil }
    let t = tokens(line[r.upperBound...])
    guard let f = t.first else { return nil }
    return parseFortranDouble(f.trimmingCharacters(in: CharacterSet(charactersIn: ";,")))
}

// MARK: - stdout

public struct XTBOutput: Sendable, Codable, Equatable {
    public var programVersion: String?
    public var totalEnergy: Double?
    public var gradientNorm: Double?
    public var homoLumoGapEV: Double?
    public var charges: [Double] = []
    public var elements: [Int] = []
    public var dipoleDebye: Vec3?
    public var optimizationConverged: Bool?
    public var thermochemistry: ThermochemistrySummary?
    public var messages: [String] = []
    public var normalTermination = false
    /// Calculation setup recovered from the output (method, solvation, job types, time).
    public var info: CalculationInfo?

    public static func read(url: URL) throws -> XTBOutput { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> XTBOutput {
        let L = splitLines(text)
        guard text.contains("xtb version") || text.contains("normal termination of xtb")
                || text.contains("x T B") || text.contains(":: total energy") || text.contains("| TOTAL ENERGY") else {
            throw MolIOError.parse(format: "xtb", line: nil, message: "not an xtb output")
        }
        var o = XTBOutput()
        var th = ThermochemistrySummary()
        var haveTh = false
        var i = 0
        func eh(_ s: Substring) -> Double? {
            let t = tokens(s)
            guard let k = t.firstIndex(of: "Eh"), k > 0 else { return nil }
            return parseFortranDouble(t[k - 1])
        }
        while i < L.count {
            let s = L[i]
            if o.programVersion == nil, let r = s.range(of: "xtb version ") { o.programVersion = tokens(s[r.upperBound...]).first.map(String.init) }
            if (s.contains(":: total energy") || s.contains("| TOTAL ENERGY")), let v = eh(s) { o.totalEnergy = v }
            if (s.contains(":: gradient norm") || s.contains("| GRADIENT NORM")), let k = tokens(s).firstIndex(where: { $0.hasPrefix("Eh/") }), k > 0 {
                o.gradientNorm = Double(tokens(s)[k - 1])
            }
            if s.contains("HOMO-LUMO"), let k = tokens(s).firstIndex(of: "eV"), k > 0 { o.homoLumoGapEV = Double(tokens(s)[k - 1]) }
            if s.contains(":: zero point energy"), let v = eh(s) { th.zeroPointEnergy = v; haveTh = true }
            if s.contains(":: total enthalpy"), let v = eh(s) { th.totalEnthalpy = v; haveTh = true }
            if s.contains(":: total free energy"), let v = eh(s) { th.totalGibbs = v; haveTh = true }
            if s.contains(":: G(RRHO) contrib."), let v = eh(s) { th.gibbsCorrection = v; haveTh = true }
            if s.contains("GEOMETRY OPTIMIZATION CONVERGED") { o.optimizationConverged = true }
            if s.contains("FAILED TO CONVERGE GEOMETRY OPTIMIZATION") { o.optimizationConverged = false; o.messages.append("geometry optimization failed to converge") }
            if s.contains("normal termination of xtb") { o.normalTermination = true }
            if s.contains("abnormal termination of xtb") { o.normalTermination = false; o.messages.append("abnormal termination") }
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("full:") {
                let t = tokens(s)
                if t.count >= 4, let x = Double(t[1]), let y = Double(t[2]), let z = Double(t[3]) {
                    o.dipoleDebye = Vec3(x, y, z) * OrcaOutput.debyePerAU   // x y z are printed in a.u.
                }
            }
            // charge table: "#   Z          covCN         q      C6AA      α(0)"
            let tk = tokens(s)
            if tk.count >= 4, tk[0] == "#", tk[1] == "Z", tk.contains("q") {
                let qi = tk.firstIndex(of: "q") ?? 3
                var k = i + 1
                var q: [Double] = [], z: [Int] = []
                var closed = false
                while k < L.count {
                    let t = tokens(L[k])
                    if t.isEmpty {
                        // a blank line closes the table only if the file goes on (a cut file ends in blanks)
                        closed = L[(k + 1)...].contains { !tokens($0).isEmpty }; break
                    }
                    guard t.count >= 4, Int(t[0]) != nil, let zz = Int(t[1]) else { throw xtbFail("xtb", k, "bad charge row '\(L[k])'") }
                    // columns: idx Z symbol covCN q ... (the symbol is its own token); q is at qi+1 because "#" has no counterpart
                    let col = t.count > qi + 1 && Double(t[2]) == nil ? qi + 1 : qi
                    guard col < t.count, let qv = Double(t[col]) else { throw xtbFail("xtb", k, "bad charge value in '\(L[k])'") }
                    q.append(qv); z.append(zz); k += 1
                }
                guard closed, !q.isEmpty else { throw xtbFail("xtb", L.count - 1, "truncated charge table") }
                o.charges = q; o.elements = z
                i = k; continue
            }
            i += 1
        }
        if haveTh { th.electronicEnergy = o.totalEnergy; o.thermochemistry = th }
        o.info = runInfo(lines: L.map(String.init))
        return o
    }

    /// Program-neutral result. `geometry` (e.g. from xtbopt.xyz) is attached as the single step when given.
    public func result(geometry: Molecule? = nil) -> CalculationResult {
        var r = CalculationResult()
        if let g = geometry { r.steps = [g]; if let e = totalEnergy { r.energies = [e] } }
        r.normalTermination = normalTermination
        r.dipole = dipoleDebye
        var x = CalculationExtras()
        x.program = "xtb"
        x.programVersion = programVersion
        x.finalEnergy = totalEnergy
        if !charges.isEmpty { x.charges["xtb"] = charges }
        x.thermochemistry = thermochemistry
        x.homoLumoGapEV = homoLumoGapEV
        x.optimizationConverged = optimizationConverged
        x.messages = messages
        x.info = info
        r.extras = x
        return r
    }

    public var result: CalculationResult { result(geometry: nil) }
}

// MARK: - gradient (Turbomole $grad)

public struct XTBGradientCycle: Sendable, Codable, Equatable {
    public var energy: Double
    public var gradientNorm: Double
    public var molecule: Molecule      // Angstrom
    public var gradient: [Vec3]        // Hartree/Bohr
}

public struct XTBGradientFile: Sendable, Codable, Equatable {
    public var cycles: [XTBGradientCycle]
    public var last: XTBGradientCycle? { cycles.last }

    public static func read(url: URL) throws -> XTBGradientFile { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> XTBGradientFile {
        let L = splitLines(text)
        guard L.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$grad") }) else {
            throw MolIOError.parse(format: "xtb-gradient", line: nil, message: "missing $grad")
        }
        var cycles: [XTBGradientCycle] = []
        var i = 0
        var ended = false
        while i < L.count {
            let s = L[i].trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("$end") { ended = true; break }
            if s.hasPrefix("cycle") {
                let e = xtbValue(after: "SCF energy =", in: s) ?? xtbValue(after: "energy =", in: s)
                let g = xtbValue(after: "|dE/dxyz| =", in: s) ?? 0
                guard let en = e else { throw xtbFail("xtb-gradient", i, "bad cycle line") }
                var k = i + 1
                var atoms: [Atom] = []
                var grad: [Vec3] = []
                while k < L.count {
                    let t = tokens(L[k])
                    if t.isEmpty { k += 1; continue }
                    if t.count == 4, parseFortranDouble(t[3]) == nil {
                        guard grad.isEmpty, let x = parseFortranDouble(t[0]), let y = parseFortranDouble(t[1]), let z = parseFortranDouble(t[2]),
                              let zn = IOElements.atomicNumber(label: String(t[3])) else { throw xtbFail("xtb-gradient", k, "bad coordinate row") }
                        atoms.append(Atom(id: atoms.count, atomicNumber: zn, position: Vec3(x, y, z) * bohrToAngstrom))
                    } else if t.count == 3 {
                        guard let x = parseFortranDouble(t[0]), let y = parseFortranDouble(t[1]), let z = parseFortranDouble(t[2]) else { throw xtbFail("xtb-gradient", k, "bad gradient row") }
                        grad.append(Vec3(x, y, z))
                    } else { break }
                    k += 1
                }
                guard !atoms.isEmpty, grad.count == atoms.count else { throw xtbFail("xtb-gradient", k - 1, "cycle has \(atoms.count) atoms but \(grad.count) gradient rows (truncated?)") }
                var m = Molecule(atoms: atoms)
                m.perceiveBonds()
                cycles.append(XTBGradientCycle(energy: en, gradientNorm: g, molecule: m, gradient: grad))
                i = k; continue
            }
            i += 1
        }
        guard ended, !cycles.isEmpty else { throw MolIOError.parse(format: "xtb-gradient", line: nil, message: "no complete cycle or missing $end") }
        return XTBGradientFile(cycles: cycles)
    }
}

// MARK: - charges file

public enum XTBChargesFile {
    /// One charge per line.
    public static func parse(_ text: String) throws -> [Double] {
        var q: [Double] = []
        for (n, l) in splitLines(text).enumerated() {
            let t = tokens(l)
            if t.isEmpty { continue }
            guard t.count == 1, let v = parseFortranDouble(t[0]) else { throw xtbFail("xtb-charges", n, "bad charge line '\(l)'") }
            q.append(v)
        }
        guard !q.isEmpty else { throw MolIOError.parse(format: "xtb-charges", line: nil, message: "no charges") }
        return q
    }
}

// MARK: - trajectory / xtbopt.xyz

public struct XTBTrajectory: Sendable, Codable, Equatable {
    public var molecules: [Molecule]
    public var energies: [Double]
    public var gradientNorms: [Double?]

    public static func read(url: URL) throws -> XTBTrajectory { try parse(try readText(url)) }

    /// Multi-frame XYZ whose comment lines look like " energy: -5.07 gnorm: 0.01 xtb: 6.7.1 (...)".
    /// Every frame must carry an energy.
    public static func parse(_ text: String) throws -> XTBTrajectory {
        let frames = try XYZFormat.parse(text)
        guard !frames.isEmpty else { throw MolIOError.parse(format: "xtb-xyz", line: nil, message: "no frames") }
        var e: [Double] = [], g: [Double?] = []
        for (n, f) in frames.enumerated() {
            guard let en = xtbValue(after: "energy:", in: f.title) else {
                throw MolIOError.parse(format: "xtb-xyz", line: nil, message: "frame \(n + 1) has no 'energy:' in its comment line")
            }
            e.append(en); g.append(xtbValue(after: "gnorm:", in: f.title))
        }
        var mols = frames
        for k in mols.indices { mols[k].perceiveBonds() }
        return XTBTrajectory(molecules: mols, energies: e, gradientNorms: g)
    }

    public var result: CalculationResult {
        var r = CalculationResult()
        r.steps = molecules; r.energies = energies
        var x = CalculationExtras(); x.program = "xtb"; x.finalEnergy = energies.last
        if gradientNorms.contains(where: { $0 != nil }) { x.stepInfo = gradientNorms.map { OptimizationStepInfo(gradientNorm: $0) } }
        r.extras = x
        return r
    }
}

// MARK: - g98.out frequencies

/// xtb's Gaussian-98-style vibrational output (`g98.out`): "Frequencies --", "Red. masses --", "Frc consts --",
/// "IR Inten --" and "Atom AN X Y Z" displacement blocks (3 modes per block).
public enum XTBG98Frequencies {
    public static func read(url: URL) throws -> [NormalMode] { try parse(try readText(url)) }

    public static func parse(_ text: String, atomCount: Int? = nil) throws -> [NormalMode] {
        var L = splitLines(text)
        // An unterminated last line is a partial write; trailing blanks cannot close a block in a cut file.
        if !(text.hasSuffix("\n") || text.hasSuffix("\r") || text.hasSuffix("\r\n")), !L.isEmpty { L.removeLast() }
        while let l = L.last, tokens(l).isEmpty { L.removeLast() }
        var modes: [NormalMode] = []
        var i = 0
        var natoms = atomCount
        func nums(_ s: Substring) -> [Double] {
            guard let r = s.range(of: "--") else { return [] }
            return tokens(s[r.upperBound...]).compactMap { parseFortranDouble($0) }
        }
        while i < L.count {
            let s = L[i]
            if s.contains("Frequencies --") {
                let f = nums(s)
                guard !f.isEmpty else { throw xtbFail("xtb-g98", i, "empty frequency line") }
                var red: [Double] = [], frc: [Double] = [], ir: [Double] = []
                var k = i + 1
                var sawAtomHeader = false
                while k < L.count {
                    let l = L[k]
                    if l.contains("Red. masses --") { red = nums(l) }
                    else if l.contains("Frc consts  --") || l.contains("Frc consts --") { frc = nums(l) }
                    else if l.contains("IR Inten    --") || l.contains("IR Inten --") { ir = nums(l) }
                    else if tokens(l).first == "Atom" { sawAtomHeader = true; k += 1; break }
                    else if l.contains("Frequencies --") { break }
                    k += 1
                }
                guard sawAtomHeader else { throw xtbFail("xtb-g98", k - 1, "missing 'Atom AN X Y Z' header") }
                var disp: [[Vec3]] = Array(repeating: [], count: f.count)
                var terminated = false
                var rows = 0
                while k < L.count {
                    let t = tokens(L[k])
                    if t.count == 2 + 3 * f.count, Int(t[0]) != nil, Int(t[1]) != nil {
                        let v = t.dropFirst(2).compactMap { Double($0) }
                        guard v.count == 3 * f.count else { throw xtbFail("xtb-g98", k, "bad displacement row") }
                        for m in 0..<f.count { disp[m].append(Vec3(v[3 * m], v[3 * m + 1], v[3 * m + 2])) }
                        rows += 1; k += 1
                    } else { terminated = true; break }
                }
                // A block that runs to end of file is complete only if its atom count is known to match.
                if !terminated, rows > 0, let n = natoms, n == rows { terminated = true }
                guard terminated, rows > 0 else { throw xtbFail("xtb-g98", L.count - 1, "truncated displacement block") }
                if let n = natoms, n != rows { throw xtbFail("xtb-g98", k - 1, "displacement block has \(rows) atoms, expected \(n)") }
                natoms = rows
                for m in 0..<f.count {
                    var nm = NormalMode(frequency: f[m], irIntensity: m < ir.count ? ir[m] : 0, displacements: disp[m])
                    if m < red.count { nm.reducedMass = red[m] }
                    if m < frc.count { nm.forceConstant = frc[m] }
                    modes.append(nm)
                }
                i = k; continue
            }
            i += 1
        }
        guard !modes.isEmpty else { throw MolIOError.parse(format: "xtb-g98", line: nil, message: "no frequency data found") }
        return modes
    }
}
