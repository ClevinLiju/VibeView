import Foundation
import MolCore
import MolIO

// File > Export (agent "export"): multi-frame and selection-only export, plus Molden and cube files.
//
//   doc.exportFormats {docId}  -> {formats: [{id, name, extensions, multiFrame, available, note}]}
//   doc.exportAs {docId, format, frames: "current"|"all"|[int], atoms: [int]|null, energies: bool = true,
//                 volume: str|null}
//                -> {text, format, extension, frameCount, atomCount}
//
// The text goes back to the front end, which writes it to the path the user picked in a Save dialog (the
// main process only writes there), so this method never touches the file system.

extension Engine {
    func docExportFormats(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        return ["formats": .array(ExportWriter.formats(for: d))]
    }

    func docExportAs(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        // All the work is synchronous on the snapshot (no SIMD-holding values cross an async boundary).
        return try ExportWriter.export(d, p)
    }
}

enum ExportWriter {
    /// Formats with more than one structure per file.
    static let multiFrame: Set<MoleculeFileFormat> = [.xyz, .sdf, .pdb, .molden]

    static func formats(for d: EngineDocument) -> [JSON] {
        var out: [JSON] = []
        for f in MolecularFileLoader.writableFormats {
            out.append(obj(["id": f.rawValue, "name": f.displayName, "extensions": f.fileExtensions, "multiFrame": multiFrame.contains(f),
                            "available": true, "note": JSON.null]))
        }
        let hasModes = (d.result?.normalModes.count ?? 0) > 0
        let moldenNote = d.wavefunction != nil ? "geometry, basis set and MOs" + (hasModes ? ", normal modes" : "")
            : hasModes ? "geometry and normal modes" : "geometry (and frames)"
        out.append(obj(["id": "molden", "name": MoleculeFileFormat.molden.displayName, "extensions": MoleculeFileFormat.molden.fileExtensions,
                        "multiFrame": true, "available": true, "note": moldenNote]))
        out.append(obj(["id": "cube", "name": MoleculeFileFormat.cube.displayName, "extensions": MoleculeFileFormat.cube.fileExtensions,
                        "multiFrame": false, "available": !d.volumes.isEmpty, "volumes": d.volumes.map { $0.name },
                        "note": d.volumes.isEmpty ? "the document has no volumetric data" : "volumetric data from the file"]))
        return out
    }

    /// Energies parallel to `d.frames` (the result may list more energies than geometries). Without result energies,
    /// a multi-frame XYZ's comment lines are read ("energy: …" from xtb, "E …" from ORCA, "E=…").
    static func frameEnergies(_ d: EngineDocument) -> [Double?] {
        let n = max(d.frames.count, 1)
        let e = d.result?.energies ?? []
        // A multi-frame XYZ states its own energies; prefer them unless the result's energies match frame for frame.
        if d.frames.count > 1, d.format == .xyz, e.count != d.frames.count {
            let c = d.frames.map { XYZFormat.commentEnergy($0.title) }
            if c.contains(where: { $0 != nil }) { return c }
        }
        let off = e.count - n
        return (0..<n).map { k in e.indices.contains(k + off) ? e[k + off] : nil }
    }

    static func subset(_ m: Molecule, _ atoms: [Int]) -> Molecule {
        var map = [Int: Int]()
        var out = Molecule(charge: m.charge, multiplicity: m.multiplicity, title: m.title)
        for i in atoms where m.atoms.indices.contains(i) && map[i] == nil {
            map[i] = out.atoms.count
            var a = m.atoms[i]
            a.id = out.atoms.count
            out.atoms.append(a)
        }
        for b in m.bonds { if let a = map[b.a], let c = map[b.b] { out.bonds.append(Bond(a, c, order: b.order)) } }
        // A fragment doesn't keep the whole molecule's charge/spin.
        if out.atoms.count != m.atoms.count { out.charge = 0; out.multiplicity = 1 }
        return out
    }

    static func export(_ d: EngineDocument, _ p: Params) throws -> JSON {
        let name = try p.string("format")
        let fmt: MoleculeFileFormat
        if let f = MoleculeFileFormat(rawValue: name) ?? MoleculeFileFormat.format(forExtension: name) { fmt = f } else {
            throw RPCError.badRequest("unknown format '\(name)'")
        }
        guard MolecularFileLoader.writableFormats.contains(fmt) || fmt == .molden || fmt == .cube else {
            throw RPCError.badRequest("\(fmt.displayName) can't be written")
        }
        let atoms = try p.optInts("atoms").flatMap { $0.isEmpty ? nil : $0 }
        if let a = atoms { try checkAtoms(a, in: d.molecule) }
        let withEnergies = p.bool("energies", default: true)
        let energies = frameEnergies(d)
        let frameCount = max(d.frames.count, 1)

        // Which frames: indices into d.frames, or nil = the current (edited) molecule.
        var picks: [Int?] = [nil]
        if let s = p.optString("frames") {
            switch s {
            case "current": picks = [nil]
            case "all": picks = d.frames.isEmpty ? [nil] : Array(0..<d.frames.count)
            default: throw RPCError.badRequest("frames must be \"current\", \"all\" or a list of frame indices")
            }
        } else if p.has("frames") {
            let ks = try p.ints("frames")
            for k in ks where !(0..<frameCount).contains(k) { throw RPCError.badRequest("no frame \(k) (0..<\(frameCount))") }
            picks = d.frames.isEmpty ? [nil] : ks
        }
        if !multiFrame.contains(fmt) && picks.count > 1 { picks = [picks.last!] }

        var mols: [Molecule] = []
        var energyOf: [Double?] = []
        for k in picks {
            var m: Molecule
            if let k = k { m = d.frame(k) ?? d.molecule } else { m = d.molecule }
            if let a = atoms {
                guard m.atoms.count == d.molecule.atoms.count else {
                    throw RPCError.badRequest("frame \(k ?? 0) has \(m.atoms.count) atoms, the selection refers to \(d.molecule.atoms.count)")
                }
                m = subset(m, a)
            }
            let e: Double? = k.map { energies[$0] } ?? (d.frames.isEmpty ? energies.last ?? nil : nil)
            if fmt == .xyz || fmt == .sdf {
                let base = d.displayTitle.isEmpty ? (m.title.isEmpty ? "VibeView" : m.title) : d.displayTitle
                var t = picks.count > 1 ? "\(base) frame \((k ?? 0) + 1)" : (m.title.isEmpty ? base : m.title)
                if withEnergies, let e = e { t += String(format: "  E = %.10f Eh", e) }
                m.title = t
            }
            mols.append(m)
            energyOf.append(e)
        }

        let text: String
        switch fmt {
        case .xyz: text = XYZFormat.write(mols)
        case .pdb: text = mols.count > 1 ? PDBFormat.write(models: mols) : PDBFormat.write(mols[0])
        case .sdf:
            text = MDLMolFormat.writeSDF(mols.enumerated().map { i, m in
                var props: [SDFProperty] = []
                if withEnergies, let e = energyOf[i] { props.append(SDFProperty(name: "ENERGY_HARTREE", value: String(format: "%.10f", e))) }
                if picks.count > 1 { props.append(SDFProperty(name: "FRAME", value: String((picks[i] ?? 0) + 1))) }
                return SDFRecord(molecule: m, properties: props)
            })
        case .molden:
            let cur = mols.last!
            let sameAtoms = atoms == nil && cur.atoms.count == d.molecule.atoms.count
            let wf = sameAtoms ? d.wavefunction : nil
            let modes = sameAtoms ? (d.result?.normalModes ?? []).filter { $0.displacements.count == cur.atoms.count } : []
            let geoms = mols.count > 1 ? mols : []
            let es = geoms.isEmpty ? [] : energyOf.compactMap { $0 }
            text = MoldenFile.write(molecule: cur, wavefunction: wf, normalModes: modes, geometries: geoms,
                                    geometryEnergies: es.count == geoms.count ? es : [], title: d.displayTitle)
        case .cube:
            guard !d.volumes.isEmpty else { throw RPCError.notFound("the document has no volumetric data") }
            let want = p.optString("volume")
            let vols = want.map { w in d.volumes.filter { $0.name == w } } ?? [d.volumes[0]]
            guard !vols.isEmpty else { throw RPCError.notFound("no volume '\(want ?? "")'") }
            let cube = CubeFile(title: d.displayTitle, comment: "exported by VibeView: \(vols.map { $0.name }.joined(separator: ", "))",
                                molecule: atoms == nil ? d.molecule : mols[0], grids: vols.map { $0.grid })
            text = cube.write()
        default:
            text = try MolecularFileLoader.write(mols[0], format: fmt)
        }
        return obj(["text": text, "format": fmt.rawValue, "extension": fmt.fileExtensions.first ?? "txt",
                    "frameCount": mols.count, "atomCount": mols.first?.atoms.count ?? 0])
    }
}
