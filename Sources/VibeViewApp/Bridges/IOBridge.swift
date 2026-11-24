import Foundation
import MolCore
import MolIO

// INTEGRATION BRIDGE (Lead C). The single place where the app talks to MolIO.

public struct LoadedFile: Sendable {
    public var molecule: Molecule
    public var result: CalculationResult?
    /// Basis + MO coefficients (from .fchk) for orbital surfaces.
    public var wavefunction: Wavefunction?
}

public enum IOBridgeError: Error, LocalizedError {
    case unsupported(String), parse(String), empty
    public var errorDescription: String? {
        switch self {
        case .unsupported(let e): "VibeView can't read “.\(e)” files."
        case .parse(let m): "The file could not be read: \(m)"
        case .empty: "The file contains no atoms."
        }
    }
}

public enum IOBridge {
    /// Read any supported file. `ext` is a hint; the content is sniffed when it is ambiguous.
    public static func read(data: Data, ext: String, fileName: String? = nil) throws -> LoadedFile {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw IOBridgeError.parse("not a text file")
        }
        let format = MoleculeFileFormat.detect(contents: String(text.prefix(4096)), fileName: fileName)
            ?? MoleculeFileFormat.format(forExtension: ext)
        do {
            return try finish(try read(text: text, format: format, ext: ext))
        } catch let e as MolIOError {
            throw IOBridgeError.parse(e.description)
        }
    }

    private static func finish(_ l: LoadedFile) throws -> LoadedFile {
        do {
            var loaded = l
            if loaded.molecule.atoms.isEmpty && (loaded.result?.steps.isEmpty ?? true) { throw IOBridgeError.empty }
            loaded.molecule = prepared(loaded.molecule)
            if var r = loaded.result {
                r.steps = r.steps.map { prepared($0, perceiveOrders: false) }
                loaded.result = r
            }
            return loaded
        } catch let e as MolIOError {
            throw IOBridgeError.parse(e.description)
        }
    }

    public static func read(url: URL) throws -> LoadedFile {
        let data = try Data(contentsOf: url)
        return try read(data: data, ext: url.pathExtension, fileName: url.lastPathComponent)
    }

    private static func read(text: String, format: MoleculeFileFormat?, ext: String) throws -> LoadedFile {
        guard let format else { throw IOBridgeError.unsupported(ext) }
        switch format {
        case .xyz:
            let frames = try XYZFormat.parse(text)
            return multiFrame(frames)
        case .gaussianInput:
            guard let job = try GaussianInputReader.parse(text).first else { throw IOBridgeError.empty }
            var m = job.molecule
            if let cm = job.chargeMultiplicities.first { m.charge = cm.charge; m.multiplicity = cm.multiplicity }
            if m.title.isEmpty { m.title = job.title }
            return LoadedFile(molecule: m, result: nil)
        case .gaussianOutput:
            let log = try GaussianLog.parse(text)
            var r = log.result
            if r.routeSection.isEmpty { r.routeSection = log.firstRoute }
            let m = r.steps.last ?? log.inputOrientations.last ?? Molecule()
            return LoadedFile(molecule: m, result: r)
        case .formattedCheckpoint:
            let f = try FormattedCheckpoint.parse(text)
            var m = f.molecule
            if m.title.isEmpty { m.title = f.title }
            return LoadedFile(molecule: m, result: f.calculationResult, wavefunction: f.wavefunction)
        case .cube:
            let c = try CubeFile.parse(text)
            var r = CalculationResult()
            r.steps = [c.molecule]
            for (k, g) in c.grids.enumerated() {
                let key = c.orbitalIndices.indices.contains(k) ? "MO \(c.orbitalIndices[k])" : (c.grids.count == 1 ? "cube" : "cube \(k + 1)")
                r.volumes[key] = g
            }
            var m = c.molecule
            if m.title.isEmpty { m.title = c.title }
            return LoadedFile(molecule: m, result: r)
        case .pdb:
            let p = try PDBFormat.parse(text)
            return multiFrame(p.models)
        case .mol, .sdf:
            let recs = try MDLMolFormat.parse(text)
            return multiFrame(recs.map(\.molecule))
        case .cml:
            return multiFrame(try CMLFormat.parse(text))
        case .orcaOutput:
            let r = try OrcaOutput.parse(text).result
            return LoadedFile(molecule: r.steps.last ?? Molecule(), result: r)
        case .qchemOutput:
            let r = try QChemOutput.parse(text).result
            return LoadedFile(molecule: r.steps.last ?? Molecule(), result: r)
        case .orcaInput:
            return LoadedFile(molecule: try OrcaInputFile.parse(text).molecule, result: nil)
        case .qchemInput:
            guard let m = try QChemInputFile.parse(text).jobs.compactMap(\.molecule).first else { throw IOBridgeError.empty }
            return LoadedFile(molecule: m, result: nil)
        case .molden:
            let f = try MoldenFile.parse(text)
            return LoadedFile(molecule: f.geometries.last ?? f.molecule, result: f.result, wavefunction: f.wavefunction)
        case .orcaHessian:
            let h = try OrcaHessian.parse(text)
            var r = CalculationResult()
            r.steps = [h.molecule]
            if let e = h.energy { r.energies = [e] }
            r.normalModes = h.normalModes
            r.normalTermination = true
            return LoadedFile(molecule: h.molecule, result: r)
        case .xtbOutput:
            throw IOBridgeError.parse("an xtb log holds no coordinates — open xtbopt.xyz (or the input .xyz) from the same folder instead")
        }
    }

    /// One frame = plain structure; several = a trajectory the frame player can step through.
    private static func multiFrame(_ frames: [Molecule]) -> LoadedFile {
        guard let first = frames.first else { return LoadedFile(molecule: Molecule(), result: nil) }
        if frames.count == 1 { return LoadedFile(molecule: first, result: nil) }
        var r = CalculationResult()
        r.steps = frames
        r.normalTermination = true
        return LoadedFile(molecule: frames.last ?? first, result: r)
    }

    /// Ensure connectivity exists so the structure draws and edits sensibly.
    static func prepared(_ m: Molecule, perceiveOrders: Bool = true) -> Molecule {
        var m = m
        m.renumberAtomIDs()
        guard m.atoms.count > 1 && m.atoms.count < 200_000 else { return m }
        if m.bonds.isEmpty {
            m.perceiveBonds()
            if perceiveOrders && m.atoms.count < 2000 { m.perceiveBondOrders() }
        } else if hasUnbondedHeavyAtoms(m) {
            // Partial connectivity, e.g. a PDB whose CONECT records cover only HETATM groups:
            // keep every stated bond (orders included) and add the perceived ones that are missing.
            var stated = Set(m.bonds.map { Int64($0.a) << 32 | Int64($0.b) })
            for b in m.perceivedBonds() where stated.insert(Int64(b.a) << 32 | Int64(b.b)).inserted {
                m.bonds.append(b)
            }
        }
        return m
    }

    /// True when some non-hydrogen atom has no bond although the molecule has bonds elsewhere.
    static func hasUnbondedHeavyAtoms(_ m: Molecule) -> Bool {
        var bonded = [Bool](repeating: false, count: m.atoms.count)
        for b in m.bonds where b.a < bonded.count && b.b < bonded.count { bonded[b.a] = true; bonded[b.b] = true }
        return m.atoms.indices.contains { !bonded[$0] && m.atoms[$0].atomicNumber > 1 }
    }

    // MARK: Writing

    public static func write(_ m: Molecule, ext: String) throws -> Data {
        let text: String
        switch MoleculeFileFormat.format(forExtension: ext) {
        case .xyz?: text = XYZFormat.write(m)
        case .pdb?: text = PDBFormat.write(m)
        case .mol?: text = MDLMolFormat.write(m)
        case .sdf?: text = MDLMolFormat.writeSDF([SDFRecord(molecule: m)])
        case .cml?: text = CMLFormat.write(m)
        case .gaussianInput?, nil:
            var job = GaussianJob(molecule: m, route: GaussianRoute(parsing: "#p B3LYP/6-31G(d) Opt"), title: m.title.isEmpty ? "VibeView structure" : m.title)
            job.chargeMultiplicities = [ChargeMultiplicity(charge: m.charge, multiplicity: m.multiplicity)]
            text = job.inputText
        default: throw IOBridgeError.unsupported(ext)
        }
        return Data(text.utf8)
    }
}
