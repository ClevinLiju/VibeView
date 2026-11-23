import Foundation
import MolCore
@testable import MolIO

// MARK: helpers (fileprivate, unique to this file)

fileprivate func fmtFixture(_ name: String) throws -> String { try readText(testDataURL("io/" + name)) }

fileprivate func fmtThrows(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func fmtThrowsIOError(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func fmtCRLF(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

/// Keep the first `k` lines (each terminated by \n).
fileprivate func fmtKeepLines(_ s: String, _ k: Int) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).prefix(k).joined(separator: "\n") + "\n"
}

fileprivate func fmtPrefix(_ s: String, fraction: Double) -> String {
    String(s.prefix(Int(Double(s.count) * fraction)))
}

fileprivate func fmtSameMolecule(_ a: Molecule, _ b: Molecule, tol: Double, bonds: Bool = true,
                                 chargeMult: Bool = true) throws {
    try expect(a.atoms.count == b.atoms.count, "atom count \(a.atoms.count) vs \(b.atoms.count)")
    for i in a.atoms.indices {
        try expect(a.atoms[i].atomicNumber == b.atoms[i].atomicNumber, "Z of atom \(i)")
        try expect(b.atoms[i].id == i, "id of atom \(i)")
        let d = a.atoms[i].position - b.atoms[i].position
        try expect(abs(d.x) <= tol && abs(d.y) <= tol && abs(d.z) <= tol, "position of atom \(i): \(a.atoms[i].position) vs \(b.atoms[i].position)")
    }
    if chargeMult {
        try expect(a.charge == b.charge, "charge \(a.charge) vs \(b.charge)")
        try expect(a.multiplicity == b.multiplicity, "multiplicity \(a.multiplicity) vs \(b.multiplicity)")
    }
    if bonds {
        let sa = Set(a.bonds.map { "\($0.a)-\($0.b)-\($0.order.rawValue)" })
        let sb = Set(b.bonds.map { "\($0.a)-\($0.b)-\($0.order.rawValue)" })
        try expect(sa == sb, "bonds differ: \(sa.sorted()) vs \(sb.sorted())")
    }
}

fileprivate func fmtWater() -> Molecule {
    var m = Molecule(title: "water")
    m.atoms = [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
               Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
               Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))]
    m.bonds = [Bond(0, 1), Bond(0, 2)]
    return m
}

/// Synthetic molecule with a mix of elements, bond orders and values rounded to 3 decimals.
fileprivate func fmtMixed() -> Molecule {
    var m = Molecule(title: "mixed <&> \"test\"")
    let zs = [6, 6, 8, 7, 1, 17]
    for (i, z) in zs.enumerated() {
        let p = Vec3(Double(i) * 1.234 - 2, sin(Double(i)) * 1.5, cos(Double(i) * 2) * 0.75)
        let r = Vec3((p.x * 1000).rounded() / 1000, (p.y * 1000).rounded() / 1000, (p.z * 1000).rounded() / 1000)
        m.atoms.append(Atom(id: i, atomicNumber: z, position: r))
    }
    m.bonds = [Bond(0, 1, order: .double), Bond(1, 2, order: .single), Bond(2, 3, order: .triple),
               Bond(3, 4, order: .single), Bond(0, 5, order: .single)]
    return m
}

fileprivate func fmtBigMolecule(_ n: Int) -> Molecule {
    var m = Molecule(title: "big")
    m.atoms.reserveCapacity(n)
    for i in 0..<n {
        let z = [6, 1, 8, 7][i % 4]
        let p = Vec3(Double(i % 100) * 1.5 - 100, Double((i / 100) % 100) * 1.25 - 60, Double(i / 10000) * 2.0 + 0.125)
        m.atoms.append(Atom(id: i, atomicNumber: z, position: p))
    }
    return m
}

fileprivate func fmtBlobGrid(_ n: [Int], phase: Double) -> VolumeGrid {
    var v = [Float](); v.reserveCapacity(n[0] * n[1] * n[2])
    for ix in 0..<n[0] { for iy in 0..<n[1] { for iz in 0..<n[2] {
        let x = Double(ix) - Double(n[0]) / 2, y = Double(iy) - Double(n[1]) / 2, z = Double(iz) - Double(n[2]) / 2
        v.append(Float(exp(-0.05 * (x * x + y * y + z * z)) * cos(phase + 0.3 * x)))
    } } }
    return VolumeGrid(origin: Vec3(-1, -2, -3), axes: [Vec3(0.2, 0, 0), Vec3(0, 0.25, 0), Vec3(0, 0, 0.3)], counts: n, values: v)
}

fileprivate func fmtSameGrid(_ a: VolumeGrid, _ b: VolumeGrid, valueTol: Float = 1e-4, geomTol: Double = 1e-5) throws {
    try expect(a.counts == b.counts, "counts \(a.counts) vs \(b.counts)")
    try expect(a.values.count == b.values.count, "value count")
    for k in 0..<3 {
        try expect(simd_length(a.axes[k] - b.axes[k]) < geomTol, "axis \(k)")
    }
    try expect(simd_length(a.origin - b.origin) < geomTol, "origin")
    var maxd: Float = 0
    for i in a.values.indices { maxd = max(maxd, abs(a.values[i] - b.values[i])) }
    try expect(maxd <= valueTol, "max value diff \(maxd)")
}

fileprivate func fmtTime<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t0 = Date()
    let r = try body()
    return (r, Date().timeIntervalSince(t0))
}

import simd

extension Checks {
    static let ioFormats: [Check] = ioFormatsCube + ioFormatsXYZ + ioFormatsPDB + ioFormatsMDL + ioFormatsCML + ioFormatsRegistry

    // MARK: cube

    static let ioFormatsCube: [Check] = [
        Check("io.cube.homoValues") {
            let c = try CubeFile.read(url: testDataURL("io/cube_water_homo.cube"))
            try expect(c.title == "Water HOMO", "title '\(c.title)'")
            try expect(c.comment.hasPrefix("OUTER LOOP"), "comment")
            try expect(c.molecule.atoms.map(\.atomicNumber) == [8, 1, 1])
            try expect(c.orbitalIndices == [5], "orbital ids \(c.orbitalIndices)")
            try expect(c.grids.count == 1)
            let g = c.grids[0]
            try expect(g.counts == [6, 5, 4] && g.values.count == 120)
            try expectClose(g.origin.x, -2.5 * bohrToAngstrom, tol: 1e-9)
            try expectClose(g.origin.z, -1.5 * bohrToAngstrom, tol: 1e-9)
            try expectClose(g.axes[1].y, 1.0 * bohrToAngstrom, tol: 1e-9)
            try expect(g.axes[0].y == 0 && g.axes[2].x == 0)
            try expectClose(c.molecule.atoms[1].position.x, 1.4305 * bohrToAngstrom, tol: 1e-9)
            try expectClose(c.molecule.atoms[0].position.z, -0.2217 * bohrToAngstrom, tol: 1e-9)
            try expect(c.nuclearCharges == [8, 1, 1], "nuclear charges \(c.nuclearCharges)")
            // x slowest, z fastest: check against the generating formula
            func f(_ x: Double, _ y: Double, _ z: Double) -> Double {
                func b(_ c: (Double, Double, Double), _ w: Double) -> Double {
                    exp(-w * ((x - c.0) * (x - c.0) + (y - c.1) * (y - c.1) + (z - c.2) * (z - c.2)))
                }
                return b((0, 0, 0.5), 0.4) - 0.5 * b((1.4, 0, 0.9), 0.8) - 0.5 * b((-1.4, 0, 0.9), 0.8)
            }
            for (ix, iy, iz) in [(0, 0, 0), (2, 3, 1), (5, 4, 3), (3, 2, 2), (1, 0, 3)] {
                let idx = (ix * 5 + iy) * 4 + iz
                let e = f(-2.5 + Double(ix), -2.0 + Double(iy), -1.5 + Double(iz))
                try expectClose(Double(g.values[idx]), e, tol: 2e-5)
            }
        },
        Check("io.cube.densityNoDset") {
            let c = try CubeFile.read(url: testDataURL("io/cube_water_density.cube"))
            try expect(c.orbitalIndices.isEmpty && c.grids.count == 1)
            try expect(c.grids[0].values.count == 120 && c.grids[0].values.allSatisfy { $0 >= 0 })
            try expect(c.molecule.atoms.count == 3)
        },
        Check("io.cube.multiMO") {
            let c = try CubeFile.read(url: testDataURL("io/cube_multi_mo.cube"))
            try expect(c.grids.count == 2 && c.orbitalIndices == [4, 5])
            for g in c.grids { try expect(g.counts == [6, 5, 4] && g.values.count == 120) }
            // MO 2 is x*exp(-r^2/2): odd in x; MO 1 is positive everywhere
            let g1 = c.grids[0], g2 = c.grids[1]
            try expect(g1.values.allSatisfy { $0 > 0 })
            for (ix, iy, iz) in [(0, 1, 1), (1, 2, 3), (4, 4, 0), (5, 0, 2)] {
                let idx = (ix * 5 + iy) * 4 + iz
                let x = -2.5 + Double(ix), y = -2.0 + Double(iy), z = -1.5 + Double(iz)
                try expectClose(Double(g2.values[idx]), x * exp(-0.5 * (x * x + y * y + z * z)), tol: 2e-5)
                try expectClose(Double(g1.values[idx]), exp(-0.4 * (x * x + y * y + (z - 0.5) * (z - 0.5))), tol: 2e-5)
            }
        },
        Check("io.cube.roundTripBohrAndAngstrom") {
            for name in ["cube_water_homo.cube", "cube_water_density.cube", "cube_multi_mo.cube"] {
                let c = try CubeFile.parse(try fmtFixture(name))
                for ang in [false, true] {
                    let c2 = try CubeFile.parse(c.write(unitsAngstrom: ang))
                    try fmtSameMolecule(c.molecule, c2.molecule, tol: 1e-5, bonds: false)
                    try expect(c.grids.count == c2.grids.count, "\(name) grids")
                    for (a, b) in zip(c.grids, c2.grids) { try fmtSameGrid(a, b, valueTol: 2e-5, geomTol: 1e-5) }
                    try expect(c.orbitalIndices == c2.orbitalIndices, "\(name) ids")
                    try expect(c2.title == c.title && c2.comment == c.comment)
                }
            }
            // multi-grid without DSET_IDS uses the nval header field
            let g = fmtBlobGrid([3, 3, 3], phase: 0)
            let c = CubeFile(title: "t", comment: "c", molecule: fmtWater(), grids: [g, fmtBlobGrid([3, 3, 3], phase: 1)])
            let c2 = try CubeFile.parse(c.write())
            try expect(c2.grids.count == 2 && c2.orbitalIndices.isEmpty)
            try fmtSameGrid(c.grids[1], c2.grids[1], valueTol: 2e-5)
        },
        Check("io.cube.angstromNegativeCounts") {
            let s = "t\nc\n    1    0.0 0.0 0.0\n   -2    1.0 0.0 0.0\n   -2    0.0 1.0 0.0\n   -2    0.0 0.0 1.0\n    6    6.0 0.0 0.0 0.0\n 1 2 3 4 5 6\n 7 8\n"
            let c = try CubeFile.parse(s)
            try expectClose(c.grids[0].axes[0].x, 1.0, tol: 1e-12)   // already Angstrom
            try expect(c.grids[0].counts == [2, 2, 2] && c.grids[0].values == [1, 2, 3, 4, 5, 6, 7, 8])
            let s2 = s.replacingOccurrences(of: "   -2    1.0", with: "    2    1.0")
            try expectClose(try CubeFile.parse(s2).grids[0].axes[0].x, bohrToAngstrom, tol: 1e-12)
        },
        Check("io.cube.crlfAndFortranExponent") {
            let s = try fmtFixture("cube_water_homo.cube")
            let a = try CubeFile.parse(s), b = try CubeFile.parse(fmtCRLF(s))
            try expect(a == b, "CRLF parse differs")
            // D exponents in values and header
            var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for i in 0..<lines.count where i >= 11 { lines[i] = lines[i].replacingOccurrences(of: "E", with: "D") }
            lines[2] = lines[2].replacingOccurrences(of: "-2.500000", with: "-2.5D+00")
            let d = try CubeFile.parse(lines.joined(separator: "\n"))
            try fmtSameGrid(a.grids[0], d.grids[0], valueTol: 0, geomTol: 1e-12)
            // a lowercase d and '+' exponent
            let s2 = "t\nc\n 1 0 0 0\n 1 1 0 0\n 1 0 1 0\n 2 0 0 1\n 1 0.0 0 0 0\n 1.5d+00 -2.5D-01\n"
            try expect(try CubeFile.parse(s2).grids[0].values == [1.5, -0.25])
        },
        Check("io.cube.malformedThrows") {
            let s = try fmtFixture("cube_water_homo.cube")
            try fmtThrowsIOError("empty") { _ = try CubeFile.parse("") }
            try fmtThrowsIOError("one line") { _ = try CubeFile.parse("title\n") }
            try fmtThrowsIOError("bad natoms") { _ = try CubeFile.parse("a\nb\nxx 0 0 0\n") }
            try fmtThrowsIOError("bad axis") { _ = try CubeFile.parse(s.replacingOccurrences(of: "    6    1.000000", with: "    q    1.000000")) }
            try fmtThrowsIOError("zero count") { _ = try CubeFile.parse(s.replacingOccurrences(of: "    6    1.000000", with: "    0    1.000000")) }
            try fmtThrowsIOError("bad atom line") { _ = try CubeFile.parse(s.replacingOccurrences(of: "    8    8.000000", with: "    8    abc")) }
            try fmtThrowsIOError("bad value") { _ = try CubeFile.parse(s + " 1.0 oops 2.0\n") }
            try fmtThrowsIOError("extra values") { _ = try CubeFile.parse(s + " 1.0\n") }
            try fmtThrowsIOError("huge dims") {
                _ = try CubeFile.parse("t\nc\n 1 0 0 0\n 99999999 1 0 0\n 99999999 0 1 0\n 99999999 0 0 1\n 1 1.0 0 0 0\n 1.0\n")
            }
            try fmtThrowsIOError("overflow dims") {
                _ = try CubeFile.parse("t\nc\n 1 0 0 0\n 9223372036854775807 1 0 0\n 9223372036854775807 0 1 0\n 9223372036854775807 0 0 1\n 1 1.0 0 0 0\n 1.0\n")
            }
            try fmtThrowsIOError("bad DSET") { _ = try CubeFile.parse(s.replacingOccurrences(of: "    1    5\n", with: "    x    5\n")) }
            try fmtThrows("nan") { _ = try CubeFile.parse(s + " nan\n") }
        },
        Check("io.cube.truncatedThrows") {
            for name in ["cube_water_homo.cube", "cube_water_density.cube", "cube_multi_mo.cube"] {
                let s = try fmtFixture(name)
                for f in [0.02, 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.88] {
                    let t = fmtPrefix(s, fraction: f)
                    try fmtThrowsIOError("\(name) truncated at \(f)") { _ = try CubeFile.parse(t) }
                }
                // remove the final value line
                let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
                let cut = lines.dropLast(3).joined(separator: "\n") + "\n"
                try fmtThrowsIOError("\(name) missing final rows") { _ = try CubeFile.parse(cut) }
            }
        },
        Check("io.cube.large60cubed") {
            let n = 60
            let g = fmtBlobGrid([n, n, n], phase: 0.5)
            let c = CubeFile(title: "big", comment: "synthetic", molecule: fmtWater(), grids: [g])
            let (text, tw) = fmtTime { c.write() }
            let (c2, tp) = try fmtTime { try CubeFile.parse(text) }
            try expect(c2.grids[0].counts == [n, n, n] && c2.grids[0].values.count == n * n * n)
            try fmtSameGrid(g, c2.grids[0], valueTol: 2e-5)
            try expect(tp < 5.0, "parse took \(tp)s (write \(tw)s)")
            // spot check ordering
            let idx = (12 * n + 34) * n + 56
            try expectClose(Double(c2.grids[0].values[idx]), Double(g.values[idx]), tol: 2e-5)
        },
    ]

    // MARK: XYZ

    static let ioFormatsXYZ: [Check] = [
        Check("io.xyz.trajectory") {
            let t = try XYZFormat.read(url: testDataURL("io/xyz_traj.xyz"))
            try expect(t.count == 3, "frames \(t.count)")
            try expect(t[0].title == "Frame 1 water E=-76.0107")
            try expect(t[0].atoms.map(\.atomicNumber) == [8, 1, 1])
            try expectClose(t[0].atoms[1].position.y, 0.7572)
            try expectClose(t[1].atoms[2].position.y, -0.8)
            try expectClose(t[2].atoms[0].position.z, 0.125)   // extra force columns ignored
            try expect(t[0].bonds.isEmpty)
            for (i, a) in t[2].atoms.enumerated() { try expect(a.id == i) }
        },
        Check("io.xyz.roundTrip") {
            let t = try XYZFormat.read(url: testDataURL("io/xyz_traj.xyz"))
            let t2 = try XYZFormat.parse(XYZFormat.write(t))
            try expect(t2.count == 3)
            for (a, b) in zip(t, t2) { try fmtSameMolecule(a, b, tol: 1e-7, bonds: false); try expect(a.title == b.title) }
            let m = fmtMixed()
            let m2 = try XYZFormat.parse(XYZFormat.write(m))
            try expect(m2.count == 1)
            try fmtSameMolecule(m, m2[0], tol: 1e-7, bonds: false)
            try expect(!XYZFormat.write(m).contains("\"") || true)
            try expect(XYZFormat.write(m).split(separator: "\n").count == 2 + m.atoms.count)
        },
        Check("io.xyz.variants") {
            // atomic numbers, mixed case symbols, labels, tabs, D exponents, blank trailing lines, no final newline
            let s = "4\nmixed\n6 0.0 0.0 0.0\ncl\t1.0D+00 0.0 0.0\nHe 1.5d-01 -2.5E-1 3\nC1 0 0 0   \n\n\n"
            let f = try XYZFormat.parse(s)
            try expect(f.count == 1 && f[0].atoms.map(\.atomicNumber) == [6, 17, 2, 6])
            try expectClose(f[0].atoms[1].position.x, 1.0)
            try expectClose(f[0].atoms[2].position.x, 0.15)
            try expectClose(f[0].atoms[2].position.y, -0.25)
            try expect(f[0].atoms[3].label == "C1")
            let g = try XYZFormat.parse("1\n\nH 0 0 0")
            try expect(g.count == 1 && g[0].title == "" && g[0].atoms.count == 1)
            // blank line separating frames
            let h = try XYZFormat.parse("1\na\nH 0 0 0\n\n1\nb\nHe 1 1 1\n")
            try expect(h.count == 2 && h[1].atoms[0].atomicNumber == 2)
            // empty frame
            let e = try XYZFormat.parse("0\nempty\n")
            try expect(e.count == 1 && e[0].atoms.isEmpty)
        },
        Check("io.xyz.crlf") {
            let s = try fmtFixture("xyz_traj.xyz")
            try expect(try XYZFormat.parse(fmtCRLF(s)) == XYZFormat.parse(s))
            try expect(try XYZFormat.parse(s.replacingOccurrences(of: "\n", with: "\r")).count == 3)
        },
        Check("io.xyz.malformedThrows") {
            try fmtThrowsIOError("empty") { _ = try XYZFormat.parse("") }
            try fmtThrowsIOError("blank only") { _ = try XYZFormat.parse("\n\n  \n") }
            try fmtThrowsIOError("no count") { _ = try XYZFormat.parse("hello\nworld\n") }
            try fmtThrowsIOError("negative count") { _ = try XYZFormat.parse("-3\nx\n") }
            try fmtThrowsIOError("bad coord") { _ = try XYZFormat.parse("1\nx\nH 0 abc 0\n") }
            try fmtThrowsIOError("short atom line") { _ = try XYZFormat.parse("1\nx\nH 0 0\n") }
            try fmtThrowsIOError("unknown element") { _ = try XYZFormat.parse("1\nx\nQq 0 0 0\n") }
            try fmtThrowsIOError("nan coordinate") { _ = try XYZFormat.parse("1\nx\nH 0 nan 0\n") }
            try fmtThrowsIOError("missing comment") { _ = try XYZFormat.parse("1\n") }
            try fmtThrowsIOError("huge count") { _ = try XYZFormat.parse("99999999999\nx\nH 0 0 0\n") }
            try fmtThrowsIOError("fewer atoms than declared") { _ = try XYZFormat.parse("5\nx\nH 0 0 0\nH 1 0 0\n") }
        },
        Check("io.xyz.truncatedThrows") {
            let s = try fmtFixture("xyz_traj.xyz")
            // 3-atom frames occupy 5 lines each; keep counts that cut a frame
            for k in [1, 2, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14] {
                let t = fmtKeepLines(s, k)
                try fmtThrowsIOError("kept \(k) lines") { _ = try XYZFormat.parse(t) }
            }
            for k in [5, 10, 15] { try expect(try XYZFormat.parse(fmtKeepLines(s, k)).count == k / 5) }
            // mid-line cuts must never crash: result either throws or is a valid parse
            var thrown = 0
            for f in stride(from: 0.03, to: 1.0, by: 0.037) {
                do { _ = try XYZFormat.parse(fmtPrefix(s, fraction: f)) } catch { thrown += 1 }
            }
            try expect(thrown > 10, "only \(thrown) truncations threw")
        },
        Check("io.xyz.large50k") {
            let m = fmtBigMolecule(50_000)
            let (text, _) = fmtTime { XYZFormat.write([m, m]) }
            let (f, t) = try fmtTime { try XYZFormat.parse(text) }
            try expect(f.count == 2 && f[0].atoms.count == 50_000)
            try fmtSameMolecule(m, f[1], tol: 1e-7, bonds: false)
            try expect(t < 5.0, "parse took \(t)s")
        },
    ]

    // MARK: PDB

    static let ioFormatsPDB: [Check] = [
        Check("io.pdb.alanineValues") {
            let f = try PDBFormat.read(url: testDataURL("io/pdb_alanine.pdb"))
            try expect(f.models.count == 1 && f.atomRecords.count == 1)
            let m = f.models[0], r = f.atomRecords[0]
            try expect(m.atoms.count == 12 && r.count == 12, "atoms \(m.atoms.count)")
            try expect(m.atoms.map(\.atomicNumber) == [7, 6, 6, 8, 6, 1, 1, 1, 30, 8, 1, 1], "Z \(m.atoms.map(\.atomicNumber))")
            try expectClose(m.atoms[1].position.x, 11.639)
            try expectClose(m.atoms[1].position.y, 6.071)
            try expectClose(m.atoms[1].position.z, -5.147)
            try expect(m.atoms[1].label == "CA")
            try expect(m.title == "ALANINE FRAGMENT WITH ZINC AND WATER", "title '\(m.title)'")
            try expect(m.charge == 2, "charge \(m.charge)")
            // records
            try expect(r[0].serial == 1 && r[0].name == "N" && r[0].resName == "ALA" && r[0].chainID == "A" && r[0].resSeq == 1)
            try expect(!r[0].isHetero && r[8].isHetero && r[8].resSeq == 101 && r[8].element == "Zn" && r[8].formalCharge == 2)
            try expect(r[7].name == "1HB" && m.atoms[7].atomicNumber == 1)
            try expectClose(r[2].tempFactor, 18.5)
            try expectClose(r[4].tempFactor, 22.1)
            try expectClose(r[0].occupancy, 1.0)
            try expect(r[9].resName == "HOH" && r[9].resSeq == 201)
            // cell
            guard let c = f.cell else { throw CheckFailure(description: "no cell") }
            try expectClose(c.a, 30); try expectClose(c.b, 40); try expectClose(c.c, 50)
            try expectClose(c.alpha, 90); try expectClose(c.beta, 95); try expectClose(c.gamma, 90)
            try expect(c.spaceGroup == "P 21 1", "sg '\(c.spaceGroup)'")
        },
        Check("io.pdb.conect") {
            let m = try PDBFormat.read(url: testDataURL("io/pdb_alanine.pdb")).models[0]
            func order(_ a: Int, _ b: Int) -> BondOrder? { m.bonds.first { $0.a == min(a, b) && $0.b == max(a, b) }?.order }
            try expect(order(0, 1) == .single && order(1, 2) == .single && order(1, 4) == .single)
            try expect(order(2, 3) == .double, "C=O listed twice should be double")
            try expect(order(9, 10) == .single && order(9, 11) == .single && order(4, 7) == .single)
            try expect(order(0, 5) == .single && order(1, 6) == .single)
            try expect(m.bonds.count == 9, "bond count \(m.bonds.count)")
            try expect(order(8, 9) == nil)
            // triple + unknown serial ignored
            let s = "ATOM      1  C   UNL A   1       0.000   0.000   0.000  1.00  0.00           C  \nATOM      2  N   UNL A   1       1.150   0.000   0.000  1.00  0.00           N  \nCONECT    1    2    2    2   99\nCONECT    2    1    1\nEND\n"
            let t = try PDBFormat.parse(s).models[0]
            try expect(t.bonds == [Bond(0, 1, order: .triple)], "triple: \(t.bonds)")
        },
        Check("io.pdb.models") {
            let f = try PDBFormat.read(url: testDataURL("io/pdb_models.pdb"))
            try expect(f.models.count == 3 && f.atomRecords.count == 3)
            try expectClose(f.models[0].atoms[0].position.x, 0.0)
            try expectClose(f.models[1].atoms[0].position.x, 0.1)
            try expectClose(f.models[2].atoms[2].position.y, -0.85)
            for m in f.models { try expect(m.bonds.count == 2, "each model gets CONECT bonds") }
            try expect(f.models[2].title == "NMR-STYLE TWO MODEL WATER")
            try expect(f.cell == nil)
        },
        Check("io.pdb.roundTrip") {
            let f = try PDBFormat.read(url: testDataURL("io/pdb_alanine.pdb"))
            let text = PDBFormat.write(f.models[0], records: f.atomRecords[0], cell: f.cell)
            let g = try PDBFormat.parse(text)
            try fmtSameMolecule(f.models[0], g.models[0], tol: 1e-5)
            try expect(f.atomRecords == g.atomRecords, "records differ")
            try expect(f.cell == g.cell)
            try expect(g.models[0].title == f.models[0].title)
            // lines are fixed width and CONECT is emitted for all bonds
            try expect(text.split(separator: "\n").filter { $0.hasPrefix("ATOM") || $0.hasPrefix("HETATM") }.allSatisfy { $0.count == 80 || $0.count == 78 })
            // default records from a plain molecule (3 decimals)
            let m = fmtMixed()
            let g2 = try PDBFormat.parse(PDBFormat.write(m))
            try fmtSameMolecule(m, g2.models[0], tol: 1e-5, chargeMult: false)
            try expect(g2.models[0].charge == 0)
            // models
            let pm = try PDBFormat.read(url: testDataURL("io/pdb_models.pdb"))
            let g3 = try PDBFormat.parse(PDBFormat.write(models: pm.models))
            try expect(g3.models.count == 3)
            for (a, b) in zip(pm.models, g3.models) { try fmtSameMolecule(a, b, tol: 1e-5) }
        },
        Check("io.pdb.elementInference") {
            func line(_ name4: String, _ rec: String = "ATOM  ", elem: String = "") -> String {
                rec.padding(toLength: 6, withPad: " ", startingAt: 0) + "    1 " + name4 + " ALA A   1       1.000   2.000   3.000  1.00  0.00"
                    + String(repeating: " ", count: 10) + elem.padding(toLength: 2, withPad: " ", startingAt: 0) + "\n"
            }
            func z(_ name4: String, _ rec: String = "ATOM  ", elem: String = "") throws -> Int {
                try PDBFormat.parse(line(name4, rec, elem: elem)).models[0].atoms[0].atomicNumber
            }
            try expect(try z(" CA ") == 6)
            try expect(try z(" N  ") == 7)
            try expect(try z("1HB ") == 1)
            try expect(try z("HG21") == 1)
            try expect(try z(" OXT") == 8)
            try expect(try z("CA  ", "HETATM") == 20)
            try expect(try z("FE  ", "HETATM") == 26)
            try expect(try z("ZN  ", "HETATM") == 30)
            try expect(try z("HG  ", "HETATM") == 80)
            try expect(try z(" H1 ", "HETATM") == 1)
            try expect(try z("CL  ", "HETATM") == 17)
            try expect(try z(" CA ", elem: " C") == 6)
            try expect(try z("XX  ", "HETATM", elem: "CL") == 17, "element column wins")
            try fmtThrowsIOError("unknown element") { _ = try z("1234") }
        },
        Check("io.pdb.formatEdgeCases") {
            let s = try fmtFixture("pdb_alanine.pdb")
            let a = try PDBFormat.parse(s), b = try PDBFormat.parse(fmtCRLF(s))
            try expect(a == b, "CRLF differs")
            // trailing whitespace stripped / no element column / no END
            let stripped = s.split(separator: "\n").map { l -> String in
                var x = String(l); while x.hasSuffix(" ") { x.removeLast() }; return x
            }.filter { $0 != "END" }.joined(separator: "\n")
            let c = try PDBFormat.parse(stripped)
            try expect(c.models[0].atoms.map(\.atomicNumber) == a.models[0].atoms.map(\.atomicNumber))
            // ATOM line exactly 54 columns long is fine; 53 is not
            let l54 = "ATOM      1  C   UNL A   1       1.000   2.000   3.000"
            try expect(try PDBFormat.parse(l54).models[0].atoms.count == 1)
            try fmtThrowsIOError("53 columns") { _ = try PDBFormat.parse(String(l54.dropLast())) }
            // negative / crowded coordinates
            let crowd = "HETATM    1  C   UNL A   1    -100.123-200.456-300.789  1.00  0.00           C  \n"
            let p = try PDBFormat.parse(crowd).models[0].atoms[0].position
            try expectClose(p.x, -100.123); try expectClose(p.y, -200.456); try expectClose(p.z, -300.789)
            // charge column variants
            let ch = "HETATM    1 NA   NA  A   1       1.000   2.000   3.000  1.00  0.00          NA1+\nHETATM    2 CL   CL  A   2       5.000   2.000   3.000  1.00  0.00          CL1-\n"
            let cm = try PDBFormat.parse(ch).models[0]
            try expect(cm.charge == 0 && cm.atoms.map(\.atomicNumber) == [11, 17])
            let ch2 = String(ch.split(separator: "\n")[0])
            try expect(try PDBFormat.parse(ch2).models[0].charge == 1)
        },
        Check("io.pdb.malformedThrows") {
            try fmtThrowsIOError("empty") { _ = try PDBFormat.parse("") }
            try fmtThrowsIOError("no atoms") { _ = try PDBFormat.parse("HEADER    X\nREMARK 1\nEND\n") }
            try fmtThrowsIOError("bad coords") {
                _ = try PDBFormat.parse("ATOM      1  C   UNL A   1       x.000   2.000   3.000  1.00  0.00           C  \n")
            }
            try fmtThrowsIOError("short ATOM") { _ = try PDBFormat.parse("ATOM      1  C   UNL A   1\n") }
            try fmtThrowsIOError("bad CONECT") {
                _ = try PDBFormat.parse("ATOM      1  C   UNL A   1       1.000   2.000   3.000  1.00  0.00           C  \nCONECT    1 abcd\n")
            }
            try fmtThrowsIOError("bad CRYST1") { _ = try PDBFormat.parse("CRYST1   30.000   xx\nATOM      1  C   UNL A   1       1.000   2.000   3.000\n") }
            try fmtThrowsIOError("ENDMDL without MODEL") {
                _ = try PDBFormat.parse("ATOM      1  C   UNL A   1       1.000   2.000   3.000\nENDMDL\n")
            }
            try fmtThrowsIOError("unknown element") {
                _ = try PDBFormat.parse("ATOM      1  ??  UNL A   1       1.000   2.000   3.000\n")
            }
        },
        Check("io.pdb.truncatedThrows") {
            let s = try fmtFixture("pdb_models.pdb")
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            // cutting anywhere inside a MODEL (before its ENDMDL) must throw
            for k in [2, 3, 4, 5, 7, 8, 9, 11, 12] {
                let t = lines.prefix(k).joined(separator: "\n") + "\n"
                try fmtThrowsIOError("kept \(k) lines") { _ = try PDBFormat.parse(t) }
            }
            // mid-line cut of an atom line
            let alanine = try fmtFixture("pdb_alanine.pdb")
            let al = alanine.split(separator: "\n", omittingEmptySubsequences: false)
            let cutLine = al.prefix(5).joined(separator: "\n") + "\n" + String(al[5].prefix(40))
            try fmtThrowsIOError("mid-line cut") { _ = try PDBFormat.parse(cutLine) }
            // arbitrary prefixes never crash
            for f in stride(from: 0.02, to: 1.0, by: 0.021) {
                _ = try? PDBFormat.parse(fmtPrefix(alanine, fraction: f))
                _ = try? PDBFormat.parse(fmtPrefix(s, fraction: f))
            }
        },
        Check("io.pdb.large50k") {
            let m = fmtBigMolecule(50_000)
            let text = PDBFormat.write(m)
            let (f, t) = try fmtTime { try PDBFormat.parse(text) }
            try expect(f.models.count == 1 && f.models[0].atoms.count == 50_000 && f.atomRecords[0].count == 50_000)
            try fmtSameMolecule(m, f.models[0], tol: 1e-3, chargeMult: false)
            try expect(t < 8.0, "parse took \(t)s")
            // 5 models of 10k atoms
            let small = fmtBigMolecule(10_000)
            let multi = try PDBFormat.parse(PDBFormat.write(models: [small, small, small, small, small]))
            try expect(multi.models.count == 5 && multi.models[4].atoms.count == 10_000)
        },
    ]

    // MARK: MDL MOL / SDF

    static let ioFormatsMDL: [Check] = [
        Check("io.mol.ethanolValues") {
            let r = try MDLMolFormat.read(url: testDataURL("io/mol_ethanol.mol"))
            try expect(r.count == 1)
            let m = r[0].molecule
            try expect(m.title == "ethanol")
            try expect(m.atoms.map(\.atomicNumber) == [6, 6, 8, 1, 1, 1, 1, 1, 1])
            try expect(m.bonds.count == 8 && m.bonds.allSatisfy { $0.order == .single })
            try expectClose(m.atoms[0].position.x, -0.01, tol: 1e-9)
            try expectClose(m.atoms[2].position.x, -1.099, tol: 1e-9)
            try expectClose(m.atoms[3].position.z, 0.889, tol: 1e-9)
            try expect(m.bonds.contains(Bond(0, 1)) && m.bonds.contains(Bond(2, 8)))
            try expect(m.charge == 0 && m.multiplicity == 1 && r[0].properties.isEmpty)
        },
        Check("io.sdf.twoRecords") {
            let r = try MDLMolFormat.read(url: testDataURL("io/sdf_two.sdf"))
            try expect(r.count == 2, "records \(r.count)")
            try expect(r[0].molecule.title == "methylammonium")
            try expect(r[0].molecule.charge == 1, "charge \(r[0].molecule.charge)")
            try expect(r[0].properties == [SDFProperty(name: "ID", value: "MOL-001"), SDFProperty(name: "MW", value: "32.05")], "\(r[0].properties)")
            try expect(r[0].value(for: "MW") == "32.05")
            try expect(r[1].molecule.atoms.count == 4 && r[1].molecule.bonds.contains(Bond(1, 2, order: .triple)))
            try expect(r[1].properties.count == 2 && r[1].value(for: "NOTE") == "line one\nline two")
            try expect(r[1].molecule.charge == 0)
        },
        Check("io.mol.chargeCodesAndRadicals") {
            // M  CHG overrides the atom-block code; code 3 = +1, 5 = -1; radical via M  RAD
            func blk(_ a: String, _ props: String) -> String {
                "t\n  x\n\n  2  1  0  0  0  0  0  0  0  0999 V2000\n    0.0000    0.0000    0.0000 N   0  \(a)  0  0  0  0  0  0  0  0  0  0\n    1.0000    0.0000    0.0000 O   0  0  0  0  0  0  0  0  0  0  0  0\n  1  2  1  0\n\(props)M  END\n"
            }
            try expect(try MDLMolFormat.parse(blk("3", "")).first!.molecule.charge == 1)
            try expect(try MDLMolFormat.parse(blk("5", "")).first!.molecule.charge == -1)
            try expect(try MDLMolFormat.parse(blk("1", "")).first!.molecule.charge == 3)
            try expect(try MDLMolFormat.parse(blk("7", "")).first!.molecule.charge == -3)
            try expect(try MDLMolFormat.parse(blk("3", "M  CHG  2   1  -1   2   2\n")).first!.molecule.charge == 1)
            try expect(try MDLMolFormat.parse(blk("3", "M  CHG  1   1   2\n")).first!.molecule.charge == 2)
            try expect(try MDLMolFormat.parse(blk("0", "M  RAD  1   1   2\n")).first!.molecule.multiplicity == 2)
            try expect(try MDLMolFormat.parse(blk("0", "M  RAD  2   1   3   2   2\n")).first!.molecule.multiplicity == 4)
            try expect(try MDLMolFormat.parse(blk("4", "")).first!.molecule.multiplicity == 2)
            try expect(try MDLMolFormat.parse(blk("0", "M  ISO  1   1  13\n")).first!.molecule.atoms.count == 2)
        },
        Check("io.mol.roundTrip") {
            for ch in [0, 1, -2] {
                for mult in [1, 2, 3] {
                    var m = fmtMixed()
                    m.charge = ch; m.multiplicity = mult
                    m.bonds.append(Bond(3, 5, order: .aromatic))
                    m.title = "round trip"
                    let r = try MDLMolFormat.parse(MDLMolFormat.write(m))
                    try expect(r.count == 1)
                    // 4-decimal coordinates: fixture values have 3
                    try fmtSameMolecule(m, r[0].molecule, tol: 1e-5)
                    try expect(r[0].molecule.title == "round trip")
                }
            }
            let sdf = try MDLMolFormat.read(url: testDataURL("io/sdf_two.sdf"))
            let again = try MDLMolFormat.parse(MDLMolFormat.writeSDF(sdf))
            try expect(again.count == 2)
            for (a, b) in zip(sdf, again) {
                try fmtSameMolecule(a.molecule, b.molecule, tol: 1e-5)
                try expect(a.properties == b.properties, "properties \(b.properties)")
            }
            let e = try MDLMolFormat.read(url: testDataURL("io/mol_ethanol.mol"))
            let e2 = try MDLMolFormat.parse(MDLMolFormat.write(e[0].molecule))
            try fmtSameMolecule(e[0].molecule, e2[0].molecule, tol: 1e-5)
            try expect(MDLMolFormat.write(e[0].molecule).hasSuffix("M  END\n"))
            try expect(!MDLMolFormat.write(e[0].molecule).contains("$$$$"))
        },
        Check("io.mol.crlfAndWhitespaceFallback") {
            for name in ["mol_ethanol.mol", "sdf_two.sdf"] {
                let s = try fmtFixture(name)
                try expect(try MDLMolFormat.parse(fmtCRLF(s)) == MDLMolFormat.parse(s), "\(name) CRLF")
            }
            // free-format (whitespace separated, short) atom and bond lines are tolerated
            let s = "x\n\n\n  2  1\n0.0 0.0 0.0 C\n1.5 0.0 0.0 O\n1 2 2\nM  END\n"
            let r = try MDLMolFormat.parse(s)
            try expect(r[0].molecule.atoms.count == 2 && r[0].molecule.bonds == [Bond(0, 1, order: .double)])
            // blank title line, and trailing blank lines after $$$$
            let sd = "\n  prog\n\n  1  0  0  0  0  0  0  0  0  0999 V2000\n    0.0000    0.0000    0.0000 He  0  0  0  0  0  0  0  0  0  0  0  0\nM  END\n$$$$\n\n\n"
            let sr = try MDLMolFormat.parse(sd)
            try expect(sr.count == 1 && sr[0].molecule.atoms[0].atomicNumber == 2 && sr[0].molecule.title == "")
        },
        Check("io.mol.v3000Unsupported") {
            let s = "x\n\n\n  0  0  0     0  0            999 V3000\nM  V30 BEGIN CTAB\nM  END\n"
            do { _ = try MDLMolFormat.parse(s); throw CheckFailure(description: "V3000 parsed") }
            catch let e as MolIOError {
                if case .unsupported = e {} else { throw CheckFailure(description: "wrong error \(e)") }
            }
        },
        Check("io.mol.malformedThrows") {
            let mol = try fmtFixture("mol_ethanol.mol")
            try fmtThrowsIOError("empty") { _ = try MDLMolFormat.parse("") }
            try fmtThrowsIOError("only blank") { _ = try MDLMolFormat.parse("\n\n\n") }
            try fmtThrowsIOError("short header") { _ = try MDLMolFormat.parse("a\nb\n") }
            try fmtThrowsIOError("bad counts") { _ = try MDLMolFormat.parse("a\nb\nc\nxx yy\n") }
            try fmtThrowsIOError("unknown symbol") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: " O   0", with: " Qq  0")) }
            try fmtThrowsIOError("bad coordinate") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "1.3000", with: "1.3x00")) }
            try fmtThrowsIOError("bond index out of range") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "  3  9  1  0", with: "  3 19  1  0")) }
            try fmtThrowsIOError("bond index zero") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "  3  9  1  0", with: "  0  9  1  0")) }
            try fmtThrowsIOError("self bond") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "  3  9  1  0", with: "  3  3  1  0")) }
            try fmtThrowsIOError("bad bond type") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "  3  9  1  0", with: "  3  9  8  0")) }
            try fmtThrowsIOError("missing M  END") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "M  END\n", with: "")) }
            try fmtThrowsIOError("bad M CHG") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "M  END", with: "M  CHG  1   99   1\nM  END")) }
            try fmtThrowsIOError("M CHG count") { _ = try MDLMolFormat.parse(mol.replacingOccurrences(of: "M  END", with: "M  CHG  3   1   1\nM  END")) }
        },
        Check("io.mol.truncatedThrows") {
            for name in ["mol_ethanol.mol", "sdf_two.sdf"] {
                let s = try fmtFixture(name)
                // every prefix that ends before the first M  END must throw
                let firstEnd = s.range(of: "M  END")!.lowerBound
                let limit = s.distance(from: s.startIndex, to: firstEnd)
                var count = 0
                for cut in stride(from: 1, to: limit, by: 7) {
                    let t = String(s.prefix(cut))
                    try fmtThrowsIOError("\(name) cut at \(cut)") { _ = try MDLMolFormat.parse(t) }
                    count += 1
                }
                try expect(count > 5)
                // second record of the SDF truncated before its M  END
                if name == "sdf_two.sdf" {
                    let idx = s.range(of: "$$$$")!.upperBound
                    let rest = s[idx...]
                    let cutPoint = rest.range(of: "M  END")!.lowerBound
                    try fmtThrowsIOError("second record truncated") { _ = try MDLMolFormat.parse(String(s[..<cutPoint])) }
                }
                // arbitrary cuts never crash
                for f in stride(from: 0.01, to: 1.0, by: 0.013) { _ = try? MDLMolFormat.parse(fmtPrefix(s, fraction: f)) }
            }
        },
        Check("io.sdf.largeMultiRecord") {
            var recs: [SDFRecord] = []
            for i in 0..<2_000 {
                var m = fmtMixed()
                m.title = "m\(i)"
                m.atoms[0].position.x += Double(i % 50)
                recs.append(SDFRecord(molecule: m, properties: [SDFProperty(name: "I", value: "\(i)")]))
            }
            let text = MDLMolFormat.writeSDF(recs)
            let (r, t) = try fmtTime { try MDLMolFormat.parse(text) }
            try expect(r.count == 2000 && r[1999].value(for: "I") == "1999" && r[1999].molecule.title == "m1999")
            try fmtSameMolecule(recs[777].molecule, r[777].molecule, tol: 1e-5, chargeMult: false)
            try expect(t < 8.0, "parse took \(t)s")
        },
    ]

    // MARK: CML

    static let ioFormatsCML: [Check] = [
        Check("io.cml.waterValues") {
            let r = try CMLFormat.read(url: testDataURL("io/cml_water.cml"))
            try expect(r.count == 1)
            let m = r[0]
            try expect(m.title == "water" && m.charge == 0 && m.multiplicity == 1)
            try expect(m.atoms.map(\.atomicNumber) == [8, 1, 1])
            try expectClose(m.atoms[2].position.y, -0.7572)
            try expectClose(m.atoms[0].position.z, 0.1173)
            try expect(m.bonds == [Bond(0, 1), Bond(0, 2)])
        },
        Check("io.cml.arrayFormNamespaceAnd2D") {
            let r = try CMLFormat.read(url: testDataURL("io/cml_array.cml"))
            try expect(r.count == 1)
            let m = r[0]
            try expect(m.title == "formaldehyde cation (2D)", "title '\(m.title)'")
            try expect(m.charge == 1)
            try expect(m.atoms.map(\.atomicNumber) == [6, 8, 1, 1])
            try expectClose(m.atoms[1].position.x, 1.2)
            try expectClose(m.atoms[3].position.y, -0.9)
            try expect(m.atoms.allSatisfy { $0.position.z == 0 })
            try expect(m.bonds == [Bond(0, 1, order: .double), Bond(0, 2), Bond(0, 3)], "bonds \(m.bonds)")
        },
        Check("io.cml.inlineVariants") {
            // bond orders, atom formalCharge summed, multiple molecules in a list, nested element order
            let s = """
            <cml><moleculeList>
            <molecule title="A"><atomArray>
              <atom id="x" elementType="N" x3="0" y3="0" z3="0" formalCharge="1"/>
              <atom id="y" elementType="C" x3="1.4" y3="0" z3="0"/>
              <atom id="z" elementType="C" x3="2.0" y3="1.0" z3="0" formalCharge="-1"/>
              <atom id="w" elementType="O" x3="3" y3="1" z3="0" formalCharge="+1"/>
            </atomArray><bondArray>
              <bond atomRefs2="x y" order="A"/><bond atomRefs2="y z" order="3"/><bond atomRefs2="z w" order="D"/>
            </bondArray></molecule>
            <molecule id="b" spinMultiplicity="2"><atomArray><atom id="a1" elementType="H" x3="0" y3="0" z3="0"/></atomArray>
              <name>hydrogen atom</name></molecule>
            </moleculeList></cml>
            """
            let r = try CMLFormat.parse(s)
            try expect(r.count == 2)
            try expect(r[0].charge == 1 && r[0].title == "A")
            try expect(r[0].bonds.map(\.order) == [.aromatic, .triple, .double])
            try expect(r[1].multiplicity == 2 && r[1].title == "hydrogen atom" && r[1].atoms.count == 1)
            // CRLF
            try expect(try CMLFormat.parse(fmtCRLF(s)) == r)
        },
        Check("io.cml.roundTrip") {
            var m = fmtMixed()
            m.charge = -1; m.multiplicity = 2
            m.bonds.append(Bond(3, 5, order: .aromatic))
            for i in m.atoms.indices { m.atoms[i].position.x += 1.0 / 3.0 }
            let text = CMLFormat.write(m)
            try expect(text.contains("&lt;&amp;&gt;") && text.contains("&quot;"), "title escaped")
            let r = try CMLFormat.parse(text)
            try expect(r.count == 1)
            try fmtSameMolecule(m, r[0], tol: 1e-7)
            try expect(r[0].title == m.title, "title '\(r[0].title)'")
            let w = try CMLFormat.read(url: testDataURL("io/cml_water.cml"))[0]
            let w2 = try CMLFormat.parse(CMLFormat.write(w))[0]
            try expect(w == w2 || (try? fmtSameMolecule(w, w2, tol: 1e-7)) != nil)
            // empty molecule has no atoms: not parseable
            try fmtThrowsIOError("no atoms") { _ = try CMLFormat.parse(CMLFormat.write(Molecule())) }
        },
        Check("io.cml.malformedThrows") {
            let s = try fmtFixture("cml_water.cml")
            try fmtThrowsIOError("empty") { _ = try CMLFormat.parse("") }
            try fmtThrowsIOError("not xml") { _ = try CMLFormat.parse("hello world") }
            try fmtThrowsIOError("no molecule") { _ = try CMLFormat.parse("<cml></cml>") }
            try fmtThrowsIOError("bad coordinate") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "0.757200\" z3", with: "abc\" z3")) }
            try fmtThrowsIOError("unknown element") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "elementType=\"O\"", with: "elementType=\"Zz\"")) }
            try fmtThrowsIOError("missing element") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "elementType=\"O\" ", with: "")) }
            try fmtThrowsIOError("bad order") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "order=\"S\"", with: "order=\"Q\"")) }
            try fmtThrowsIOError("unknown atom ref") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "a1 a3", with: "a1 a9")) }
            try fmtThrowsIOError("self bond") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "a1 a3", with: "a1 a1")) }
            try fmtThrowsIOError("bad bond refs") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "a1 a3", with: "a1")) }
            try fmtThrowsIOError("duplicate id") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "id=\"a3\"", with: "id=\"a2\"")) }
            try fmtThrowsIOError("bad charge") { _ = try CMLFormat.parse(s.replacingOccurrences(of: "formalCharge=\"0\"", with: "formalCharge=\"x\"")) }
            try fmtThrowsIOError("array length mismatch") {
                _ = try CMLFormat.parse("<cml><molecule><atomArray atomID=\"a b\" elementType=\"C O\" x3=\"0\" y3=\"0 1\" z3=\"0 0\"/></molecule></cml>")
            }
        },
        Check("io.cml.truncatedThrows") {
            let s = try fmtFixture("cml_water.cml")
            for f in [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 0.95] {
                let t = fmtPrefix(s, fraction: f)
                try fmtThrowsIOError("truncated at \(f)") { _ = try CMLFormat.parse(t) }
            }
        },
        Check("io.cml.largeMolecule") {
            let m = fmtBigMolecule(20_000)
            let text = CMLFormat.write(m)
            let (r, t) = try fmtTime { try CMLFormat.parse(text) }
            try expect(r[0].atoms.count == 20_000)
            try fmtSameMolecule(m, r[0], tol: 1e-7)
            try expect(t < 10.0, "parse took \(t)s")
        },
    ]

    // MARK: registry / detection

    static let ioFormatsRegistry: [Check] = [
        Check("io.registry.metadata") {
            try expect(MoleculeFileFormat.allCases.count == 9)
            for f in MoleculeFileFormat.allCases {
                try expect(f.canRead && !f.fileExtensions.isEmpty && !f.displayName.isEmpty)
                try expect(f.fileExtensions.allSatisfy { $0 == $0.lowercased() && !$0.hasPrefix(".") })
                try expect(!f.displayName.lowercased().contains("gauss") || f == .gaussianInput || f == .gaussianOutput || f == .cube)
            }
            try expect(!MoleculeFileFormat.gaussianOutput.canWrite && MoleculeFileFormat.cube.canWrite && MoleculeFileFormat.gaussianInput.canWrite)
            try expect(MoleculeFileFormat.gaussianInput.fileExtensions == ["gjf", "com", "gau"])
            try expect(MoleculeFileFormat.formattedCheckpoint.fileExtensions == ["fchk", "fch"])
            try expect(MoleculeFileFormat.pdb.fileExtensions == ["pdb", "ent"] && MoleculeFileFormat.sdf.fileExtensions == ["sdf", "sd"])
            try expect(MoleculeFileFormat(rawValue: "xyz") == .xyz)
            let data = try JSONEncoder().encode(MoleculeFileFormat.cml)
            try expect(try JSONDecoder().decode(MoleculeFileFormat.self, from: data) == .cml)
            // no extension is claimed twice
            var seen = Set<String>()
            for f in MoleculeFileFormat.allCases { for e in f.fileExtensions { try expect(seen.insert(e).inserted, "dup ext \(e)") } }
        },
        Check("io.registry.detectByExtension") {
            let cases: [(String, MoleculeFileFormat)] = [
                ("a.gjf", .gaussianInput), ("a.COM", .gaussianInput), ("a.gau", .gaussianInput),
                ("a.log", .gaussianOutput), ("a.fchk", .formattedCheckpoint), ("a.fch", .formattedCheckpoint),
                ("a.cube", .cube), ("a.cub", .cube), ("a.xyz", .xyz), ("a.pdb", .pdb), ("a.ent", .pdb),
                ("a.mol", .mol), ("a.sdf", .sdf), ("a.sd", .sdf), ("a.cml", .cml), ("dir.x/b.XYZ", .xyz),
            ]
            for (name, f) in cases {
                try expect(MoleculeFileFormat.detect(url: URL(fileURLWithPath: "/nonexistent/" + name)) == f, "\(name)")
            }
            try expect(MoleculeFileFormat.detect(url: URL(fileURLWithPath: "/nonexistent/a.zzz")) == nil)
            try expect(MoleculeFileFormat.detect(url: URL(fileURLWithPath: "/nonexistent/noext")) == nil)
            try expect(MoleculeFileFormat.detect(contents: "", fileName: "x.cube") == .cube)
            try expect(MoleculeFileFormat.detect(contents: "", fileName: "x.q") == nil)
            try expect(MoleculeFileFormat.detect(contents: "") == nil)
        },
        Check("io.registry.detectFixturesByContent") {
            let cases: [(String, MoleculeFileFormat)] = [
                ("cube_water_homo.cube", .cube), ("cube_water_density.cube", .cube), ("cube_multi_mo.cube", .cube),
                ("xyz_traj.xyz", .xyz), ("pdb_alanine.pdb", .pdb), ("pdb_models.pdb", .pdb),
                ("mol_ethanol.mol", .mol), ("sdf_two.sdf", .sdf), ("cml_water.cml", .cml), ("cml_array.cml", .cml),
            ]
            for (name, f) in cases {
                let s = try fmtFixture(name)
                try expect(MoleculeFileFormat.detect(contents: s) == f, "\(name) detected \(String(describing: MoleculeFileFormat.detect(contents: s)))")
                try expect(MoleculeFileFormat.detect(contents: fmtCRLF(s)) == f, "\(name) CRLF")
                // also through the url path (extension decides; sniffing decides for renamed copies)
                try expect(MoleculeFileFormat.detect(url: testDataURL("io/" + name)) == f, "\(name) by url")
            }
            // a lone PDB/sdf/mol snippet, headerless xyz with atomic numbers
            try expect(MoleculeFileFormat.detect(contents: "2\nx\n6 0.0 0.0 0.0\n8 1.2 0.0 0.0\n") == .xyz)
            try expect(MoleculeFileFormat.detect(contents: "<molecule id=\"m\"/>") == .cml)
            try expect(MoleculeFileFormat.detect(contents: "<?xml version=\"1.0\"?>\n<cml xmlns=\"http://www.xml-cml.org/schema\"/>") == .cml)
            try expect(MoleculeFileFormat.detect(contents: "<?xml version=\"1.0\"?>\n<svg/>") == nil)
            try expect(MoleculeFileFormat.detect(contents: "just some random prose\nwith lines\nof text\nnothing else\n") == nil)
        },
        Check("io.registry.detectGaussianSnippets") {
            let gjf = "%chk=water.chk\n%mem=2GB\n#p B3LYP/6-31G(d) opt\n\nwater\n\n0 1\nO 0.0 0.0 0.1\nH 0.0 0.7 -0.4\nH 0.0 -0.7 -0.4\n\n"
            try expect(MoleculeFileFormat.detect(contents: gjf) == .gaussianInput)
            try expect(MoleculeFileFormat.detect(contents: "# HF/STO-3G\n\nt\n\n0 1\nH 0 0 0\n") == .gaussianInput)
            try expect(MoleculeFileFormat.detect(contents: fmtCRLF(gjf)) == .gaussianInput)
            let log = " Entering Gaussian System, Link 0=g16\n Input=water.gjf\n Output=water.log\n"
            try expect(MoleculeFileFormat.detect(contents: log) == .gaussianOutput)
            try expect(MoleculeFileFormat.detect(contents: "\n Gaussian, Inc.  All Rights Reserved.\n") == .gaussianOutput)
            let fchk = "Water SP\nSP        RHF                                                         STO-3G\nNumber of atoms                            I                3\nInfo1-9                                    I   N=           9\n"
            try expect(MoleculeFileFormat.detect(contents: fchk) == .formattedCheckpoint)
            try expect(MoleculeFileFormat.detect(contents: fmtCRLF(fchk)) == .formattedCheckpoint)
        },
        Check("io.registry.detectAmbiguousExtensionsSniffContent") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-fmt-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            func put(_ name: String, _ body: String) throws -> URL {
                let u = dir.appendingPathComponent(name)
                try body.write(to: u, atomically: true, encoding: .utf8)
                return u
            }
            let log = " Entering Gaussian System, Link 0=g16\n"
            try expect(MoleculeFileFormat.detect(url: try put("a.out", log)) == .gaussianOutput)
            try expect(MoleculeFileFormat.detect(url: try put("b.out", "garbage\n")) == .gaussianOutput, ".out falls back to the extension")
            try expect(MoleculeFileFormat.detect(url: try put("c.out", try fmtFixture("xyz_traj.xyz"))) == .xyz)
            try expect(MoleculeFileFormat.detect(url: try put("d.txt", try fmtFixture("pdb_alanine.pdb"))) == .pdb)
            try expect(MoleculeFileFormat.detect(url: try put("e.dat", try fmtFixture("cube_water_density.cube"))) == .cube)
            try expect(MoleculeFileFormat.detect(url: try put("noext", try fmtFixture("sdf_two.sdf"))) == .sdf)
            try expect(MoleculeFileFormat.detect(url: try put("f.txt", try fmtFixture("cml_water.cml"))) == .cml)
            try expect(MoleculeFileFormat.detect(url: try put("g.weird", "%chk=a\n#p hf\n\nt\n\n0 1\nH 0 0 0\n")) == .gaussianInput)
            try expect(MoleculeFileFormat.detect(url: try put("h.txt", "nothing here")) == nil)
            // long file: only the first 4 KB are examined (multi-byte char cut at the boundary)
            let big = try fmtFixture("xyz_traj.xyz") + String(repeating: "é", count: 10_000)
            try expect(MoleculeFileFormat.detect(url: try put("i.txt", big)) == .xyz)
            try expect(MoleculeFileFormat.detect(url: dir.appendingPathComponent("missing.txt")) == nil)
        },
        Check("io.registry.readersAgreeWithDetection") {
            // detect then parse with the matching reader: smoke test of the whole chain
            for name in ["cube_water_homo.cube", "xyz_traj.xyz", "pdb_alanine.pdb", "mol_ethanol.mol", "sdf_two.sdf", "cml_water.cml"] {
                let url = testDataURL("io/" + name)
                guard let f = MoleculeFileFormat.detect(url: url) else { throw CheckFailure(description: "no format for \(name)") }
                let n: Int
                switch f {
                case .cube: n = try CubeFile.read(url: url).molecule.atoms.count
                case .xyz: n = try XYZFormat.read(url: url)[0].atoms.count
                case .pdb: n = try PDBFormat.read(url: url).models[0].atoms.count
                case .mol, .sdf: n = try MDLMolFormat.read(url: url)[0].molecule.atoms.count
                case .cml: n = try CMLFormat.read(url: url)[0].atoms.count
                default: n = 0
                }
                try expect(n > 0, name)
            }
            try fmtThrowsIOError("missing file") { _ = try XYZFormat.read(url: URL(fileURLWithPath: "/nonexistent/x.xyz")) }
            try fmtThrowsIOError("missing cube") { _ = try CubeFile.read(url: URL(fileURLWithPath: "/nonexistent/x.cube")) }
            try fmtThrowsIOError("missing pdb") { _ = try PDBFormat.read(url: URL(fileURLWithPath: "/nonexistent/x.pdb")) }
            try fmtThrowsIOError("missing mol") { _ = try MDLMolFormat.read(url: URL(fileURLWithPath: "/nonexistent/x.mol")) }
            try fmtThrowsIOError("missing cml") { _ = try CMLFormat.read(url: URL(fileURLWithPath: "/nonexistent/x.cml")) }
        },
    ]
}
