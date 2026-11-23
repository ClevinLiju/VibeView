import Foundation
import MolCore

// CalcSpec: pure, testable description of a Gaussian calculation, and the generator for its input file.
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
        "\(kind.letter) " + atoms.map(String.init).joined(separator: " ") + " S \(steps) " + CalcSpec.fixed(stepSize, 6)
    }
}

public struct CalcSpec: Sendable, Codable, Equatable {
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

    public var nprocShared: Int = 4
    public var memory: String = "4GB"
    public var checkpoint: String? = nil
    public var extraKeywords: String = ""
    public var printLevel: PrintLevel = .additional
    public var title: String = ""

    public init() {}

    public init(molecule: Molecule) {
        self.charge = molecule.charge
        self.multiplicity = molecule.multiplicity
        self.title = molecule.title
    }

    public static let methods = ["B3LYP", "HF", "MP2", "M06-2X", "wB97X-D", "PBE0", "CAM-B3LYP"]
    public static let bases = ["STO-3G", "6-31G(d)", "6-31+G(d,p)", "6-311+G(d,p)", "def2-SVP", "def2-TZVP", "cc-pVDZ", "aug-cc-pVTZ", "LANL2DZ"]

    /// (display title, Gaussian Solvent= keyword)
    public static let solventList: [(title: String, keyword: String)] = [
        ("Water", "Water"), ("Acetonitrile", "Acetonitrile"), ("Methanol", "Methanol"), ("Ethanol", "Ethanol"),
        ("DMSO", "DiMethylSulfoxide"), ("Chloroform", "Chloroform"), ("Dichloromethane", "Dichloromethane"),
        ("Toluene", "Toluene"), ("Benzene", "Benzene"), ("THF", "TetraHydroFuran"), ("Acetone", "Acetone"),
        ("n-Hexane", "n-Hexane"), ("Cyclohexane", "CycloHexane"), ("Diethyl ether", "DiethylEther"),
        ("DMF", "N,N-DiMethylFormamide"), ("Heptane", "Heptane"),
    ]
    public static var solvents: [String] { solventList.map(\.keyword) }

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
        case .pcm(let s): parts.append("SCRF=(PCM,Solvent=\(s))")
        case .smd(let s): parts.append("SCRF=(SMD,Solvent=\(s))")
        }
        let extra = extraKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append(extra) }
        return printLevel.rawValue + " " + parts.joined(separator: " ")
    }

    public func link0Lines() -> [String] {
        var l: [String] = []
        if nprocShared > 0 { l.append("%nprocshared=\(nprocShared)") }
        let mem = memory.trimmingCharacters(in: .whitespaces)
        if !mem.isEmpty { l.append("%mem=\(mem)") }
        if let c = checkpoint?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            l.append("%chk=" + (c.contains(".") ? c : c + ".chk"))
        }
        return l
    }

    /// Trailing input section (ModRedundant lines) or empty.
    public func trailerLines() -> [String] {
        jobType == .scan ? scanCoordinates.map(\.modRedundantLine) : []
    }

    public func inputText(molecule: Molecule) -> String {
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
        if method.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Choose a method.") }
        if basis.trimmingCharacters(in: .whitespaces).isEmpty && !Self.basisOptional(method) { p.append("Choose a basis set.") }
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
        return ["AM1", "PM3", "PM6", "PM7", "PM3MM", "RM1", "INDO", "CNDO"].contains(m)
    }
}
