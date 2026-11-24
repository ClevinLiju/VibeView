import Foundation
import MolCore

// Molden-format reader/writer, written from the public Molden format description
// ([Atoms], [GTO], [5D]/[7F]/[9G], [MO], [FREQ], [FR-COORD], [FR-NORM-COORD], [INT],
// [GEOMETRIES], [GEOCONV]).
//
// NORMALIZATION CONCLUSION (determined empirically on ORCA 6.1.1 `orca_2mkl -molden` files, see the
// io.molden checks): ORCA writes, for every primitive, the contraction coefficient multiplied by the
// primitive normalization (i.e. coefficients for UNNORMALIZED primitives; e.g. STO-3G O 1s coefficient
// 0.1543 appears as 4.2519 for exponent 130.709). `BasisSet` wants coefficients for NORMALIZED
// primitives, so the reader divides each coefficient by N(alpha, l) = sqrt(2 (2 alpha)^(l+3/2) / Gamma(l+3/2))
// and then (default) rescales the shell so the contracted function has unit norm. With that
// transformation both water/STO-3G and H2CO/def2-SVP (pure d) give unit-norm basis functions and
// orthonormal MOs (C S C^T = I). Any l-dependent constant that a program folds into its primitive
// factor is absorbed by the contracted renormalization (all conventions share the alpha^(l/2+3/4)
// dependence). Other programs that write coefficients for already-normalized primitives can be read
// with `primitiveConvention: .normalizedPrimitives`.
//
// SIGN CONVENTION: ORCA is documented to use the opposite sign for pure f/g functions with
// m = +-3 and +-4 relative to the Molden standard. The reader flips those MO coefficients when the
// title contains "orca" (disable with `applyOrcaSignConvention: false`). NOTE: no real fixture
// with f or g functions was available, so this flip is implemented from the documented behaviour
// and is NOT validated by the checks.

public struct MoldenFile: Sendable {
    public enum PrimitiveConvention: Sendable {
        /// Coefficients multiply unnormalized primitives (ORCA's convention; default).
        case unnormalizedPrimitives
        /// Coefficients multiply already-normalized primitives.
        case normalizedPrimitives
    }

    public var title: String = ""
    /// Geometry in Angstrom (charge/multiplicity derived from the electron count when MOs exist).
    public var molecule: Molecule
    public var wavefunction: Wavefunction?
    public var normalModes: [NormalMode] = []
    /// Frames from [GEOMETRIES] XYZ (Angstrom).
    public var geometries: [Molecule] = []
    /// Energies from [GEOCONV] (Hartree), one per frame when present.
    public var geometryEnergies: [Double] = []
    public var orbitals: [OrbitalInfo] = []
    /// True if the ORCA f/g sign convention was undone while reading.
    public var orcaSignConventionApplied: Bool = false

    public var result: CalculationResult {
        var r = CalculationResult()
        r.steps = geometries.isEmpty ? [molecule] : geometries
        if !geometryEnergies.isEmpty, geometryEnergies.count == r.steps.count { r.energies = geometryEnergies }
        r.normalModes = normalModes
        r.orbitals = orbitals
        r.normalTermination = true
        var ex = CalculationExtras()
        ex.program = "molden"
        r.extras = ex
        return r
    }

    public static func read(url: URL, normalizeContractions: Bool = true,
                            primitiveConvention: PrimitiveConvention = .unnormalizedPrimitives,
                            applyOrcaSignConvention: Bool = true) throws -> MoldenFile {
        try parse(try readText(url), normalizeContractions: normalizeContractions,
                  primitiveConvention: primitiveConvention, applyOrcaSignConvention: applyOrcaSignConvention)
    }

    // MARK: parsing

    fileprivate struct Section {
        var name: String
        var arg: String
        var line: Int
        var lines: [(Int, Substring)]
    }

    fileprivate static func fail(_ line: Int?, _ msg: String) -> MolIOError {
        .parse(format: "Molden", line: line, message: msg)
    }

    public static func parse(_ text: String, normalizeContractions: Bool = true,
                             primitiveConvention: PrimitiveConvention = .unnormalizedPrimitives,
                             applyOrcaSignConvention: Bool = true) throws -> MoldenFile {
        var sections: [Section] = []
        for (n, raw) in splitLines(text).enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                let name = t[t.index(after: t.startIndex)..<close].trimmingCharacters(in: .whitespaces).lowercased()
                let arg = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
                sections.append(Section(name: name, arg: arg, line: n + 1, lines: []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append((n + 1, raw))
            }
        }
        guard !sections.isEmpty else { throw fail(nil, "no Molden sections found") }
        func sec(_ n: String) -> Section? { sections.first { $0.name == n } }

        // Title
        var title = ""
        if let s = sec("title") {
            title = s.lines.map { $0.1.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }

        // Atoms
        guard let atomsSec = sec("atoms") else { throw fail(nil, "missing [Atoms] section") }
        let atomsInAU = !atomsSec.arg.lowercased().hasPrefix("ang")
        var atoms: [Atom] = []
        var bohr: [Vec3] = []
        for (ln, raw) in atomsSec.lines {
            let tk = tokens(raw)
            if tk.isEmpty { continue }
            guard tk.count >= 6, Int(tk[1]) != nil, let x = parseFortranDouble(tk[3]),
                  let y = parseFortranDouble(tk[4]), let z = parseFortranDouble(tk[5]) else {
                throw fail(ln, "malformed [Atoms] line")
            }
            var zn = Int(tk[2]) ?? -1
            if zn < 0 || zn >= IOElements.symbols.count { zn = IOElements.atomicNumber(label: String(tk[0])) ?? 0 }
            if zn == 0, let zz = IOElements.atomicNumber(label: String(tk[0])) { zn = zz }
            let p = Vec3(x, y, z)
            let pb = atomsInAU ? p : p * angstromToBohr
            bohr.append(pb)
            atoms.append(Atom(id: atoms.count, atomicNumber: zn, position: pb * bohrToAngstrom))
        }
        guard !atoms.isEmpty else { throw fail(atomsSec.line, "[Atoms] section is empty") }
        var molecule = Molecule(atoms: atoms, bonds: [], charge: 0, multiplicity: 1, title: title)

        // Pure/Cartesian flags
        var dPure = false, fPure = false, gPure = false
        for s in sections {
            switch s.name {
            case "5d": dPure = true; fPure = true
            case "5d7f": dPure = true; fPure = true
            case "5d10f": dPure = true
            case "7f": fPure = true
            case "9g": gPure = true
            default: break
            }
        }

        var file = MoldenFile(title: title, molecule: molecule)
        let isOrca = title.lowercased().contains("orca")

        // GTO
        var shells: [BasisSet.Shell] = []
        if let g = sec("gto") {
            shells = try parseGTO(g, bohr: bohr, dPure: dPure, fPure: fPure, gPure: gPure,
                                  normalize: normalizeContractions, convention: primitiveConvention)
        }
        let basis = BasisSet(shells: shells)
        let nbf = basis.functionCount

        // MO
        struct RawMO { var ene = 0.0; var occ = 0.0; var spin = "alpha"; var coefs: [(Int, Double)] = []; var line = 0; var seenKeys = Set<String>() }
        var mos: [RawMO] = []
        if let m = sec("mo") {
            var cur: RawMO? = nil
            for (ln, raw) in m.lines {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let eq = t.firstIndex(of: "="), !t.hasPrefix("-"), t[..<eq].allSatisfy({ $0.isLetter || $0 == " " }) {
                    let key = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    guard ["sym", "ene", "spin", "occup"].contains(key) else { throw fail(ln, "unknown [MO] key '\(key)'") }
                    if let c = cur, !c.coefs.isEmpty || c.seenKeys.contains(key) { mos.append(c); cur = nil }
                    if cur == nil { cur = RawMO(); cur?.line = ln }
                    cur?.seenKeys.insert(key)
                    switch key {
                    case "ene":
                        guard let v = parseFortranDouble(val) else { throw fail(ln, "bad orbital energy") }
                        cur?.ene = v
                    case "occup":
                        guard let v = parseFortranDouble(val) else { throw fail(ln, "bad occupation") }
                        cur?.occ = v
                    case "spin": cur?.spin = val.lowercased().hasPrefix("b") ? "beta" : "alpha"
                    default: break
                    }
                } else {
                    let tk = tokens(t)
                    guard tk.count >= 2, let idx = Int(tk[0]), let v = parseFortranDouble(tk[1]), v.isFinite else {
                        throw fail(ln, "malformed MO coefficient line")
                    }
                    guard cur != nil else { throw fail(ln, "MO coefficient before any MO header") }
                    guard idx >= 1 else { throw fail(ln, "MO coefficient index \(idx) < 1") }
                    if nbf > 0 && idx > nbf { throw fail(ln, "MO coefficient index \(idx) exceeds the basis size \(nbf)") }
                    cur?.coefs.append((idx, v))
                }
            }
            if let c = cur { mos.append(c) }
            if nbf > 0, let last = mos.last {
                // The last block of a file that ends early is the only one we can detect: it must reach nbf.
                if (last.coefs.last?.0 ?? 0) < nbf { throw fail(last.line, "last MO is truncated (ends before basis function \(nbf))") }
            }
        }

        // Orbital infos + wavefunction
        let hasBeta = mos.contains { $0.spin == "beta" }
        var aMOs = mos.filter { $0.spin == "alpha" }
        let bMOs = mos.filter { $0.spin == "beta" }
        var aIdx = 0, bIdx = 0
        for mo in mos {
            let isB = mo.spin == "beta"
            if isB { bIdx += 1 } else { aIdx += 1 }
            file.orbitals.append(OrbitalInfo(index: isB ? bIdx : aIdx, energy: mo.ene, occupied: mo.occ > 0.5,
                                             spin: hasBeta ? (isB ? .beta : .alpha) : .restricted))
        }
        if nbf > 0, !aMOs.isEmpty {
            // Index permutation / sign vector per basis function.
            let (perm, flip) = basisAdjustments(shells, orcaSigns: isOrca && applyOrcaSignConvention)
            file.orcaSignConventionApplied = isOrca && applyOrcaSignConvention && flip.contains(true)
            func build(_ list: [RawMO]) -> MOCoefficients {
                var c = [Double](repeating: 0, count: list.count * nbf)
                for (i, mo) in list.enumerated() {
                    for (idx, v) in mo.coefs {
                        let target = perm[idx - 1]
                        c[i * nbf + target] = flip[target] ? -v : v
                    }
                }
                return MOCoefficients(energies: list.map(\.ene), coefficients: c, basisCount: nbf, occupiedCount: 0)
            }
            var alpha = build(aMOs)
            let nA: Int, nB: Int
            if hasBeta {
                nA = Int(aMOs.reduce(0) { $0 + $1.occ }.rounded())
                nB = Int(bMOs.reduce(0) { $0 + $1.occ }.rounded())
            } else {
                nA = aMOs.filter { $0.occ > 0.5 }.count
                nB = aMOs.filter { $0.occ > 1.5 }.count
            }
            alpha.occupiedCount = nA
            var beta: MOCoefficients? = nil
            if hasBeta { var b = build(bMOs); b.occupiedCount = nB; beta = b }
            aMOs = []
            file.wavefunction = Wavefunction(basis: basis, alpha: alpha, beta: beta,
                                             atomicNumbers: atoms.map(\.atomicNumber), nuclearPositions: bohr,
                                             betaElectronCount: nB)
            let electrons = nA + nB
            molecule.charge = atoms.reduce(0) { $0 + $1.atomicNumber } - electrons
            molecule.multiplicity = abs(nA - nB) + 1
            file.molecule = molecule
        }

        // Vibrations
        file.normalModes = try parseModes(sections, natoms: atoms.count)

        // Geometries
        if let g = sec("geometries") {
            file.geometries = try parseXYZFrames(g)
        }
        if let g = sec("geoconv") {
            var inEnergy = false
            var vals: [Double] = []
            for (_, raw) in g.lines {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let v = parseFortranDouble(t.split(separator: " ").first ?? "") {
                    if inEnergy { vals.append(v) }
                } else { inEnergy = t.lowercased() == "energy" }
            }
            file.geometryEnergies = vals
        }
        return file
    }

    // MARK: [GTO]

    fileprivate static func parseGTO(_ g: Section, bohr: [Vec3], dPure: Bool, fPure: Bool, gPure: Bool,
                                     normalize: Bool, convention: PrimitiveConvention) throws -> [BasisSet.Shell] {
        var out: [BasisSet.Shell] = []
        var atomIndex = -1
        let lines = g.lines
        var i = 0
        while i < lines.count {
            let (ln, raw) = lines[i]
            i += 1
            let tk = tokens(raw)
            if tk.isEmpty { continue }
            if Int(tk[0]) != nil {
                guard let a = Int(tk[0]), a >= 1, a <= bohr.count else { throw fail(ln, "[GTO] atom index out of range") }
                atomIndex = a - 1
                continue
            }
            let label = tk[0].lowercased()
            let l: Int
            switch label {
            case "s": l = 0
            case "p": l = 1
            case "d": l = 2
            case "f": l = 3
            case "g": l = 4
            case "sp", "l": l = 1
            default: throw fail(ln, "unknown shell label '\(tk[0])'")
            }
            guard atomIndex >= 0 else { throw fail(ln, "shell before any atom header") }
            guard tk.count >= 2, let nprim = Int(tk[1]), nprim >= 1, nprim <= 1000 else { throw fail(ln, "bad primitive count") }
            let isSP = label == "sp" || label == "l"
            var exps: [Double] = [], c1: [Double] = [], c2: [Double] = []
            for _ in 0..<nprim {
                guard i < lines.count else { throw fail(ln, "[GTO] shell truncated (expected \(nprim) primitives)") }
                let (pl, praw) = lines[i]; i += 1
                let pt = tokens(praw)
                guard pt.count >= (isSP ? 3 : 2), let e = parseFortranDouble(pt[0]), let a = parseFortranDouble(pt[1]),
                      e > 0, e.isFinite, a.isFinite else { throw fail(pl, "malformed primitive line") }
                exps.append(e); c1.append(a)
                if isSP {
                    guard let b = parseFortranDouble(pt[2]), b.isFinite else { throw fail(pl, "malformed sp primitive line") }
                    c2.append(b)
                }
            }
            let pure = (l == 2 && dPure) || (l == 3 && fPure) || (l == 4 && gPure)
            let center = bohr[atomIndex]
            let ls = isSP ? 0 : l
            let s1 = adjust(c1, exps, ls, normalize, convention)
            let s2 = isSP ? adjust(c2, exps, 1, normalize, convention) : nil
            out.append(BasisSet.Shell(atomIndex: atomIndex, center: center, angularMomentum: l, isSP: isSP,
                                      isPure: isSP ? false : pure, exponents: exps, coefficients: s1, spCoefficients: s2))
        }
        return out
    }

    /// Radial primitive normalization sqrt(2 (2a)^(l+3/2) / Gamma(l+3/2)).
    static func radialNorm(_ a: Double, _ l: Int) -> Double {
        let p = Double(l) + 1.5
        return (2 * pow(2 * a, p) / tgamma(p)).squareRoot()
    }

    private static func adjust(_ c: [Double], _ e: [Double], _ l: Int, _ normalize: Bool, _ conv: PrimitiveConvention) -> [Double] {
        var out = c
        if conv == .unnormalizedPrimitives { for k in out.indices { out[k] /= radialNorm(e[k], l) } }
        if normalize {
            var n2 = 0.0
            let p = Double(l) + 1.5
            for i in out.indices { for j in out.indices {
                n2 += out[i] * out[j] * pow(2 * (e[i] * e[j]).squareRoot() / (e[i] + e[j]), p)
            } }
            if n2 > 1e-300, n2.isFinite { let s = 1 / n2.squareRoot(); for k in out.indices { out[k] *= s } }
        }
        return out
    }

    /// Molden Cartesian g order (powers x,y,z).
    private static let moldenG: [(Int, Int, Int)] = [(4,0,0),(0,4,0),(0,0,4),(3,1,0),(3,0,1),(1,3,0),(0,3,1),
                                                    (1,0,3),(0,1,3),(2,2,0),(2,0,2),(0,2,2),(2,1,1),(1,2,1),(1,1,2)]

    /// For each file basis-function index (0-based): position in the BasisSet ordering; and per target
    /// position whether the sign is flipped (ORCA m = +-3, +-4 convention).
    fileprivate static func basisAdjustments(_ shells: [BasisSet.Shell], orcaSigns: Bool) -> ([Int], [Bool]) {
        var perm: [Int] = [], flip: [Bool] = []
        var base = 0
        for s in shells {
            let n = s.functionCount
            var local = Array(0..<n)
            var fl = [Bool](repeating: false, count: n)
            if !s.isSP && !s.isPure && s.angularMomentum == 4 {
                let order = BasisSet.cartesianOrder(4)
                // file index f (Molden order) -> BasisSet position
                local = moldenG.map { p in order.firstIndex { $0 == p } ?? 0 }
            }
            if orcaSigns && !s.isSP && s.isPure && (s.angularMomentum == 3 || s.angularMomentum == 4) {
                for (k, m) in BasisSet.pureOrder(s.angularMomentum).enumerated() where abs(m) >= 3 { fl[k] = true }
            }
            for k in 0..<n { perm.append(base + local[k]) }
            flip.append(contentsOf: fl.map { $0 })
            base += n
        }
        return (perm, flip)
    }

    // MARK: vibrations / geometries

    fileprivate static func parseModes(_ sections: [Section], natoms: Int) throws -> [NormalMode] {
        func sec(_ n: String) -> Section? { sections.first { $0.name == n } }
        func numbers(_ s: Section) throws -> [Double] {
            var v: [Double] = []
            for (ln, raw) in s.lines {
                for t in tokens(raw) {
                    guard let d = parseFortranDouble(t) else { throw fail(ln, "bad number '\(t)'") }
                    v.append(d)
                }
            }
            return v
        }
        guard let fs = sec("freq") else { return [] }
        let freqs = try numbers(fs)
        let ints = try sec("int").map(numbers) ?? []
        var modes: [NormalMode] = []
        var blocks: [[Vec3]] = []
        if let ns = sec("fr-norm-coord") {
            var cur: [Vec3]? = nil
            for (ln, raw) in ns.lines {
                let tk = tokens(raw)
                if tk.isEmpty { continue }
                if tk[0].lowercased() == "vibration" {
                    if let c = cur { blocks.append(c) }
                    cur = []
                } else {
                    guard tk.count >= 3, let x = parseFortranDouble(tk[0]), let y = parseFortranDouble(tk[1]),
                          let z = parseFortranDouble(tk[2]), cur != nil else { throw fail(ln, "malformed normal-coordinate line") }
                    cur?.append(Vec3(x, y, z))
                }
            }
            if let c = cur { blocks.append(c) }
        }
        for (i, f) in freqs.enumerated() {
            var disp: [Vec3] = []
            if i < blocks.count {
                guard blocks[i].count == natoms else {
                    throw fail(nil, "vibration \(i + 1) has \(blocks[i].count) displacements, expected \(natoms)")
                }
                disp = blocks[i]
            } else { disp = [Vec3](repeating: .zero, count: natoms) }
            modes.append(NormalMode(frequency: f, irIntensity: i < ints.count ? ints[i] : 0, displacements: disp))
        }
        return modes
    }

    fileprivate static func parseXYZFrames(_ g: Section) throws -> [Molecule] {
        var frames: [Molecule] = []
        let lines = g.lines.filter { _ in true }
        var i = 0
        // Skip a leading "XYZ"/"ZMAT" keyword line.
        func isBlank(_ s: Substring) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        while i < lines.count {
            let t = lines[i].1.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.uppercased() == "XYZ" || t.uppercased() == "ZMAT" { i += 1; continue }
            guard let n = Int(t), n >= 1 else { throw fail(lines[i].0, "bad [GEOMETRIES] atom count") }
            i += 2 // count + comment
            var atoms: [Atom] = []
            for _ in 0..<n {
                guard i < lines.count else { throw fail(lines[lines.count - 1].0, "[GEOMETRIES] frame truncated") }
                let (ln, raw) = lines[i]; i += 1
                let tk = tokens(raw)
                guard tk.count >= 4, let x = parseFortranDouble(tk[1]), let y = parseFortranDouble(tk[2]),
                      let z = parseFortranDouble(tk[3]) else { throw fail(ln, "malformed geometry line") }
                atoms.append(Atom(id: atoms.count, atomicNumber: IOElements.atomicNumber(label: String(tk[0])) ?? 0,
                                  position: Vec3(x, y, z)))
            }
            frames.append(Molecule(atoms: atoms))
        }
        return frames
    }
}

// MARK: - Writer

public enum MoldenWriter {
    public static func write(_ file: MoldenFile) -> String {
        MoldenFile.write(molecule: file.molecule, wavefunction: file.wavefunction, normalModes: file.normalModes,
                         geometries: file.geometries, geometryEnergies: file.geometryEnergies,
                         title: file.title, orcaSignConvention: file.orcaSignConventionApplied)
    }
}

extension MoldenFile {
    public func write() -> String { MoldenWriter.write(self) }

    /// Molden text. Coefficients are written for unnormalized primitives (the convention `parse` assumes
    /// by default), so parse(write(x)) reproduces the basis and MOs. With `orcaSignConvention` the
    /// ORCA f/g sign flip is re-applied (use it when writing a file that was read with the flip undone).
    public static func write(molecule: Molecule, wavefunction: Wavefunction?, normalModes: [NormalMode] = [],
                             geometries: [Molecule] = [], geometryEnergies: [Double] = [],
                             title: String = "", orcaSignConvention: Bool = false) -> String {
        func num(_ x: Double) -> String { "\(x)" }
        var o = "[Molden Format]\n[Title]\n"
        var t = title.isEmpty ? "VibeView" : title
        if !orcaSignConvention { t = t.replacingOccurrences(of: "orca", with: "OR-CA", options: .caseInsensitive) }
        o += " \(t.replacingOccurrences(of: "\n", with: " "))\n\n[Atoms] AU\n"
        let bohr: [Vec3] = (wavefunction?.nuclearPositions.count == molecule.atoms.count)
            ? wavefunction!.nuclearPositions : molecule.atoms.map { $0.position * angstromToBohr }
        for (i, a) in molecule.atoms.enumerated() {
            let s = IOElements.symbol(a.atomicNumber)
            o += "\(s) \(i + 1) \(a.atomicNumber) \(num(bohr[i].x)) \(num(bohr[i].y)) \(num(bohr[i].z))\n"
        }
        if let wf = wavefunction {
            o += "[GTO]\n"
            let labels = ["s", "p", "d", "f", "g"]
            var lastAtom = -1
            for sh in wf.basis.shells {
                if sh.atomIndex != lastAtom {
                    if lastAtom >= 0 { o += "\n" }
                    o += "\(sh.atomIndex + 1) 0\n"
                    lastAtom = sh.atomIndex
                }
                let l = sh.angularMomentum
                let label = sh.isSP ? "sp" : (l < labels.count ? labels[l] : "s")
                o += "\(label) \(sh.exponents.count) 1.00\n"
                for k in sh.exponents.indices {
                    let e = sh.exponents[k]
                    let c1 = (k < sh.coefficients.count ? sh.coefficients[k] : 0) * MoldenFile.radialNorm(e, sh.isSP ? 0 : l)
                    if sh.isSP {
                        let c2 = ((sh.spCoefficients.flatMap { k < $0.count ? $0[k] : nil }) ?? 0) * MoldenFile.radialNorm(e, 1)
                        o += "\(num(e)) \(num(c1)) \(num(c2))\n"
                    } else {
                        o += "\(num(e)) \(num(c1))\n"
                    }
                }
            }
            o += "\n"
            let dP = wf.basis.shells.first { $0.angularMomentum == 2 && !$0.isSP }?.isPure ?? false
            let fP = wf.basis.shells.first { $0.angularMomentum == 3 && !$0.isSP }?.isPure ?? false
            let gP = wf.basis.shells.first { $0.angularMomentum == 4 && !$0.isSP }?.isPure ?? false
            if dP && fP { o += "[5D]\n[7F]\n" } else if dP { o += "[5D10F]\n" } else if fP { o += "[7F]\n" }
            if gP { o += "[9G]\n" }
            let (perm, flip) = MoldenFile.basisAdjustments(wf.basis.shells, orcaSigns: orcaSignConvention)
            let nbf = wf.basis.functionCount
            o += "[MO]\n"
            func emit(_ set: MOCoefficients, spin: String, occFor: (Int) -> Double) {
                for i in 0..<set.orbitalCount {
                    o += " Sym= A\n Ene= \(num(i < set.energies.count ? set.energies[i] : 0))\n Spin= \(spin)\n Occup= \(num(occFor(i)))\n"
                    for f in 0..<nbf {
                        let target = perm[f]
                        var v = set.coefficients[i * nbf + target]
                        if flip[target] { v = -v }
                        o += "\(f + 1) \(num(v))\n"
                    }
                }
            }
            if let b = wf.beta {
                emit(wf.alpha, spin: "Alpha") { $0 < wf.alpha.occupiedCount ? 1 : 0 }
                emit(b, spin: "Beta") { $0 < b.occupiedCount ? 1 : 0 }
            } else {
                let nB = wf.betaElectronCount ?? wf.alpha.occupiedCount
                emit(wf.alpha, spin: "Alpha") { $0 < nB ? 2 : ($0 < wf.alpha.occupiedCount ? 1 : 0) }
            }
        }
        if !normalModes.isEmpty {
            o += "[FREQ]\n" + normalModes.map { num($0.frequency) }.joined(separator: "\n") + "\n"
            o += "[FR-COORD]\n"
            for (i, a) in molecule.atoms.enumerated() {
                o += "\(IOElements.symbol(a.atomicNumber)) \(num(bohr[i].x)) \(num(bohr[i].y)) \(num(bohr[i].z))\n"
            }
            o += "[FR-NORM-COORD]\n"
            for (k, m) in normalModes.enumerated() {
                o += "vibration \(k + 1)\n"
                for d in m.displacements { o += "\(num(d.x)) \(num(d.y)) \(num(d.z))\n" }
            }
            o += "[INT]\n" + normalModes.map { num($0.irIntensity) }.joined(separator: "\n") + "\n"
        }
        if !geometries.isEmpty {
            o += "[GEOMETRIES] XYZ\n"
            for g in geometries {
                o += "\(g.atoms.count)\n\n"
                for a in g.atoms { o += "\(IOElements.symbol(a.atomicNumber)) \(num(a.position.x)) \(num(a.position.y)) \(num(a.position.z))\n" }
            }
            if !geometryEnergies.isEmpty {
                o += "[GEOCONV]\nenergy\n" + geometryEnergies.map { num($0) }.joined(separator: "\n") + "\n"
            }
        }
        return o
    }
}
