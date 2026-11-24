import Foundation
import MolCore

/// Display bond orders for standard amino-acid residues, from residue and atom names (ATOM records).
///
/// PDB files almost never state bond orders for polymer residues, and distance-based order perception
/// is unreliable on crystal geometries. Each standard residue gets one fixed Lewis structure:
/// backbone C=O (OXT stays single), one C=O in Asp/Glu carboxylates and Asn/Gln amides, one C=N in the
/// Arg guanidinium, and a Kekulé structure for the Phe, Tyr, Trp and His rings (the His double bonds
/// follow the protonated nitrogen when HD1/HE2 hydrogens are present). Every other bond with both atoms
/// in standard residues (including peptide and disulfide bonds) becomes single. Ligands, water and
/// unknown residues are left untouched.
public enum PDBResidueBondOrders {
    /// Residue names treated as standard amino acids (incl. common protonation-state variants).
    public static let standardResidues: Set<String> = [
        "ALA", "ARG", "ASN", "ASP", "CYS", "GLN", "GLU", "GLY", "HIS", "ILE", "LEU", "LYS", "MET", "PHE",
        "PRO", "SER", "THR", "TRP", "TYR", "VAL", "SEC", "MSE",
        "HID", "HIE", "HIP", "HSD", "HSE", "HSP", "ASH", "GLH", "LYN", "CYX", "CYM", "ARN",
    ]

    private static let ringPhe: [(String, String)] = [("CG", "CD1"), ("CE1", "CZ"), ("CD2", "CE2")]
    private static let sideChain: [String: [(String, String)]] = [
        "ASP": [("CG", "OD1")], "ASH": [("CG", "OD1")], "ASN": [("CG", "OD1")],
        "GLU": [("CD", "OE1")], "GLH": [("CD", "OE1")], "GLN": [("CD", "OE1")],
        "ARG": [("CZ", "NH1")], "ARN": [("CZ", "NH1")],
        "PHE": ringPhe, "TYR": ringPhe,
        "TRP": [("CG", "CD1"), ("CD2", "CE3"), ("CZ3", "CH2"), ("CZ2", "CE2")],
    ]

    /// Double-bonded atom-name pairs for one residue. `atomNames` are the names present in that residue
    /// (used to choose the histidine tautomer).
    public static func doubleBondPairs(residue: String, atomNames: Set<String>) -> [(String, String)] {
        let r = residue.uppercased()
        var out: [(String, String)] = [("C", "O")]
        if let s = sideChain[r] { out += s }
        if ["HIS", "HID", "HIE", "HIP", "HSD", "HSE", "HSP"].contains(r) {
            let hd1 = atomNames.contains("HD1"), he2 = atomNames.contains("HE2")
            let deltaOnly = r == "HID" || r == "HSD" || (r == "HIS" && hd1 && !he2)
            out += [("CG", "CD2"), deltaOnly ? ("CE1", "NE2") : ("ND1", "CE1")]
        }
        return out
    }

    /// Sets bond orders of existing bonds from residue templates. Returns the number of bonds made double.
    /// `records` must be parallel to `molecule.atoms`; bonds touching a non-standard residue are not changed.
    @discardableResult
    public static func apply(to m: inout Molecule, records: [PDBAtomRecord]) -> Int {
        guard records.count == m.atoms.count, !m.bonds.isEmpty else { return 0 }
        struct Key: Hashable { var chain: String, seq: Int, icode: String, name: String }
        func key(_ i: Int) -> Key { let r = records[i]; return Key(chain: r.chainID, seq: r.resSeq, icode: r.iCode, name: r.resName) }
        func isStandard(_ i: Int) -> Bool { !records[i].isHetero && standardResidues.contains(records[i].resName.uppercased()) }

        var names: [Key: Set<String>] = [:]
        for i in records.indices where isStandard(i) { names[key(i), default: []].insert(records[i].name.uppercased()) }
        var doubles: [Key: Set<[String]>] = [:]
        for (k, n) in names {
            doubles[k] = Set(doubleBondPairs(residue: k.name, atomNames: n).map { [$0.0, $0.1].sorted() })
        }
        var count = 0
        for bi in m.bonds.indices {
            let a = m.bonds[bi].a, b = m.bonds[bi].b
            guard a < records.count, b < records.count, isStandard(a), isStandard(b) else { continue }
            var order = BondOrder.single
            let ka = key(a)
            if ka == key(b), let d = doubles[ka],
               d.contains([records[a].name.uppercased(), records[b].name.uppercased()].sorted()) {
                order = .double; count += 1
            }
            m.bonds[bi].order = order
        }
        return count
    }

    /// True when any ATOM record belongs to a standard amino-acid residue.
    public static func containsProtein(_ records: [PDBAtomRecord]) -> Bool {
        records.contains { !$0.isHetero && standardResidues.contains($0.resName.uppercased()) }
    }

    /// Display-ready model: when it contains standard residues, adds distance-perceived bonds that are
    /// missing (stated CONECT bonds and their orders are kept) and then applies the residue templates.
    /// Models without standard residues are returned unchanged.
    public static func prepared(_ model: Molecule, records: [PDBAtomRecord]) -> Molecule {
        guard records.count == model.atoms.count, containsProtein(records) else { return model }
        var m = model
        var bonded = Set<Int>()
        for b in m.bonds { bonded.insert(b.a); bonded.insert(b.b) }
        let missing = records.indices.contains { i in
            !records[i].isHetero && standardResidues.contains(records[i].resName.uppercased()) && !bonded.contains(i)
        }
        if missing {
            var stated = Set(m.bonds.map { Int64(min($0.a, $0.b)) << 32 | Int64(max($0.a, $0.b)) })
            for b in m.perceivedBonds() where stated.insert(Int64(min(b.a, b.b)) << 32 | Int64(max(b.a, b.b))).inserted {
                m.bonds.append(b)
            }
        }
        apply(to: &m, records: records)
        return m
    }
}

extension PDBFile {
    /// Every model passed through `PDBResidueBondOrders.prepared` (used by `MolecularFileLoader`).
    public func withResidueBondOrders() -> PDBFile {
        var f = self
        for i in f.models.indices where i < f.atomRecords.count {
            f.models[i] = PDBResidueBondOrders.prepared(f.models[i], records: f.atomRecords[i])
        }
        return f
    }
}
