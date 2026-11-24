import Foundation
import MolCore
import MolIO

public enum XTBTask: String, Sendable, CaseIterable { case singlePoint, optimize, hessian }
public enum XTBMethod: String, Sendable, CaseIterable {
    case gfn2, gfn1, gfnff
    var flag: [String] {
        switch self { case .gfn2: return ["--gfn", "2"]; case .gfn1: return ["--gfn", "1"]; case .gfnff: return ["--gfnff"] }
    }
}

public struct XTBResult: Sendable {
    public var energy: Double            // Eh
    public var gradientNorm: Double?     // Eh/a0
    public var homoLumoGap: Double?      // eV
    public var molecule: Molecule
    public var frequencies: [Double]     // cm^-1
    public var irIntensities: [Double]   // km/mol
    public var log: String
    public var workingDirectory: URL
}

public struct XTBRunner: Sendable {
    public typealias Task = XTBTask
    public typealias Method = XTBMethod
    public var executable: URL?
    public var keepFiles = false
    /// nil = default search (MOLSCOPE_XTB, PATH, conda envs, homebrew). When set, only these directories are searched.
    public var searchDirectories: [String]?

    public init(executable: URL? = nil) { self.executable = executable }

    public static func locate(searchDirectories: [String]? = nil) -> URL? {
        if let dirs = searchDirectories {
            let fm = FileManager.default
            for d in dirs {
                let p = (d as NSString).appendingPathComponent("xtb")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
            return nil
        }
        if let o = ProcessInfo.processInfo.environment["MOLSCOPE_XTB"], !o.isEmpty,
           FileManager.default.isExecutableFile(atPath: o) { return URL(fileURLWithPath: o) }
        return ProgramLocator.find("xtb")
    }

    public func run(_ molecule: Molecule, task: XTBTask, method: XTBMethod = .gfn2, solvent: String? = nil,
                    threads: Int = 4, accuracy: Double = 1.0) async throws -> XTBResult {
        let exe: URL
        if let given = executable {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: given.path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: given.path) else {
                throw ComputeError.notInstalled(program: "xtb", searched: [given.path])
            }
            exe = given
        } else if let found = Self.locate(searchDirectories: searchDirectories) {
            exe = found
        } else {
            throw ComputeError.notInstalled(program: "xtb", searched: searchDirectories ?? ProgramLocator.searchDirectories(for: "xtb"))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("molscope-xtb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = false
        defer { if !ok && !keepFiles { try? FileManager.default.removeItem(at: dir) } }
        try XYZFormat.write(molecule).write(to: dir.appendingPathComponent("input.xyz"), atomically: true, encoding: .utf8)
        var args = ["input.xyz"] + method.flag
        switch task {
        case .singlePoint: break
        case .optimize: args += ["--opt"]
        case .hessian: args += ["--ohess"]
        }
        args += ["--chrg", String(molecule.charge), "--uhf", String(max(0, molecule.multiplicity - 1))]
        if let s = solvent, !s.isEmpty { args += ["--alpb", s] }
        if accuracy != 1.0 { args += ["--acc", String(accuracy)] }
        args += ["-P", String(max(1, threads))]
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "\(max(1, threads)),1"
        env["OMP_STACKSIZE"] = "512M"
        let out = try await ProgramRunner.run(executable: exe, arguments: args, workingDirectory: dir, environment: env)
        let log = out.stdout
        guard let energy = Self.parseEnergy(log) else {
            throw ComputeError.parse("xtb output has no TOTAL ENERGY\n" + String(log.suffix(400)))
        }
        var mol = molecule
        let optURL = dir.appendingPathComponent("xtbopt.xyz")
        if task != .singlePoint, let t = try? String(contentsOf: optURL, encoding: .utf8),
           let g = Self.parseXYZCoordinates(t), g.count == mol.atoms.count {
            for i in 0..<g.count { mol.atoms[i].position = g[i] }
        }
        var freqs: [Double] = [], ir: [Double] = []
        if task == .hessian, let t = try? String(contentsOf: dir.appendingPathComponent("vibspectrum"), encoding: .utf8) {
            (freqs, ir) = Self.parseVibSpectrum(t)
        }
        let result = XTBResult(energy: energy, gradientNorm: Self.parseGradientNorm(log),
                               homoLumoGap: Self.parseGap(log), molecule: mol, frequencies: freqs,
                               irIntensities: ir, log: log, workingDirectory: dir)
        ok = true
        if !keepFiles { try? FileManager.default.removeItem(at: dir) }
        return result
    }

    // MARK: parsers (internal-public for tests)

    /// Last "TOTAL ENERGY   -5.07 Eh" value.
    public static func parseEnergy(_ log: String) -> Double? { lastValue(log, key: "TOTAL ENERGY") }
    public static func parseGradientNorm(_ log: String) -> Double? { lastValue(log, key: "GRADIENT NORM") }
    public static func parseGap(_ log: String) -> Double? { lastValue(log, key: "HOMO-LUMO GAP") }

    private static func lastValue(_ log: String, key: String) -> Double? {
        var result: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: key) else { continue }
            let rest = line[r.upperBound...].replacingOccurrences(of: "|", with: " ")
            for tok in rest.split(separator: " ") { if let v = Double(tok) { result = v; break } }
        }
        return result
    }

    public static func parseXYZCoordinates(_ text: String) -> [Vec3]? {
        guard let mols = try? XYZFormat.parse(text), let m = mols.last else { return nil }
        return m.atoms.map(\.position)
    }

    /// Turbomole `$vibrational spectrum` block. Skips zero-frequency (translation/rotation) modes.
    public static func parseVibSpectrum(_ text: String) -> (frequencies: [Double], intensities: [Double]) {
        var f: [Double] = [], ir: [Double] = []
        var inBlock = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("$vibrational") { inBlock = true; continue }
            if line.hasPrefix("$end") { break }
            if !inBlock || line.hasPrefix("#") || line.isEmpty { continue }
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // mode [symmetry] wavenumber intensity selection
            guard t.count >= 4, Int(t[0]) != nil else { continue }
            let nums = t.dropFirst().compactMap { Double($0) }
            guard nums.count >= 2 else { continue }
            if abs(nums[0]) < 1e-6 { continue }
            f.append(nums[0]); ir.append(nums[1])
        }
        return (f, ir)
    }
}
