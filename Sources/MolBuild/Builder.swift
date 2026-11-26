import Foundation
import MolSIMD
import MolCore

// Attach / place operations (Worker A, Lead 4).

public enum Builder {
    static func rotationAligning(_ a: Vec3, to b: Vec3) -> simd_quatd {
        let u = bUnit(a), v = bUnit(b)
        let d = simd_dot(u, v)
        if d > 1 - 1e-12 { return simd_quatd(angle: 0, axis: Vec3(0, 0, 1)) }
        if d < -1 + 1e-12 { return simd_quatd(angle: .pi, axis: buildPerpendicular(u)) }
        return simd_quatd(angle: acos(d), axis: simd_normalize(simd_cross(u, v)))
    }

    static func terminalHost(_ m: Molecule, _ h: Int) -> Int? {
        guard h >= 0, h < m.atoms.count, m.atoms[h].atomicNumber == 1 else { return nil }
        let nb = m.buildNeighbors(of: h)
        return nb.count == 1 ? nb[0] : nil
    }

    public static func attach(_ f: Fragment, to m: Molecule, replacingHydrogen h: Int) -> Molecule? {
        guard let x = terminalHost(m, h) else { return nil }
        let fm = f.molecule
        let px = m.atoms[x].position
        let dir = bUnit(m.atoms[h].position - px)
        let len = BuildElements.bondLength(m.atoms[x].atomicNumber, fm.atoms[f.anchor].atomicNumber)
        let target = px + dir * len
        let anchorPos = fm.atoms[f.anchor].position
        let q = rotationAligning(fm.atoms[f.leaving].position - anchorPos, to: -dir)
        var local = fm.atoms.map { target + q.act($0.position - anchorPos) }
        let fragIdx = fm.atoms.indices.filter { $0 != f.leaving && $0 != f.anchor }
        let hostIdx = m.atoms.indices.filter { $0 != h && $0 != x }
        var bestScore = Double.infinity
        var bestAngle = 0.0
        let steps = 72
        for s in 0..<steps {
            let ang = Double(s) * 2 * .pi / Double(steps)
            let qq = simd_quatd(angle: ang, axis: dir)
            var score = 0.0
            for fi in fragIdx {
                let p = target + qq.act(local[fi] - target)
                for hi in hostIdx {
                    let d = max(simd_distance(p, m.atoms[hi].position), 0.3)
                    if d < 6 { let r = 1 / (d * d * d); score += r * r }
                }
            }
            if score < bestScore - 1e-9 { bestScore = score; bestAngle = ang }
        }
        let qq = simd_quatd(angle: bestAngle, axis: dir)
        local = local.map { target + qq.act($0 - target) }
        var out = m
        let off = out.atoms.count
        for (i, a) in fm.atoms.enumerated() {
            var na = a; na.id = off + i; na.position = local[i]; out.atoms.append(na)
        }
        for b in fm.bonds { out.bonds.append(Bond(b.a + off, b.b + off, order: b.order)) }
        out.buildSetBond(x, off + f.anchor, .single)
        out.charge += fm.charge
        out = out.buildRemovingAtoms([h, off + f.leaving])
        return relaxClashes(out, newFrom: off - 1)
    }

    /// If the joined structure has atoms closer than 0.9 Å, relax only the new atoms (indices ≥ `newFrom`).
    static func relaxClashes(_ m: Molecule, newFrom: Int) -> Molecule {
        let n = m.atoms.count
        var clash = false
        outer: for i in 0..<n { for j in (i + 1)..<max(n, i + 1) where simd_distance(m.atoms[i].position, m.atoms[j].position) < 0.9 { clash = true; break outer } }
        guard clash, newFrom >= 0, newFrom < n else { return m }
        let frozen = Set(0..<newFrom)
        return Cleanup.minimize(m, frozen: frozen, maxSteps: 300).molecule
    }

    public static func place(_ f: Fragment, in m: Molecule, at p: Vec3) -> Molecule {
        var frag = f.molecule
        let c = Editing.centroid(frag)
        for i in frag.atoms.indices { frag.atoms[i].position += p - c }
        var out = m
        out.buildAppend(frag)
        out.charge += frag.charge
        return out
    }

    public static func attachElement(_ z: Int, to m: Molecule, replacingHydrogen h: Int, addHydrogens: Bool = true) -> Molecule? {
        guard let x = terminalHost(m, h) else { return nil }
        var out = m
        let px = out.atoms[x].position
        let dir = bUnit(out.atoms[h].position - px)
        out.atoms[h].atomicNumber = z
        out.atoms[h].position = px + dir * BuildElements.bondLength(out.atoms[x].atomicNumber, z)
        if addHydrogens && z > 1 { Editing.addHydrogens(&out, atoms: [h]) }
        return out
    }

    public static func bondElement(_ z: Int, to m: Molecule, atom: Int, addHydrogens: Bool = true) -> Molecule? {
        guard atom >= 0, atom < m.atoms.count else { return nil }
        let shift = Editing.chargeShift(m)
        let open = Editing.openValence(m, atom, shift: shift)
        if open <= 0 {
            // saturated: grow from one of its terminal hydrogens instead
            if let h = m.buildNeighbors(of: atom).first(where: { m.atoms[$0].atomicNumber == 1 && m.buildNeighbors(of: $0).count == 1 }) {
                return attachElement(z, to: m, replacingHydrogen: h, addHydrogens: addHydrogens)
            }
            return nil
        }
        var out = m
        let hyb = Editing.hybridization(out, atom: atom)
        let dirs = Editing.newDirections(out, atom: atom, count: 1, hyb: hyb == .none ? .sp3 : hyb)
        guard let d = dirs.first else { return nil }
        let idx = out.buildAddAtom(z, at: out.atoms[atom].position + d * BuildElements.bondLength(out.atoms[atom].atomicNumber, z))
        out.buildSetBond(atom, idx, .single)
        if addHydrogens && z > 1 { Editing.addHydrogens(&out, atoms: [idx]) }
        return out
    }

    public static func placeElement(_ z: Int, in m: Molecule, at p: Vec3, addHydrogens: Bool = true) -> Molecule {
        var out = m
        let idx = out.buildAddAtom(z, at: p)
        if addHydrogens && z > 1 { Editing.addHydrogens(&out, atoms: [idx]) }
        return out
    }
}
