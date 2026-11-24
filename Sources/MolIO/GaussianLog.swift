import Foundation
import MolCore

// Gaussian output (.log / .out) parser. Written from the publicly visible layout of the program's
// text output; no proprietary material was consulted.
//
// Truncation policy: a log of a job that died mid-way is still useful. Everything complete is kept,
// a partial trailing block (half an orientation table, a frequency block cut mid-mode, ...) is
// dropped and `normalTermination` is false. Parsing throws only when the text is not a Gaussian
// log at all, or when a block that is present is structurally corrupt (e.g. non-numeric
// coordinates inside an orientation table).

public struct GaussianLog: Sendable, Codable, Equatable {

    // MARK: Nested types

    /// One geometry printed by the program (an Input/Z-matrix orientation, optionally followed by the
    /// Standard orientation of the same step), with the SCF energy computed at it.
    public struct GeometryStep: Sendable, Codable, Equatable {
        public var input: Molecule?
        public var standard: Molecule?
        public var energy: Double?
        /// Preferred geometry: Standard orientation, else Input orientation.
        public var molecule: Molecule? { standard ?? input }
    }

    public struct SCFEnergy: Sendable, Codable, Equatable {
        /// e.g. "RB3LYP", "UHF"
        public var method: String
        public var energy: Double
        public var cycles: Int?
        /// Index into `geometrySteps` this energy was computed at (nil if no geometry preceded it).
        public var geometryIndex: Int?
    }

    public struct ConvergenceCriterion: Sendable, Codable, Equatable {
        public var name: String       // "Maximum Force", "RMS     Force", "Maximum Displacement", "RMS     Displacement"
        public var value: Double
        public var threshold: Double
        public var converged: Bool
    }

    public struct OptimizationStep: Sendable, Codable, Equatable {
        /// "Step number N" as printed when available, else a running count.
        public var stepNumber: Int
        /// Relaxed-scan point (1-based) this step belongs to, if any.
        public var scanPoint: Int?
        public var geometryIndex: Int?
        public var energy: Double?
        public var criteria: [ConvergenceCriterion]
        public var predictedEnergyChange: Double?
        /// True iff all four criteria are YES.
        public var converged: Bool
    }

    public struct ScanPoint: Sendable, Codable, Equatable {
        public var index: Int         // 1-based scan point
        public var total: Int?
        public var energy: Double?
        public var geometry: Molecule?
        public var geometryIndex: Int?
    }

    /// A row of "Summary of the potential surface scan": N, scanned coordinate values, energy.
    public struct ScanSummaryRow: Sendable, Codable, Equatable {
        public var index: Int
        public var coordinates: [Double]
        public var energy: Double
    }

    public struct IRCPoint: Sendable, Codable, Equatable {
        public var path: Int          // 1 = forward, 2 = reverse as printed
        public var point: Int
        public var reactionCoordinate: Double?
        public var energy: Double?
        public var geometry: Molecule?
    }

    public struct Vibration: Sendable, Codable, Equatable {
        public var frequency: Double
        public var reducedMass: Double?
        public var forceConstant: Double?
        public var irIntensity: Double?
        public var ramanActivity: Double?
        public var depolarizationP: Double?
        public var depolarizationU: Double?
        public var symmetry: String?
        public var displacements: [Vec3]
        public var normalMode: NormalMode {
            NormalMode(frequency: frequency, irIntensity: irIntensity ?? 0, ramanActivity: ramanActivity,
                       symmetry: symmetry, displacements: displacements)
        }
    }

    public struct Thermochemistry: Sendable, Codable, Equatable {
        public var temperature: Double?                 // K
        public var pressure: Double?                    // atm
        public var zeroPointCorrection: Double?         // Hartree
        public var thermalCorrectionEnergy: Double?
        public var thermalCorrectionEnthalpy: Double?
        public var thermalCorrectionGibbs: Double?
        public var sumElectronicZeroPoint: Double?
        public var sumElectronicThermalEnergy: Double?
        public var sumElectronicThermalEnthalpy: Double?
        public var sumElectronicThermalGibbs: Double?
        public var isComplete: Bool {
            zeroPointCorrection != nil && thermalCorrectionEnergy != nil && thermalCorrectionEnthalpy != nil
                && thermalCorrectionGibbs != nil && sumElectronicZeroPoint != nil && sumElectronicThermalEnergy != nil
                && sumElectronicThermalEnthalpy != nil && sumElectronicThermalGibbs != nil
        }
    }

    /// Orbital energies (Hartree) of the last printed set.
    public struct Orbitals: Sendable, Codable, Equatable {
        public var alphaOccupied: [Double] = []
        public var alphaVirtual: [Double] = []
        public var betaOccupied: [Double] = []
        public var betaVirtual: [Double] = []
        public var isUnrestricted: Bool { !betaOccupied.isEmpty || !betaVirtual.isEmpty }
        public var isEmpty: Bool { alphaOccupied.isEmpty && alphaVirtual.isEmpty && betaOccupied.isEmpty && betaVirtual.isEmpty }
        public var alpha: [Double] { alphaOccupied + alphaVirtual }
        public var beta: [Double] { betaOccupied + betaVirtual }
        public var alphaHOMO: Double? { alphaOccupied.last }
        public var alphaLUMO: Double? { alphaVirtual.first }
        public var betaHOMO: Double? { betaOccupied.last }
        public var betaLUMO: Double? { betaVirtual.first }
        /// Highest occupied orbital energy over both spins.
        public var homo: Double? {
            switch (alphaHOMO, betaHOMO) {
            case let (a?, b?): return max(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        /// Lowest unoccupied orbital energy over both spins.
        public var lumo: Double? {
            switch (alphaLUMO, betaLUMO) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        /// HOMO-LUMO gap in Hartree.
        public var gap: Double? { if let h = homo, let l = lumo { return l - h }; return nil }
    }

    public struct Transition: Sendable, Codable, Equatable {
        public enum Spin: String, Sendable, Codable { case alpha, beta }
        public var from: Int
        public var to: Int
        public var coefficient: Double
        /// "A"/"B" suffix in unrestricted calculations.
        public var spin: Spin?
        /// True for "<-" lines (de-excitation amplitudes).
        public var isDeexcitation: Bool
    }

    public struct ExcitedStateDetail: Sendable, Codable, Equatable {
        public var index: Int
        public var label: String              // e.g. "Singlet-A\""
        public var multiplicity: Int?
        public var symmetry: String?
        public var energyEV: Double
        public var wavelengthNM: Double
        public var oscillatorStrength: Double
        public var s2: Double?
        public var totalEnergy: Double?       // Hartree, "Total Energy, E(TD-HF/TD-DFT)"
        public var transitions: [Transition]
    }

    // MARK: Stored properties

    public var programVersion: String?
    public var routeSections: [String] = []
    public var title: String = ""
    public var charge: Int = 0
    public var multiplicity: Int = 1
    /// Number of jobs in the file (Link1 chains), at least 1 for a recognized log.
    public var jobCount: Int = 0
    /// Number of "Normal termination of Gaussian" lines.
    public var normalTerminationCount: Int = 0
    /// True iff the last job ended with "Error termination".
    public var errorTermination: Bool = false
    public var errorMessage: String?

    public var geometrySteps: [GeometryStep] = []
    public var scfEnergies: [SCFEnergy] = []
    public var optimizationSteps: [OptimizationStep] = []
    public var optimizationCompleted: Bool = false
    public var stationaryPointFound: Bool = false
    public var scanPoints: [ScanPoint] = []
    public var scanSummary: [ScanSummaryRow] = []
    public var ircPoints: [IRCPoint] = []

    /// Vibrations of the last frequency calculation (high-precision modes preferred when present).
    public var vibrations: [Vibration] = []
    public var hasHighPrecisionModes: Bool = false
    /// "Low frequencies ---" values of the last frequency job, as printed.
    public var lowFrequencies: [Double] = []
    public var thermochemistries: [Thermochemistry] = []
    public var thermochemistry: Thermochemistry? { thermochemistries.last }

    public var orbitals = Orbitals()
    public var mullikenCharges: [Double] = []
    public var mullikenSpinDensities: [Double] = []
    public var aptCharges: [Double] = []
    public var naturalCharges: [Double] = []
    public var hirshfeldCharges: [Double] = []
    public var cm5Charges: [Double] = []
    public var hirshfeldSpinDensities: [Double] = []
    /// Debye.
    public var dipole: Vec3?
    public var dipoleMagnitude: Double?
    public var excitedStates: [ExcitedStateDetail] = []

    /// Contract view for the rest of the app.
    public var result = CalculationResult()

    public init() {}

    // MARK: Derived views

    public var inputOrientations: [Molecule] { geometrySteps.compactMap(\.input) }
    public var standardOrientations: [Molecule] { geometrySteps.compactMap(\.standard) }
    public var normalTermination: Bool { result.normalTermination }
    public var firstRoute: String { routeSections.first ?? "" }

    // MARK: Entry points

    public static func parse(_ text: String) throws -> GaussianLog {
        var p = GaussianLogParser(lines: splitLines(text))
        try p.run()
        return try p.finish()
    }

    public static func read(url: URL) throws -> GaussianLog {
        try parse(try readText(url))
    }
}

// MARK: - Parser core

struct GaussianLogParser {
    let lines: [Substring]
    var log = GaussianLog()
    var recognized = false

    // jobs
    var enteringCount = 0
    var jobNormal: [Bool] = []
    var jobError: [Bool] = []
    var jobErrorLine: [String?] = []

    // molecule state
    var charge = 0
    var multiplicity = 1
    var title = ""
    var titleSet = false
    var natoms = 0          // from the latest orientation table or NAtoms=

    // opt / scan / irc state
    var pendingStepNumber: Int?
    var currentScanPoint: Int?
    var currentScanTotal: Int?
    var currentIRC: (point: Int, path: Int)?
    var runningOptCount = 0

    // frequency state
    var stdModes: [GaussianLog.Vibration] = []
    var hpModes: [GaussianLog.Vibration] = []
    var lastLowFreqLine = -10

    // orbital state
    var alphaLastVirtual = false
    var betaLastVirtual = false

    init(lines: [Substring]) { self.lines = lines }

    var n: Int { lines.count }

    func err(_ i: Int, _ msg: String) -> MolIOError {
        .parse(format: "Gaussian log", line: i + 1, message: msg)
    }

    /// True when every line after `i` is blank (the position is the tail of a truncated file).
    func isTail(_ i: Int) -> Bool {
        var k = i + 1
        while k < n { if !glTrim(lines[k]).isEmpty { return false }; k += 1 }
        return true
    }

    mutating func ensureJob() {
        if jobNormal.isEmpty { jobNormal.append(false); jobError.append(false); jobErrorLine.append(nil) }
    }

    mutating func startJob() {
        jobNormal.append(false); jobError.append(false); jobErrorLine.append(nil)
    }

    mutating func run() throws {
        var i = 0
        while i < n {
            let t = glTrim(lines[i])
            guard let c = t.first else { i += 1; continue }
            switch c {
            case "#":
                i = handleRoute(i, t)
            case "E":
                if t.hasPrefix("Entering Gaussian System") { recognized = true; enteringCount += 1; startJob(); i += 1 }
                else if t.hasPrefix("Error termination") { recognized = true; ensureJob(); jobError[jobError.count - 1] = true
                    if jobErrorLine[jobErrorLine.count - 1] == nil || t.hasPrefix("Error termination via") { jobErrorLine[jobErrorLine.count - 1] = String(t) }
                    i += 1 }
                else if t.hasPrefix("Excited State") { i = try handleExcitedState(i, t) }
                else { i += 1 }
            case "L":
                // "Link1:  Proceeding to internal job step number  2." starts a new job without a new
                // "Entering Gaussian System" banner (opt freq, --Link1-- inputs).
                if t.hasPrefix("Low frequencies ---") { try handleLowFrequencies(i, t) }
                else if t.hasPrefix("Link1:") && t.contains("Proceeding to internal job step") { recognized = true; enteringCount += 1; startJob() }
                i += 1
            case "G":
                if log.programVersion == nil, t.hasPrefix("Gaussian "), isVersionLine(t) { log.programVersion = String(t); recognized = true }
                i += 1
            case "N":
                if t.hasPrefix("Normal termination of Gaussian") {
                    recognized = true; ensureJob(); jobNormal[jobNormal.count - 1] = true; log.normalTerminationCount += 1; i += 1
                } else if t.hasPrefix("NAtoms=") {
                    let tk = tokens(t); if tk.count > 1, let v = Int(tk[1]), v > 0 { if natoms == 0 { natoms = v } }
                    i += 1
                } else if t.hasPrefix("NET REACTION COORDINATE UP TO THIS POINT") {
                    handleIRCNet(t); i += 1
                } else { i += 1 }
            case "C":
                if t.hasPrefix("Charge =") && t.contains("Multiplicity") { try handleCharge(i, t) } else { i += 1; continue }
                i += 1
            case "S":
                if t.hasPrefix("SCF Done:") { try handleSCF(i, t); i += 1 }
                else if t.hasPrefix("Standard orientation:") { i = try handleOrientation(i, standard: true) }
                else if t.hasPrefix("Symbolic Z-matrix:") { handleTitle(i); recognized = true; i += 1 }
                else if t.hasPrefix("Step number") { handleStepNumber(t); i += 1 }
                else if t.hasPrefix("Sum of electronic") { handleThermoLine(t); i += 1 }
                else if t.hasPrefix("Summary of the potential surface scan") { i = handleScanSummary(i) }
                else if t.hasPrefix("Summary of Natural Population Analysis") { i = try handleNaturalPopulation(i) }
                else { i += 1 }
            case "I":
                if t.hasPrefix("Input orientation:") { i = try handleOrientation(i, standard: false) }
                else if t.hasPrefix("Item") && t.contains("Converged?") { i = try handleConvergence(i) }
                else { i += 1 }
            case "Z":
                if t.hasPrefix("Z-Matrix orientation:") { i = try handleOrientation(i, standard: false) }
                else if t.hasPrefix("Zero-point correction=") { handleThermoLine(t); i += 1 }
                else { i += 1 }
            case "T":
                if t.hasPrefix("Thermal correction to") { handleThermoLine(t); i += 1 }
                else if t.hasPrefix("Temperature ") && t.contains("Kelvin") { handleTemperature(t); i += 1 }
                else if t.hasPrefix("Total Energy, E(") { handleTotalEnergy(t); i += 1 }
                else { i += 1 }
            case "M":
                if t.hasPrefix("Mulliken charges") || t.hasPrefix("Mulliken atomic charges") { i = try handleMulliken(i, t) }
                else { i += 1 }
            case "A":
                if t.hasPrefix("Alpha") && t.contains("eigenvalues --") { try handleEigenvalues(i, t, alpha: true); i += 1 }
                else if t.hasPrefix("APT charges:") || t.hasPrefix("APT atomic charges:") { i = try handleAPT(i) }
                else { i += 1 }
            case "B":
                if t.hasPrefix("Beta") && t.contains("eigenvalues --") { try handleEigenvalues(i, t, alpha: false) }
                i += 1
            case "D":
                if t.hasPrefix("Dipole moment") && t.contains("Debye") { i = try handleDipole(i) } else { i += 1 }
            case "F":
                if t.hasPrefix("Frequencies --") { i = try handleVibrationBlock(i, t) } else { i += 1 }
            case "H":
                if t.hasPrefix("Hirshfeld charges") { i = try handleHirshfeld(i) } else { i += 1 }
            case "O":
                if t.hasPrefix("Optimization completed") { handleOptimizationCompleted() }
                else if t.hasPrefix("Optimization stopped") { log.optimizationCompleted = false; log.stationaryPointFound = false }
                i += 1
            case "o":
                if t.hasPrefix("on scan point") { handleScanPointText(t) }
                i += 1
            case "P":
                if t.hasPrefix("Point Number:") { handlePointNumber(t) }
                else if t.hasPrefix("Predicted change in Energy") { handlePredicted(i, t) }
                i += 1
            case "-":
                if t.hasPrefix("-- Stationary point found") { log.stationaryPointFound = true }
                i += 1
            default:
                i += 1
            }
        }
    }

    func isVersionLine(_ t: Substring) -> Bool {
        // "Gaussian 16:  ES64L-G16RevC.01 3-Jul-2019"
        let tk = tokens(t)
        guard tk.count >= 2, tk[0] == "Gaussian", tk[1].hasSuffix(":") else { return false }
        return Int(tk[1].dropLast()) != nil
    }

    // MARK: Route / title / charge

    mutating func handleRoute(_ i: Int, _ t: Substring) -> Int {
        guard i > 0, glIsDashed(lines[i - 1]) else { return i + 1 }
        recognized = true
        ensureJob()
        var parts: [String] = [String(t)]
        var j = i + 1
        while j < n {
            let u = glTrim(lines[j])
            if glIsDashed(u) { break }
            if !u.isEmpty { parts.append(String(u)) }
            j += 1
        }
        // A route cut off before its closing rule is incomplete; keep what we have (still useful).
        log.routeSections.append(parts.joined(separator: " "))
        return j
    }

    mutating func handleTitle(_ i: Int) {
        // lines[i-1] dashed, title line(s), dashed.
        guard i >= 3, glIsDashed(lines[i - 1]) else { return }
        var k = i - 2
        var parts: [String] = []
        while k >= 0, !glIsDashed(lines[k]), parts.count < 6 { parts.insert(String(glTrim(lines[k])), at: 0); k -= 1 }
        guard k >= 0, glIsDashed(lines[k]) else { return }
        title = parts.joined(separator: " ")
        if !titleSet { log.title = title; titleSet = true }
    }

    mutating func handleCharge(_ i: Int, _ t: Substring) throws {
        recognized = true
        let tk = tokens(t.replacingOccurrences(of: "=", with: " = "))
        // Charge = c Multiplicity = m
        guard let ci = tk.firstIndex(where: { $0 == "Charge" }), let mi = tk.firstIndex(where: { $0 == "Multiplicity" }),
              ci + 2 < tk.count, mi + 2 < tk.count, let c = Int(tk[ci + 2]), let m = Int(tk[mi + 2]) else {
            if isTail(i) { return }
            throw err(i, "malformed Charge/Multiplicity line")
        }
        charge = c; multiplicity = m
        log.charge = c; log.multiplicity = m
    }

    // MARK: SCF

    mutating func handleSCF(_ i: Int, _ t: Substring) throws {
        recognized = true
        // SCF Done:  E(RB3LYP) =  -76.4089146     A.U. after   10 cycles
        guard let open = t.firstIndex(of: "("), let close = t[open...].firstIndex(of: ")"),
              let eq = t[close...].firstIndex(of: "=") else {
            if isTail(i) { return }
            throw err(i, "malformed SCF Done line")
        }
        let method = String(t[t.index(after: open)..<close])
        let rest = t[t.index(after: eq)...]
        let tk = tokens(rest)
        guard let first = tk.first, let e = parseFortranDouble(first) else {
            if isTail(i) { return }
            throw err(i, "non-numeric SCF energy")
        }
        var cycles: Int? = nil
        if let ai = tk.firstIndex(where: { $0 == "after" }), ai + 1 < tk.count { cycles = Int(tk[ai + 1]) }
        ensureJob()
        let gi = log.geometrySteps.isEmpty ? nil : log.geometrySteps.count - 1
        if let g = gi { log.geometrySteps[g].energy = e }
        log.scfEnergies.append(.init(method: method, energy: e, cycles: cycles, geometryIndex: gi))
    }

    // MARK: Finish

    mutating func finish() throws -> GaussianLog {
        guard recognized || !log.geometrySteps.isEmpty || !log.scfEnergies.isEmpty else {
            throw MolIOError.parse(format: "Gaussian log", line: nil, message: "not a Gaussian output file (no recognizable content)")
        }
        ensureJob()
        log.jobCount = max(1, max(enteringCount, jobNormal.count))
        log.errorTermination = jobError.last ?? false
        log.errorMessage = jobErrorLine.last ?? nil
        let normal = jobNormal.last ?? false

        log.hasHighPrecisionModes = !hpModes.isEmpty
        log.vibrations = hpModes.isEmpty ? stdModes : hpModes

        var r = CalculationResult()
        let withE = log.geometrySteps.filter { $0.energy != nil && $0.molecule != nil }
        if !withE.isEmpty {
            r.steps = withE.compactMap(\.molecule)
            r.energies = withE.compactMap(\.energy)
        } else {
            r.steps = log.geometrySteps.compactMap(\.molecule)
        }
        if !log.mullikenCharges.isEmpty, var last = r.steps.last, last.atoms.count == log.mullikenCharges.count {
            for k in 0..<last.atoms.count { last.atoms[k].charge = log.mullikenCharges[k] }
            r.steps[r.steps.count - 1] = last
        }
        r.normalModes = log.vibrations.map(\.normalMode)
        let o = log.orbitals
        let unres = o.isUnrestricted
        var idx = 1
        for e in o.alphaOccupied { r.orbitals.append(.init(index: idx, energy: e, occupied: true, spin: unres ? .alpha : .restricted)); idx += 1 }
        for e in o.alphaVirtual { r.orbitals.append(.init(index: idx, energy: e, occupied: false, spin: unres ? .alpha : .restricted)); idx += 1 }
        idx = 1
        for e in o.betaOccupied { r.orbitals.append(.init(index: idx, energy: e, occupied: true, spin: .beta)); idx += 1 }
        for e in o.betaVirtual { r.orbitals.append(.init(index: idx, energy: e, occupied: false, spin: .beta)); idx += 1 }
        r.excitedStates = log.excitedStates.map {
            ExcitedState(energyEV: $0.energyEV, wavelengthNM: $0.wavelengthNM, oscillatorStrength: $0.oscillatorStrength)
        }
        r.mullikenCharges = log.mullikenCharges
        r.dipole = log.dipole
        r.routeSection = log.routeSections.first ?? ""
        r.normalTermination = normal
        for (k, v) in zip(r.normalModes.indices, log.vibrations) {
            r.normalModes[k].reducedMass = v.reducedMass; r.normalModes[k].forceConstant = v.forceConstant
        }
        for (k, s) in log.excitedStates.enumerated() where k < r.excitedStates.count {
            r.excitedStates[k].multiplicity = s.multiplicity; r.excitedStates[k].symmetry = s.symmetry
        }
        var x = CalculationExtras()
        x.program = "gaussian"
        x.programVersion = log.programVersion
        x.finalEnergy = log.scfEnergies.last?.energy
        let schemes: [(String, [Double])] = [("Mulliken", log.mullikenCharges), ("APT", log.aptCharges), ("NBO", log.naturalCharges),
                                             ("Hirshfeld", log.hirshfeldCharges), ("CM5", log.cm5Charges)]
        for (name, q) in schemes where !q.isEmpty { x.charges[name] = q }
        if !log.mullikenSpinDensities.isEmpty { x.spinDensities["Mulliken"] = log.mullikenSpinDensities }
        if !log.hirshfeldSpinDensities.isEmpty { x.spinDensities["Hirshfeld"] = log.hirshfeldSpinDensities }
        if let t = log.thermochemistry {
            let e0 = t.sumElectronicZeroPoint.flatMap { s in t.zeroPointCorrection.map { s - $0 } }
            x.thermochemistry = ThermochemistrySummary(
                temperature: t.temperature, pressure: t.pressure, electronicEnergy: e0,
                zeroPointEnergy: t.zeroPointCorrection, thermalEnergyCorrection: t.thermalCorrectionEnergy,
                enthalpyCorrection: t.thermalCorrectionEnthalpy, gibbsCorrection: t.thermalCorrectionGibbs,
                totalEnthalpy: t.sumElectronicThermalEnthalpy, totalGibbs: t.sumElectronicThermalGibbs,
                entropy: t.thermalCorrectionEnthalpy.flatMap { h in t.thermalCorrectionGibbs.map { h - $0 } })
        }
        if let g = o.gap { x.homoLumoGapEV = g * 27.211386245988 }
        if !log.optimizationSteps.isEmpty { x.optimizationConverged = log.optimizationCompleted || log.stationaryPointFound }
        if let m = log.errorMessage, log.errorTermination { x.messages.append(m) }
        r.extras = x
        log.result = r
        return log
    }
}

// MARK: - Small text helpers

@inline(__always)
func glTrim(_ s: Substring) -> Substring {
    var a = s.startIndex, b = s.endIndex
    while a < b, s[a] == " " || s[a] == "\t" { a = s.index(after: a) }
    while b > a {
        let p = s.index(before: b)
        if s[p] == " " || s[p] == "\t" { b = p } else { break }
    }
    return s[a..<b]
}

/// A rule line: non-empty, only '-' (after trimming).
func glIsDashed(_ s: Substring) -> Bool {
    let t = glTrim(s)
    if t.count < 3 { return false }
    for ch in t where ch != "-" { return false }
    return true
}

/// Whitespace tokens, additionally splitting fixed-width numbers that touch each other
/// ("-100.12345-10.12345" -> two tokens).
func glNumberTokens(_ s: Substring) -> [Substring] {
    var out: [Substring] = []
    for tok in s.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        var start = tok.startIndex
        var prev: Character = " "
        var idx = tok.startIndex
        while idx < tok.endIndex {
            let ch = tok[idx]
            if ch == "-", idx != start, prev.isNumber || prev == "." {
                out.append(tok[start..<idx]); start = idx
            }
            prev = ch
            idx = tok.index(after: idx)
        }
        out.append(tok[start..<tok.endIndex])
    }
    return out
}

/// Text after the "--" (or "---") separator of "Label --   v1  v2" lines.
func glAfterDashes(_ t: Substring) -> Substring {
    guard let r = t.range(of: "--") else { return t[t.endIndex...] }
    var e = r.upperBound
    while e < t.endIndex, t[e] == "-" { e = t.index(after: e) }
    return t[e...]
}

/// Parse "key= value" pairs ("X=   0.1 Y= -0.2 Tot= 1.0").
func glKeyedValues(_ t: Substring) -> [String: Double] {
    var out: [String: Double] = [:]
    let tk = t.replacingOccurrences(of: "=", with: "= ").split(separator: " ")
    var k = 0
    while k < tk.count {
        let key = tk[k]
        if key.hasSuffix("="), k + 1 < tk.count {
            if let v = Double(tk[k + 1]) { out[String(key.dropLast())] = v }
            k += 2
        } else { k += 1 }
    }
    return out
}
