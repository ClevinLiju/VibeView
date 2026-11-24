import Foundation
import MolCore

// Shared helpers for all MolIO readers/writers (owned by Lead 2).

/// Bohr → Ångström (CODATA 2018).
public let bohrToAngstrom: Double = 0.529177210903
public let angstromToBohr: Double = 1.0 / 0.529177210903

public enum MolIOError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)                                  // path or reason
    case parse(format: String, line: Int?, message: String)  // line is 1-based when known
    case unsupported(String)

    public var description: String {
        switch self {
        case .unreadable(let s): return "cannot read \(s)"
        case .parse(let f, let l, let m): return "\(f) parse error\(l.map { " at line \($0)" } ?? ""): \(m)"
        case .unsupported(let s): return "unsupported: \(s)"
        }
    }
}

/// Private element lookup (to be replaced by Lead 1's MolCore element table once it lands).
/// Z = 0 is used for dummy / ghost atoms ("X", "Bq").
public enum IOElements {
    public static let symbols: [String] = [
        "X",
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne",
        "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar", "K", "Ca",
        "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn",
        "Ga", "Ge", "As", "Se", "Br", "Kr", "Rb", "Sr", "Y", "Zr",
        "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn",
        "Sb", "Te", "I", "Xe", "Cs", "Ba", "La", "Ce", "Pr", "Nd",
        "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb",
        "Lu", "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg",
        "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra", "Ac", "Th",
        "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm",
        "Md", "No", "Lr", "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds",
        "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og",
    ]
    private static let table: [String: Int] = {
        var d: [String: Int] = [:]
        for (z, s) in symbols.enumerated() { d[s.uppercased()] = z }
        d["BQ"] = 0; d["GH"] = 0; d["D"] = 1; d["T"] = 1
        return d
    }()

    /// Symbol for Z ("X" for 0 or out-of-range).
    public static func symbol(_ z: Int) -> String { (z >= 0 && z < symbols.count) ? symbols[z] : "X" }

    /// Exact symbol match, case-insensitive ("cl", "CL", "Cl" → 17).
    public static func atomicNumber(exact s: String) -> Int? { table[s.uppercased()] }

    /// Lenient match for labels such as "C1", "C-CA-0.1", "Cl(Fragment=2)", "H_a", "16" (numeric Z).
    public static func atomicNumber(label raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let z = Int(s), z >= 0, z < symbols.count { return z }
        let letters = s.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }
        if letters.count >= 2, let z = table[String(letters.prefix(2)).uppercased()] { return z }
        return table[String(letters.prefix(1)).uppercased()]
    }
}

/// Split text into lines, accepting \n, \r\n and \r.
func splitLines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
}

/// Whitespace tokenization.
@inline(__always)
func tokens<S: StringProtocol>(_ s: S) -> [Substring] where S.SubSequence == Substring {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" })
}

/// Parse a number that may use a Fortran exponent ("1.0D-03", "-0.5d+2").
public func parseFortranDouble<S: StringProtocol>(_ s: S) -> Double? {
    if let d = Double(s) { return d }
    let fixed = s.replacingOccurrences(of: "D", with: "E").replacingOccurrences(of: "d", with: "e")
    return Double(fixed)
}

/// Read a text file as UTF-8, falling back to Latin-1.
public func readText(_ url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url) else { throw MolIOError.unreadable(url.path) }
    if let s = String(data: data, encoding: .utf8) { return s }
    if let s = String(data: data, encoding: .isoLatin1) { return s }
    throw MolIOError.unreadable(url.path)
}
