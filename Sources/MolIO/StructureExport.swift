import Foundation
import MolCore

/// File ▸ Export ▸ Structure: one structure or every frame, optionally only some atoms.
///
/// Multi-frame formats (XYZ trajectory, multi-model PDB, multi-record SDF) hold every frame; any other writable
/// format gets the last of the requested frames. XYZ/SDF titles carry "frame k" and the frame energy when known.
public enum StructureExport {
    public static let multiFrameFormats: Set<MoleculeFileFormat> = [.xyz, .pdb, .sdf]

    /// The atoms `atoms` (0-based, in that order) of `m`, with the bonds among them.
    public static func subset(_ m: Molecule, atoms: [Int]) -> Molecule {
        var map = [Int: Int]()
        var out = Molecule(charge: m.charge, multiplicity: m.multiplicity, title: m.title)
        for i in atoms where m.atoms.indices.contains(i) && map[i] == nil {
            map[i] = out.atoms.count
            var a = m.atoms[i]
            a.id = out.atoms.count
            out.atoms.append(a)
        }
        for b in m.bonds { if let a = map[b.a], let c = map[b.b] { out.bonds.append(Bond(a, c, order: b.order)) } }
        // A fragment doesn't keep the whole molecule's charge and spin.
        if out.atoms.count != m.atoms.count { out.charge = 0; out.multiplicity = 1 }
        return out
    }

    public struct Output: Sendable, Equatable {
        public var text: String
        public var frameCount: Int
        public var atomCount: Int
    }

    /// `frames` in order; `energies` parallel to `frames` (nil entries allowed); `atoms` = subset or nil for all.
    public static func text(frames: [Molecule], format: MoleculeFileFormat, energies: [Double?] = [], atoms: [Int]? = nil,
                            title: String = "") throws -> Output {
        guard !frames.isEmpty else { throw MolIOError.unsupported("nothing to export") }
        guard MolecularFileLoader.writableFormats.contains(format) else {
            throw MolIOError.unsupported("\(format.displayName) files cannot be written")
        }
        var picks = Array(frames.indices)
        if !multiFrameFormats.contains(format) { picks = [frames.count - 1] }
        let multi = picks.count > 1
        var mols: [Molecule] = []
        var es: [Double?] = []
        for k in picks {
            var m = frames[k]
            if let a = atoms {
                guard a.allSatisfy({ $0 >= 0 && $0 < m.atoms.count }) else {
                    throw MolIOError.unsupported("frame \(k + 1) has \(m.atoms.count) atoms; the selection does not fit it")
                }
                m = subset(m, atoms: a)
            }
            let e = k < energies.count ? energies[k] : nil
            if format == .xyz || format == .sdf {
                let base = title.isEmpty ? (m.title.isEmpty ? "VibeView" : m.title) : title
                var t = multi ? "\(base) frame \(k + 1)" : (m.title.isEmpty ? base : m.title)
                if let e { t += String(format: "  E = %.10f Eh", e) }
                m.title = t
            }
            mols.append(m); es.append(e)
        }
        let text: String
        switch format {
        case .xyz: text = XYZFormat.write(mols)
        case .pdb: text = multi ? PDBFormat.write(models: mols) : PDBFormat.write(mols[0])
        case .sdf:
            text = MDLMolFormat.writeSDF(mols.enumerated().map { i, m in
                var props: [SDFProperty] = []
                if let e = es[i] { props.append(SDFProperty(name: "ENERGY_HARTREE", value: String(format: "%.10f", e))) }
                if multi { props.append(SDFProperty(name: "FRAME", value: String(picks[i] + 1))) }
                return SDFRecord(molecule: m, properties: props)
            })
        default: text = try MolecularFileLoader.write(mols[0], format: format)
        }
        return Output(text: text, frameCount: mols.count, atomCount: mols.first?.atoms.count ?? 0)
    }

    /// Energies parallel to `frameCount` frames: a result may list more energies than geometries (the last ones match).
    public static func frameEnergies(_ energies: [Double], frameCount n: Int) -> [Double?] {
        let off = energies.count - n
        return (0..<max(n, 0)).map { k in energies.indices.contains(k + off) ? energies[k + off] : nil }
    }
}
