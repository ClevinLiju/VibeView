import Foundation
import MolCore

/// xtb geometry-optimization convergence level (`--opt <level>`).
public enum XTBOptLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case crude, sloppy, loose, normal, tight, vtight, extreme
    public var id: String { rawValue }
    public var title: String { rawValue == "vtight" ? "Very tight" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public enum XTBSolvationModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, alpb, gbsa
    public var id: String { rawValue }
    public var title: String { switch self { case .none: "None (gas phase)"; case .alpb: "ALPB"; case .gbsa: "GBSA" } }
    public var flag: String? { switch self { case .none: nil; case .alpb: "--alpb"; case .gbsa: "--gbsa" } }
}

/// Solvent names accepted by xtb 6.x for each implicit-solvation model.
public enum XTBSolvents {
    public static let alpb = ["acetone", "acetonitrile", "aniline", "benzaldehyde", "benzene", "ch2cl2", "chcl3", "cs2",
                              "dioxane", "dmf", "dmso", "ether", "ethylacetate", "furane", "hexadecane", "hexane",
                              "methanol", "nitromethane", "octanol", "woctanol", "phenol", "toluene", "thf", "water"]
    public static let gbsa = ["acetone", "acetonitrile", "benzene", "ch2cl2", "chcl3", "cs2", "dmf", "dmso", "ether",
                              "water", "methanol", "n-hexane", "thf", "toluene"]
    public static func names(for model: XTBSolvationModel) -> [String] {
        switch model { case .none: []; case .alpb: alpb; case .gbsa: gbsa }
    }
}

/// Everything needed to launch one xtb job. Codable so the app can persist presets.
public struct XTBSettings: Codable, Sendable, Equatable {
    public var method: XTBMethod = .gfn2
    public var task: XTBTask = .optimize
    public var optLevel: XTBOptLevel = .normal
    /// `--cycles`: maximum optimization cycles (nil = xtb default).
    public var maxCycles: Int?
    public var solvationModel: XTBSolvationModel = .none
    public var solvent: String?
    /// nil = take from the molecule (`charge`, `multiplicity - 1`).
    public var charge: Int?
    public var uhf: Int?
    /// `--etemp` in K (nil = xtb default 300 K).
    public var electronicTemperature: Double?
    /// `--acc` (nil = 1.0).
    public var accuracy: Double?
    public var threads: Int = 4
    public var extraArguments: [String] = []
    /// Wall-clock limit in seconds (nil = none).
    public var timeout: TimeInterval?

    public init(method: XTBMethod = .gfn2, task: XTBTask = .optimize, optLevel: XTBOptLevel = .normal,
                maxCycles: Int? = nil, solvationModel: XTBSolvationModel = .none, solvent: String? = nil,
                charge: Int? = nil, uhf: Int? = nil, electronicTemperature: Double? = nil, accuracy: Double? = nil,
                threads: Int = 4, extraArguments: [String] = [], timeout: TimeInterval? = nil) {
        self.method = method; self.task = task; self.optLevel = optLevel; self.maxCycles = maxCycles
        self.solvationModel = solvationModel; self.solvent = solvent; self.charge = charge; self.uhf = uhf
        self.electronicTemperature = electronicTemperature; self.accuracy = accuracy; self.threads = threads
        self.extraArguments = extraArguments; self.timeout = timeout
    }

    public init(from decoder: Decoder) throws {
        // Lenient decoding: missing keys keep their defaults so older presets still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = XTBSettings()
        method = try c.decodeIfPresent(XTBMethod.self, forKey: .method) ?? d.method
        task = try c.decodeIfPresent(XTBTask.self, forKey: .task) ?? d.task
        optLevel = try c.decodeIfPresent(XTBOptLevel.self, forKey: .optLevel) ?? d.optLevel
        maxCycles = try c.decodeIfPresent(Int.self, forKey: .maxCycles)
        solvationModel = try c.decodeIfPresent(XTBSolvationModel.self, forKey: .solvationModel) ?? d.solvationModel
        solvent = try c.decodeIfPresent(String.self, forKey: .solvent)
        charge = try c.decodeIfPresent(Int.self, forKey: .charge)
        uhf = try c.decodeIfPresent(Int.self, forKey: .uhf)
        electronicTemperature = try c.decodeIfPresent(Double.self, forKey: .electronicTemperature)
        accuracy = try c.decodeIfPresent(Double.self, forKey: .accuracy)
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
    }

    /// Human-readable problems; empty means the settings can be run.
    public func validationErrors(molecule: Molecule? = nil) -> [String] {
        var e: [String] = []
        if let n = maxCycles, n < 1 { e.append("Max cycles must be at least 1.") }
        if threads < 1 || threads > 256 { e.append("Threads must be between 1 and 256.") }
        if let t = electronicTemperature, !(t > 0 && t <= 50_000) { e.append("Electronic temperature must be between 0 and 50000 K.") }
        if let a = accuracy, !(a >= 0.0001 && a <= 1000) { e.append("Accuracy must be between 0.0001 and 1000.") }
        if let u = uhf, u < 0 { e.append("Unpaired electrons (uhf) cannot be negative.") }
        if let t = timeout, t <= 0 { e.append("Timeout must be positive.") }
        if solvationModel != .none {
            let s = (solvent ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if s.isEmpty { e.append("Choose a solvent for \(solvationModel.title).") }
            else if !XTBSolvents.names(for: solvationModel).contains(s) && !(s == "h2o" && solvationModel != .none) {
                e.append("\(solvationModel.title) does not support the solvent \"\(solvent!)\".")
            }
            if method == .gfn0 { e.append("Implicit solvation is not available for GFN0-xTB.") }
        }
        if let m = molecule {
            if m.atoms.isEmpty { e.append("The molecule has no atoms.") }
            let ch = charge ?? m.charge
            let electrons = m.atoms.reduce(0) { $0 + $1.atomicNumber } - ch
            let u = uhf ?? max(0, m.multiplicity - 1)
            if method != .gfnff, !m.atoms.isEmpty, (electrons - u) % 2 != 0 {
                e.append("Charge \(ch) and \(u) unpaired electron(s) are inconsistent with \(electrons) electrons.")
            }
        }
        for a in extraArguments where a.contains("\n") { e.append("Extra arguments cannot contain line breaks.") }
        return e
    }

    /// xtb arguments (without the executable).
    public func arguments(inputFile: String = "input.xyz", molecule: Molecule? = nil) -> [String] {
        var a = [inputFile] + method.flag
        let level = optLevel == .normal ? [] : [optLevel.rawValue]
        switch task {
        case .singlePoint: break
        case .optimize: a += ["--opt"] + level
        case .hessian: a += ["--ohess"] + level
        }
        if let n = maxCycles, task != .singlePoint { a += ["--cycles", String(n)] }
        let ch = charge ?? molecule?.charge ?? 0
        let u = uhf ?? max(0, (molecule?.multiplicity ?? 1) - 1)
        a += ["--chrg", String(ch), "--uhf", String(u)]
        if let f = solvationModel.flag, let s = solvent?.trimmingCharacters(in: .whitespaces), !s.isEmpty { a += [f, s] }
        if let t = electronicTemperature { a += ["--etemp", Self.format(t)] }
        if let acc = accuracy, acc != 1.0 { a += ["--acc", Self.format(acc)] }
        a += ["-P", String(max(1, threads))]
        a += extraArguments.filter { !$0.isEmpty }
        return a
    }

    /// Shell-quoted preview, e.g. `xtb input.xyz --gfn 2 --opt tight --cycles 3 --chrg 0 --uhf 0 --alpb water -P 4`.
    public func commandLine(molecule: Molecule? = nil, executable: String = "xtb") -> String {
        environmentPrefix("OMP_NUM_THREADS", "\(max(1, threads)),1") + shellQuoted([executable] + arguments(molecule: molecule))
    }

    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        // Case-insensitive on Windows, so an inherited `Omp_Num_Threads` is replaced rather than duplicated.
        ProgramLocator.setEnvironmentValue("\(max(1, threads)),1", forKey: "OMP_NUM_THREADS", in: &env)
        ProgramLocator.setEnvironmentValue(ProgramLocator.environmentValue("OMP_STACKSIZE", in: env) ?? "512M",
                                           forKey: "OMP_STACKSIZE", in: &env)
        ProgramLocator.setEnvironmentValue("1", forKey: "OMP_MAX_ACTIVE_LEVELS", in: &env)
        return env
    }

    static func format(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(Int(x)) : String(x)
    }
}
