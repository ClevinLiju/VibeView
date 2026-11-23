import Foundation
import MolCore

// Formatted checkpoint (.fchk) reader/writer, from the public description of the layout:
//   line 1: title; line 2: job type (A10), method (A30), basis (A30);
//   then sections: "Name (40 cols)", type letter I/R/C/L/H, and either a scalar value or "N=  count"
//   followed by the array (I: 6 per line I12, R: 5 per line E16.8, C/H: 5 per line A12, L: 6 per line).
//
// Unlike logs, any truncation or malformation throws: an array shorter than its declared N,
// a bad header, a non-numeric value, inconsistent basis-set arrays.

/// Hartree atomic unit of dipole (e*bohr) to Debye.
public let atomicUnitToDebye: Double = 2.541746473

public struct FormattedCheckpoint: Sendable, Codable, Equatable {

    public enum Value: Sendable, Codable, Equatable {
        case ints([Int])
        case reals([Double])
        case string(String)
        case logicals([Bool])
    }

    /// One section exactly as it appeared in the file (order preserved).
    public struct Section: Sendable, Codable, Equatable {
        public var name: String
        public var isScalar: Bool
        public var value: Value
    }

    public var title: String = ""
    public var jobType: String = ""
    public var method: String = ""
    public var basisName: String = ""

    /// Geometry in Å with charge and multiplicity.
    public var molecule = Molecule()
    public var alphaElectrons: Int = 0
    public var betaElectrons: Int = 0
    public var totalEnergy: Double?
    public var scfEnergy: Double?

    /// Basis set and MOs (centers in Bohr); nil when the file has no basis information.
    public var wavefunction: Wavefunction?

    public var mullikenCharges: [Double]?
    /// "Dipole Moment" as stored in the file: atomic units (e*bohr).
    public var dipoleAtomicUnits: Vec3?
    /// Dipole in Debye (converted from the stored atomic units).
    public var dipole: Vec3? {
        get { dipoleAtomicUnits.map { $0 * atomicUnitToDebye } }
        set { dipoleAtomicUnits = newValue.map { $0 / atomicUnitToDebye } }
    }
    /// Hartree/Bohr, 3N.
    public var cartesianGradient: [Double]?
    /// Lower-triangular packed 3N x 3N Hessian, Hartree/Bohr^2.
    public var cartesianForceConstants: [Double]?
    /// Best effort from "Vib-E2"/"Vib-Modes": frequencies, IR intensities, Cartesian displacement vectors.
    public var normalModes: [NormalMode] = []
    /// "Route" section text if present.
    public var route: String?

    /// Every section by name, in file order, so nothing is lost.
    public var sections: [Section] = []

    public init() {}

    // MARK: Generic access

    public func section(_ name: String) -> Section? { sections.last { $0.name == name } }
    public func ints(_ name: String) -> [Int]? { if case .ints(let v)? = section(name)?.value { return v }; return nil }
    public func reals(_ name: String) -> [Double]? { if case .reals(let v)? = section(name)?.value { return v }; return nil }
    public func int(_ name: String) -> Int? { ints(name)?.first }
    public func real(_ name: String) -> Double? { reals(name)?.first }
    public func string(_ name: String) -> String? { if case .string(let s)? = section(name)?.value { return s }; return nil }
    /// Scalar sections by name.
    public var scalars: [String: Value] {
        var d: [String: Value] = [:]
        for s in sections where s.isScalar { d[s.name] = s.value }
        return d
    }
    /// Array sections by name.
    public var arrays: [String: Value] {
        var d: [String: Value] = [:]
        for s in sections where !s.isScalar { d[s.name] = s.value }
        return d
    }

    public static func read(url: URL) throws -> FormattedCheckpoint { try parse(try readText(url)) }

    // MARK: Parsing

    static func fail(_ line: Int?, _ msg: String) -> MolIOError { .parse(format: "fchk", line: line, message: msg) }

    /// Fortran reals: accepts D exponents and exponent-less glued forms such as "1.5000000-100".
    static func parseReal(_ s: Substring) -> Double? {
        if let d = Double(s) { return d }
        if let d = parseFortranDouble(s) { return d }
        // "1.23456789-100" (three-digit exponent drops the 'E')
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            if (s[idx] == "-" || s[idx] == "+"), s[s.index(before: idx)] != "E", s[s.index(before: idx)] != "e" {
                return Double("\(s[..<idx])E\(s[idx...])")
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    public static func parse(_ text: String) throws -> FormattedCheckpoint {
        var lines = splitLines(text)
        while let l = lines.last, glTrim(l).isEmpty { lines.removeLast() }
        guard lines.count >= 3 else { throw fail(nil, "file too short to be a formatted checkpoint") }
        var fc = FormattedCheckpoint()
        fc.title = String(glTrim(lines[0]))
        let jt = tokens(lines[1])
        guard jt.count >= 2 else { throw fail(2, "bad job-type line") }
        fc.jobType = String(jt[0])
        if jt.count >= 3 {
            fc.method = jt[1..<(jt.count - 1)].joined(separator: " ")
            fc.basisName = String(jt[jt.count - 1])
        } else { fc.method = String(jt[1]) }

        var i = 2
        let n = lines.count
        while i < n {
            let line = lines[i]
            if glTrim(line).isEmpty { i += 1; continue }
            let tk = tokens(line)
            guard tk.count >= 3 else { throw fail(i + 1, "bad section header") }
            let isArray = tk.count >= 4 && (tk[tk.count - 2] == "N=" )
            let isArrayGlued = !isArray && tk[tk.count - 1].hasPrefix("N=") && tk[tk.count - 1].count > 2
            var typeIdx: Int
            var count = 0
            if isArray {
                typeIdx = tk.count - 3
                guard let c = Int(tk[tk.count - 1]), c >= 0 else { throw fail(i + 1, "bad array length") }
                count = c
            } else if isArrayGlued {
                typeIdx = tk.count - 2
                guard let c = Int(tk[tk.count - 1].dropFirst(2)), c >= 0 else { throw fail(i + 1, "bad array length") }
                count = c
            } else {
                typeIdx = tk.count - 2
            }
            guard typeIdx >= 1 else { throw fail(i + 1, "bad section header") }
            let typ = tk[typeIdx]
            guard typ.count == 1, "IRCLH".contains(typ) else { throw fail(i + 1, "unknown section type '\(typ)'") }
            let name = String(glTrim(line[..<tk[typeIdx].startIndex]))
            guard !name.isEmpty else { throw fail(i + 1, "empty section name") }

            if !(isArray || isArrayGlued) {
                let vtok = tk[tk.count - 1]
                let v: Value
                switch typ {
                case "I": guard let x = Int(vtok) else { throw fail(i + 1, "bad integer scalar for '\(name)'") }; v = .ints([x])
                case "R": guard let x = parseReal(vtok) else { throw fail(i + 1, "bad real scalar for '\(name)'") }; v = .reals([x])
                case "L":
                    switch vtok { case "T", "1": v = .logicals([true]); case "F", "0": v = .logicals([false])
                    default: throw fail(i + 1, "bad logical scalar for '\(name)'") }
                default: v = .string(String(vtok))
                }
                fc.sections.append(.init(name: name, isScalar: true, value: v))
                i += 1
                continue
            }

            // Array body.
            i += 1
            switch typ {
            case "I":
                var out: [Int] = []; out.reserveCapacity(count)
                while out.count < count {
                    guard i < n else { throw fail(nil, "array '\(name)' truncated: \(out.count) of \(count) values") }
                    for s in tokens(lines[i]) {
                        guard let x = Int(s) else { throw fail(i + 1, "non-integer value in '\(name)'") }
                        out.append(x)
                    }
                    guard out.count <= count else { throw fail(i + 1, "array '\(name)' longer than declared N=\(count)") }
                    i += 1
                }
                fc.sections.append(.init(name: name, isScalar: false, value: .ints(out)))
            case "R":
                var out: [Double] = []; out.reserveCapacity(count)
                while out.count < count {
                    guard i < n else { throw fail(nil, "array '\(name)' truncated: \(out.count) of \(count) values") }
                    for s in tokens(lines[i]) {
                        guard let x = parseReal(s) else { throw fail(i + 1, "non-numeric value in '\(name)'") }
                        out.append(x)
                    }
                    guard out.count <= count else { throw fail(i + 1, "array '\(name)' longer than declared N=\(count)") }
                    i += 1
                }
                fc.sections.append(.init(name: name, isScalar: false, value: .reals(out)))
            case "L":
                var out: [Bool] = []
                while out.count < count {
                    guard i < n else { throw fail(nil, "array '\(name)' truncated") }
                    for s in tokens(lines[i]) {
                        switch s { case "T", "1": out.append(true); case "F", "0": out.append(false)
                        default: throw fail(i + 1, "bad logical in '\(name)'") }
                    }
                    guard out.count <= count else { throw fail(i + 1, "array '\(name)' longer than declared N=\(count)") }
                    i += 1
                }
                fc.sections.append(.init(name: name, isScalar: false, value: .logicals(out)))
            default: // C / H: N chunks of 12 characters, 5 per line
                let lineCount = (count + 4) / 5
                var s = ""
                for k in 0..<lineCount {
                    guard i < n else { throw fail(nil, "character array '\(name)' truncated") }
                    let chunks = min(5, count - 5 * k)
                    var l = String(lines[i])
                    if l.count < chunks * 12 { l += String(repeating: " ", count: chunks * 12 - l.count) }
                    s += l.prefix(chunks * 12)
                    i += 1
                }
                while s.last == " " { s.removeLast() }
                fc.sections.append(.init(name: name, isScalar: false, value: .string(s)))
            }
        }
        try fc.interpret()
        return fc
    }

    // MARK: Interpretation of known sections

    private mutating func interpret() throws {
        guard let nAtoms = int("Number of atoms"), nAtoms >= 0 else { throw Self.fail(nil, "missing 'Number of atoms'") }
        guard let zs = ints("Atomic numbers"), zs.count == nAtoms else { throw Self.fail(nil, "'Atomic numbers' missing or its length differs from the atom count") }
        guard let coords = reals("Current cartesian coordinates"), coords.count == 3 * nAtoms else {
            throw Self.fail(nil, "'Current cartesian coordinates' missing or not 3N long")
        }
        var atoms: [Atom] = []
        atoms.reserveCapacity(nAtoms)
        for a in 0..<nAtoms {
            atoms.append(Atom(id: a, atomicNumber: max(0, zs[a]),
                              position: Vec3(coords[3 * a], coords[3 * a + 1], coords[3 * a + 2]) * bohrToAngstrom))
        }
        molecule = Molecule(atoms: atoms, bonds: [], charge: int("Charge") ?? 0, multiplicity: int("Multiplicity") ?? 1, title: title)
        alphaElectrons = int("Number of alpha electrons") ?? 0
        betaElectrons = int("Number of beta electrons") ?? 0
        totalEnergy = real("Total Energy")
        scfEnergy = real("SCF Energy")
        if let m = reals("Mulliken Charges") {
            guard m.count == nAtoms else { throw Self.fail(nil, "'Mulliken Charges' length differs from the atom count") }
            mullikenCharges = m
        }
        if let d = reals("Dipole Moment") {
            guard d.count == 3 else { throw Self.fail(nil, "'Dipole Moment' must have 3 values") }
            dipoleAtomicUnits = Vec3(d[0], d[1], d[2])
        }
        if let g = reals("Cartesian Gradient") {
            guard g.count == 3 * nAtoms else { throw Self.fail(nil, "'Cartesian Gradient' is not 3N long") }
            cartesianGradient = g
        }
        if let h = reals("Cartesian Force Constants") {
            let m = 3 * nAtoms
            guard h.count == m * (m + 1) / 2 else { throw Self.fail(nil, "'Cartesian Force Constants' has the wrong length") }
            cartesianForceConstants = h
        }
        route = string("Route")
        try interpretWavefunction(nAtoms: nAtoms, coords: coords, zs: zs)
        interpretVibrations(nAtoms: nAtoms)
    }

    private mutating func interpretWavefunction(nAtoms: Int, coords: [Double], zs: [Int]) throws {
        guard let types = ints("Shell types") else { return }
        func need(_ name: String) throws -> [Double] {
            guard let v = reals(name) else { throw Self.fail(nil, "basis information incomplete: missing '\(name)'") }
            return v
        }
        guard let prims = ints("Number of primitives per shell"), let map = ints("Shell to atom map") else {
            throw Self.fail(nil, "basis information incomplete: missing shell arrays")
        }
        let exps = try need("Primitive exponents")
        let cc = try need("Contraction coefficients")
        let nShell = types.count
        guard prims.count == nShell, map.count == nShell else { throw Self.fail(nil, "shell array lengths disagree") }
        let totalPrims = prims.reduce(0, +)
        guard prims.allSatisfy({ $0 >= 1 }), totalPrims == exps.count, totalPrims == cc.count else {
            throw Self.fail(nil, "primitive counts disagree with exponent/coefficient arrays")
        }
        let hasSP = types.contains(-1)
        var sp: [Double]? = reals("P(S=P) Contraction coefficients")
        if hasSP {
            guard let s = sp, s.count == totalPrims else { throw Self.fail(nil, "SP shells need 'P(S=P) Contraction coefficients' of full length") }
        } else if let s = sp, s.count != totalPrims { throw Self.fail(nil, "'P(S=P) Contraction coefficients' has the wrong length") }
        if !hasSP { sp = nil }
        var shellXYZ: [Double]? = reals("Coordinates of each shell")
        if let s = shellXYZ, s.count != 3 * nShell { throw Self.fail(nil, "'Coordinates of each shell' is not 3 x shells long") }
        if shellXYZ == nil { shellXYZ = nil }

        var shells: [BasisSet.Shell] = []
        shells.reserveCapacity(nShell)
        var off = 0
        for s in 0..<nShell {
            let t = types[s]
            guard abs(t) <= 9 else { throw Self.fail(nil, "unsupported shell type \(t)") }
            let a = map[s]
            guard a >= 1, a <= nAtoms else { throw Self.fail(nil, "shell \(s + 1) refers to atom \(a), outside 1...\(nAtoms)") }
            let np = prims[s]
            let center: Vec3
            if let xyz = shellXYZ { center = Vec3(xyz[3 * s], xyz[3 * s + 1], xyz[3 * s + 2]) }
            else { center = Vec3(coords[3 * (a - 1)], coords[3 * (a - 1) + 1], coords[3 * (a - 1) + 2]) }
            let isSP = t == -1
            let l = isSP ? 1 : abs(t)
            let pure = !isSP && t <= -2
            shells.append(BasisSet.Shell(
                atomIndex: a - 1, center: center, angularMomentum: l, isSP: isSP, isPure: pure,
                exponents: Array(exps[off..<(off + np)]), coefficients: Array(cc[off..<(off + np)]),
                spCoefficients: isSP ? Array(sp![off..<(off + np)]) : nil))
            off += np
        }
        let basis = BasisSet(shells: shells)
        let nbf = basis.functionCount
        if let declared = int("Number of basis functions"), declared != nbf {
            throw Self.fail(nil, "'Number of basis functions' (\(declared)) differs from the shell expansion (\(nbf))")
        }
        guard nbf > 0 else { throw Self.fail(nil, "empty basis") }

        func moSet(_ coefName: String, _ energyName: String, occ: Int) throws -> MOCoefficients? {
            guard let c = reals(coefName) else { return nil }
            guard !c.isEmpty, c.count % nbf == 0, c.count / nbf <= nbf else {
                throw Self.fail(nil, "'\(coefName)' length \(c.count) is not a multiple of the basis size \(nbf)")
            }
            let nmo = c.count / nbf
            var e = reals(energyName) ?? Array(repeating: 0, count: nmo)
            if e.count != nmo { throw Self.fail(nil, "'\(energyName)' length differs from the number of orbitals") }
            if reals(energyName) == nil { e = Array(repeating: 0, count: nmo) }
            return MOCoefficients(energies: e, coefficients: c, basisCount: nbf, occupiedCount: occ)
        }
        guard let alpha = try moSet("Alpha MO coefficients", "Alpha Orbital Energies", occ: alphaElectrons) else {
            throw Self.fail(nil, "basis present but 'Alpha MO coefficients' missing")
        }
        let beta = try moSet("Beta MO coefficients", "Beta Orbital Energies", occ: betaElectrons)
        let tri = nbf * (nbf + 1) / 2
        var dens: [Double]? = reals("Total SCF Density")
        var spin: [Double]? = reals("Spin SCF Density")
        if let d = dens, d.count != tri { throw Self.fail(nil, "'Total SCF Density' length \(d.count) != \(tri)") }
        if let d = spin, d.count != tri { throw Self.fail(nil, "'Spin SCF Density' length \(d.count) != \(tri)") }
        if dens?.isEmpty == true { dens = nil }
        if spin?.isEmpty == true { spin = nil }
        wavefunction = Wavefunction(
            basis: basis, alpha: alpha, beta: beta, totalDensity: dens, spinDensity: spin,
            atomicNumbers: zs, nuclearPositions: (0..<nAtoms).map { Vec3(coords[3 * $0], coords[3 * $0 + 1], coords[3 * $0 + 2]) },
            betaElectronCount: betaElectrons)
    }

    private mutating func interpretVibrations(nAtoms: Int) {
        guard nAtoms > 0, let modes = reals("Vib-Modes"), let e2 = reals("Vib-E2"), !modes.isEmpty,
              modes.count % (3 * nAtoms) == 0 else { return }
        let k = modes.count / (3 * nAtoms)
        guard e2.count >= k else { return }
        var out: [NormalMode] = []
        for m in 0..<k {
            let disp = (0..<nAtoms).map { a -> Vec3 in
                let b = m * 3 * nAtoms + 3 * a
                return Vec3(modes[b], modes[b + 1], modes[b + 2])
            }
            let ir = e2.count >= 4 * k ? e2[3 * k + m] : 0
            out.append(NormalMode(frequency: e2[m], irIntensity: ir, ramanActivity: nil, symmetry: nil, displacements: disp))
        }
        normalModes = out
    }

    // MARK: Contract view

    public var calculationResult: CalculationResult {
        var r = CalculationResult()
        var m = molecule
        if let q = mullikenCharges, q.count == m.atoms.count { for k in 0..<q.count { m.atoms[k].charge = q[k] } }
        r.steps = [m]
        if let e = scfEnergy ?? totalEnergy { r.energies = [e] }
        r.normalModes = normalModes
        r.mullikenCharges = mullikenCharges ?? []
        r.dipole = dipole
        r.routeSection = route ?? ""
        r.normalTermination = true
        if let wf = wavefunction {
            let unres = wf.beta != nil
            for (k, e) in wf.alpha.energies.enumerated() {
                r.orbitals.append(.init(index: k + 1, energy: e, occupied: k < wf.alpha.occupiedCount, spin: unres ? .alpha : .restricted))
            }
            if let b = wf.beta {
                for (k, e) in b.energies.enumerated() { r.orbitals.append(.init(index: k + 1, energy: e, occupied: k < b.occupiedCount, spin: .beta)) }
            }
        }
        return r
    }
}

// MARK: - Writing

extension FormattedCheckpoint {

    private static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    private static func lpad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }

    /// Sections regenerated from the structured fields, in canonical order.
    private func generatedSections() -> [(String, Bool, Value)] {
        var g: [(String, Bool, Value)] = []
        let atoms = molecule.atoms
        g.append(("Number of atoms", true, .ints([atoms.count])))
        g.append(("Charge", true, .ints([molecule.charge])))
        g.append(("Multiplicity", true, .ints([molecule.multiplicity])))
        g.append(("Number of electrons", true, .ints([alphaElectrons + betaElectrons])))
        g.append(("Number of alpha electrons", true, .ints([alphaElectrons])))
        g.append(("Number of beta electrons", true, .ints([betaElectrons])))
        if let wf = wavefunction {
            g.append(("Number of basis functions", true, .ints([wf.basis.functionCount])))
            g.append(("Number of independent functions", true, .ints([wf.alpha.orbitalCount])))
        }
        g.append(("Atomic numbers", false, .ints(atoms.map(\.atomicNumber))))
        // coordinates: keep stored values when the molecule was not modified (exact round trip)
        var xyz: [Double] = []
        xyz.reserveCapacity(atoms.count * 3)
        for a in atoms { xyz += [a.position.x * angstromToBohr, a.position.y * angstromToBohr, a.position.z * angstromToBohr] }
        if let stored = reals("Current cartesian coordinates"), stored.count == xyz.count {
            var same = true
            for a in 0..<atoms.count {
                let p = Vec3(stored[3 * a], stored[3 * a + 1], stored[3 * a + 2]) * bohrToAngstrom
                if p != atoms[a].position { same = false; break }
            }
            if same { xyz = stored }
        }
        g.append(("Current cartesian coordinates", false, .reals(xyz)))
        if let wf = wavefunction {
            let b = wf.basis
            g.append(("Number of contracted shells", true, .ints([b.shells.count])))
            g.append(("Number of primitive shells", true, .ints([b.primitivesPerShell.reduce(0, +)])))
            g.append(("Shell types", false, .ints(b.shellTypes)))
            g.append(("Number of primitives per shell", false, .ints(b.primitivesPerShell)))
            g.append(("Shell to atom map", false, .ints(b.shellToAtomMap)))
            g.append(("Primitive exponents", false, .reals(b.primitiveExponents)))
            g.append(("Contraction coefficients", false, .reals(b.contractionCoefficients)))
            if b.shells.contains(where: \.isSP) {
                g.append(("P(S=P) Contraction coefficients", false, .reals(b.spContractionCoefficients)))
            }
            g.append(("Coordinates of each shell", false, .reals(b.shellCoordinates.flatMap { [$0.x, $0.y, $0.z] })))
        }
        if let e = scfEnergy { g.append(("SCF Energy", true, .reals([e]))) }
        if let e = totalEnergy { g.append(("Total Energy", true, .reals([e]))) }
        if let wf = wavefunction {
            g.append(("Alpha Orbital Energies", false, .reals(wf.alpha.energies)))
            g.append(("Alpha MO coefficients", false, .reals(wf.alpha.coefficients)))
            if let b = wf.beta {
                g.append(("Beta Orbital Energies", false, .reals(b.energies)))
                g.append(("Beta MO coefficients", false, .reals(b.coefficients)))
            }
            if let d = wf.totalDensity { g.append(("Total SCF Density", false, .reals(d))) }
            if let d = wf.spinDensity { g.append(("Spin SCF Density", false, .reals(d))) }
        }
        if let m = mullikenCharges { g.append(("Mulliken Charges", false, .reals(m))) }
        if let d = dipoleAtomicUnits { g.append(("Dipole Moment", false, .reals([d.x, d.y, d.z]))) }
        if let gr = cartesianGradient { g.append(("Cartesian Gradient", false, .reals(gr))) }
        if let h = cartesianForceConstants { g.append(("Cartesian Force Constants", false, .reals(h))) }
        return g
    }

    /// Serialize in the fixed-width fchk layout. Sections that came from a file keep their order; known
    /// sections are regenerated from the structured fields (so edits to `molecule`, `wavefunction`, ... are written).
    public func write() -> String {
        var out = ""
        out += String(title.prefix(72)) + "\n"
        out += Self.pad(jobType, 10) + Self.pad(method, 30) + Self.pad(basisName, 30) + "\n"
        var gen = generatedSections()
        var emitted: [(String, Bool, Value)] = []
        for s in sections {
            if let k = gen.firstIndex(where: { $0.0 == s.name }) {
                emitted.append(gen[k]); gen.remove(at: k)
            } else { emitted.append((s.name, s.isScalar, s.value)) }
        }
        emitted += gen
        for (name, scalar, value) in emitted { Self.emit(&out, name, scalar, value) }
        return out
    }

    private static func emit(_ out: inout String, _ name: String, _ scalar: Bool, _ value: Value) {
        let head = pad(name, 40)
        switch value {
        case .ints(let v):
            if scalar, v.count == 1 { out += head + "   I     " + lpad(String(v[0]), 12) + "\n"; return }
            out += head + "   I   N=" + lpad(String(v.count), 12) + "\n"
            var k = 0
            while k < v.count {
                let end = min(k + 6, v.count)
                for x in v[k..<end] { out += lpad(String(x), 12) }
                out += "\n"; k = end
            }
        case .reals(let v):
            if scalar, v.count == 1 { out += head + "   R     " + String(format: "%22.15E", v[0]) + "\n"; return }
            out += head + "   R   N=" + lpad(String(v.count), 12) + "\n"
            var k = 0
            while k < v.count {
                let end = min(k + 5, v.count)
                for x in v[k..<end] { out += String(format: "%16.8E", x) }
                out += "\n"; k = end
            }
        case .logicals(let v):
            if scalar, v.count == 1 { out += head + "   L     " + lpad(v[0] ? "1" : "0", 12) + "\n"; return }
            out += head + "   L   N=" + lpad(String(v.count), 12) + "\n"
            var k = 0
            while k < v.count {
                let end = min(k + 6, v.count)
                for x in v[k..<end] { out += lpad(x ? "1" : "0", 12) }
                out += "\n"; k = end
            }
        case .string(let s):
            if scalar { out += head + "   C     " + s + "\n"; return }
            var str = s
            if str.count % 12 != 0 { str += String(repeating: " ", count: 12 - str.count % 12) }
            let chars = Array(str)
            let chunks = chars.count / 12
            out += head + "   C   N=" + lpad(String(chunks), 12) + "\n"
            var c = 0
            while c < chunks {
                let end = min(c + 5, chunks)
                out += String(chars[(c * 12)..<(end * 12)]) + "\n"
                c = end
            }
        }
    }
}
