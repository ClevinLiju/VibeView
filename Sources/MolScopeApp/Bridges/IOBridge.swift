import Foundation
import MolCore
import MolIO

// INTEGRATION BRIDGE (owned by Lead 4). Single place where the app talks to MolIO.
// Until MolIO lands this contains minimal local fallbacks (XYZ + simple Gaussian input).

public struct LoadedFile: Sendable {
    public var molecule: Molecule
    public var result: CalculationResult?
}

public enum IOBridgeError: Error, LocalizedError {
    case unsupported(String), parse(String)
    public var errorDescription: String? {
        switch self { case .unsupported(let e): "Format '\(e)' is not supported yet."; case .parse(let m): "Could not read file: \(m)" }
    }
}

public enum IOBridge {
    public static func read(data: Data, ext: String) throws -> LoadedFile {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw IOBridgeError.parse("not text") }
        switch ext.lowercased() {
        case "xyz": return LoadedFile(molecule: try FallbackIO.readXYZ(text), result: nil)
        case "gjf", "com": return LoadedFile(molecule: try FallbackIO.readGJF(text), result: nil)
        default: throw IOBridgeError.unsupported(ext)
        }
    }

    public static func write(_ m: Molecule, ext: String) throws -> Data {
        switch ext.lowercased() {
        case "xyz": return Data(FallbackIO.writeXYZ(m).utf8)
        case "gjf", "com": return Data(FallbackIO.writeGJF(m, route: "#p b3lyp/6-31g(d) opt", link0: []).utf8)
        default: throw IOBridgeError.unsupported(ext)
        }
    }

    /// Full Gaussian input text from a job description (route etc.) plus molecule.
    public static func gaussianInput(_ m: Molecule, route: String, title: String, link0: [String], charge: Int, multiplicity: Int, trailer: String = "") -> String {
        var mm = m; mm.charge = charge; mm.multiplicity = multiplicity; mm.title = title
        return FallbackIO.writeGJF(mm, route: route, link0: link0, trailer: trailer)
    }

    /// Parse a (possibly partial) Gaussian log for the job runner / results.
    public static func parseLog(_ text: String) -> CalculationResult? { nil }
}

enum FallbackIO {
    static func symbol(_ z: Int) -> String { BuildElementsShim.symbol(z) }

    static func readXYZ(_ text: String) throws -> Molecule {
        let lines = text.components(separatedBy: .newlines)
        guard let n = Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? ""), lines.count >= n + 2 else { throw IOBridgeError.parse("bad XYZ header") }
        var m = Molecule(title: lines[1])
        for i in 0..<n {
            let f = lines[i + 2].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 4, let x = Double(f[1]), let y = Double(f[2]), let z = Double(f[3]) else { throw IOBridgeError.parse("line \(i + 3)") }
            let zn = BuildElementsShim.atomicNumber(String(f[0])) ?? Int(f[0]) ?? 0
            m.atoms.append(Atom(id: i, atomicNumber: zn, position: Vec3(x, y, z)))
        }
        return m
    }

    static func writeXYZ(_ m: Molecule) -> String {
        var s = "\(m.atoms.count)\n\(m.title)\n"
        for a in m.atoms { s += String(format: "%-3@ %14.8f %14.8f %14.8f\n", symbol(a.atomicNumber) as NSString, a.position.x, a.position.y, a.position.z) }
        return s
    }

    static func readGJF(_ text: String) throws -> Molecule {
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count, lines[i].hasPrefix("%") { i += 1 }
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }  // route
        i += 1
        var title = ""
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { title += lines[i]; i += 1 }
        i += 1
        guard i < lines.count else { throw IOBridgeError.parse("no charge/multiplicity") }
        let cm = lines[i].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
        var m = Molecule(title: title)
        if cm.count >= 2 { m.charge = cm[0]; m.multiplicity = cm[1] }
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            let f = lines[i].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            let nums = f.dropFirst().compactMap { Double($0) }
            if f.count >= 4, nums.count >= 3 {
                let sym = String(f[0].prefix { $0.isLetter })
                let zn = BuildElementsShim.atomicNumber(sym) ?? 0
                let p = Vec3(nums[nums.count - 3], nums[nums.count - 2], nums[nums.count - 1])
                m.atoms.append(Atom(id: m.atoms.count, atomicNumber: zn, position: p))
            }
            i += 1
        }
        return m
    }

    static func writeGJF(_ m: Molecule, route: String, link0: [String], trailer: String = "") -> String {
        var s = link0.map { $0.hasPrefix("%") ? $0 : "%" + $0 }.joined(separator: "\n")
        if !s.isEmpty { s += "\n" }
        s += route + "\n\n" + (m.title.isEmpty ? "MolScope job" : m.title) + "\n\n\(m.charge) \(m.multiplicity)\n"
        for a in m.atoms { s += String(format: " %-3@ %14.8f %14.8f %14.8f\n", symbol(a.atomicNumber) as NSString, a.position.x, a.position.y, a.position.z) }
        s += "\n"
        if !trailer.isEmpty { s += trailer.trimmingCharacters(in: .newlines) + "\n\n" }
        return s
    }
}
