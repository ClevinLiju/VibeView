import Foundation
import MolCore

// Program-neutral job API (Lead A, round 2) for the calc-setup UI and job runner (Lead C):
//   spec (CalcSpec)  ->  CalcJobPlanner.plan(spec, baseName:)  ->  CalcJobPlan (files, command line, log name)
//   run the program (e.g. MolCompute.ProgramRunner) in a directory where `plan.write(to:)` put the files
//   ->  CalcJobResults.collect(plan, directory:)  ->  LoadedMolecularFile (frames, result, wavefunction).
// MolIO never launches processes; it only describes and reads them.

/// A file the job needs in its working directory.
public struct CalcJobFile: Sendable, Equatable {
    public var name: String
    public var contents: String
    public init(name: String, contents: String) { self.name = name; self.contents = contents }
}

/// Everything needed to run one calculation: input files, command line, and where the log ends up.
public struct CalcJobPlan: Sendable, Equatable {
    public var program: QCProgram
    /// Stem of the files the program writes (ORCA: the %base name when a checkpoint name was set).
    public var baseName: String
    /// Input file first, then auxiliary files (xtb `xcontrol.inp`).
    public var files: [CalcJobFile]
    /// Executable name to locate (e.g. with `ProgramLocator.find`): "orca", "qchem", "g16", "xtb".
    /// ORCA with nprocs > 1 must be started by its absolute path (its MPI launcher requires it).
    public var executableName: String
    /// Arguments after the executable, relative to the working directory.
    public var arguments: [String]
    /// Extra environment (thread counts).
    public var environment: [String: String]
    /// True when the program writes its log to stdout, which the runner must save as `outputFileName`.
    public var captureStdout: Bool
    /// The main log/output file, relative to the working directory.
    public var outputFileName: String
    /// Other files the program may write that `CalcJobResults.collect` reads when present.
    public var companionFileNames: [String]

    public var inputFileName: String { files.first?.name ?? "" }
    public var inputText: String { files.first?.contents ?? "" }

    /// Write `files` into `directory` (created if needed).
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for f in files {
            try f.contents.write(to: directory.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
        }
    }
}

public enum CalcJobPlanner {
    /// A plan for `spec`. Throws `MolIOError.unsupported` when `spec.validationErrors()` is not empty.
    /// `baseName` must be a plain file stem (letters, digits, "-", "_", "."); it names the input and log.
    public static func plan(_ spec: CalcSpec, baseName: String = "job") throws -> CalcJobPlan {
        let errs = spec.validationErrors()
        if !errs.isEmpty { throw MolIOError.unsupported(errs.joined(separator: "; ")) }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !baseName.isEmpty, baseName.unicodeScalars.allSatisfy({ ok.contains($0) }), !baseName.hasPrefix(".") else {
            throw MolIOError.unsupported("job base name '\(baseName)' must be a plain file stem")
        }
        let np = max(1, spec.nprocs)
        switch spec.program {
        case .orca:
            // ORCA names its files after the input, or after %base when a checkpoint name is set
            let stem = (spec.checkpointName?.isEmpty == false) ? spec.checkpointName!.replacingOccurrences(of: ".chk", with: "") : baseName
            let inp = baseName + ".inp"
            return CalcJobPlan(program: .orca, baseName: stem, files: [CalcJobFile(name: inp, contents: OrcaInput.write(spec))],
                               executableName: "orca", arguments: [inp], environment: [:], captureStdout: true,
                               outputFileName: baseName + ".out",
                               companionFileNames: [stem + ".hess", stem + "_trj.xyz", stem + ".engrad",
                                                    stem + ".molden.input", stem + ".xyz", stem + ".gbw"])
        case .qchem:
            let inp = baseName + ".in"
            return CalcJobPlan(program: .qchem, baseName: baseName, files: [CalcJobFile(name: inp, contents: QChemInput.write(spec))],
                               executableName: "qchem", arguments: ["-nt", String(np), inp, baseName + ".out"],
                               environment: [:], captureStdout: false, outputFileName: baseName + ".out", companionFileNames: [])
        case .gaussian:
            var s = spec
            if s.checkpointName == nil { s.checkpointName = baseName }
            let inp = baseName + ".gjf"
            return CalcJobPlan(program: .gaussian, baseName: baseName,
                               files: [CalcJobFile(name: inp, contents: GaussianJob(spec: s).inputText)],
                               executableName: "g16", arguments: [inp], environment: [:], captureStdout: false,
                               outputFileName: baseName + ".log", companionFileNames: [baseName + ".fchk"])
        case .xtb:
            let xyz = baseName + ".xyz"
            var args = XTBInput.arguments(for: spec)
            if !args.isEmpty { args[0] = xyz }
            var files = [CalcJobFile(name: xyz, contents: XYZFormat.write([spec.molecule]))]
            if let xc = XTBInput.xcontrol(for: spec) { files.append(CalcJobFile(name: "xcontrol.inp", contents: xc)) }
            return CalcJobPlan(program: .xtb, baseName: baseName, files: files, executableName: "xtb", arguments: args,
                               environment: ["OMP_NUM_THREADS": "\(np),1", "OMP_STACKSIZE": "1G", "OMP_MAX_ACTIVE_LEVELS": "1"],
                               captureStdout: true, outputFileName: baseName + ".out",
                               companionFileNames: ["xtbopt.xyz", "xtbopt.log", "xtbscan.log", "g98.out", "charges", "gradient"])
        }
    }
}

public enum CalcJobResults {
    /// Read a finished (or failed / still running) job: the main log plus whatever companion files exist.
    /// - ORCA: the `.hess` file supplies normal modes when the log has none; `.molden.input` (made with
    ///   `orca_2mkl <base> -molden`) supplies the wavefunction.
    /// - Gaussian: `<base>.fchk` (from `formchk`) supplies the wavefunction.
    /// - xtb: the geometry comes from `xtbopt.xyz` (or the input), normal modes from `g98.out`, scan frames from `xtbscan.log`.
    /// Throws when the main log is missing or unreadable; a truncated log parses as far as it is complete.
    public static func collect(_ plan: CalcJobPlan, directory: URL) throws -> LoadedMolecularFile {
        let dir = directory
        func url(_ n: String) -> URL { dir.appendingPathComponent(n) }
        func exists(_ n: String) -> Bool { FileManager.default.fileExists(atPath: url(n).path) }
        let logURL = url(plan.outputFileName)
        guard exists(plan.outputFileName) else { throw MolIOError.unsupported("job output \(plan.outputFileName) not found") }
        let text = try readText(logURL)
        let format: MoleculeFileFormat
        switch plan.program {
        case .orca: format = .orcaOutput
        case .qchem: format = .qchemOutput
        case .gaussian: format = .gaussianOutput
        case .xtb: format = .xtbOutput
        }
        var out = try MolecularFileLoader.load(text: text, format: format, fileName: plan.outputFileName)
        out.program = plan.program
        switch plan.program {
        case .orca:
            if var r = out.result {
                let hess = plan.baseName + ".hess"
                if r.normalModes.isEmpty, exists(hess), let h = try? OrcaHessian.read(url: url(hess)) { r.normalModes = h.normalModes }
                out.result = r
            }
            let mol = plan.baseName + ".molden.input"
            if exists(mol), let m = try? MoldenFile.read(url: url(mol)) { out.wavefunction = m.wavefunction }
        case .gaussian:
            let f = plan.baseName + ".fchk"
            if exists(f), let fc = try? FormattedCheckpoint.read(url: url(f)) { out.wavefunction = fc.wavefunction }
        case .xtb:
            let x = try XTBOutput.parse(text)
            var geom: Molecule?
            if let t = try? readText(url("xtbopt.xyz")), let ms = try? XYZFormat.parse(t), let m = ms.last, !m.atoms.isEmpty { geom = m }
            if geom == nil, let t = try? readText(url(plan.inputFileName)), let m = try? XYZFormat.parse(t).last { geom = m }
            var r = x.result(geometry: geom)
            if let t = try? readText(url("xtbopt.log")), let tr = try? XTBTrajectory.parse(t), !tr.molecules.isEmpty {
                r.steps = tr.molecules; r.energies = tr.energies
                if let g = geom, let lastE = tr.energies.last { r.steps[r.steps.count - 1] = g; r.energies[r.energies.count - 1] = lastE }
            }
            if exists("g98.out"), let modes = try? XTBG98Frequencies.read(url: url("g98.out")) { r.normalModes = modes }
            out.result = r
            if let g = geom { out.molecules = r.steps.count > 1 ? r.steps : [g] }
        case .qchem:
            break
        }
        return out
    }
}
