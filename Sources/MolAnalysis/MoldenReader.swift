import Foundation
import MolCore
import MolIO

/// Minimal reader for the public Molden format ([Atoms], [GTO], [5D]/[7F]/[9G] flags, [MO]) producing a
/// MolIO `Wavefunction` in the `BasisSet` conventions (coefficients for normalized primitives, fchk function
/// order). Local fallback for MolAnalysis until MolIO's own Molden reader is available.
///
/// Conventions handled:
/// - Contraction coefficients: if the shells are not normalized when read as normalized-primitive coefficients,
///   they are assumed to include the primitive normalization (as written by orca_2mkl) and are divided by it.
/// - Cartesian g functions are reordered from the Molden order to `BasisSet.cartesianOrder(4)`.
/// - Files written by ORCA: MO coefficients of pure functions with |m| ≥ 3 are sign-flipped to the standard
///   real solid harmonics.
public enum MoldenWavefunctionReader {
    public enum ReadError: Error, CustomStringConvertible {
        case missing(String), malformed(String)
        public var description: String {
            switch self { case .missing(let s): return "Molden: missing \(s)"; case .malformed(let s): return "Molden: malformed \(s)" }
        }
    }

    public static func read(url: URL) throws -> Wavefunction { try parse(String(contentsOf: url, encoding: .utf8)) }

    public static func parse(_ text: String) throws -> Wavefunction {
        let lines = text.components(separatedBy: .newlines)
        func num(_ s: Substring) -> Double? { Double(s.replacingOccurrences(of: "D", with: "E").replacingOccurrences(of: "d", with: "e")) }
        var section = "", atomsInBohr = true
        var atomZ: [Int] = [], atomPos: [Vec3] = []
        var shellsRaw: [(atom: Int, kind: String, exps: [Double], c1: [Double], c2: [Double])] = []
        var pureD = false, pureF = false, pureG = false
        struct MO { var energy = 0.0, spin = "alpha", occ = 0.0, coefs: [Int: Double] = [:] }
        var mos: [MO] = []
        var currentAtom = -1
        let isORCA = text.range(of: "orca", options: .caseInsensitive) != nil
        var i = 0
        while i < lines.count {
            let raw = lines[i]; let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                let close = line.firstIndex(of: "]") ?? line.endIndex
                section = line[line.index(after: line.startIndex)..<close].lowercased()
                let rest = line[close...].lowercased()
                switch section {
                case "atoms": atomsInBohr = !rest.contains("angs")
                case "5d", "5d7f": pureD = true; pureF = section == "5d7f" || pureF
                case "5d10f": pureD = true; pureF = false
                case "7f": pureF = true
                case "9g": pureG = true
                default: break
                }
                continue
            }
            let tok = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch section {
            case "atoms":
                guard tok.count >= 6, let z = Int(tok[2]), let x = num(tok[3]), let y = num(tok[4]), let w = num(tok[5]) else { continue }
                atomZ.append(z)
                let p = Vec3(x, y, w)
                atomPos.append(atomsInBohr ? p : p * PhysConst.angstromToBohr)
            case "gto":
                if tok.count >= 1, let a = Int(tok[0]), tok.count <= 2 { currentAtom = a - 1; continue }
                guard tok.count >= 2, let np = Int(tok[1]) else { continue }
                let kind = tok[0].lowercased()
                var e: [Double] = [], c1: [Double] = [], c2: [Double] = []
                for _ in 0..<np {
                    guard i < lines.count else { throw ReadError.malformed("GTO primitives") }
                    let t = lines[i].split(whereSeparator: { $0 == " " || $0 == "\t" }); i += 1
                    guard t.count >= 2, let ex = num(t[0]), let cc = num(t[1]) else { throw ReadError.malformed("primitive line") }
                    e.append(ex); c1.append(cc)
                    if kind == "sp", t.count >= 3, let cp = num(t[2]) { c2.append(cp) }
                }
                shellsRaw.append((currentAtom, kind, e, c1, c2))
            case "mo":
                if line.contains("=") {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let key = parts[0].lowercased(), val = parts.count > 1 ? parts[1] : ""
                    if mos.last.map({ !$0.coefs.isEmpty }) ?? true { mos.append(MO()) }
                    switch key {
                    case "ene": mos[mos.count - 1].energy = num(Substring(val)) ?? 0
                    case "spin": mos[mos.count - 1].spin = val.lowercased().hasPrefix("b") ? "beta" : "alpha"
                    case "occup": mos[mos.count - 1].occ = num(Substring(val)) ?? 0
                    default: break
                    }
                } else if tok.count >= 2, let idx = Int(tok[0]), let c = num(tok[1]), !mos.isEmpty {
                    mos[mos.count - 1].coefs[idx - 1] = c
                }
            default: break
            }
        }
        guard !atomZ.isEmpty else { throw ReadError.missing("[Atoms]") }
        guard !shellsRaw.isEmpty else { throw ReadError.missing("[GTO]") }
        guard !mos.isEmpty else { throw ReadError.missing("[MO]") }

        let lOf: [String: Int] = ["s": 0, "p": 1, "sp": 1, "d": 2, "f": 3, "g": 4, "h": 5]
        var shells: [BasisSet.Shell] = []
        for r in shellsRaw {
            guard let l = lOf[r.kind], r.atom >= 0, r.atom < atomPos.count else { throw ReadError.malformed("shell \(r.kind)") }
            let pure = (l == 2 && pureD) || (l == 3 && pureF) || (l >= 4 && pureG)
            shells.append(BasisSet.Shell(atomIndex: r.atom, center: atomPos[r.atom], angularMomentum: l, isSP: r.kind == "sp",
                                         isPure: pure, exponents: r.exps, coefficients: r.c1,
                                         spCoefficients: r.kind == "sp" ? r.c2 : nil))
        }
        // Normalization convention detection.
        func norm(_ c: [Double], _ e: [Double], _ l: Int) -> Double {
            var s = 0.0
            for a in c.indices { for b in c.indices { s += c[a] * c[b] * BasisPreparation.primitiveOverlap(e[a], e[b], l) } }
            return s
        }
        let normalizedAsIs = shells.allSatisfy { abs(norm($0.coefficients, $0.exponents, $0.isSP ? 0 : $0.angularMomentum) - 1) < 1e-3 }
        if !normalizedAsIs {
            for k in shells.indices {
                let s = shells[k]
                let l0 = s.isSP ? 0 : s.angularMomentum
                shells[k].coefficients = zip(s.coefficients, s.exponents).map { $0 / BasisPreparation.radialNorm($1, l0) }
                if let sp = s.spCoefficients { shells[k].spCoefficients = zip(sp, s.exponents).map { $0 / BasisPreparation.radialNorm($1, 1) } }
            }
        }
        let basis = BasisSet(shells: shells)
        let nbf = basis.functionCount

        // Per-function permutation / sign: file index → BasisSet index.
        var perm = Array(0..<nbf), sign = [Double](repeating: 1, count: nbf)
        let moldenG: [(Int, Int, Int)] = [(4,0,0),(0,4,0),(0,0,4),(3,1,0),(3,0,1),(1,3,0),(0,3,1),(1,0,3),(0,1,3),
                                          (2,2,0),(2,0,2),(0,2,2),(2,1,1),(1,2,1),(1,1,2)]
        for (si, off) in basis.shellOffsets.enumerated() {
            let s = shells[si]
            if s.angularMomentum == 4 && !s.isPure {
                let target = BasisSet.cartesianOrder(4)
                for (fi, m) in moldenG.enumerated() {
                    if let t = target.firstIndex(where: { $0 == m }) { perm[off + fi] = off + t }
                }
            }
            if isORCA && s.isPure && s.angularMomentum >= 3 {
                for (fi, m) in BasisSet.pureOrder(s.angularMomentum).enumerated() where abs(m) >= 3 { sign[off + fi] = -1 }
            }
        }

        func coefficientRows(_ set: [MO]) -> [Double] {
            var out = [Double](repeating: 0, count: set.count * nbf)
            for (r, mo) in set.enumerated() {
                for (idx, c) in mo.coefs where idx < nbf { out[r * nbf + perm[idx]] = c * sign[idx] }
            }
            return out
        }
        let alphaMOs = mos.filter { $0.spin == "alpha" }.sorted { $0.energy < $1.energy }
        let betaMOs = mos.filter { $0.spin == "beta" }.sorted { $0.energy < $1.energy }
        let unrestricted = !betaMOs.isEmpty
        let occA = alphaMOs.reduce(0.0) { $0 + $1.occ }, occB = betaMOs.reduce(0.0) { $0 + $1.occ }
        var nA: Int, nB: Int
        if unrestricted {
            nA = Int(occA.rounded()); nB = Int(occB.rounded())
        } else {
            let doubly = alphaMOs.filter { $0.occ > 1.5 }.count, singly = alphaMOs.filter { $0.occ > 0.5 && $0.occ <= 1.5 }.count
            nA = doubly + singly; nB = doubly
        }
        let alpha = MOCoefficients(energies: alphaMOs.map(\.energy), coefficients: coefficientRows(alphaMOs), basisCount: nbf, occupiedCount: nA)
        let beta = unrestricted ? MOCoefficients(energies: betaMOs.map(\.energy), coefficients: coefficientRows(betaMOs), basisCount: nbf, occupiedCount: nB) : nil
        return Wavefunction(basis: basis, alpha: alpha, beta: beta, atomicNumbers: atomZ, nuclearPositions: atomPos, betaElectronCount: nB)
    }
}
