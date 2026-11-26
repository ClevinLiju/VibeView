import Foundation
import simd
import MolCore

// Click-to-build semantics (round 3, Lead C).
//
// What a click with the Sketch tool does depends on what is under the cursor:
//
// | Clicked on      | Element payload (Z)                            | Fragment payload                                   |
// |-----------------|------------------------------------------------|----------------------------------------------------|
// | empty space     | a new free atom, filled with hydrogens          | a free copy of the fragment, centred on the point  |
// | a hydrogen      | the H becomes Z (bonded to the same host), +H   | the H is replaced by the fragment (substituent)    |
// | a heavy atom    | that atom BECOMES Z (replace in place)          | that atom is REPLACED by the fragment's attachment |
//
// Replacing a heavy atom X keeps X's position and all of its bonds to non-hydrogen neighbours (with their bond
// orders); X's own hydrogens are removed and the new atom is refilled with hydrogens up to its normal valence.
// For a fragment, the attachment atom is the atom that would bond to a host in substituent mode (`Fragment.anchor`);
// it takes X's place, inherits X's heavy-atom bonds, and the rest of the fragment points away from X's
// neighbours (along X's former hydrogen direction), with a torsion chosen to avoid clashes. The attachment atom's
// hydrogens are recomputed for its new bonds.
//
// Examples (all checked in `build.place.*`):
// - benzene, NH2 (amino) fragment or N element on a ring carbon → that carbon becomes a pyridine-type N: C5H5N.
// - methane, OH (hydroxyl) fragment on the carbon → C is replaced by O, refilled to valence 2: H2O (water).
//   (Clicking one of methane's hydrogens instead gives methanol, CH4O.)
// - ethane, phenyl fragment on a carbon → that carbon becomes the ipso carbon of a phenyl ring: toluene, C7H8.
// - A replacement that would exceed the new atom's maximum valence (e.g. O into an aromatic ring, or a ring
//   fragment onto an aromatic ring carbon) is refused with `BuildError.valenceExceeded`.
// - Clicking a heavy atom with its own element changes nothing (Option-click in the app grows a new atom instead).

public enum BuildError: Error, LocalizedError, Equatable, Sendable {
    case noSuchAtom
    case valenceExceeded(symbol: String, bonds: Int, maximum: Int)
    case sameAtom
    case alreadyBonded
    case hydrogenAlreadyBonded
    case unknownFragment(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchAtom: "There is no atom there."
        case let .valenceExceeded(s, b, mx): "\(s) can't take \(b) bonds (at most \(mx))."
        case .sameAtom: "Pick two different atoms."
        case .alreadyBonded: "These atoms are already bonded with that order."
        case .hydrogenAlreadyBonded: "That hydrogen already has a bond. Click the hydrogen with a fragment to replace it instead."
        case .unknownFragment(let id): "Unknown fragment “\(id)”."
        }
    }
}

/// What the Sketch tool places.
public enum BuildItem: Equatable, Sendable {
    case element(Int)
    case fragment(String)    // FragmentLibrary id
    case group(String)       // GroupLibrary id (element picker: hybridized atoms and functional groups)
}

/// What was clicked.
public enum BuildTarget: Equatable, Sendable {
    case empty(Vec3)
    case atom(Int)
}

public extension Builder {
    /// The single entry point for a Sketch click: see the table at the top of this file.
    static func click(_ item: BuildItem, on target: BuildTarget, in m: Molecule) throws -> Molecule {
        if case .group(let id) = item {
            guard let g = GroupLibrary.group(id: id) else { throw BuildError.unknownFragment(id) }
            return try clickGroup(g, on: target, in: m)
        }
        switch (item, target) {
        case let (.element(z), .empty(p)):
            return placeElement(z, in: m, at: p, addHydrogens: true)
        case let (.fragment(id), .empty(p)):
            guard let f = FragmentLibrary.fragment(id: id) else { throw BuildError.unknownFragment(id) }
            return place(f, in: m, at: p)
        case let (.group(id), .empty): throw BuildError.unknownFragment(id)   // handled above
        case let (_, .atom(i)):
            guard m.atoms.indices.contains(i) else { throw BuildError.noSuchAtom }
            if m.atoms[i].atomicNumber == 1, terminalHost(m, i) != nil {
                switch item {
                case .element(let z):
                    if let r = attachElement(z, to: m, replacingHydrogen: i, addHydrogens: true) { return r }
                case .fragment(let id):
                    guard let f = FragmentLibrary.fragment(id: id) else { throw BuildError.unknownFragment(id) }
                    if let r = attach(f, to: m, replacingHydrogen: i) { return r }
                case .group: break   // handled above
                }
                throw BuildError.noSuchAtom
            }
            switch item {
            case .element(let z): return try replaceAtom(i, in: m, withElement: z)
            case .fragment(let id):
                guard let f = FragmentLibrary.fragment(id: id) else { throw BuildError.unknownFragment(id) }
                return try replaceAtom(i, in: m, with: f)
            case .group(let id): throw BuildError.unknownFragment(id)   // handled above
            }
        }
    }

    /// Turn heavy atom `i` (or a free H) into element `z` in place: position and heavy-atom bonds are kept,
    /// hydrogens are refilled to the new valence.
    static func replaceAtom(_ i: Int, in m: Molecule, withElement z: Int) throws -> Molecule {
        guard m.atoms.indices.contains(i) else { throw BuildError.noSuchAtom }
        if m.atoms[i].atomicNumber == z { return m }
        try checkValence(z, heavyBondOrder: heavyBondOrderSum(m, i), aromatic: hasAromatic(m, i))
        var out = m
        let a = Editing.stripTerminalH(&out, from: [i])[0]
        out.atoms[a].atomicNumber = z
        if z > 1 { Editing.addHydrogens(&out, atoms: [a]) }
        return out
    }

    /// Replace heavy atom `i` with fragment `f`, the fragment's attachment atom taking `i`'s place and bonds.
    static func replaceAtom(_ i: Int, in m: Molecule, with f: Fragment) throws -> Molecule {
        guard m.atoms.indices.contains(i) else { throw BuildError.noSuchAtom }
        let fm = f.molecule
        let anchorZ = fm.atoms[f.anchor].atomicNumber
        let hostOrders = m.buildNeighbors(of: i).filter { !isTerminalH(m, $0) }
            .map { ($0, m.buildBond(i, $0)?.order ?? .single) }
        let fragHeavy = fm.buildNeighbors(of: f.anchor).filter { fm.atoms[$0].atomicNumber > 1 }
        let fragOrder = fragHeavy.reduce(0.0) { $0 + (fm.buildBond(f.anchor, $1)?.order.rawValue ?? 1) }
        let total = fragOrder + hostOrders.reduce(0.0) { $0 + $1.1.rawValue }
        let aromatic = hostOrders.contains { $0.1 == .aromatic } || fragHeavy.contains { fm.buildBond(f.anchor, $0)?.order == .aromatic }
        try checkValence(anchorZ, heavyBondOrder: total, aromatic: aromatic)

        // Direction in which the fragment body should point: along X's hydrogens, else away from its neighbours.
        let px = m.atoms[i].position
        let hs = m.buildNeighbors(of: i).filter { isTerminalH(m, $0) }
        var out = bUnit(hs.reduce(Vec3.zero) { $0 + bUnit(m.atoms[$1].position - px) })
        if hs.isEmpty {
            let s = hostOrders.reduce(Vec3.zero) { $0 + bUnit(m.atoms[$1.0].position - px) }
            out = simd_length(s) > 1e-6 ? -simd_normalize(s)
                : (hostOrders.isEmpty ? Vec3(1, 0, 0) : buildPerpendicular(m.atoms[hostOrders[0].0].position - px))
        }
        // Orient: the anchor→leaving vector (which points at a host in substituent mode) points back at X's neighbours.
        let anchorPos = fm.atoms[f.anchor].position
        let q = rotationAligning(fm.atoms[f.leaving].position - anchorPos, to: -out)
        var local = fm.atoms.map { px + q.act($0.position - anchorPos) }
        // Torsion about `out` that keeps the fragment away from the host.
        let fragIdx = fm.atoms.indices.filter { $0 != f.leaving && $0 != f.anchor }
        let hostIdx = m.atoms.indices.filter { $0 != i && !hs.contains($0) }
        if !fragIdx.isEmpty && !hostIdx.isEmpty {
            var best = (score: Double.infinity, angle: 0.0)
            for s in 0..<72 {
                let ang = Double(s) * 2 * .pi / 72
                let qq = simd_quatd(angle: ang, axis: out)
                var score = 0.0
                for fi in fragIdx {
                    let p = px + qq.act(local[fi] - px)
                    for hi in hostIdx {
                        let d = max(simd_distance(p, m.atoms[hi].position), 0.3)
                        if d < 6 { let r = 1 / (d * d * d); score += r * r }
                    }
                }
                if score < best.score - 1e-9 { best = (score, ang) }
            }
            let qq = simd_quatd(angle: best.angle, axis: out)
            local = local.map { px + qq.act($0 - px) }
        }

        var r = m
        let off = r.atoms.count
        for (k, a) in fm.atoms.enumerated() { var na = a; na.id = off + k; na.position = local[k]; r.atoms.append(na) }
        for b in fm.bonds { r.bonds.append(Bond(b.a + off, b.b + off, order: b.order)) }
        for (n, order) in hostOrders { r.buildSetBond(n, off + f.anchor, order) }
        r.charge += fm.charge
        var remove = Set(hs).union([i, off + f.leaving])
        for n in fm.buildNeighbors(of: f.anchor) where n != f.leaving && fm.atoms[n].atomicNumber == 1 && fm.buildNeighbors(of: n).count == 1 {
            remove.insert(off + n)     // the anchor's hydrogens are recomputed below
        }
        r = r.buildRemovingAtoms(remove)
        let newAnchor = off + f.anchor - remove.filter { $0 < off + f.anchor }.count
        Editing.addHydrogens(&r, atoms: [newAnchor])
        let firstNew = off - remove.filter { $0 < off }.count
        return relaxClashes(r, newFrom: firstNew)
    }

    // MARK: helpers

    internal static func isTerminalH(_ m: Molecule, _ j: Int) -> Bool {
        m.atoms[j].atomicNumber == 1 && m.buildNeighbors(of: j).count == 1
    }

    /// Bond-order sum of atom `i` to everything except its terminal hydrogens.
    internal static func heavyBondOrderSum(_ m: Molecule, _ i: Int) -> Double {
        m.buildNeighbors(of: i).filter { !isTerminalH(m, $0) }.reduce(0) { $0 + (m.buildBond(i, $1)?.order.rawValue ?? 1) }
    }

    internal static func hasAromatic(_ m: Molecule, _ i: Int) -> Bool {
        m.bonds.contains { ($0.a == i || $0.b == i) && $0.order == .aromatic }
    }

    /// Maximum valence used for build refusals (nil = no limit, e.g. metals).
    public static func maximumValence(_ z: Int) -> Int? {
        let v = Editing.allowedValences(z)
        return v.max()
    }

    internal static func checkValence(_ z: Int, heavyBondOrder: Double, aromatic: Bool) throws {
        guard let mx = maximumValence(z), z > 1 || heavyBondOrder > 0 else { return }
        // Aromatic bonds count 1.5; a pyridine-type N (two aromatic bonds = 3) is fine, so round down the half bonds.
        let bonds = aromatic ? Int(floor(heavyBondOrder + 1e-6)) : Int((heavyBondOrder).rounded())
        // Oxygen-group atoms only enter aromatic rings as 2-coordinate (furan/thiophene-type); in a 6-ring with
        // three aromatic bond-orders they'd need 3 bonds.
        if bonds > mx { throw BuildError.valenceExceeded(symbol: BuildElements.symbol(z), bonds: bonds, maximum: mx) }
    }
}

// MARK: - Bond tool

public extension Editing {
    /// Create (or re-order) a bond between any two atoms, including atoms in separate fragments.
    /// Hydrogens on both ends are adjusted to the new valence. When the atoms were in different fragments, the
    /// smaller fragment is moved along the new bond so that it has its ideal length.
    static func connect(_ m: Molecule, _ a: Int, _ b: Int, order: BondOrder = .single) throws -> Molecule {
        guard m.atoms.indices.contains(a), m.atoms.indices.contains(b) else { throw BuildError.noSuchAtom }
        guard a != b else { throw BuildError.sameAtom }
        if let existing = m.buildBond(a, b), existing.order == order { throw BuildError.alreadyBonded }
        let already = m.buildBond(a, b) != nil
        for x in [a, b] where m.atoms[x].atomicNumber == 1 {
            if !already && !m.buildNeighbors(of: x).isEmpty { throw BuildError.hydrogenAlreadyBonded }
        }
        let effOrder: BondOrder = (m.atoms[a].atomicNumber == 1 || m.atoms[b].atomicNumber == 1) ? .single : order
        for (x, y) in [(a, b), (b, a)] where m.atoms[x].atomicNumber > 1 {
            let others = m.buildNeighbors(of: x).filter { $0 != y && !Builder.isTerminalH(m, $0) }
            let sum = others.reduce(0.0) { $0 + (m.buildBond(x, $1)?.order.rawValue ?? 1) } + effOrder.rawValue
            try Builder.checkValence(m.atoms[x].atomicNumber, heavyBondOrder: sum, aromatic: Builder.hasAromatic(m, x))
        }
        var out = m
        let separate = !Editing.reachable(m, from: a, to: b, without: (-1, -1))
        if separate {
            // Move the smaller fragment so the new bond gets its ideal length before hydrogens are rebuilt.
            let fa = fragmentAtoms(m, a), fb = fragmentAtoms(m, b)
            let (fixed, moving, movingSet) = fa.count >= fb.count ? (a, b, fb) : (b, a, fa)
            let pf = out.atoms[fixed].position, pm = out.atoms[moving].position
            let ideal = BuildElements.bondLength(m.atoms[a].atomicNumber, m.atoms[b].atomicNumber, order: effOrder)
            let v = pm - pf
            let dir = simd_length(v) < 1e-9 ? Vec3(1, 0, 0) : simd_normalize(v)
            let delta = pf + dir * ideal - pm
            for i in movingSet { out.atoms[i].position += delta }
        }
        if out.atoms[a].atomicNumber == 1 || out.atoms[b].atomicNumber == 1 {
            out.buildSetBond(a, b, .single)
            return out
        }
        Editing.setBondOrder(&out, a, b, effOrder, adjustHydrogens: true)
        return out
    }

    /// Delete the bond between `a` and `b`; hydrogens on both ends are refilled.
    static func disconnect(_ m: Molecule, _ a: Int, _ b: Int) throws -> Molecule {
        guard m.atoms.indices.contains(a), m.atoms.indices.contains(b), m.buildBond(a, b) != nil else { throw BuildError.noSuchAtom }
        var out = m
        Editing.setBondOrder(&out, a, b, nil, adjustHydrogens: true)
        return out
    }

    /// Atom indices of the connected fragment containing `i`.
    static func fragmentAtoms(_ m: Molecule, _ i: Int) -> Set<Int> {
        var seen: Set<Int> = [i]; var stack = [i]
        while let x = stack.popLast() { for n in m.buildNeighbors(of: x) where seen.insert(n).inserted { stack.append(n) } }
        return seen
    }
}

// MARK: - Measurement edits that move the smaller side

public extension GeometryEdit {
    /// Size of the side that would move; a ring (where `movingSide` falls back to the single atom) counts as
    /// immovable so the edit moves the other, acyclic side instead of distorting the ring.
    private static func sideCost(_ m: Molecule, fixed a: Int, moving b: Int) -> Int {
        let s = movingSide(m, fixed: a, moving: b)
        if s.count == 1 && m.buildNeighbors(of: b).count > 1 { return Int.max }
        return s.count
    }
    /// Set a distance, moving whichever end's side has fewer atoms.
    static func setDistanceMovingSmaller(_ m: inout Molecule, _ a: Int, _ b: Int, to d: Double) {
        if sideCost(m, fixed: b, moving: a) < sideCost(m, fixed: a, moving: b) { setDistance(&m, b, a, to: d) }
        else { setDistance(&m, a, b, to: d) }
    }
    /// Set an angle a–b–c, rotating whichever end's side has fewer atoms.
    static func setAngleMovingSmaller(_ m: inout Molecule, _ a: Int, _ b: Int, _ c: Int, to deg: Double) {
        if sideCost(m, fixed: b, moving: a) < sideCost(m, fixed: b, moving: c) { setAngle(&m, c, b, a, to: deg) }
        else { setAngle(&m, a, b, c, to: deg) }
    }
    /// Set a dihedral a–b–c–d, rotating whichever end's side has fewer atoms.
    static func setDihedralMovingSmaller(_ m: inout Molecule, _ a: Int, _ b: Int, _ c: Int, _ d: Int, to deg: Double) {
        if sideCost(m, fixed: b, moving: a) < sideCost(m, fixed: c, moving: d) { setDihedral(&m, d, c, b, a, to: deg) }
        else { setDihedral(&m, a, b, c, d, to: deg) }
    }
}
