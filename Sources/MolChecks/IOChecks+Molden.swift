import Foundation
import MolCore
import simd
@testable import MolIO

// Molden checks. Real fixtures: ORCA 6.1.1 orca_2mkl files in TestData/io/orca/.
// The orthonormality checks use a self-contained Gaussian overlap routine (Obara-Saika 1D recursion,
// Cartesian primitives, s/p/pure-d via real solid harmonics in the order 0,+1,-1,+2,-2).

fileprivate func mldFixture(_ n: String) throws -> String { try readText(testDataURL("io/orca/" + n)) }

// MARK: overlap machinery

fileprivate struct MldTerm { var a: Double; var w: Double; var c: Vec3; var p: (Int, Int, Int) }

fileprivate func mldRadial(_ a: Double, _ l: Int) -> Double {
    let p = Double(l) + 1.5
    return (2 * pow(2 * a, p) / tgamma(p)).squareRoot()
}

/// Terms (primitive, Cartesian monomial) of every basis function of a shell, unit-normalized convention.
fileprivate func mldFunctions(_ sh: BasisSet.Shell) throws -> [[MldTerm]] {
    let pi = Double.pi
    func build(_ l: Int, _ coefs: [Double], _ lin: [[((Int, Int, Int), Double)]]) -> [[MldTerm]] {
        lin.map { comb in
            var out: [MldTerm] = []
            for (k, a) in sh.exponents.enumerated() {
                for (pw, t) in comb { out.append(MldTerm(a: a, w: coefs[k] * mldRadial(a, l) * t, c: sh.center, p: pw)) }
            }
            return out
        }
    }
    func pFuncs(_ coefs: [Double]) -> [[MldTerm]] {
        let n = (3 / (4 * pi)).squareRoot()
        return build(1, coefs, [[((1, 0, 0), n)], [((0, 1, 0), n)], [((0, 0, 1), n)]])
    }
    let sN = (1 / (4 * pi)).squareRoot()
    if sh.isSP {
        return build(0, sh.coefficients, [[((0, 0, 0), sN)]]) + pFuncs(sh.spCoefficients ?? [])
    }
    switch (sh.angularMomentum, sh.isPure) {
    case (0, _): return build(0, sh.coefficients, [[((0, 0, 0), sN)]])
    case (1, _): return pFuncs(sh.coefficients)
    case (2, true):
        let a = (5 / (16 * pi)).squareRoot(), b = (15 / (4 * pi)).squareRoot(), c = (15 / (16 * pi)).squareRoot()
        return build(2, sh.coefficients, [
            [((0, 0, 2), 2 * a), ((2, 0, 0), -a), ((0, 2, 0), -a)],
            [((1, 0, 1), b)], [((0, 1, 1), b)],
            [((2, 0, 0), c), ((0, 2, 0), -c)],
            [((1, 1, 0), b)]])
    default: throw CheckFailure(description: "overlap routine supports s, p, pure d only")
    }
}

/// 1D Obara-Saika overlap of (x-A)^i e^{-a(x-A)^2} and (x-B)^j e^{-b(x-B)^2}.
fileprivate func mldS1(_ i: Int, _ j: Int, _ a: Double, _ b: Double, _ A: Double, _ B: Double) -> Double {
    let p = a + b, P = (a * A + b * B) / p
    let s00 = (Double.pi / p).squareRoot() * exp(-a * b / p * (A - B) * (A - B))
    func s(_ i: Int, _ j: Int) -> Double {
        if i < 0 || j < 0 { return 0 }
        if i == 0 && j == 0 { return s00 }
        if i > 0 {
            return (P - A) * s(i - 1, j) + (Double(i - 1) * s(i - 2, j) + Double(j) * s(i - 1, j - 1)) / (2 * p)
        }
        return (P - B) * s(i, j - 1) + (Double(j - 1) * s(i, j - 2) + Double(i) * s(i - 1, j - 1)) / (2 * p)
    }
    return s(i, j)
}

fileprivate func mldOverlapMatrix(_ basis: BasisSet) throws -> [[Double]] {
    var funcs: [[MldTerm]] = []
    for sh in basis.shells { funcs += try mldFunctions(sh) }
    let n = funcs.count
    var S = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in i..<n {
        var v = 0.0
        for t in funcs[i] { for u in funcs[j] {
            v += t.w * u.w * mldS1(t.p.0, u.p.0, t.a, u.a, t.c.x, u.c.x) * mldS1(t.p.1, u.p.1, t.a, u.a, t.c.y, u.c.y)
                * mldS1(t.p.2, u.p.2, t.a, u.a, t.c.z, u.c.z)
        } }
        S[i][j] = v; S[j][i] = v
    } }
    return S
}

fileprivate func mldOrthoDeviation(_ set: MOCoefficients, _ S: [[Double]]) -> Double {
    let n = set.basisCount, m = set.orbitalCount
    var worst = 0.0
    for i in 0..<m { for j in i..<m {
        var v = 0.0
        let ci = set.orbital(i), cj = set.orbital(j)
        for a in 0..<n { for b in 0..<n { v += ci[ci.startIndex + a] * S[a][b] * cj[cj.startIndex + b] } }
        worst = max(worst, abs(v - (i == j ? 1 : 0)))
    } }
    return worst
}

fileprivate func mldRelClose(_ a: [Double], _ b: [Double], _ tol: Double = 1e-8) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) where abs(x - y) > tol * max(1, abs(x), abs(y)) { return false }
    return true
}

fileprivate func mldSameWF(_ a: Wavefunction, _ b: Wavefunction) throws {
    try expect(a.basis.shells.count == b.basis.shells.count, "shell count")
    for (s, t) in zip(a.basis.shells, b.basis.shells) {
        try expect(s.atomIndex == t.atomIndex && s.angularMomentum == t.angularMomentum && s.isSP == t.isSP && s.isPure == t.isPure, "shell kind")
        try expect(mldRelClose(s.exponents, t.exponents) && mldRelClose(s.coefficients, t.coefficients), "shell numbers")
        try expect(mldRelClose(s.spCoefficients ?? [], t.spCoefficients ?? []), "sp coefficients")
        try expect(mldRelClose([s.center.x, s.center.y, s.center.z], [t.center.x, t.center.y, t.center.z]), "center")
    }
    for (x, y) in [(a.alpha, b.alpha)] + (a.beta != nil && b.beta != nil ? [(a.beta!, b.beta!)] : []) {
        try expect(x.occupiedCount == y.occupiedCount && x.basisCount == y.basisCount, "MO set meta")
        try expect(mldRelClose(x.energies, y.energies) && mldRelClose(x.coefficients, y.coefficients), "MO numbers")
    }
    try expect((a.beta == nil) == (b.beta == nil), "beta presence")
    try expect(a.betaElectrons == b.betaElectrons, "beta electrons")
}

fileprivate func mldTiny(d: Bool, sparse: Bool = true) -> String {
    let es = [3.42525091, 0.623913730, 0.168855404], cs = [0.15432897, 0.53532814, 0.44463454]
    func prim() -> String {
        var s = ""
        for k in 0..<3 {
            let e = String(format: "%.8E", es[k]), c = String(format: "%.8E", cs[k] * mldRadial(es[k], 0))
            s += d ? "\(e.replacingOccurrences(of: "E", with: "D")) \(c.replacingOccurrences(of: "E", with: "D"))\n" : "\(e) \(c)\n"
        }
        return s
    }
    return """
    [Molden Format]
    [Title]
     tiny H2

    [Atoms] AU
    H 1 1 0.0 0.0 0.0
    H 2 1 0.0 0.0 1.4
    [GTO]
    1 0
    s 3 1.0
    \(prim())
    2 0
    s 3 1.0
    \(prim())
    [MO]
     Sym= A
     Ene= -5.0D-01
     Spin= Alpha
     Occup= 2.0D+00
    1 5.0D-01
    2 5.0D-01
     Sym= A
     Ene= 6.0D-01
     Spin= Alpha
     Occup= 0.0
    \(sparse ? "2 1.0D+00" : "1 0.0\n2 1.0")
    [FREQ]
    4400.5D+00
    [FR-COORD]
    H 0.0 0.0 0.0
    H 0.0 0.0 1.4
    [FR-NORM-COORD]
    vibration 1
    0.0 0.0 -0.5
    0.0 0.0 0.5
    [INT]
    1.5

    """.replacingOccurrences(of: "    ", with: "")
}

fileprivate func mldThrowsIO(_ label: String, _ s: String) throws {
    do { _ = try MoldenFile.parse(s) } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func mldKeepLines(_ s: String, _ k: Int) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).prefix(k).joined(separator: "\n") + "\n"
}

extension Checks {
    static let ioMolden: [Check] = [
        Check("io.molden.water.header") {
            let f = try MoldenFile.parse(try mldFixture("water_optfreq.molden.input"))
            try expect(f.molecule.atoms.map(\.atomicNumber) == [8, 1, 1], "Z")
            try expectClose(f.molecule.atoms[1].position.y, 1.4325611793 * bohrToAngstrom, tol: 1e-9)
            try expect(f.molecule.charge == 0 && f.molecule.multiplicity == 1, "charge/mult")
            let wf = try wfOrFail(f)
            try expect(wf.basis.functionCount == 7 && wf.alpha.orbitalCount == 7, "nbf=7 got \(wf.basis.functionCount)")
            try expect(wf.alpha.occupiedCount == 5 && wf.betaElectrons == 5 && wf.beta == nil, "5/5 electrons, restricted")
            try expect(wf.basis.shells.count == 5 && wf.basis.shells[0].exponents.count == 3, "shells")
            try expectClose(wf.nuclearPositions[1].y, 1.4325611793, tol: 1e-9)
            try expect(f.result.extras?.program == "molden", "program")
        },
        Check("io.molden.water.energies") {
            let wf = try wfOrFail(try MoldenFile.parse(try mldFixture("water_optfreq.molden.input")))
            // ORBITAL ENERGIES of the final SCF in water_optfreq.out
            let ref = [-20.251577, -1.257550, -0.593855, -0.459731, -0.392617, 0.581795, 0.692675]
            for (a, b) in zip(wf.alpha.energies, ref) { try expectClose(a, b, tol: 1e-5) }
        },
        Check("io.molden.water.mos_match_out") {
            // Columns of "MOLECULAR ORBITALS" in water_optfreq.out (final block), rows s, 2s, pz, px, py, H, H;
            // the file order is s, 2s, px, py, pz, H, H.
            let ref: [[Double]] = [
                [0.994216, 0.025847, -0.004164, 0, 0, -0.005584, -0.005584],
                [-0.233766, 0.844449, -0.122839, 0, 0, 0.155595, 0.155595],
                [0, 0, 0, 0, -0.612697, -0.449222, 0.449222],
                [-0.104036, 0.538168, 0.755877, 0, 0, -0.295102, -0.295102],
                [0, 0, 0, -1, 0, 0, 0]]
            let wf = try wfOrFail(try MoldenFile.parse(try mldFixture("water_optfreq.molden.input")))
            for (m, col) in ref.enumerated() {
                let row = Array(wf.alpha.orbital(m))
                let mine = [row[0], row[1], row[4], row[2], row[3], row[5], row[6]]
                var sign = 1.0
                if let k = col.indices.max(by: { abs(col[$0]) < abs(col[$1]) }), mine[k] * col[k] < 0 { sign = -1 }
                for (x, y) in zip(mine, col) { try expectClose(sign * x, y, tol: 2e-6) }
            }
        },
        Check("io.molden.water.basis_unit_norm_and_orthonormal") {
            let wf = try wfOrFail(try MoldenFile.parse(try mldFixture("water_optfreq.molden.input")))
            let S = try mldOverlapMatrix(wf.basis)
            for i in S.indices { try expectClose(S[i][i], 1, tol: 1e-4) }
            let dev = mldOrthoDeviation(wf.alpha, S)
            try expect(dev < 1e-4, "C S C^T deviates from I by \(dev)")
        },
        Check("io.molden.h2co.def2svp") {
            let f = try MoldenFile.parse(try mldFixture("h2co_tddft.molden.input"))
            let wf = try wfOrFail(f)
            try expect(wf.alpha.occupiedCount == 8 && wf.betaElectrons == 8, "16 electrons")
            try expect(wf.basis.shells.contains { $0.angularMomentum == 2 && $0.isPure }, "pure d present")
            try expect(f.molecule.charge == 0 && f.molecule.multiplicity == 1, "neutral singlet")
            let ref = [-19.148763, -10.284115, -1.045669, -0.626310, -0.495380, -0.446245, -0.399892, -0.267121, -0.044255]
            for (a, b) in zip(wf.alpha.energies, ref) { try expectClose(a, b, tol: 1e-5) }
            try expect(f.orbitals.count == wf.alpha.orbitalCount && f.orbitals[7].occupied && !f.orbitals[8].occupied, "orbital infos")
        },
        Check("io.molden.h2co.unit_norm_and_orthonormal") {
            let wf = try wfOrFail(try MoldenFile.parse(try mldFixture("h2co_tddft.molden.input")))
            let S = try mldOverlapMatrix(wf.basis)
            for i in S.indices { try expectClose(S[i][i], 1, tol: 1e-4) }
            let dev = mldOrthoDeviation(wf.alpha, S)
            try expect(dev < 1e-4, "C S C^T deviates from I by \(dev)")
        },
        Check("io.molden.h2co.renormalization_required_for_d") {
            // Documents the empirical conclusion (measured on the real ORCA 6.1.1 file): the contracted shells
            // as written are not unit-normalized, so the default renormalization of each contracted shell
            // is required for an orthonormal MO set.
            let t = try mldFixture("h2co_tddft.molden.input")
            let b = try wfOrFail(try MoldenFile.parse(t, normalizeContractions: false))
            let raw = mldOrthoDeviation(b.alpha, try mldOverlapMatrix(b.basis))
            try expect(raw > 1e-4, "without renormalization the MOs should not be orthonormal (\(raw))")
            // The wrong convention must fail the orthonormality test (so the check is discriminating).
            let w = try wfOrFail(try MoldenFile.parse(t, normalizeContractions: false, primitiveConvention: .normalizedPrimitives))
            let dev = mldOrthoDeviation(w.alpha, try mldOverlapMatrix(w.basis))
            try expect(dev > 0.1, "wrong convention unexpectedly orthonormal (\(dev))")
        },
        Check("io.molden.oh.uhf") {
            let f = try MoldenFile.parse(try mldFixture("oh_uhf.molden.input"))
            let wf = try wfOrFail(f)
            try expect(wf.alpha.occupiedCount == 5 && wf.beta?.occupiedCount == 4 && wf.betaElectrons == 4, "5a/4b")
            try expect(f.molecule.multiplicity == 2 && f.molecule.charge == 0, "doublet neutral")
            let a = [-20.285711, -1.292187, -0.550984, -0.524557, -0.429668, 0.620055]
            let b = [-20.257236, -1.128200, -0.502870, -0.377794, 0.360032, 0.655761]
            for (x, y) in zip(wf.alpha.energies, a) { try expectClose(x, y, tol: 1e-5) }
            for (x, y) in zip(wf.beta?.energies ?? [], b) { try expectClose(x, y, tol: 1e-5) }
            try expect(f.orbitals.filter { $0.spin == .beta }.count == 6 && f.orbitals.filter { $0.spin == .alpha }.count == 6, "spin infos")
        },
        Check("io.molden.oh.orthonormal_per_spin") {
            let wf = try wfOrFail(try MoldenFile.parse(try mldFixture("oh_uhf.molden.input")))
            let S = try mldOverlapMatrix(wf.basis)
            for set in [wf.alpha, wf.beta!] { try expect(mldOrthoDeviation(set, S) < 1e-4, "UHF set not orthonormal") }
        },
        Check("io.molden.roundtrip.water") {
            let a = try MoldenFile.parse(try mldFixture("water_optfreq.molden.input"))
            let b = try MoldenFile.parse(a.write())
            try mldSameWF(try wfOrFail(a), try wfOrFail(b))
            for (p, q) in zip(a.molecule.atoms, b.molecule.atoms) { try expect(simd_length(p.position - q.position) < 1e-12, "geometry") }
        },
        Check("io.molden.roundtrip.h2co_pure_d") {
            let a = try MoldenFile.parse(try mldFixture("h2co_tddft.molden.input"))
            let text = a.write()
            try expect(text.contains("[5D"), "pure flag written")
            try mldSameWF(try wfOrFail(a), try wfOrFail(try MoldenFile.parse(text)))
        },
        Check("io.molden.roundtrip.uhf") {
            let a = try MoldenFile.parse(try mldFixture("oh_uhf.molden.input"))
            let b = try MoldenFile.parse(a.write())
            try mldSameWF(try wfOrFail(a), try wfOrFail(b))
            try expect(b.molecule.multiplicity == 2, "multiplicity survives")
        },
        Check("io.molden.roundtrip.modes_and_frames") {
            var f = try MoldenFile.parse(mldTiny(d: false))
            f.geometries = [f.molecule, f.molecule]
            f.geometryEnergies = [-1.1, -1.2]
            let g = try MoldenFile.parse(f.write())
            try expect(g.normalModes.count == 1, "mode count")
            try expectClose(g.normalModes[0].frequency, 4400.5, tol: 1e-9)
            try expectClose(g.normalModes[0].irIntensity, 1.5, tol: 1e-12)
            try expect(g.normalModes[0].displacements == f.normalModes[0].displacements, "displacements")
            try expect(g.geometries.count == 2 && g.geometryEnergies == [-1.1, -1.2], "frames/energies")
            try expect(g.result.steps.count == 2 && g.result.energies == [-1.1, -1.2], "result steps")
            // writer from raw parts, no wavefunction
            let t = MoldenFile.write(molecule: f.molecule, wavefunction: nil, normalModes: f.normalModes)
            try expect(try MoldenFile.parse(t).wavefunction == nil, "no basis -> no wavefunction")
        },
        Check("io.molden.fortran_d_exponents") {
            let a = try MoldenFile.parse(mldTiny(d: true)), b = try MoldenFile.parse(mldTiny(d: false))
            let wa = try wfOrFail(a)
            try expect(wa.basis.shells[0].exponents.count == 3, "prims")
            try expectClose(wa.alpha.energies[0], -0.5, tol: 1e-12)
            try expectClose(a.normalModes[0].frequency, 4400.5, tol: 1e-9)
            try mldSameWF(wa, try wfOrFail(b))
        },
        Check("io.molden.sparse_mo_indices") {
            let wf = try wfOrFail(try MoldenFile.parse(mldTiny(d: false)))
            try expect(Array(wf.alpha.orbital(1)) == [0, 1], "sparse MO filled with zeros: \(Array(wf.alpha.orbital(1)))")
            try expect(Array(wf.alpha.orbital(0)) == [0.5, 0.5], "dense MO")
            let dense = try wfOrFail(try MoldenFile.parse(mldTiny(d: false, sparse: false)))
            try expect(dense.alpha == wf.alpha, "dense == sparse")
            try expect(wf.alpha.occupiedCount == 1 && wf.betaElectrons == 1, "occupation 2 -> one orbital")
        },
        Check("io.molden.crlf_equals_lf") {
            let t = try mldFixture("h2co_tddft.molden.input")
            let a = try MoldenFile.parse(t), b = try MoldenFile.parse(t.replacingOccurrences(of: "\n", with: "\r\n"))
            try expect(a.wavefunction == b.wavefunction && a.molecule == b.molecule && a.title == b.title, "CRLF differs")
            let c = try MoldenFile.parse(mldTiny(d: true).replacingOccurrences(of: "\n", with: "\r"))
            try expect(c.normalModes.count == 1, "CR-only")
        },
        Check("io.molden.angstrom_atoms") {
            let t = mldTiny(d: false).replacingOccurrences(of: "[Atoms] AU", with: "[Atoms] Angs")
                .replacingOccurrences(of: "H 2 1 0.0 0.0 1.4", with: "H 2 1 0.0 0.0 0.74")
            let f = try MoldenFile.parse(t)
            try expectClose(f.molecule.atoms[1].position.z, 0.74, tol: 1e-12)
            try expectClose(try wfOrFail(f).nuclearPositions[1].z, 0.74 * angstromToBohr, tol: 1e-12)
        },
        Check("io.molden.cartesian_default_and_sp") {
            // d shell without [5D] flag is Cartesian; "sp" shells carry two coefficient columns.
            let t = """
            [Molden Format]
            [Atoms] Angs
            O 1 8 0.0 0.0 0.0
            [GTO]
            1 0
            sp 2 1.0
            1.0 0.5 0.4
            0.3 0.6 0.7
            d 1 1.0
            0.8 1.0

            [MO]
             Ene= 0.0
             Spin= Alpha
             Occup= 2.0
            10 1.0
            """.replacingOccurrences(of: "            ", with: "")
            let wf = try wfOrFail(try MoldenFile.parse(t))
            try expect(wf.basis.shells[0].isSP && wf.basis.shells[0].spCoefficients?.count == 2, "SP shell")
            try expect(!wf.basis.shells[1].isPure && wf.basis.functionCount == 10, "cartesian d: \(wf.basis.functionCount)")
        },
        Check("io.molden.cartesian_g_reorder_and_orca_f_sign") {
            func text(_ l: String, _ n: Int, title: String, flags: String) -> String {
                var s = "[Molden Format]\n[Title]\n \(title)\n[Atoms] AU\nC 1 6 0.0 0.0 0.0\n[GTO]\n1 0\n\(l) 1 1.0\n1.0 1.0\n\n\(flags)[MO]\n Ene= 0.0\n Spin= Alpha\n Occup= 2.0\n"
                for k in 1...n { s += "\(k) \(k).0\n" }
                return s
            }
            // g Cartesian: file (Molden) order -> BasisSet.cartesianOrder(4)
            let moldenG: [(Int, Int, Int)] = [(4,0,0),(0,4,0),(0,0,4),(3,1,0),(3,0,1),(1,3,0),(0,3,1),(1,0,3),(0,1,3),(2,2,0),(2,0,2),(0,2,2),(2,1,1),(1,2,1),(1,1,2)]
            let g = try wfOrFail(try MoldenFile.parse(text("g", 15, title: "x", flags: "")))
            let order = BasisSet.cartesianOrder(4)
            for (j, p) in order.enumerated() {
                let want = Double((moldenG.firstIndex { $0 == p } ?? -1) + 1)
                try expectClose(g.alpha.coefficients[j], want, tol: 1e-12)
            }
            // f pure: m = 0,+1,-1,+2,-2,+3,-3 ; ORCA flips m = +-3 (positions 5, 6)
            let fo = try wfOrFail(try MoldenFile.parse(text("f", 7, title: "created by orca_2mkl", flags: "[5D]\n[7F]\n")))
            try expect(fo.basis.shells[0].isPure, "pure f")
            try expect(Array(fo.alpha.orbital(0)) == [1, 2, 3, 4, 5, -6, -7], "ORCA sign flip: \(Array(fo.alpha.orbital(0)))")
            let fx = try wfOrFail(try MoldenFile.parse(text("f", 7, title: "other program", flags: "[5D]\n[7F]\n")))
            try expect(Array(fx.alpha.orbital(0)) == [1, 2, 3, 4, 5, 6, 7], "no flip for other programs")
            let fn = try wfOrFail(try MoldenFile.parse(text("f", 7, title: "orca", flags: "[7F]\n"), applyOrcaSignConvention: false))
            try expect(Array(fn.alpha.orbital(0)) == [1, 2, 3, 4, 5, 6, 7], "flip can be disabled")
            // round trip keeps the file convention
            let f2 = try MoldenFile.parse(text("f", 7, title: "created by orca_2mkl", flags: "[5D]\n[7F]\n"))
            let f3 = try MoldenFile.parse(f2.write())
            try mldSameWF(try wfOrFail(f2), try wfOrFail(f3))
        },
        Check("io.molden.empty_and_garbage_throw") {
            try mldThrowsIO("empty", "")
            try mldThrowsIO("garbage", "hello world\nthis is not molden\n\u{0}\u{1}")
            try mldThrowsIO("only header", "[Molden Format]\n")
        },
        Check("io.molden.missing_atoms_throws") {
            let t = try mldFixture("water_optfreq.molden.input")
            let cut = t.replacingOccurrences(of: "[Atoms] AU", with: "[Atomz] AU")
            try mldThrowsIO("missing [Atoms]", cut)
        },
        Check("io.molden.bad_shell_label_throws") {
            let t = try mldFixture("water_optfreq.molden.input")
            try mldThrowsIO("shell label", t.replacingOccurrences(of: "\np   3 1.0", with: "\nq   3 1.0"))
            try mldThrowsIO("bad primitive count", t.replacingOccurrences(of: "\np   3 1.0", with: "\np   x 1.0"))
        },
        Check("io.molden.mo_index_out_of_range_throws") {
            let t = try mldFixture("water_optfreq.molden.input")
            try mldThrowsIO("index > nbasis", t.replacingOccurrences(of: "\n  7       0.155594656235", with: "\n  8       0.155594656235"))
            try mldThrowsIO("index 0", t.replacingOccurrences(of: "\n  1       0.994216405452", with: "\n  0       0.994216405452"))
            try mldThrowsIO("bad value", t.replacingOccurrences(of: "0.994216405452", with: "abc"))
            try mldThrowsIO("atom index in GTO", t.replacingOccurrences(of: "\n  3 0\n", with: "\n  9 0\n"))
        },
        Check("io.molden.truncated_inside_gto_and_mo_throws") {
            let t = try mldFixture("water_optfreq.molden.input")
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let gto = lines.firstIndex { $0.hasPrefix("[GTO]") }!
            // inside the first shell (header + 1 primitive of 3)
            try mldThrowsIO("cut in GTO shell", mldKeepLines(t, gto + 4))
            let mo = lines.firstIndex { $0.hasPrefix("[MO]") }!
            // inside the 2nd MO (after a few coefficient lines), and inside the last MO
            try mldThrowsIO("cut in MO 2", mldKeepLines(t, mo + 1 + 11 + 4 + 3))
            let total = lines.count
            try mldThrowsIO("cut in last MO", mldKeepLines(t, total - 3))
        },
        Check("io.molden.truncation_never_crashes") {
            for name in ["water_optfreq.molden.input", "oh_uhf.molden.input"] {
                let t = try mldFixture(name)
                let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for k in 0...lines.count {
                    do {
                        let f = try MoldenFile.parse(mldKeepLines(t, k))
                        if let wf = f.wavefunction {
                            for set in [wf.alpha] + (wf.beta.map { [$0] } ?? []) {
                                try expect(set.coefficients.count == set.orbitalCount * set.basisCount && set.energies.count == set.orbitalCount, "inconsistent partial data at line \(k)")
                            }
                        }
                    } catch is MolIOError {}
                }
                // character-level prefixes
                for pct in stride(from: 1, to: 100, by: 3) {
                    let p = String(t.prefix(t.count * pct / 100))
                    do { _ = try MoldenFile.parse(p) } catch is MolIOError {}
                }
            }
        },
    ]
}

fileprivate func wfOrFail(_ f: MoldenFile) throws -> Wavefunction {
    guard let w = f.wavefunction else { throw CheckFailure(description: "no wavefunction") }
    return w
}
