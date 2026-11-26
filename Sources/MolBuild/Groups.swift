import Foundation
import simd
import MolCore

// Element groups for the periodic-table picker. After picking an element in the periodic table the user
// chooses "the atom alone" in a given hybridization, or a typical functional group that contains that element.
//
// Every group is a `Fragment` template (anchor = the attachment atom, leaving = the hydrogen that marks the open
// valence) plus the order of the bond it makes to its host:
//
// | Clicked on                       | What `Builder.clickGroup` does                                                    |
// |----------------------------------|-----------------------------------------------------------------------------------|
// | empty space                      | the whole template, hydrogens included (C sp² alone = planar CH₃·, ready to join) |
// | a hydrogen                       | the H is replaced by the group; bond length and angles follow the host            |
// | a heavy atom with a free valence | a functional group is bonded to it along the free direction                       |
// | any other heavy atom             | the atom is replaced in place (atom templates keep their hybridization)           |
//
// Double/triple-bonded groups (=O, =CH₂, =NH, =S, ≡N, ≡CH) take further hydrogens off the host and re-place the
// host's remaining hydrogens in the new (sp²/sp) geometry. Atom templates in sp²/sp hybridization leave valences open;
// when one is bonded to a host that also has a free valence the bond order is raised (two sp² C → C=C), and the two
// planes are made coplanar.
// `Builder.click(.group(id), …)` routes here; element and fragment clicks are unchanged.

public enum BuildGroupKind: String, Sendable { case atom, group }

public struct BuildGroup: Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Short formula label for the picker (e.g. "–CH₃").
    public let label: String
    /// The element tile it is listed under.
    public let element: Int
    public let kind: BuildGroupKind
    public let hybridization: Hybridization?
    /// Order of the bond to the host atom.
    public let bondOrder: BondOrder
    public let fragment: Fragment
}

public enum GroupLibrary {
    public static let all: [BuildGroup] = GroupFactory.build()
    public static func group(id: String) -> BuildGroup? { all.first { $0.id == id } }
    public static func groups(forElement z: Int) -> [BuildGroup] { all.filter { $0.element == z } }
}

// MARK: - placement

public extension Builder {
    /// A Sketch click with a group payload (see the table at the top of this file).
    static func clickGroup(_ g: BuildGroup, on target: BuildTarget, in m: Molecule) throws -> Molecule {
        switch target {
        case .empty(let p):
            return place(g.fragment, in: m, at: p)
        case .atom(let i):
            guard m.atoms.indices.contains(i) else { throw BuildError.noSuchAtom }
            if m.atoms[i].atomicNumber == 1, let x = terminalHost(m, i) {
                return try attachGroup(g, to: m, host: x, replacingHydrogen: i)
            }
            if g.kind == .group, m.atoms[i].atomicNumber > 1, !hasAromatic(m, i), groupFreeValence(m, i) >= Int(g.bondOrder.rawValue) {
                return try attachGroup(g, to: m, host: i, replacingHydrogen: nil)
            }
            if g.kind == .atom { return try replaceAtom(i, in: m, withAtomGroup: g) }
            return try replaceAtom(i, in: m, with: g.fragment)
        }
    }

    /// Free valence of atom `i`: the smallest allowed valence that fits minus the bond-order sum.
    internal static func groupFreeValence(_ m: Molecule, _ i: Int) -> Int {
        Editing.openValence(m, i, shift: Editing.chargeShift(m))
    }

    /// Bond group `g` to `x`, replacing hydrogen `h` (or using a free valence of `x` when `h` is nil).
    static func attachGroup(_ g: BuildGroup, to m: Molecule, host x: Int, replacingHydrogen h: Int?) throws -> Molecule {
        let f = g.fragment, fm = f.molecule
        let k = Int(g.bondOrder.rawValue)
        let zx = m.atoms[x].atomicNumber, za = fm.atoms[f.anchor].atomicNumber
        let px = m.atoms[x].position
        let hint: Vec3? = h.map { bUnit(m.atoms[$0].position - px) }
        var remove = Set<Int>()
        if let h { remove.insert(h) }
        // Hydrogens on x other than h, nearest to the clicked one first.
        var hsX = m.buildNeighbors(of: x).filter { $0 != h && isTerminalH(m, $0) }
        if let hint { hsX.sort { simd_dot(bUnit(m.atoms[$0].position - px), hint) > simd_dot(bUnit(m.atoms[$1].position - px), hint) } }
        var tmp = m.buildRemovingAtoms(remove)
        let xt = x - remove.filter { $0 < x }.count
        var free = groupFreeValence(tmp, xt)
        if k > free {
            let need = k - free
            guard hsX.count >= need else {
                let bonds = Int(floor(tmp.buildBondOrderSum(xt) + 1e-6)) + k
                throw BuildError.valenceExceeded(symbol: BuildElements.symbol(zx), bonds: bonds, maximum: maximumValence(zx) ?? bonds - 1)
            }
            for j in hsX.prefix(need) { remove.insert(j) }
            hsX.removeFirst(need)
            tmp = m.buildRemovingAtoms(remove)
            free = groupFreeValence(tmp, x - remove.filter { $0 < x }.count)
        }
        guard free >= k else {
            throw BuildError.valenceExceeded(symbol: BuildElements.symbol(zx), bonds: Int(floor(tmp.buildBondOrderSum(xt) + 1e-6)) + k,
                                             maximum: maximumValence(zx) ?? 0)
        }
        let order: BondOrder = k == 3 ? .triple : (k == 2 ? .double : .single)

        // Direction of the new bond (and new positions for x's remaining hydrogens when x changes hybridization).
        var out = m
        var dir: Vec3
        if let hint, k == 1 {
            dir = hint
        } else {
            let bare = m.buildRemovingAtoms(remove.union(hsX))
            let xb = x - remove.union(hsX).filter { $0 < x }.count
            let otherDouble = bare.bonds.contains { ($0.a == xb || $0.b == xb) && $0.order == .double }
            let hyb: Hybridization = k == 3 || (k == 2 && otherDouble) ? .sp : (k == 2 ? .sp2 : {
                let hh = Editing.hybridization(bare, atom: xb); return hh == .none ? .sp3 : hh
            }())
            let dirs = Editing.newDirections(bare, atom: xb, count: hsX.count + 1, hyb: hyb)
            if dirs.count >= hsX.count + 1 {
                var best = 0
                if let hint { best = dirs.indices.max { simd_dot(dirs[$0], hint) < simd_dot(dirs[$1], hint) } ?? 0 }
                dir = dirs[best]
                let rest = dirs.indices.filter { $0 != best }.map { dirs[$0] }
                let lh = BuildElements.bondLength(zx, 1)
                for (j, hj) in hsX.enumerated() { out.atoms[hj].position = px + rest[j] * lh }
            } else {
                dir = hint ?? dirs.first ?? buildPerpendicular(Vec3(0, 0, 1))
            }
        }

        // Orient the template: anchor on the bond, anchor→leaving pointing back at x.
        let len = BuildElements.bondLength(zx, za, order: order)
        let target = px + dir * len
        let anchorPos = fm.atoms[f.anchor].position
        let q = rotationAligning(fm.atoms[f.leaving].position - anchorPos, to: -dir)
        var local = fm.atoms.map { target + q.act($0.position - anchorPos) }
        local = bestTorsion(local, about: dir, through: target, fragment: fm, anchor: f.anchor, leaving: f.leaving,
                            host: out, x: x, skip: remove, planar: order == .double)

        let off = out.atoms.count
        for (j, a) in fm.atoms.enumerated() { var na = a; na.id = off + j; na.position = local[j]; out.atoms.append(na) }
        for b in fm.bonds { out.bonds.append(Bond(b.a + off, b.b + off, order: b.order)) }
        out.buildSetBond(x, off + f.anchor, order)
        out.charge += fm.charge
        remove.insert(off + f.leaving)
        out = out.buildRemovingAtoms(remove)
        let nx = x - remove.filter { $0 < x }.count
        let na = off + f.anchor - remove.filter { $0 < off + f.anchor }.count
        let firstNew = off - remove.filter { $0 < off }.count

        // sp²/sp atom templates: pair up open valences across the new bond (C sp² + C sp² → C=C).
        if g.kind == .atom, order == .single, let hyb = g.hybridization, hyb == .sp2 || hyb == .sp {
            let up = min(groupFreeValence(out, na), groupFreeValence(out, nx), 2)
            if up > 0 {
                let newOrder: BondOrder = up >= 2 ? .triple : .double
                out.buildSetBond(nx, na, newOrder)
                // New bond length: slide the new atoms along the bond.
                let pnx = out.atoms[nx].position
                let axis = bUnit(out.atoms[na].position - pnx)
                let d = BuildElements.bondLength(zx, za, order: newOrder) - simd_distance(out.atoms[na].position, pnx)
                for j in firstNew..<out.atoms.count { out.atoms[j].position += axis * d }
                if newOrder == .double { alignPlanes(&out, host: nx, anchor: na, newFrom: firstNew) }
            }
        }
        return relaxClashes(out, newFrom: firstNew)
    }

    /// Turn atom `i` into the atom template's element, refilled with hydrogens in the template's hybridization.
    static func replaceAtom(_ i: Int, in m: Molecule, withAtomGroup g: BuildGroup) throws -> Molecule {
        let fm = g.fragment.molecule
        let z = fm.atoms[g.fragment.anchor].atomicNumber
        let templateH = fm.atoms.filter { $0.atomicNumber == 1 }.count
        let heavy = heavyBondOrderSum(m, i)
        try checkValence(z, heavyBondOrder: heavy, aromatic: hasAromatic(m, i))
        var out = m
        let a = Editing.stripTerminalH(&out, from: [i])[0]
        out.atoms[a].atomicNumber = z
        let count = max(0, templateH - Int(floor(heavy + 1e-6)))
        Editing.placeHydrogens(&out, atom: a, count: count, hyb: g.hybridization)
        return out
    }

    /// Choose the rotation of the placed template about the new bond: fewest contacts with the host and, for a
    /// double bond, the template's plane coplanar with the host's.
    internal static func bestTorsion(_ local: [Vec3], about axis: Vec3, through c: Vec3, fragment fm: Molecule, anchor: Int, leaving: Int,
                                     host m: Molecule, x: Int, skip: Set<Int>, planar: Bool) -> [Vec3] {
        let fragIdx = fm.atoms.indices.filter { $0 != leaving && $0 != anchor }
        let hostIdx = m.atoms.indices.filter { $0 != x && !skip.contains($0) }
        guard !fragIdx.isEmpty else { return local }
        let px = m.atoms[x].position
        // Host plane normal (x, the new bond, one other neighbour of x).
        var hostN: Vec3? = nil
        if planar, let o = m.buildNeighbors(of: x).first(where: { !skip.contains($0) }) {
            let n = simd_cross(axis, m.atoms[o].position - px)
            if simd_length(n) > 1e-6 { hostN = simd_normalize(n) }
        }
        let fragRef = fm.buildNeighbors(of: anchor).first { $0 != leaving }
        var best = (score: Double.infinity, angle: 0.0)
        for s in 0..<72 {
            let ang = Double(s) * 2 * .pi / 72
            let qq = simd_quatd(angle: ang, axis: axis)
            var score = 0.0
            for fi in fragIdx {
                let p = c + qq.act(local[fi] - c)
                for hi in hostIdx {
                    let d = max(simd_distance(p, m.atoms[hi].position), 0.3)
                    if d < 6 { let r = 1 / (d * d * d); score += r * r }
                }
            }
            if let hostN, let fr = fragRef {
                let n = simd_cross(axis, qq.act(local[fr] - c))
                if simd_length(n) > 1e-6 { let cs = simd_dot(simd_normalize(n), hostN); score += 50 * (1 - cs * cs) }
            }
            if score < best.score - 1e-9 { best = (score, ang) }
        }
        let qq = simd_quatd(angle: best.angle, axis: axis)
        return local.map { c + qq.act($0 - c) }
    }

    /// Rotate the atoms from `newFrom` about the host–anchor bond so the anchor's substituent plane matches the host's.
    internal static func alignPlanes(_ m: inout Molecule, host x: Int, anchor a: Int, newFrom: Int) {
        let px = m.atoms[x].position, pa = m.atoms[a].position
        let axis = bUnit(pa - px)
        guard let o = m.buildNeighbors(of: x).first(where: { $0 != a }),
              let r = m.buildNeighbors(of: a).first(where: { $0 != x }) else { return }
        func perpComp(_ v: Vec3) -> Vec3 { v - simd_dot(v, axis) * axis }
        let vo = perpComp(m.atoms[o].position - px), vr = perpComp(m.atoms[r].position - pa)
        guard simd_length(vo) > 1e-6, simd_length(vr) > 1e-6 else { return }
        // Angle that brings vr onto the line of vo (either side): pick the one with fewer clashes (trans to vo).
        let u = simd_normalize(vo), w = simd_normalize(vr)
        var ang = atan2(simd_dot(simd_cross(w, u), axis), simd_dot(w, u))     // vr → +vo
        ang += .pi                                                              // vr → −vo (substituent trans)
        let qq = simd_quatd(angle: ang, axis: axis)
        for j in newFrom..<m.atoms.count { m.atoms[j].position = pa + qq.act(m.atoms[j].position - pa) }
    }
}

// MARK: - templates

enum GroupFactory {
    static let tetra: [Vec3] = { let s = 1 / 3.0.squareRoot(); return [Vec3(1, 1, 1) * s, Vec3(1, -1, -1) * s, Vec3(-1, 1, -1) * s, Vec3(-1, -1, 1) * s] }()
    static let trigonal: [Vec3] = (0..<3).map { j in let a = Double(j) * 2 * .pi / 3; return Vec3(cos(a), sin(a), 0) }

    /// A single atom with `nH` hydrogens in the given geometry (lone pairs / open valences take the remaining slots).
    static func atomTemplate(_ id: String, _ z: Int, _ hyb: Hybridization, nH: Int) -> Fragment {
        var m = Molecule()
        m.buildAddAtom(z, at: .zero)
        let dirs: [Vec3] = hyb == .sp ? [Vec3(1, 0, 0), Vec3(-1, 0, 0)] : (hyb == .sp2 ? trigonal : tetra)
        let l = BuildElements.bondLength(z, 1)
        for d in dirs.prefix(nH) { let i = m.buildAddAtom(1, at: d * l); m.buildSetBond(0, i, .single) }
        let c = Editing.centroid(m)
        for i in m.atoms.indices { m.atoms[i].position -= c }
        m.title = id
        return Fragment(id: id, name: id, category: .groups, molecule: m, anchor: 0, leaving: m.atoms.count - 1)
    }

    /// Hydrogens for every open valence (sp² geometry for atoms in `sp2`, none for `noH`), leaving H on the anchor.
    static func finish(_ fb: FB, id: String, anchor: Int, sp2: Set<Int> = [], noH: Set<Int> = []) -> Fragment {
        var mol = fb.m
        let n0 = mol.atoms.count
        for i in 0..<n0 where !noH.contains(i) {
            let n = Editing.openValence(mol, i, shift: [:])
            if n > 0 { Editing.placeHydrogens(&mol, atom: i, count: n, hyb: sp2.contains(i) ? .sp2 : nil) }
        }
        let relaxed = Builder.relaxClashes(mol, newFrom: 0)
        if relaxed.atoms.count == mol.atoms.count { mol = relaxed }
        let c = Editing.centroid(mol)
        for i in mol.atoms.indices { mol.atoms[i].position -= c }
        mol.title = id
        let lv = mol.buildNeighbors(of: anchor).last { mol.atoms[$0].atomicNumber == 1 } ?? -1
        precondition(lv >= 0, "group \(id): anchor has no hydrogen")
        return Fragment(id: id, name: id, category: .groups, molecule: mol, anchor: anchor, leaving: lv)
    }

    static func build() -> [BuildGroup] {
        var out = [BuildGroup]()
        func atom(_ z: Int, _ hyb: Hybridization, nH: Int, _ name: String, _ label: String) {
            let id = "\(BuildElements.symbol(z)).\(hyb.rawValue)"
            out.append(BuildGroup(id: id, name: name, label: label, element: z, kind: .atom, hybridization: hyb, bondOrder: .single,
                                  fragment: atomTemplate(id, z, hyb, nH: nH)))
        }
        /// A group from the existing fragment library.
        func lib(_ z: Int, _ fragmentId: String, _ name: String, _ label: String) {
            guard let f = FragmentLibrary.fragment(id: fragmentId) else { return }
            out.append(BuildGroup(id: "\(BuildElements.symbol(z)).\(fragmentId)", name: name, label: label, element: z, kind: .group,
                                  hybridization: nil, bondOrder: .single, fragment: f))
        }
        func grp(_ z: Int, _ key: String, _ name: String, _ label: String, anchor: Int = 0, sp2: Set<Int> = [], noH: Set<Int> = [],
                 _ build: (inout FB) -> Void) {
            var fb = FB(); build(&fb)
            let id = "\(BuildElements.symbol(z)).\(key)"
            out.append(BuildGroup(id: id, name: name, label: label, element: z, kind: .group, hybridization: nil, bondOrder: .single,
                                  fragment: finish(fb, id: id, anchor: anchor, sp2: sp2, noH: noH)))
        }
        func multiple(_ z: Int, _ key: String, _ name: String, _ label: String, _ order: BondOrder, hyb: Hybridization, nH: Int) {
            let id = "\(BuildElements.symbol(z)).\(key)"
            out.append(BuildGroup(id: id, name: name, label: label, element: z, kind: .group, hybridization: hyb, bondOrder: order,
                                  fragment: atomTemplate(id, z, hyb, nH: nH)))
        }
        func ring(_ z: Int, _ key: String, _ name: String, _ label: String, subZ: Int) {
            var r = Ring2D(zs: Array(repeating: 6, count: 6), side: 1.40)
            let s = r.sub(0, z: subZ)
            var fb = FB(); fb.m = r.molecule()
            let id = "\(BuildElements.symbol(z)).\(key)"
            out.append(BuildGroup(id: id, name: name, label: label, element: z, kind: .group, hybridization: nil, bondOrder: .single,
                                  fragment: finish(fb, id: id, anchor: s)))
        }

        // Carbon
        atom(6, .sp3, nH: 4, "Carbon, tetrahedral (sp³)", "C sp³")
        atom(6, .sp2, nH: 3, "Carbon, trigonal (sp²)", "C sp²")
        atom(6, .sp, nH: 2, "Carbon, linear (sp)", "C sp")
        lib(6, "methyl", "Methyl", "–CH₃")
        lib(6, "ethyl", "Ethyl", "–C₂H₅")
        lib(6, "isopropyl", "Isopropyl", "–CH(CH₃)₂")
        lib(6, "tert-butyl", "tert-Butyl", "–C(CH₃)₃")
        lib(6, "vinyl", "Vinyl", "–CH=CH₂")
        lib(6, "ethynyl", "Ethynyl", "–C≡CH")
        lib(6, "phenyl", "Phenyl", "–C₆H₅")
        ring(6, "benzyl", "Benzyl", "–CH₂C₆H₅", subZ: 6)
        lib(6, "formyl", "Carbonyl: aldehyde (formyl)", "–CHO")
        lib(6, "acetyl", "Ketone (acetyl)", "–C(=O)CH₃")
        lib(6, "carboxyl", "Carboxylic acid", "–COOH")
        lib(6, "ester", "Methyl ester", "–COOCH₃")
        lib(6, "amide", "Carboxamide", "–C(=O)NH₂")
        lib(6, "cyano", "Nitrile (cyano)", "–C≡N")
        lib(6, "trifluoromethyl", "Trifluoromethyl", "–CF₃")
        multiple(6, "methylidene", "Methylidene (=CH₂)", "=CH₂", .double, hyb: .sp2, nH: 3)
        multiple(6, "methylidyne", "Methylidyne (≡CH)", "≡CH", .triple, hyb: .sp, nH: 2)

        // Nitrogen
        atom(7, .sp3, nH: 3, "Nitrogen, pyramidal (sp³)", "N sp³")
        atom(7, .sp2, nH: 2, "Nitrogen, trigonal (sp²)", "N sp²")
        atom(7, .sp, nH: 1, "Nitrogen, linear (sp)", "N sp")
        lib(7, "amino", "Amine", "–NH₂")
        grp(7, "methylamino", "Methylamine", "–NHCH₃") { let n = $0.add(7); $0.add(6, n) }
        grp(7, "dimethylamino", "Dimethylamine", "–N(CH₃)₂") { let n = $0.add(7); let c = $0.add(6, n); $0.add(6, n, b: c, angle: 111) }
        grp(7, "acetamido", "Amide (acetamido)", "–NHC(=O)CH₃", sp2: [0]) {
            let n = $0.add(7); let c = $0.add(6, n, angle: 121)
            let o = $0.add(8, c, .double, b: n, angle: 122)
            $0.add(6, c, b: n, c: o, angle: 115, dihedral: 180)
        }
        lib(7, "nitro", "Nitro", "–NO₂")
        lib(7, "cyano", "Nitrile (cyano)", "–C≡N")
        lib(7, "amide", "Amide (carboxamide)", "–C(=O)NH₂")
        grp(7, "azido", "Azide", "–N=N⁺=N⁻", noH: [1, 2]) {
            let n1 = $0.add(7); let n2 = $0.add(7, n1, .double, length: 1.24); $0.add(7, n2, .double, b: n1, angle: 180, length: 1.13)
        }
        grp(7, "imine", "Imine (–N=CH₂)", "–N=CH₂", sp2: [0, 1]) { let n = $0.add(7); $0.add(6, n, .double) }
        multiple(7, "imino", "Imino (=NH)", "=NH", .double, hyb: .sp2, nH: 2)
        multiple(7, "nitrile", "Nitrile N (≡N)", "≡N", .triple, hyb: .sp, nH: 1)

        // Oxygen
        atom(8, .sp3, nH: 2, "Oxygen, bent (sp³)", "O sp³")
        atom(8, .sp2, nH: 1, "Oxygen, sp² (one open valence)", "O sp²")
        lib(8, "hydroxyl", "Hydroxyl", "–OH")
        lib(8, "methoxy", "Methoxy (ether)", "–OCH₃")
        grp(8, "ethoxy", "Ethoxy", "–OC₂H₅") { let o = $0.add(8); let c = $0.add(6, o); $0.add(6, c, b: o, angle: 109.5) }
        ring(8, "phenoxy", "Phenoxy", "–OC₆H₅", subZ: 8)
        grp(8, "acetoxy", "Ester (acetoxy)", "–OC(=O)CH₃") {
            let o = $0.add(8); let c = $0.add(6, o)
            let o2 = $0.add(8, c, .double, b: o, angle: 123)
            $0.add(6, c, b: o2, c: o, angle: 125, dihedral: 180)
        }
        multiple(8, "carbonyl", "Carbonyl (=O)", "=O", .double, hyb: .sp2, nH: 1)

        // Sulfur
        atom(16, .sp3, nH: 2, "Sulfur, bent (sp³)", "S sp³")
        atom(16, .sp2, nH: 1, "Sulfur, sp² (one open valence)", "S sp²")
        lib(16, "thiol", "Thiol", "–SH")
        grp(16, "methylthio", "Methylthio (thioether)", "–SCH₃") { let s = $0.add(16); $0.add(6, s) }
        grp(16, "methylsulfonyl", "Methylsulfonyl", "–SO₂CH₃") {
            let s = $0.add(16); let c = $0.add(6, s)
            let o1 = $0.add(8, s, .double, b: c, angle: 108, length: 1.44)
            $0.add(8, s, .double, b: c, c: o1, angle: 108, dihedral: 120, length: 1.44)
        }
        grp(16, "sulfonamide", "Sulfonamide", "–SO₂NH₂") {
            let s = $0.add(16); let n = $0.add(7, s, length: 1.63)
            let o1 = $0.add(8, s, .double, b: n, angle: 107, length: 1.44)
            $0.add(8, s, .double, b: n, c: o1, angle: 107, dihedral: 120, length: 1.44)
        }
        grp(16, "sulfonic", "Sulfonic acid", "–SO₃H") {
            let s = $0.add(16); let o = $0.add(8, s, length: 1.58)
            let o1 = $0.add(8, s, .double, b: o, angle: 107, length: 1.44)
            $0.add(8, s, .double, b: o, c: o1, angle: 107, dihedral: 120, length: 1.44)
        }
        multiple(16, "thione", "Thione (=S)", "=S", .double, hyb: .sp2, nH: 1)

        // Phosphorus
        atom(15, .sp3, nH: 3, "Phosphorus, pyramidal (–PH₂)", "P sp³")
        grp(15, "dimethylphosphino", "Dimethylphosphine", "–P(CH₃)₂") { let p = $0.add(15); let c = $0.add(6, p); $0.add(6, p, b: c, angle: 100) }
        grp(15, "phosphonic", "Phosphonic acid", "–P(=O)(OH)₂") {
            let p = $0.add(15); let o = $0.add(8, p, .double, length: 1.48)
            let o2 = $0.add(8, p, b: o, angle: 112, length: 1.57)
            $0.add(8, p, b: o, c: o2, angle: 112, dihedral: 120, length: 1.57)
        }
        grp(15, "phosphate", "Phosphate", "–OP(=O)(OH)₂") {
            let o0 = $0.add(8); let p = $0.add(15, o0, angle: 120, length: 1.60)
            let o = $0.add(8, p, .double, b: o0, angle: 112, length: 1.48)
            $0.add(8, p, b: o0, c: o, angle: 106, dihedral: 120, length: 1.57)
            $0.add(8, p, b: o0, c: o, angle: 106, dihedral: -120, length: 1.57)
        }

        // Boron, silicon
        atom(5, .sp2, nH: 3, "Boron, trigonal (sp², –BH₂)", "B sp²")
        grp(5, "boronic", "Boronic acid", "–B(OH)₂", sp2: [0, 1, 2]) { let b = $0.add(5); let o = $0.add(8, b, length: 1.37); $0.add(8, b, b: o, angle: 120, length: 1.37) }
        atom(14, .sp3, nH: 4, "Silicon, tetrahedral (–SiH₃)", "Si sp³")
        grp(14, "trimethylsilyl", "Trimethylsilyl", "–Si(CH₃)₃") {
            let si = $0.add(14); let c1 = $0.add(6, si); let c2 = $0.add(6, si, b: c1, angle: 109.5)
            $0.add(6, si, b: c1, c: c2, angle: 109.5, dihedral: 120)
        }

        // Halogens
        lib(9, "trifluoromethyl", "Trifluoromethyl", "–CF₃")
        grp(17, "trichloromethyl", "Trichloromethyl", "–CCl₃") {
            let c = $0.add(6); let a = $0.add(17, c); let b = $0.add(17, c, b: a, angle: 109.5)
            $0.add(17, c, b: a, c: b, angle: 109.5, dihedral: 120)
        }
        grp(17, "acylchloride", "Acyl chloride", "–C(=O)Cl") { let c = $0.add(6); let o = $0.add(8, c, .double); $0.add(17, c, b: o, angle: 120) }
        grp(9, "fluoromethyl", "Fluoromethyl", "–CH₂F") { let c = $0.add(6); $0.add(9, c) }
        grp(17, "chloromethyl", "Chloromethyl", "–CH₂Cl") { let c = $0.add(6); $0.add(17, c) }
        grp(35, "bromomethyl", "Bromomethyl", "–CH₂Br") { let c = $0.add(6); $0.add(35, c) }
        grp(53, "iodomethyl", "Iodomethyl", "–CH₂I") { let c = $0.add(6); $0.add(53, c) }
        return out
    }
}
