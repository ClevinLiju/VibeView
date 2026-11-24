import Foundation
import MolCore

// One-call file loading for the app (Lead A, round 2): detect the format, parse it, and return
// geometry frames plus whatever results / wavefunction / volumes the file carries.

public struct LoadedMolecularFile: Sendable {
    public var format: MoleculeFileFormat
    /// Geometry frames in file order: opt/scan/IRC steps, trajectory frames, PDB models, SDF records.
    /// The last one is the one to show. Never empty.
    public var molecules: [Molecule]
    /// Calculation results (program outputs, fchk, molden, hess).
    public var result: CalculationResult?
    /// Basis set + MOs for orbital surfaces (fchk, molden).
    public var wavefunction: Wavefunction?
    /// Volumetric data (cube files): one grid per data set.
    public var volumes: [VolumeGrid] = []
    /// SD-file data items per record (parallel to `molecules` for .sdf).
    public var sdfProperties: [[SDFProperty]] = []
    /// Gaussian/ORCA/Q-Chem input: the program-neutral job when it could be recovered (best effort).
    public var program: QCProgram?
    /// Sibling files considered by `MolecularFileLoader.loadWithCompanions(url:)` / `CalcJobResults.collect`
    /// (`used` marks the ones merged). Empty for a plain `load`.
    public var companions: [CompanionFile] = []

    public var molecule: Molecule { molecules.last ?? Molecule() }
}

public enum MolecularFileLoader {
    /// Formats `write(_:format:)` can produce.
    public static let writableFormats: [MoleculeFileFormat] = [.xyz, .pdb, .mol, .sdf, .cml, .gaussianInput, .orcaInput, .qchemInput]

    public static func load(url: URL) throws -> LoadedMolecularFile {
        let text = try readText(url)
        guard let f = MoleculeFileFormat.detect(contents: text, fileName: url.lastPathComponent) ?? MoleculeFileFormat.detect(url: url) else {
            throw MolIOError.unsupported("unrecognized file format: \(url.lastPathComponent)")
        }
        var out = try load(text: text, format: f)
        if f == .xtbOutput, out.molecules.first?.atoms.isEmpty ?? true {
            // xtb writes the geometry to separate files next to the log
            let dir = url.deletingLastPathComponent()
            for name in ["xtbopt.xyz", "xtbopt.coord.xyz", "xtblast.xyz"] {
                let u = dir.appendingPathComponent(name)
                if let t = try? readText(u), let ms = try? XYZFormat.parse(t), !ms.isEmpty { out.molecules = ms; break }
            }
            if let m = out.molecules.last, !m.atoms.isEmpty, var r = out.result {
                r.steps = [m]
                out.result = r
            }
        }
        return out
    }

    /// Parse `text` as `format`; with `format == nil` the content (and `fileName`) decide.
    public static func load(text: String, format: MoleculeFileFormat? = nil, fileName: String? = nil) throws -> LoadedMolecularFile {
        guard let f = format ?? MoleculeFileFormat.detect(contents: text, fileName: fileName) else {
            throw MolIOError.unsupported("unrecognized file format\(fileName.map { ": " + $0 } ?? "")")
        }
        func done(_ ms: [Molecule], result: CalculationResult? = nil, wf: Wavefunction? = nil, program: QCProgram? = nil) throws -> LoadedMolecularFile {
            let frames = ms.filter { !$0.atoms.isEmpty }
            guard !frames.isEmpty || f == .xtbOutput else { throw MolIOError.parse(format: f.rawValue, line: nil, message: "file contains no atoms") }
            return LoadedMolecularFile(format: f, molecules: frames.isEmpty ? [Molecule()] : frames, result: result, wavefunction: wf, program: program)
        }
        switch f {
        case .xyz:
            return try done(try XYZFormat.parse(text))
        case .pdb:
            return try done(try PDBFormat.parse(text).withResidueBondOrders().models)
        case .mol, .sdf:
            let recs = try MDLMolFormat.parse(text)
            var o = try done(recs.map(\.molecule))
            o.sdfProperties = recs.map(\.properties)
            return o
        case .cml:
            return try done(try CMLFormat.parse(text))
        case .cube:
            let c = try CubeFile.parse(text)
            var o = try done([c.molecule])
            o.volumes = c.grids
            return o
        case .gaussianInput:
            let jobs = try GaussianInputReader.parse(text)
            return try done(jobs.map(\.molecule), program: .gaussian)
        case .gaussianOutput:
            let log = try GaussianLog.parse(text)
            let r = log.result
            return try done(r.steps.isEmpty ? log.standardOrientations + log.inputOrientations : r.steps, result: r, program: .gaussian)
        case .formattedCheckpoint:
            let fc = try FormattedCheckpoint.parse(text)
            return try done([fc.molecule], result: fc.calculationResult, wf: fc.wavefunction, program: .gaussian)
        case .orcaInput:
            let i = try OrcaInputFile.parse(text)
            return try done([i.molecule], program: .orca)
        case .orcaOutput:
            let o = try OrcaOutput.parse(text)
            let r = o.result
            return try done(r.steps.isEmpty ? o.geometries : r.steps, result: r, program: .orca)
        case .orcaHessian:
            let h = try OrcaHessian.parse(text)
            var r = CalculationResult()
            r.steps = [h.molecule]; r.normalModes = h.normalModes
            var x = CalculationExtras(); x.program = "orca"; r.extras = x
            return try done([h.molecule], result: r, program: .orca)
        case .qchemInput:
            let q = try QChemInputFile.parse(text)
            return try done(q.jobs.compactMap(\.molecule), program: .qchem)
        case .qchemOutput:
            let q = try QChemOutput.parse(text)
            return try done(q.result.steps, result: q.result, program: .qchem)
        case .xtbOutput:
            let x = try XTBOutput.parse(text)
            return try done([], result: x.result, program: .xtb)
        case .molden:
            let m = try MoldenFile.parse(text)
            let frames = m.geometries.isEmpty ? [m.molecule] : m.geometries
            return try done(frames, result: m.result, wf: m.wavefunction)
        }
    }

    /// Serialize a molecule. Program inputs use a single-point HF/STO-3G-free default: callers wanting a
    /// real job should build a `CalcSpec` and use `CalcInputWriter`.
    public static func write(_ molecule: Molecule, format: MoleculeFileFormat) throws -> String {
        switch format {
        case .xyz: return XYZFormat.write(molecule)
        case .pdb: return PDBFormat.write(molecule)
        case .mol: return MDLMolFormat.write(molecule)
        case .sdf: return MDLMolFormat.writeSDF([SDFRecord(molecule: molecule)])
        case .cml: return CMLFormat.write(molecule)
        case .gaussianInput:
            return GaussianJob(spec: CalcSpec(program: .gaussian, method: "B3LYP", basis: "6-31G(d)", molecule: molecule)).inputText
        case .orcaInput:
            return OrcaInput.write(CalcSpec(program: .orca, method: "B3LYP", basis: "def2-SVP", molecule: molecule))
        case .qchemInput:
            return QChemInput.write(CalcSpec(program: .qchem, method: "B3LYP", basis: "def2-SVP", molecule: molecule))
        default:
            throw MolIOError.unsupported("writing \(format.displayName)")
        }
    }
}
