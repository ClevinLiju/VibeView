import Foundation
import MolCore

// Program-neutral calculation description (Lead A, round 2). The calc-setup UI (Lead C) edits a
// `CalcSpec`; `CalcInputWriter.write(_:)` turns it into the input text for the chosen program.
// Per-program writers: `GaussianJob(spec:)`, `OrcaInput.write(_:)`, `QChemInput.write(_:)`,
// `XTBInput.arguments(for:)` / `XTBInput.xcontrol(for:)`.

public enum QCProgram: String, CaseIterable, Sendable, Codable {
    case gaussian, orca, qchem, xtb
    public var displayName: String {
        switch self {
        case .gaussian: return "Gaussian"
        case .orca: return "ORCA"
        case .qchem: return "Q-Chem"
        case .xtb: return "xtb"
        }
    }
    /// Default input-file extension.
    public var inputExtension: String {
        switch self {
        case .gaussian: return "gjf"
        case .orca: return "inp"
        case .qchem: return "in"
        case .xtb: return "xyz"
        }
    }
}

public enum CalcTask: String, CaseIterable, Sendable, Codable {
    case energy            // single point
    case optimize
    case frequencies
    case optimizeAndFrequencies
    case transitionState   // TS optimization (+ freq when `computeFrequenciesAfterTS`)
    case scan              // relaxed scan of `scan`
    case irc
    case gradient
}

public enum SolvationModel: String, CaseIterable, Sendable, Codable {
    case pcm, cpcm, smd, alpb, gbsa   // alpb/gbsa: xtb only
}

public struct Solvation: Sendable, Codable, Equatable {
    public var model: SolvationModel
    public var solvent: String          // "water", "acetonitrile", ...
    public init(model: SolvationModel, solvent: String) { self.model = model; self.solvent = solvent }
}

public enum DispersionCorrection: String, CaseIterable, Sendable, Codable {
    case d3zero, d3bj, d4
}

/// A relaxed-scan coordinate: 2 atoms = bond, 3 = angle, 4 = dihedral (0-based atom indices).
public struct ScanCoordinate: Sendable, Codable, Equatable {
    public var atoms: [Int]
    public var start: Double            // Å or degrees
    public var end: Double
    public var steps: Int               // number of points including both ends
    public init(atoms: [Int], start: Double, end: Double, steps: Int) {
        self.atoms = atoms; self.start = start; self.end = end; self.steps = steps
    }
    public var stepSize: Double { steps > 1 ? (end - start) / Double(steps - 1) : 0 }
}

public struct ExcitedStatesSpec: Sendable, Codable, Equatable {
    public var roots: Int
    public var triplets: Bool = false
    public var tammDancoff: Bool = false
    public init(roots: Int, triplets: Bool = false, tammDancoff: Bool = false) {
        self.roots = roots; self.triplets = triplets; self.tammDancoff = tammDancoff
    }
}

public struct CalcSpec: Sendable, Codable, Equatable {
    public var program: QCProgram
    public var task: CalcTask = .energy
    /// "HF", "B3LYP", "PBE0", "wB97X-D", "MP2", "CCSD(T)", "GFN2-xTB", "GFN1-xTB", "GFN-FF".
    public var method: String
    /// "def2-SVP", "6-31G(d)", ...; empty for xtb / semiempirical.
    public var basis: String = ""
    public var dispersion: DispersionCorrection? = nil
    public var solvation: Solvation? = nil
    /// nil = program default (restricted for singlets, unrestricted otherwise).
    public var unrestricted: Bool? = nil
    public var excitedStates: ExcitedStatesSpec? = nil
    public var scan: ScanCoordinate? = nil
    /// 0-based atom indices frozen during optimization.
    public var frozenAtoms: [Int] = []
    public var computeFrequenciesAfterTS: Bool = true
    public var tightOptimization: Bool = false
    public var nprocs: Int = 1
    /// Total memory in MB (ORCA %maxcore is derived per core).
    public var memoryMB: Int = 2000
    public var title: String = ""
    /// Molecule with charge/multiplicity (Å).
    public var molecule: Molecule
    /// Extra raw keywords appended to the route / "!" line / $rem (program-specific syntax).
    public var extraKeywords: [String] = []
    /// Extra raw input appended verbatim (ORCA % blocks, Q-Chem $sections, Gaussian trailing sections).
    public var extraInput: String = ""
    /// Gaussian %chk / ORCA base name; nil = none.
    public var checkpointName: String? = nil

    public init(program: QCProgram, task: CalcTask = .energy, method: String, basis: String = "",
                molecule: Molecule, title: String = "") {
        self.program = program; self.task = task; self.method = method; self.basis = basis
        self.molecule = molecule; self.title = title
    }

    public var charge: Int { molecule.charge }
    public var multiplicity: Int { molecule.multiplicity }
    public var isUnrestricted: Bool { unrestricted ?? (molecule.multiplicity != 1) }
    public var includesOptimization: Bool { [.optimize, .optimizeAndFrequencies, .transitionState, .scan].contains(task) }
    public var includesFrequencies: Bool {
        task == .frequencies || task == .optimizeAndFrequencies || (task == .transitionState && computeFrequenciesAfterTS)
    }

    /// Problems that make the spec unwritable for its program (empty = OK).
    public func validationErrors() -> [String] {
        var e: [String] = []
        if molecule.atoms.isEmpty { e.append("molecule has no atoms") }
        if method.trimmingCharacters(in: .whitespaces).isEmpty { e.append("method is empty") }
        if multiplicity < 1 { e.append("multiplicity must be >= 1") }
        let electrons = molecule.atoms.reduce(0) { $0 + $1.atomicNumber } - charge
        if electrons < 0 { e.append("charge exceeds nuclear charge") }
        else if (electrons + multiplicity - 1) % 2 != 0 { e.append("charge \(charge) and multiplicity \(multiplicity) are inconsistent with \(electrons) electrons") }
        if task == .scan {
            if let s = scan {
                if !(2...4).contains(s.atoms.count) { e.append("scan needs 2-4 atoms") }
                if s.atoms.contains(where: { $0 < 0 || $0 >= molecule.atoms.count }) { e.append("scan atom index out of range") }
                if s.steps < 2 { e.append("scan needs at least 2 points") }
            } else { e.append("scan task without scan coordinate") }
        }
        if frozenAtoms.contains(where: { $0 < 0 || $0 >= molecule.atoms.count }) { e.append("frozen atom index out of range") }
        if program != .xtb, basis.isEmpty, !CalcSpec.isBasisFree(method) { e.append("basis set is empty") }
        if program == .xtb, excitedStates != nil { e.append("xtb has no excited states") }
        if program == .xtb, [.irc, .transitionState].contains(task) { e.append("xtb does not support \(task.rawValue) here") }
        if let s = solvation, program != .xtb, [.alpb, .gbsa].contains(s.model) { e.append("\(s.model.rawValue) solvation is xtb only") }
        if let s = solvation, program == .xtb, ![.alpb, .gbsa].contains(s.model) { e.append("xtb supports alpb/gbsa solvation only") }
        return e
    }

    /// Methods that carry their own basis (semiempirical, xtb, composite).
    public static func isBasisFree(_ method: String) -> Bool {
        let m = method.uppercased()
        return m.contains("XTB") || m.hasPrefix("GFN") || ["PM6", "PM7", "AM1", "PM3", "HF-3C", "PBEH-3C", "R2SCAN-3C", "B97-3C", "CBS-QB3", "G4", "UFF"].contains(m)
    }
}

public enum CalcInputWriter {
    /// Input text for the spec's program. For xtb this is the XYZ geometry; use
    /// `XTBInput.arguments(for:)` for the command line and `XTBInput.xcontrol(for:)` for constraints.
    public static func write(_ spec: CalcSpec) throws -> String {
        let errs = spec.validationErrors()
        if !errs.isEmpty { throw MolIOError.unsupported(errs.joined(separator: "; ")) }
        switch spec.program {
        case .gaussian: return GaussianJob(spec: spec).inputText
        case .orca: return OrcaInput.write(spec)
        case .qchem: return QChemInput.write(spec)
        case .xtb: return XYZFormat.write([spec.molecule])
        }
    }
}

// MARK: - Gaussian adapter

extension GaussianJob {
    /// A Gaussian job equivalent to a program-neutral spec.
    public init(spec: CalcSpec) {
        var route = GaussianRoute()
        route.printLevel = "#P"
        let m = spec.method
        let prefix = (spec.unrestricted == true && !m.uppercased().hasPrefix("U")) ? "U" : ""
        route.method = prefix + m
        route.basis = spec.basis.isEmpty ? nil : spec.basis
        var jobs: [String] = []
        let tight = spec.tightOptimization ? ",Tight" : ""
        switch spec.task {
        case .energy: break
        case .gradient: jobs.append("Force")
        case .optimize: jobs.append(spec.frozenAtoms.isEmpty ? "Opt" + (tight.isEmpty ? "" : "(Tight)") : "Opt(ModRedundant\(tight))")
        case .frequencies: jobs.append("Freq")
        case .optimizeAndFrequencies:
            jobs.append(spec.frozenAtoms.isEmpty ? "Opt" + (tight.isEmpty ? "" : "(Tight)") : "Opt(ModRedundant\(tight))")
            jobs.append("Freq")
        case .transitionState:
            jobs.append("Opt(TS,CalcFC,NoEigenTest\(tight))")
            if spec.computeFrequenciesAfterTS { jobs.append("Freq") }
        case .scan: jobs.append("Opt(ModRedundant\(tight))")
        case .irc: jobs.append("IRC(CalcFC,MaxPoints=20)")
        }
        if let td = spec.excitedStates {
            var o = ["NStates=\(td.roots)"]
            if td.triplets { o.append("50-50") }
            jobs.append((td.tammDancoff ? "TDA" : "TD") + "(" + o.joined(separator: ",") + ")")
        }
        route.jobTypes = jobs
        var kw: [String] = []
        switch spec.dispersion {
        case .d3zero: kw.append("EmpiricalDispersion=GD3")
        case .d3bj: kw.append("EmpiricalDispersion=GD3BJ")
        case .d4, .none: break   // D4 is not a Gaussian keyword
        }
        kw.append(contentsOf: spec.extraKeywords)
        route.keywords = kw
        if let s = spec.solvation {
            route.solvation = GaussianSolvation(model: s.model == .smd ? "SMD" : (s.model == .cpcm ? "CPCM" : nil), solvent: s.solvent)
        }
        var link0 = Link0()
        link0.nprocShared = spec.nprocs
        link0.memory = "\(spec.memoryMB)MB"
        if let c = spec.checkpointName { link0.checkpoint = c.hasSuffix(".chk") ? c : c + ".chk" }
        var mod: [String] = []
        for a in spec.frozenAtoms { mod.append("X \(a + 1) F") }
        if spec.task == .scan, let s = spec.scan {
            let tag = ["", "", "B", "A", "D"][min(s.atoms.count, 4)]
            let ids = s.atoms.map { String($0 + 1) }.joined(separator: " ")
            mod.append("\(tag) \(ids) S \(s.steps - 1) \(String(format: "%.4f", s.stepSize))")
        }
        let title = spec.title.isEmpty ? (spec.molecule.title.isEmpty ? "VibeView job" : spec.molecule.title) : spec.title
        let extra = spec.extraInput.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(link0: link0, route: route, title: title, molecule: spec.molecule,
                  modRedundant: mod, extraSections: extra.isEmpty ? [] : [extra])
    }
}
