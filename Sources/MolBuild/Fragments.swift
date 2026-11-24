import Foundation
import simd
import MolCore

// Fragment library (Worker A, Lead 4). All geometry is generated programmatically.

public enum FragmentCategory: String, CaseIterable, Sendable {
    case rings, groups, aminoAcids, nucleobases
    public var title: String {
        switch self {
        case .rings: return "Rings"
        case .groups: return "Functional Groups"
        case .aminoAcids: return "Amino Acids"
        case .nucleobases: return "Nucleobases"
        }
    }
}

public struct Fragment: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: FragmentCategory
    public let molecule: Molecule
    public let anchor: Int
    public let leaving: Int
    public init(id: String, name: String, category: FragmentCategory, molecule: Molecule, anchor: Int, leaving: Int) {
        self.id = id; self.name = name; self.category = category
        self.molecule = molecule; self.anchor = anchor; self.leaving = leaving
    }
}

public enum FragmentLibrary {
    public static let all: [Fragment] = FragmentFactory.buildAll()
    public static func fragment(id: String) -> Fragment? { custom(id) ?? all.first { $0.id == id } }

    // MARK: user fragments (e.g. a structure found by name lookup), registered at run time

    private static let customLock = NSLock()
    nonisolated(unsafe) private static var customStore: [String: Fragment] = [:]
    private static func custom(_ id: String) -> Fragment? { customLock.lock(); defer { customLock.unlock() }; return customStore[id] }

    /// Register (or replace) a run-time fragment; `fragment(id:)` finds it. Category is `.groups`.
    public static func register(_ f: Fragment) { customLock.lock(); customStore[f.id] = f; customLock.unlock() }

    /// Make a fragment from any molecule: the attachment atom is the first heavy atom carrying a hydrogen
    /// (prefer carbon), the leaving atom one of its hydrogens. Returns nil if no heavy atom has a hydrogen
    /// (such a structure can still be placed free with `Builder.place`).
    public static func makeFragment(id: String, name: String, molecule m: Molecule) -> Fragment? {
        var mol = m
        mol.renumberAtomIDs()
        let c = Editing.centroid(mol)
        for i in mol.atoms.indices { mol.atoms[i].position -= c }
        func firstH(_ i: Int) -> Int? { mol.buildNeighbors(of: i).first { mol.atoms[$0].atomicNumber == 1 && mol.buildNeighbors(of: $0).count == 1 } }
        let heavy = mol.atoms.indices.filter { mol.atoms[$0].atomicNumber > 1 }
        let anchor = heavy.first { mol.atoms[$0].atomicNumber == 6 && firstH($0) != nil } ?? heavy.first { firstH($0) != nil }
        guard let a = anchor, let h = firstH(a) else { return nil }
        mol.title = name
        return Fragment(id: id, name: name, category: .groups, molecule: mol, anchor: a, leaving: h)
    }
    public static func fragments(in c: FragmentCategory) -> [Fragment] { all.filter { $0.category == c } }
}

// MARK: - internal-coordinate builder

struct FB {
    var m = Molecule()

    @discardableResult
    mutating func add(_ z: Int, _ a: Int? = nil, _ order: BondOrder = .single, b: Int? = nil, c: Int? = nil,
                      angle: Double = 109.47, dihedral: Double = 180, length: Double? = nil) -> Int {
        guard let a else { return m.buildAddAtom(z, at: .zero) }
        let pa = m.atoms[a].position
        let len = length ?? BuildElements.bondLength(m.atoms[a].atomicNumber, z, order: order)
        let th = angle * .pi / 180
        var pos: Vec3
        if let b {
            let pb = m.atoms[b].position
            let u = bUnit(pb - pa)
            var w: Vec3
            if let c {
                let pc = m.atoms[c].position
                let cb = pc - pb
                w = cb - simd_dot(cb, u) * u
                if simd_length(w) < 1e-9 { w = buildPerpendicular(u) }
            } else {
                w = Vec3(0, 0, 1) - simd_dot(Vec3(0, 0, 1), u) * u
                if simd_length(w) < 1e-9 { w = Vec3(0, 1, 0) }
                w = simd_cross(Vec3(0, 0, 1), u)       // in-plane perpendicular
                if simd_length(w) < 1e-9 { w = Vec3(0, 1, 0) }
            }
            w = simd_normalize(w)
            let v = simd_cross(u, w)
            let ph = (c == nil ? 0 : dihedral) * .pi / 180
            pos = pa + len * (u * cos(th) + sin(th) * (w * cos(ph) + v * sin(ph)))
        } else {
            pos = pa + Vec3(len, 0, 0)
        }
        let i = m.buildAddAtom(z, at: pos)
        m.buildSetBond(a, i, order)
        return i
    }

    /// Finish: add hydrogens, add forced hydrogens, choose leaving H on anchor.
    func finish(_ id: String, _ name: String, _ cat: FragmentCategory, anchor: Int, forcedH: [Int] = [], mirrorIfNeeded: ((Molecule) -> Bool)? = nil) -> Fragment {
        var mol = m
        Editing.addHydrogens(&mol)
        for a in forcedH { Editing.placeHydrogens(&mol, atom: a, count: 1, hyb: .sp2) }
        if let test = mirrorIfNeeded, test(mol) { Editing.mirror(&mol, planeNormal: Vec3(0, 0, 1)) }
        // Templates built from internal coordinates can fold side chains onto each other; relax those.
        let relaxed = Builder.relaxClashes(mol, newFrom: 0)
        if relaxed.atoms.count == mol.atoms.count { mol = relaxed }
        let c = Editing.centroid(mol)
        for i in mol.atoms.indices { mol.atoms[i].position -= c }
        mol.title = name
        let lv = mol.buildNeighbors(of: anchor).last { mol.atoms[$0].atomicNumber == 1 } ?? -1
        precondition(lv >= 0, "fragment \(id): anchor has no hydrogen")
        return Fragment(id: id, name: name, category: cat, molecule: mol, anchor: anchor, leaving: lv)
    }
}

// MARK: - planar ring systems

struct Ring2D {
    var z: [Int] = []
    var xy: [Vec3] = []
    var bonds: [(Int, Int, BondOrder)] = []
    var forcedH: [Int] = []

    static func poly(_ n: Int, side: Double) -> [Vec3] {
        let R = side / (2 * sin(.pi / Double(n)))
        return (0..<n).map { k in
            let t = Double.pi + 2 * .pi * Double(k) / Double(n)
            return Vec3(R + R * cos(t), R * sin(t), 0)
        }
    }

    /// Vertices of an n-gon sharing edge P->Q, placed away from `away`. Result starts with P, Q.
    static func fused(p: Vec3, q: Vec3, n: Int, away: Vec3) -> [Vec3] {
        let s = simd_distance(p, q)
        let e = (q - p) / s
        var nr = Vec3(-e.y, e.x, 0)
        let mid = (p + q) / 2
        if simd_dot(nr, mid - away) < 0 { nr = -nr }
        let center = mid + nr * (s / (2 * tan(.pi / Double(n))))
        let step = 2 * Double.pi / Double(n)
        func rot(_ k: Double) -> Vec3 {
            let d = p - center
            let c = cos(k), sn = sin(k)
            return center + Vec3(d.x * c - d.y * sn, d.x * sn + d.y * c, 0)
        }
        let sign = simd_distance(rot(step), q) < simd_distance(rot(-step), q) ? 1.0 : -1.0
        return (0..<n).map { rot(sign * step * Double($0)) }
    }

    /// Base ring of `zs` (aromatic or given orders), vertex 0 at origin, centre on +x.
    init(zs: [Int], side: Double, orders: [BondOrder]? = nil) {
        z = zs
        xy = Ring2D.poly(zs.count, side: side)
        for i in zs.indices { bonds.append((i, (i + 1) % zs.count, orders?[i] ?? .aromatic)) }
    }

    /// Fuse another ring on bond (i, j) (i->j in base order). Extra atoms listed from the one bonded to i.
    mutating func fuse(i: Int, j: Int, extraZ: [Int], side: Double, order: BondOrder = .aromatic) {
        let n = extraZ.count + 2
        var cen = Vec3.zero
        for p in xy { cen += p }
        cen /= Double(xy.count)
        let pts = Ring2D.fused(p: xy[j], q: xy[i], n: n, away: cen)
        var prev = i
        for (k, zz) in extraZ.enumerated() {
            z.append(zz); xy.append(pts[2 + k])
            bonds.append((prev, z.count - 1, order))
            prev = z.count - 1
        }
        bonds.append((prev, j, order))
    }

    /// Exocyclic substituent on ring atom a (radially outward in plane).
    @discardableResult
    mutating func sub(_ a: Int, z zz: Int, order: BondOrder = .single) -> Int {
        let nbs = bonds.compactMap { $0.0 == a ? $0.1 : ($0.1 == a ? $0.0 : nil) }.filter { $0 < xy.count }
        var s = Vec3.zero
        for n in nbs { s += bUnit(xy[n] - xy[a]) }
        let d = bUnit(-s)
        let len = BuildElements.bondLength(z[a], zz, order: order)
        z.append(zz); xy.append(xy[a] + d * len)
        bonds.append((a, z.count - 1, order))
        return z.count - 1
    }

    func molecule() -> Molecule {
        var m = Molecule()
        for (i, zz) in z.enumerated() { m.buildAddAtom(zz, at: xy[i]) }
        for b in bonds { m.buildSetBond(b.0, b.1, b.2) }
        return m
    }
}

// MARK: - factory

enum FragmentFactory {
    static func ringFragment(_ id: String, _ name: String, _ r: Ring2D, anchor: Int) -> Fragment {
        var fb = FB(); fb.m = r.molecule()
        return fb.finish(id, name, .rings, anchor: anchor, forcedH: r.forcedH)
    }

    static func chair() -> Fragment {
        var fb = FB()
        let h = 0.25, rho = (1.53 * 1.53 - 4 * h * h).squareRoot()
        for k in 0..<6 {
            let t = Double(k) * .pi / 3
            fb.m.buildAddAtom(6, at: Vec3(rho * cos(t), rho * sin(t), k % 2 == 0 ? h : -h))
        }
        for k in 0..<6 { fb.m.buildSetBond(k, (k + 1) % 6, .single) }
        return fb.finish("cyclohexane", "Cyclohexane (chair)", .rings, anchor: 0)
    }

    static func buildAll() -> [Fragment] {
        var out = [Fragment]()
        out += rings()
        out += groups()
        out += aminoAcids()
        out += nucleobases()
        return out
    }

    // MARK: rings
    static func rings() -> [Fragment] {
        var out = [Fragment]()
        let C = 6, N = 7
        let benz = Ring2D(zs: [C, C, C, C, C, C], side: 1.40)
        out.append(ringFragment("benzene", "Benzene", benz, anchor: 0))
        out.append(chair())
        out.append(ringFragment("cyclopentane", "Cyclopentane", Ring2D(zs: Array(repeating: C, count: 5), side: 1.53, orders: Array(repeating: .single, count: 5)), anchor: 0))
        out.append(ringFragment("cyclopropane", "Cyclopropane", Ring2D(zs: [C, C, C], side: 1.51, orders: [.single, .single, .single]), anchor: 0))
        out.append(ringFragment("cyclobutane", "Cyclobutane", Ring2D(zs: [C, C, C, C], side: 1.55, orders: Array(repeating: .single, count: 4)), anchor: 0))
        out.append(ringFragment("pyridine", "Pyridine", Ring2D(zs: [N, C, C, C, C, C], side: 1.38), anchor: 3))
        out.append(ringFragment("pyrimidine", "Pyrimidine", Ring2D(zs: [N, C, N, C, C, C], side: 1.38), anchor: 4))
        var pyrrole = Ring2D(zs: [N, C, C, C, C], side: 1.38); pyrrole.forcedH = [0]
        out.append(ringFragment("pyrrole", "Pyrrole", pyrrole, anchor: 2))
        out.append(ringFragment("furan", "Furan", Ring2D(zs: [8, C, C, C, C], side: 1.38), anchor: 2))
        out.append(ringFragment("thiophene", "Thiophene", Ring2D(zs: [16, C, C, C, C], side: 1.55), anchor: 2))
        var imid = Ring2D(zs: [C, N, C, N, C], side: 1.38); imid.forcedH = [3]
        out.append(ringFragment("imidazole", "Imidazole", imid, anchor: 2))
        var naph = Ring2D(zs: Array(repeating: C, count: 6), side: 1.40)
        naph.fuse(i: 4, j: 5, extraZ: [C, C, C, C], side: 1.40)
        out.append(ringFragment("naphthalene", "Naphthalene", naph, anchor: 1))
        var indole = indoleRing(); indole.forcedH = [2]
        out.append(ringFragment("indole", "Indole", indole, anchor: 0))
        return out
    }

    static func indoleRing() -> Ring2D {
        // atoms: 0 C3, 1 C2, 2 N1, 3 C7a, 4 C3a ; fused benzene: 5 C7, 6 C6, 7 C5, 8 C4
        var r = Ring2D(zs: [6, 6, 7, 6, 6], side: 1.40)
        r.fuse(i: 3, j: 4, extraZ: [6, 6, 6, 6], side: 1.40)
        return r
    }

    // MARK: groups
    static func groups() -> [Fragment] {
        var out = [Fragment]()
        func G(_ id: String, _ name: String, anchor: Int = 0, _ build: (inout FB) -> Void) {
            var fb = FB(); build(&fb)
            out.append(fb.finish(id, name, .groups, anchor: anchor))
        }
        G("methyl", "Methyl") { $0.add(6) }
        G("ethyl", "Ethyl") { let c = $0.add(6); $0.add(6, c) }
        G("isopropyl", "Isopropyl") { let c = $0.add(6); let a = $0.add(6, c); $0.add(6, c, b: a, angle: 112) }
        G("tert-butyl", "tert-Butyl") {
            let c = $0.add(6); let a = $0.add(6, c)
            let b = $0.add(6, c, b: a, angle: 109.5)
            $0.add(6, c, b: a, c: b, angle: 109.5, dihedral: 120)
        }
        G("vinyl", "Vinyl") { let c = $0.add(6); $0.add(6, c, .double) }
        G("ethynyl", "Ethynyl") { let c = $0.add(6); $0.add(6, c, .triple) }
        G("hydroxyl", "Hydroxyl") { $0.add(8) }
        G("thiol", "Thiol") { $0.add(16) }
        G("amino", "Amino") { $0.add(7) }
        G("methoxy", "Methoxy", anchor: 1) { let c = $0.add(6); $0.add(8, c) }
        G("fluoro", "Fluoro") { $0.add(9) }
        G("chloro", "Chloro") { $0.add(17) }
        G("bromo", "Bromo") { $0.add(35) }
        G("iodo", "Iodo") { $0.add(53) }
        G("formyl", "Formyl (aldehyde)") { let c = $0.add(6); $0.add(8, c, .double) }
        G("acetyl", "Acetyl") { let c = $0.add(6); let o = $0.add(8, c, .double); $0.add(6, c, b: o, angle: 120) }
        G("carboxyl", "Carboxyl") {
            let c = $0.add(6); let o = $0.add(8, c, .double); $0.add(8, c, b: o, angle: 120)
        }
        G("ester", "Methyl ester") {
            let c = $0.add(6); let o = $0.add(8, c, .double); let o2 = $0.add(8, c, b: o, angle: 120)
            $0.add(6, o2, b: c, c: o, angle: 115, dihedral: 180)
        }
        G("amide", "Amide") {
            let c = $0.add(6); let o = $0.add(8, c, .double); $0.add(7, c, b: o, angle: 122)
        }
        G("nitro", "Nitro") { let n = $0.add(7); let o = $0.add(8, n, .double, length: 1.22); $0.add(8, n, .double, b: o, angle: 124, length: 1.22) }
        G("cyano", "Cyano") { let c = $0.add(6); $0.add(7, c, .triple) }
        G("trifluoromethyl", "Trifluoromethyl") {
            let c = $0.add(6); let f = $0.add(9, c); let f2 = $0.add(9, c, b: f, angle: 109.5)
            $0.add(9, c, b: f, c: f2, angle: 109.5, dihedral: 120)
        }
        // phenyl: benzene alias
        let benz = FragmentFactory.ringFragment("phenyl", "Phenyl", Ring2D(zs: Array(repeating: 6, count: 6), side: 1.40), anchor: 0)
        out.insert(Fragment(id: "phenyl", name: "Phenyl", category: .groups, molecule: benz.molecule, anchor: benz.anchor, leaving: benz.leaving), at: 6)
        return out
    }

    // MARK: nucleobases
    static func nucleobases() -> [Fragment] {
        var out = [Fragment]()
        func purine() -> Ring2D {
            // 0 N1,1 C2,2 N3,3 C4,4 C5,5 C6 ; 6 N9, 7 C8, 8 N7
            var r = Ring2D(zs: [7, 6, 7, 6, 6, 6], side: 1.38)
            r.fuse(i: 3, j: 4, extraZ: [7, 6, 7], side: 1.38)
            return r
        }
        func pyr() -> Ring2D { Ring2D(zs: [7, 6, 7, 6, 6, 6], side: 1.38) }
        func nb(_ id: String, _ name: String, _ r: Ring2D, anchor: Int) {
            var fb = FB(); fb.m = r.molecule()
            out.append(fb.finish(id, name, .nucleobases, anchor: anchor, forcedH: r.forcedH))
        }
        var a = purine(); a.sub(5, z: 7); a.forcedH = [6]
        nb("adenine", "Adenine", a, anchor: 6)
        var g = purine(); g.sub(5, z: 8, order: .double); g.sub(1, z: 7); g.forcedH = [6, 0]
        nb("guanine", "Guanine", g, anchor: 6)
        var c = pyr(); c.sub(1, z: 8, order: .double); c.sub(3, z: 7); c.forcedH = [0]
        nb("cytosine", "Cytosine", c, anchor: 0)
        var t = pyr(); t.sub(1, z: 8, order: .double); t.sub(3, z: 8, order: .double); t.sub(4, z: 6); t.forcedH = [0, 2]
        nb("thymine", "Thymine", t, anchor: 0)
        var u = pyr(); u.sub(1, z: 8, order: .double); u.sub(3, z: 8, order: .double); u.forcedH = [0, 2]
        nb("uracil", "Uracil", u, anchor: 0)
        return out
    }

    // MARK: amino acids

    struct AA {
        var fb = FB()
        var N = 0, CA = 1, C = 2, CB = -1
        var forcedH: [Int] = []

        init() {
            N = fb.add(7)
            CA = fb.add(6, N)
            C = fb.add(6, CA, b: N, angle: 111)
            fb.add(8, C, .double, b: CA, c: N, angle: 121, dihedral: 0)
            fb.add(8, C, b: CA, c: N, angle: 115, dihedral: 180)
        }
        mutating func cb() -> Int { CB = fb.add(6, CA, b: N, c: C, angle: 110.5, dihedral: 122); return CB }
        @discardableResult
        mutating func s(_ z: Int, _ a: Int, _ b: Int, _ c: Int, _ dih: Double, angle: Double = 111, order: BondOrder = .single) -> Int {
            fb.add(z, a, order, b: b, c: c, angle: angle, dihedral: dih)
        }
        /// Ring attached at its atom 0 to `a`; `b`,`c` as dihedral refs. Returns the new indices.
        mutating func ring(_ r: Ring2D, at a: Int, b: Int, c: Int, chi1: Double, chi2: Double, subtract: Int = 0) -> [Int] {
            let g0 = fb.add(r.z[0], a, .single, b: b, c: c, angle: 113, dihedral: chi1)
            let pa = fb.m.atoms[a].position, p0 = fb.m.atoms[g0].position
            let dir = bUnit(p0 - pa)
            var rv = fb.m.atoms[b].position - pa
            rv -= simd_dot(rv, dir) * dir
            rv = bUnit(rv)
            let q = simd_quatd(angle: chi2 * .pi / 180, axis: dir)
            let pv = q.act(rv)
            let nz = simd_cross(dir, pv)
            var idx = [g0]
            for k in 1..<r.z.count {
                let l = r.xy[k] - r.xy[0]
                idx.append(fb.m.buildAddAtom(r.z[k], at: p0 + dir * l.x + pv * l.y + nz * l.z))
            }
            for bd in r.bonds { fb.m.buildSetBond(idx[bd.0], idx[bd.1], bd.2) }
            for f in r.forcedH { forcedH.append(idx[f]) }
            return idx
        }
    }

    static func aminoAcids() -> [Fragment] {
        var out = [Fragment]()
        func aa(_ id: String, _ name: String, _ build: (inout AA) -> Void) {
            var a = AA(); build(&a)
            let CAi = a.CA, Ni = a.N, Ci = a.C, CBi = a.CB
            let frag = a.fb.finish(id, name, .aminoAcids, anchor: Ni, forcedH: a.forcedH, mirrorIfNeeded: { mol in
                guard CBi >= 0 else { return false }
                let p = mol.atoms[CAi].position
                let v = simd_dot(mol.atoms[Ni].position - p, simd_cross(mol.atoms[Ci].position - p, mol.atoms[CBi].position - p))
                return v < 0   // L-configuration has N·(C×CB) > 0 about CA
            })
            out.append(frag)
        }
        aa("gly", "Glycine") { _ in }
        aa("ala", "Alanine") { $0.cb() }
        aa("val", "Valine") { let cb = $0.cb(); $0.s(6, cb, $0.CA, $0.N, 180); $0.s(6, cb, $0.CA, $0.N, 60) }
        aa("leu", "Leucine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180)
            $0.s(6, cg, cb, $0.CA, 180); $0.s(6, cg, cb, $0.CA, 60)
        }
        aa("ile", "Isoleucine") {
            let cb = $0.cb(); let g1 = $0.s(6, cb, $0.CA, $0.N, 180); $0.s(6, cb, $0.CA, $0.N, 60)
            $0.s(6, g1, cb, $0.CA, 180)
        }
        aa("pro", "Proline") { a in
            let cb = a.cb()
            var best = (Double.infinity, 0.0, 0.0)
            var cgP = Vec3.zero, cdP = Vec3.zero
            for chi in stride(from: -50.0, through: 50.0, by: 5.0) {
                var trial = a.fb
                let cg = trial.add(6, cb, b: a.CA, c: a.N, angle: 104, dihedral: chi)
                for d in stride(from: 0.0, to: 360.0, by: 2.0) {
                    var t2 = trial
                    let cd = t2.add(6, a.N, b: a.CA, c: cb, angle: 104, dihedral: d)
                    let e = abs(simd_distance(t2.m.atoms[cd].position, t2.m.atoms[cg].position) - 1.53)
                    if e < best.0 { best = (e, chi, d); cgP = t2.m.atoms[cg].position; cdP = t2.m.atoms[cd].position }
                }
            }
            let cg = a.fb.m.buildAddAtom(6, at: cgP); a.fb.m.buildSetBond(cb, cg, .single)
            let cd = a.fb.m.buildAddAtom(6, at: cdP); a.fb.m.buildSetBond(cg, cd, .single); a.fb.m.buildSetBond(a.N, cd, .single)
        }
        aa("ser", "Serine") { let cb = $0.cb(); $0.s(8, cb, $0.CA, $0.N, 180) }
        aa("thr", "Threonine") { let cb = $0.cb(); $0.s(8, cb, $0.CA, $0.N, 60); $0.s(6, cb, $0.CA, $0.N, -60) }
        aa("cys", "Cysteine") { let cb = $0.cb(); $0.s(16, cb, $0.CA, $0.N, 180, angle: 113) }
        aa("met", "Methionine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180)
            let sd = $0.s(16, cg, cb, $0.CA, 180, angle: 112); $0.s(6, sd, cg, cb, 180, angle: 100)
        }
        aa("asp", "Aspartic acid") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180, angle: 112)
            let o = $0.s(8, cg, cb, $0.CA, 0, angle: 120, order: .double); _ = o
            $0.s(8, cg, cb, $0.CA, 180, angle: 118)
        }
        aa("asn", "Asparagine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180, angle: 112)
            $0.s(8, cg, cb, $0.CA, 0, angle: 120, order: .double); $0.s(7, cg, cb, $0.CA, 180, angle: 116)
        }
        aa("glu", "Glutamic acid") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180); let cd = $0.s(6, cg, cb, $0.CA, 180, angle: 112)
            $0.s(8, cd, cg, cb, 0, angle: 120, order: .double); $0.s(8, cd, cg, cb, 180, angle: 118)
        }
        aa("gln", "Glutamine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180); let cd = $0.s(6, cg, cb, $0.CA, 180, angle: 112)
            $0.s(8, cd, cg, cb, 0, angle: 120, order: .double); $0.s(7, cd, cg, cb, 180, angle: 116)
        }
        aa("lys", "Lysine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180); let cd = $0.s(6, cg, cb, $0.CA, 180)
            let ce = $0.s(6, cd, cg, cb, 180); $0.s(7, ce, cd, cg, 180)
        }
        aa("arg", "Arginine") {
            let cb = $0.cb(); let cg = $0.s(6, cb, $0.CA, $0.N, 180); let cd = $0.s(6, cg, cb, $0.CA, 180)
            let ne = $0.s(7, cd, cg, cb, 180, angle: 112); let cz = $0.s(6, ne, cd, cg, 180, angle: 124)
            $0.s(7, cz, ne, cd, 0, angle: 120, order: .double); $0.s(7, cz, ne, cd, 180, angle: 118)
        }
        aa("phe", "Phenylalanine") {
            let cb = $0.cb()
            _ = $0.ring(Ring2D(zs: Array(repeating: 6, count: 6), side: 1.40), at: cb, b: $0.CA, c: $0.N, chi1: 180, chi2: 90)
        }
        aa("tyr", "Tyrosine") {
            let cb = $0.cb()
            var r = Ring2D(zs: Array(repeating: 6, count: 6), side: 1.40); r.sub(3, z: 8)
            _ = $0.ring(r, at: cb, b: $0.CA, c: $0.N, chi1: 180, chi2: 90)
        }
        aa("trp", "Tryptophan") {
            let cb = $0.cb()
            var r = indoleRing(); r.forcedH = [2]
            _ = $0.ring(r, at: cb, b: $0.CA, c: $0.N, chi1: 180, chi2: 90)
        }
        aa("his", "Histidine") {
            let cb = $0.cb()
            var r = Ring2D(zs: [6, 7, 6, 7, 6], side: 1.38); r.forcedH = [3]
            _ = $0.ring(r, at: cb, b: $0.CA, c: $0.N, chi1: 180, chi2: 90)
        }
        return out
    }
}
