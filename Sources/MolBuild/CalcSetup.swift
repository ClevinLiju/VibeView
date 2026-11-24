import Foundation
import MolCore
import simd

// CalcSetup: pure, testable description of a quantum-chemistry calculation (Gaussian, ORCA, Q-Chem, xtb)
// and the generators for their input files. The Gaussian format below is the stable, documented one;
// the other programs live in CalcPrograms.swift.
//
// OUTPUT FORMAT (documented, stable):
//   %nprocshared=N            (omitted if N <= 0)
//   %mem=4GB                  (omitted if empty)
//   %chk=name.chk             (omitted if nil/empty; ".chk" appended when the name has no extension)
//   #p METHOD/BASIS <job keywords> [SCRF=(...)] [extra keywords]
//   <blank>
//   <title>                   (spec.title, else molecule.title, else "VibeView calculation")
//   <blank>
//   <charge> <multiplicity>
//   " %-2s %14.8f %14.8f %14.8f"   one line per atom (symbol left-aligned width 2, Å; -0.0 normalised to 0)
//   <blank>
//   [ModRedundant scan lines, one per line, e.g. "B 1 2 S 10 0.100000"]
//   <blank>                   (only after a trailer section; without trailer the single blank after atoms ends the file)
// Job keyword order: job keywords, then SCRF, then extra keywords. Keywords use Gaussian's usual capitalisation.

public enum JobType: String, CaseIterable, Identifiable, Sendable, Codable {
    case energy, optimize, frequency, optFreq, scan, irc, transitionState, excitedStates, nmr
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .energy: "Single-Point Energy"
        case .optimize: "Geometry Optimization"
        case .frequency: "Vibrational Frequencies"
        case .optFreq: "Optimize + Frequencies"
        case .scan: "Relaxed Coordinate Scan"
        case .irc: "Reaction Path (IRC)"
        case .transitionState: "Transition-State Search"
        case .excitedStates: "Excited States (TD-DFT)"
        case .nmr: "NMR Shielding"
        }
    }
}

public enum Solvation: Sendable, Codable, Equatable {
    case none
    case pcm(String)
    case smd(String)
    public var solvent: String? {
        switch self { case .none: nil; case .pcm(let s), .smd(let s): s }
    }
    public var model: String { switch self { case .none: "None"; case .pcm: "PCM"; case .smd: "SMD" } }
    public var isNone: Bool { if case .none = self { return true } else { return false } }
}

public enum IRCDirection: String, CaseIterable, Identifiable, Sendable, Codable {
    case both, forward, reverse
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum TDSpinKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case unspecified, singlets, triplets, fiftyFifty
    public var id: String { rawValue }
    public var title: String {
        switch self { case .unspecified: "Default"; case .singlets: "Singlets only"; case .triplets: "Triplets only"; case .fiftyFifty: "50% / 50%" }
    }
}

public enum PrintLevel: String, CaseIterable, Identifiable, Sendable, Codable {
    case normal = "#", additional = "#p", terse = "#n"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .normal: "Normal (#)"; case .additional: "Additional (#p)"; case .terse: "Terse (#n)" }
    }
}

public enum ScanKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case bond, angle, dihedral
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var atomCount: Int { switch self { case .bond: 2; case .angle: 3; case .dihedral: 4 } }
    var letter: String { switch self { case .bond: "B"; case .angle: "A"; case .dihedral: "D" } }
}

public struct ScanCoordinate: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var kind: ScanKind
    public var atoms: [Int]          // 1-based (as written to the input file)
    public var steps: Int
    public var stepSize: Double      // Å for bonds, degrees for angle/dihedral
    public init(kind: ScanKind, atoms: [Int], steps: Int, stepSize: Double) {
        self.kind = kind; self.atoms = atoms; self.steps = steps; self.stepSize = stepSize
    }
    /// e.g. "B 1 2 S 10 0.100000"
    public var modRedundantLine: String {
        "\(kind.letter) " + atoms.map(String.init).joined(separator: " ") + " S \(steps) " + CalcSetup.fixed(stepSize, 6)
    }
    /// Current value in the given geometry (Å for bonds, degrees for angles/dihedrals); nil when atoms are out of range.
    public func currentValue(in molecule: Molecule) -> Double? {
        guard atoms.count == kind.atomCount, !atoms.contains(where: { $0 < 1 || $0 > molecule.atoms.count }) else { return nil }
        let p = atoms.map { molecule.atoms[$0 - 1].position }
        switch kind {
        case .bond: return simd_length(p[0] - p[1])
        case .angle:
            let a = simd_normalize(p[0] - p[1]), b = simd_normalize(p[2] - p[1])
            return acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi
        case .dihedral:
            let b0 = p[0] - p[1], b1 = simd_normalize(p[2] - p[1]), b2 = p[3] - p[2]
            let v = b0 - simd_dot(b0, b1) * b1, w = b2 - simd_dot(b2, b1) * b1
            let x = simd_dot(v, w), y = simd_dot(simd_cross(b1, v), w)
            return atan2(y, x) * 180 / .pi
        }
    }
}

public struct CalcSetup: Sendable, Codable, Equatable {
    public var jobType: JobType = .optimize
    public var method: String = "B3LYP"
    public var basis: String = "6-31G(d)"
    public var charge: Int = 0
    public var multiplicity: Int = 1
    public var solvation: Solvation = .none

    public var tdStates: Int = 10
    public var tdSpin: TDSpinKind = .unspecified
    public var ircDirection: IRCDirection = .both
    public var ircMaxPoints: Int = 20
    public var ircCalcFC: Bool = true
    public var tsCalcFC: Bool = true
    public var tsNoEigenTest: Bool = true
    public var scanCoordinates: [ScanCoordinate] = []

    public var program: QCProgram = .gaussian
    public var xtbMethod: XTBMethod = .gfn2
    public var nprocs: Int = 4
    public var memoryMB: Int = 4096
    public var checkpoint: String? = nil
    public var extraKeywords: String = ""
    public var printLevel: PrintLevel = .additional
    public var title: String = ""

    public init() {}

    public init(molecule: Molecule, program: QCProgram = .gaussian) {
        self.charge = molecule.charge
        self.multiplicity = molecule.multiplicity
        self.title = molecule.title
        self.program = program
        self.method = Self.defaultMethod(for: program)
        self.basis = Self.defaultBasis(for: program)
    }

    /// Switch program, resetting method/basis/solvent model when the current ones do not exist for the new program.
    public mutating func setProgram(_ p: QCProgram) {
        guard p != program else { return }
        program = p
        if !Self.methods(for: p).contains(method) { method = Self.defaultMethod(for: p) }
        if p == .xtb { basis = "" }
        else if basis.isEmpty || !Self.bases(for: p).contains(basis) { basis = Self.defaultBasis(for: p) }
        if !supportedJobTypes.contains(jobType) { jobType = .optimize }
        if p == .xtb, case .smd(let s) = solvation { solvation = .pcm(s) }
    }

    public var supportedJobTypes: [JobType] { Self.supportedJobTypes(for: program) }

    /// "4GB" / "512MB" / "2000" (MB) -> megabytes. Nil if unparseable.
    public static func parseMemoryMB(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return nil }
        let digits = t.prefix { $0.isNumber }
        guard let n = Int(digits), n > 0 else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "MB", "M": return n
        case "GB", "G": return n * 1024
        default: return nil
        }
    }

    // MARK: Catalogs

    public static func supportedJobTypes(for program: QCProgram) -> [JobType] {
        switch program {
        case .gaussian, .orca, .qchem: JobType.allCases
        case .xtb: [.energy, .optimize, .frequency, .optFreq]
        }
    }

    public static func methods(for program: QCProgram) -> [String] {
        switch program {
        case .gaussian: ["B3LYP", "HF", "MP2", "M06-2X", "wB97X-D", "PBE0", "CAM-B3LYP"]
        case .orca: ["B3LYP", "PBE0", "wB97X-D3", "M06-2X", "TPSS", "CAM-B3LYP", "B2PLYP", "HF", "MP2", "DLPNO-CCSD(T)", "r2SCAN-3c", "B97-3c", "HF-3c", "PBEh-3c"]
        case .qchem: ["B3LYP", "PBE0", "PBE", "wB97X-D", "wB97M-V", "M06-2X", "CAM-B3LYP", "HF", "MP2"]
        case .xtb: XTBMethod.allCases.map(\.title)
        }
    }

    public static func bases(for program: QCProgram) -> [String] {
        switch program {
        case .gaussian: ["STO-3G", "6-31G(d)", "6-31+G(d,p)", "6-311+G(d,p)", "def2-SVP", "def2-TZVP", "cc-pVDZ", "aug-cc-pVTZ", "LANL2DZ"]
        case .orca: ["STO-3G", "6-31G(d)", "6-31+G(d,p)", "def2-SVP", "def2-TZVP", "def2-TZVPP", "def2-QZVP", "ma-def2-SVP", "cc-pVDZ", "cc-pVTZ", "aug-cc-pVDZ"]
        case .qchem: ["STO-3G", "6-31G*", "6-31+G*", "6-311+G(d,p)", "def2-SVP", "def2-TZVP", "cc-pVDZ", "cc-pVTZ", "aug-cc-pVTZ"]
        case .xtb: []
        }
    }

    public static func defaultMethod(for p: QCProgram) -> String { p == .xtb ? XTBMethod.gfn2.title : "B3LYP" }
    public static func defaultBasis(for p: QCProgram) -> String {
        switch p { case .gaussian: "6-31G(d)"; case .orca: "def2-SVP"; case .qchem: "6-31G*"; case .xtb: "" }
    }

    // Convenience (Gaussian catalogs, kept for existing callers)
    public static let methods = methods(for: .gaussian)
    public static let bases = bases(for: .gaussian)

    public struct SolventInfo: Sendable {
        public let title: String
        public let gaussian: String
        public let orca: String?
        public let qchem: String?
        public let xtb: String?
    }

    /// One row per solvent with the keyword each program expects (nil = not available there).
    public static let solventTable: [SolventInfo] = [
        .init(title: "Water", gaussian: "Water", orca: "Water", qchem: "water", xtb: "water"),
        .init(title: "Acetonitrile", gaussian: "Acetonitrile", orca: "Acetonitrile", qchem: "acetonitrile", xtb: "acetonitrile"),
        .init(title: "Methanol", gaussian: "Methanol", orca: "Methanol", qchem: "methanol", xtb: "methanol"),
        .init(title: "Ethanol", gaussian: "Ethanol", orca: "Ethanol", qchem: "ethanol", xtb: nil),
        .init(title: "DMSO", gaussian: "DiMethylSulfoxide", orca: "DMSO", qchem: "dimethylsulfoxide", xtb: "dmso"),
        .init(title: "Chloroform", gaussian: "Chloroform", orca: "Chloroform", qchem: "chloroform", xtb: "chcl3"),
        .init(title: "Dichloromethane", gaussian: "Dichloromethane", orca: "CH2Cl2", qchem: "dichloromethane", xtb: "ch2cl2"),
        .init(title: "Toluene", gaussian: "Toluene", orca: "Toluene", qchem: "toluene", xtb: "toluene"),
        .init(title: "Benzene", gaussian: "Benzene", orca: "Benzene", qchem: "benzene", xtb: "benzene"),
        .init(title: "THF", gaussian: "TetraHydroFuran", orca: "THF", qchem: "tetrahydrofuran", xtb: "thf"),
        .init(title: "Acetone", gaussian: "Acetone", orca: "Acetone", qchem: "acetone", xtb: "acetone"),
        .init(title: "n-Hexane", gaussian: "n-Hexane", orca: "Hexane", qchem: "hexane", xtb: "hexane"),
        .init(title: "Cyclohexane", gaussian: "CycloHexane", orca: "Cyclohexane", qchem: "cyclohexane", xtb: nil),
        .init(title: "Diethyl ether", gaussian: "DiethylEther", orca: "Ether", qchem: "diethylether", xtb: "ether"),
        .init(title: "DMF", gaussian: "N,N-DiMethylFormamide", orca: "DMF", qchem: "dimethylformamide", xtb: "dmf"),
        .init(title: "Heptane", gaussian: "Heptane", orca: "Heptane", qchem: "heptane", xtb: nil),
    ]
    public static let solventList: [(title: String, keyword: String)] = solventTable.map { ($0.title, $0.gaussian) }
    public static var solvents: [String] { solventTable.map(\.title) }

    /// Finds a table row by display title or Gaussian keyword (case-insensitive).
    public static func solventInfo(_ name: String) -> SolventInfo? {
        let n = name.lowercased()
        return solventTable.first { $0.title.lowercased() == n || $0.gaussian.lowercased() == n }
    }
    /// Solvent keyword for a program; falls back to the raw name for custom solvents.
    public static func solventKeyword(_ name: String, program: QCProgram) -> String {
        guard let i = solventInfo(name) else { return name }
        switch program {
        case .gaussian: return i.gaussian
        case .orca: return i.orca ?? name
        case .qchem: return i.qchem ?? name
        case .xtb: return i.xtb ?? name
        }
    }

    // MARK: Generation

    public func routeLine() -> String {
        var parts: [String] = []
        let level = basis.isEmpty ? method : "\(method)/\(basis)"
        parts.append(level)
        switch jobType {
        case .energy: parts.append("SP")
        case .optimize: parts.append("Opt")
        case .frequency: parts.append("Freq")
        case .optFreq: parts.append("Opt Freq")
        case .scan: parts.append("Opt=ModRedundant")
        case .irc:
            var o: [String] = []
            if ircCalcFC { o.append("CalcFC") }
            o.append("MaxPoints=\(ircMaxPoints)")
            if ircDirection == .forward { o.append("Forward") } else if ircDirection == .reverse { o.append("Reverse") }
            parts.append("IRC=(" + o.joined(separator: ",") + ")")
        case .transitionState:
            var o = ["TS"]
            if tsCalcFC { o.append("CalcFC") }
            if tsNoEigenTest { o.append("NoEigenTest") }
            parts.append(o.count == 1 ? "Opt=TS" : "Opt=(" + o.joined(separator: ",") + ")")
        case .excitedStates:
            var o = ["NStates=\(tdStates)"]
            switch tdSpin {
            case .unspecified: break
            case .singlets: o.append("Singlets")
            case .triplets: o.append("Triplets")
            case .fiftyFifty: o.append("50-50")
            }
            parts.append("TD=(" + o.joined(separator: ",") + ")")
        case .nmr: parts.append("NMR=GIAO")
        }
        switch solvation {
        case .none: break
        case .pcm(let s): parts.append("SCRF=(PCM,Solvent=\(Self.solventKeyword(s, program: .gaussian)))")
        case .smd(let s): parts.append("SCRF=(SMD,Solvent=\(Self.solventKeyword(s, program: .gaussian)))")
        }
        let extra = extraKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append(extra) }
        return printLevel.rawValue + " " + parts.joined(separator: " ")
    }

    public func link0Lines() -> [String] {
        var l: [String] = []
        if nprocs > 0 { l.append("%nprocshared=\(nprocs)") }
        if memoryMB > 0 { l.append(memoryMB % 1024 == 0 ? "%mem=\(memoryMB / 1024)GB" : "%mem=\(memoryMB)MB") }
        if let c = checkpoint?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            l.append("%chk=" + (c.contains(".") ? c : c + ".chk"))
        }
        return l
    }

    /// Trailing input section (ModRedundant lines) or empty.
    public func trailerLines() -> [String] {
        jobType == .scan ? scanCoordinates.map(\.modRedundantLine) : []
    }

    public func gaussianInputText(molecule: Molecule) -> String {
        var out = link0Lines()
        out.append(routeLine())
        out.append("")
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let mt = molecule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(t.isEmpty ? (mt.isEmpty ? "VibeView calculation" : mt) : t)
        out.append("")
        out.append("\(charge) \(multiplicity)")
        for a in molecule.atoms {
            let sym = BuildElements.symbol(a.atomicNumber)
            let pad = String(repeating: " ", count: max(0, 2 - sym.count))
            out.append(" \(sym)\(pad) " + Self.fixed(a.position.x, 8, 14) + " " + Self.fixed(a.position.y, 8, 14) + " " + Self.fixed(a.position.z, 8, 14))
        }
        out.append("")
        let trailer = trailerLines()
        if !trailer.isEmpty { out += trailer; out.append("") }
        return out.joined(separator: "\n") + "\n"
    }

    /// Input file text for the selected program (for xtb: the XYZ geometry file).
    public func inputText(molecule: Molecule) -> String {
        switch program {
        case .gaussian: gaussianInputText(molecule: molecule)
        case .orca: orcaInputText(molecule: molecule)
        case .qchem: qchemInputText(molecule: molecule)
        case .xtb: xtbInputText(molecule: molecule)
        }
    }

    static func fixed(_ v: Double, _ decimals: Int, _ width: Int = 0) -> String {
        var x = v
        if abs(x) < 0.5 * pow(10, -Double(decimals)) { x = 0 }
        let s = String(format: "%.\(decimals)f", x)
        return s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    // MARK: Validation

    public func validate(molecule: Molecule) -> [String] {
        var p: [String] = []
        if molecule.atoms.isEmpty { p.append("The molecule has no atoms.") }
        if !supportedJobTypes.contains(jobType) { p.append("\(program.title) does not support \(jobType.title.lowercased()) here.") }
        if program != .xtb {
            if method.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Choose a method.") }
            if basis.trimmingCharacters(in: .whitespaces).isEmpty && !Self.basisOptional(method) { p.append("Choose a basis set.") }
        }
        if nprocs < 1 { p.append("Use at least 1 processor core.") }
        if let sv = solvation.solvent, program == .xtb, Self.solventInfo(sv)?.xtb == nil, Self.solventInfo(sv) != nil {
            p.append("xtb has no ALPB parameters for \(sv).")
        }
        if program == .xtb && solvation.model == "SMD" { p.append("xtb uses ALPB implicit solvation; SMD is not available.") }
        if multiplicity < 1 {
            p.append("Multiplicity must be at least 1.")
        } else if !molecule.atoms.isEmpty {
            let electrons = molecule.atoms.reduce(0) { $0 + $1.atomicNumber } - charge
            if electrons < 0 {
                p.append("Charge \(charge) removes more electrons than the molecule has.")
            } else {
                if multiplicity > electrons + 1 { p.append("Multiplicity \(multiplicity) is too high for \(electrons) electrons.") }
                else if electrons % 2 == 0 && multiplicity % 2 == 0 {
                    p.append("\(electrons) electrons (even) require an odd multiplicity (1, 3, ...), not \(multiplicity).")
                } else if electrons % 2 == 1 && multiplicity % 2 == 1 {
                    p.append("\(electrons) electrons (odd) require an even multiplicity (2, 4, ...), not \(multiplicity).")
                }
            }
        }
        if jobType == .scan {
            if scanCoordinates.isEmpty { p.append("Add at least one scan coordinate.") }
            for (i, c) in scanCoordinates.enumerated() {
                let n = i + 1
                if c.atoms.count != c.kind.atomCount { p.append("Scan coordinate \(n): a \(c.kind.rawValue) needs \(c.kind.atomCount) atoms.") }
                if c.atoms.contains(where: { $0 < 1 || $0 > molecule.atoms.count }) {
                    p.append("Scan coordinate \(n): atom number out of range (1–\(molecule.atoms.count)).")
                }
                if Set(c.atoms).count != c.atoms.count { p.append("Scan coordinate \(n): atoms must be distinct.") }
                if c.steps < 1 { p.append("Scan coordinate \(n): needs at least 1 step.") }
            }
        }
        if jobType == .excitedStates && tdStates < 1 { p.append("Number of excited states must be at least 1.") }
        if jobType == .irc && ircMaxPoints < 1 { p.append("IRC needs at least 1 point.") }
        return p
    }

    static func basisOptional(_ method: String) -> Bool {
        let m = method.uppercased()
        return ["AM1", "PM3", "PM6", "PM7", "PM3MM", "RM1", "INDO", "CNDO", "R2SCAN-3C", "B97-3C", "HF-3C", "PBEH-3C"].contains(m)
    }
}
