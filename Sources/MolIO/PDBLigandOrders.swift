import Foundation
import MolCore
import MolSIMD

/// Bond orders for ligands and other non-standard residues of PDB files (HETATM groups, modified residues).
///
/// PDB/RCSB files list ligand connectivity in CONECT records but almost never the bond orders, and they rarely
/// contain hydrogens. Plain valence-based perception would then make every heavy atom unsaturated, so each residue
/// is first given implicit hydrogens from its geometry: the hybridization of each heavy atom comes from its bond
/// angles (mean > 155° sp, > 115° sp2, else sp3; atoms of planar five-membered rings count as sp2) and, for terminal
/// atoms, from the bond length relative to the single-bond covalent radii (< 0.83 triple-capable, < 0.95
/// double-capable). Each atom is then filled up with dummy hydrogens to its normal valence minus its pi capacity,
/// bonds to atoms outside the residue are kept as single-bonded substituents, metal bonds are ignored (heme N–Fe), and
/// `Molecule.perceiveBondOrders` (maximum matching + aromaticity) assigns the orders. Residues whose bonds already have
/// stated multiple orders (CONECT multiplicity) are left untouched; residues with explicit hydrogens are perceived
/// directly. Missing intra-residue bonds are perceived from distances first.
public enum PDBLigandBondOrders {
    static let organic: Set<Int> = [1, 5, 6, 7, 8, 9, 14, 15, 16, 17, 34, 35, 53]
    static let waterNames: Set<String> = ["HOH", "WAT", "DOD", "H2O", "SOL", "TIP", "TIP3", "TP3", "SPC"]

    static func baseValence(_ z: Int) -> Int {
        switch z {
        case 6, 14: return 4
        case 7, 15, 5: return 3
        case 8, 16, 34: return 2
        default: return 1
        }
    }

    /// True for records that are perceived here (not a standard amino acid ATOM record, not water).
    public static func isLigandRecord(_ r: PDBAtomRecord) -> Bool {
        let name = r.resName.uppercased()
        if waterNames.contains(name) { return false }
        return r.isHetero || !PDBResidueBondOrders.standardResidues.contains(name)
    }

    /// Perceives bond orders residue by residue. Returns the number of residues whose orders were assigned.
    @discardableResult
    public static func apply(to m: inout Molecule, records: [PDBAtomRecord]) -> Int {
        guard records.count == m.atoms.count, !m.atoms.isEmpty else { return 0 }
        struct Key: Hashable { var chain: String, seq: Int, icode: String, name: String }
        var groups: [Key: [Int]] = [:], order: [Key] = []
        for (i, r) in records.enumerated() where isLigandRecord(r) {
            let k = Key(chain: r.chainID, seq: r.resSeq, icode: r.iCode, name: r.resName)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        guard !order.isEmpty else { return 0 }
        let zs = m.atoms.map { $0.atomicNumber }
        var bondsOf = [[Int]](repeating: [], count: m.atoms.count)
        for (k, b) in m.bonds.enumerated() where b.a < m.atoms.count && b.b < m.atoms.count {
            bondsOf[b.a].append(k); bondsOf[b.b].append(k)
        }
        var count = 0
        for key in order {
            guard let atoms = groups[key], atoms.count >= 2, atoms.count <= 600 else { continue }
            if perceive(&m, atoms: atoms, zs: zs, bondsOf: &bondsOf) { count += 1 }
        }
        return count
    }

    private static func perceive(_ m: inout Molecule, atoms: [Int], zs: [Int], bondsOf: inout [[Int]]) -> Bool {
        // (zs: atomic numbers of m, computed once by the caller)
        func z(_ i: Int) -> Int { zs[i] }
        let inRes = Set(atoms)
        let heavyOrganic = atoms.filter { z($0) > 1 && organic.contains(z($0)) }
        guard heavyOrganic.count >= 2 else { return false }
        // Stated orders win.
        for i in atoms { for k in bondsOf[i] where inRes.contains(m.bonds[k].a) && inRes.contains(m.bonds[k].b) {
            if m.bonds[k].order != .single { return false }
        } }
        // Missing intra-residue bonds (no CONECT): perceive them from distances.
        if heavyOrganic.contains(where: { i in !bondsOf[i].contains { inRes.contains(m.bonds[$0].a) && inRes.contains(m.bonds[$0].b) } }) {
            let sub = Molecule(atoms: atoms.enumerated().map { (k, i) in Atom(id: k, atomicNumber: z(i), position: m.atoms[i].position) })
            for b in sub.perceivedBonds() {
                let a = atoms[b.a], c = atoms[b.b]
                if m.bond(between: a, and: c) != nil { continue }
                m.bonds.append(Bond(a, c))
                bondsOf[a].append(m.bonds.count - 1); bondsOf[c].append(m.bonds.count - 1)
            }
        }

        // Sub-molecule: the residue's organic atoms, external organic neighbours as dummy H substituents.
        let members = atoms.filter { organic.contains(z($0)) }
        var local: [Int: Int] = [:]
        var sub = Molecule()
        for i in members { local[i] = sub.atoms.count; sub.atoms.append(Atom(id: sub.atoms.count, atomicNumber: z(i), position: m.atoms[i].position)) }
        var subBond: [Int: Int] = [:]   // molecule bond index -> sub bond index
        var neighbours = [[Vec3]](repeating: [], count: sub.atoms.count)
        for i in members {
            for k in bondsOf[i] {
                let b = m.bonds[k]
                let j = b.a == i ? b.b : b.a
                guard organic.contains(z(j)) else { continue }   // metal bonds are ignored
                let li = local[i]!
                if let lj = local[j] {
                    neighbours[li].append(m.atoms[j].position)
                    if li < lj { subBond[k] = sub.bonds.count; sub.bonds.append(Bond(li, lj)) }
                } else {
                    neighbours[li].append(m.atoms[j].position)
                    let h = sub.atoms.count
                    sub.atoms.append(Atom(id: h, atomicNumber: 1, position: m.atoms[j].position))
                    sub.bonds.append(Bond(li, h))
                }
            }
        }
        guard !subBond.isEmpty else { return false }
        let hasH = members.contains { z($0) == 1 }
        if !hasH {
            let n0 = members.count
            // Planar five-membered rings: their atoms may be sp2 although their angles are ~108°.
            var planar5 = Set<Int>()
            for ring in sub.smallestSetOfSmallestRings() where ring.count == 5 && ring.allSatisfy({ $0 < n0 }) {
                if isPlanar(ring.map { sub.atoms[$0].position }) { planar5.formUnion(ring) }
            }
            var added: [(Int, Int)] = []
            for li in 0..<n0 {
                let zi = sub.atoms[li].atomicNumber
                let v = baseValence(zi)
                let nb = neighbours[li]
                let d = nb.count
                if d >= v || d == 0 { continue }
                let p0 = sub.atoms[li].position
                var p: Int
                if d >= 2 {
                    var sum = 0.0, cnt = 0.0
                    for a in 0..<d { for b in (a + 1)..<d {
                        let u = nb[a] - p0, w = nb[b] - p0
                        let c = simd_dot(u, w) / max(1e-9, simd_length(u) * simd_length(w))
                        sum += acos(max(-1, min(1, c))) * 180 / .pi; cnt += 1
                    } }
                    let mean = sum / cnt
                    p = mean > 155 ? 2 : (mean > 115 ? 1 : 0)
                    if planar5.contains(li) { p = max(p, 1) }
                } else {
                    // Terminal atom: bond length against the single-bond covalent radii.
                    let j = sub.bonds.first { $0.a == li || $0.b == li }.map { $0.a == li ? $0.b : $0.a }
                    let zj = j.map { sub.atoms[$0].atomicNumber } ?? 6
                    let rs = Elements.element(zi).covalentRadius + Elements.element(zj).covalentRadius
                    let ratio = rs > 0 ? simd_length(nb[0] - p0) / rs : 1
                    p = ratio < 0.83 ? 2 : (ratio < 0.95 ? 1 : 0)
                }
                p = min(p, v - d)
                let hs = v - d - p
                for _ in 0..<max(0, hs) { added.append((li, hs)) }
            }
            for (li, _) in added {
                let h = sub.atoms.count
                // Dummy hydrogen 1 Å away, off any real direction (geometry only matters for the matching heuristics).
                sub.atoms.append(Atom(id: h, atomicNumber: 1, position: sub.atoms[li].position + Vec3(0.0, 0.0, 1.0)))
                sub.bonds.append(Bond(li, h))
            }
        }
        sub.perceiveBondOrders()
        for (k, sk) in subBond { m.bonds[k].order = sub.bonds[sk].order }
        return true
    }

    static func isPlanar(_ p: [Vec3]) -> Bool {
        guard p.count >= 4 else { return true }
        var c = Vec3(0, 0, 0)
        for q in p { c += q }
        c /= Double(p.count)
        // Normal from the first two non-parallel spokes; max deviation from that plane.
        let n = simd_cross(p[0] - c, p[1] - c) + simd_cross(p[1] - c, p[2] - c) + simd_cross(p[2] - c, p[3] - c)
        let len = simd_length(n)
        guard len > 1e-6 else { return false }
        let u = n / len
        return p.allSatisfy { abs(simd_dot($0 - c, u)) < 0.15 }
    }
}

extension PDBFile {
    /// `withResidueBondOrders()` plus ligand/non-standard residue perception (used by `MolecularFileLoader`).
    public func withPerceivedBondOrders() -> PDBFile {
        var f = withResidueBondOrders()
        for i in f.models.indices where i < f.atomRecords.count {
            PDBLigandBondOrders.apply(to: &f.models[i], records: f.atomRecords[i])
        }
        return f
    }
}
