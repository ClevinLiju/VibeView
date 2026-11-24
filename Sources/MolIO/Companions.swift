import Foundation
import MolCore

// Companion-file autoload (Lead A, round 3). When a file is opened, sibling files in the same directory
// that belong to the same calculation (same base name) are read and merged into the loaded result.
// The primary file always wins: companions only fill gaps (missing wavefunction, modes, frames, ...).
//
//   job.out  <->  job.molden.input, job.molden, job.hess, job.engrad, job_trj.xyz, job.fchk / job.fch,
//                 job.cube / job_*.cube / job.*.cube, job.log / job.out (when the primary is not the log)
//   job.chk / job.gbw are binary: never read, reported with a conversion hint (formchk / orca_2mkl).
//   xtb run directories: xtbopt.xyz (final geometry), xtbopt.log (optimization frames), g98.out (modes).

/// One sibling file considered by the companion search.
public struct CompanionFile: Sendable, Equatable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        /// Molden / formatted checkpoint: basis + MOs (orbitals).
        case wavefunction
        /// ORCA .hess or xtb g98.out: normal modes.
        case hessian
        /// ORCA .engrad: final gradient.
        case gradient
        /// ORCA _trj.xyz or xtbopt.log: geometry frames.
        case trajectory
        /// xtbopt.xyz: optimized geometry.
        case geometry
        /// Cube files: volumetric data.
        case volume
        /// Program log (when the primary is e.g. an fchk or a hess file).
        case log
        /// Binary file we cannot read (Gaussian .chk, ORCA .gbw); see `note` for the conversion command.
        case binary
    }
    public var url: URL
    public var role: Role
    /// True when data from this file was merged into the result.
    public var used: Bool
    /// What was taken ("12 normal modes", "wavefunction (58 MOs)") or why it was skipped.
    public var note: String
    public var fileName: String { url.lastPathComponent }
    public init(url: URL, role: Role, used: Bool, note: String) {
        self.url = url; self.role = role; self.used = used; self.note = note
    }
}

public enum CompanionFiles {
    /// Compound suffixes recognized when computing a file's base name, longest first.
    static let compoundSuffixes: [String] = [
        ".molden.input", "_trj.xyz", ".trj.xyz", ".molden", ".engrad", ".hess", ".fchk", ".fch", ".chk",
        ".gbw", ".cube", ".cub", ".out", ".log", ".inp", ".gjf", ".com", ".xyz", ".in", ".txt",
    ]

    /// Base name shared by the files of one calculation: "job.molden.input" -> "job", "job_trj.xyz" -> "job",
    /// "my.job.out" -> "my.job". Unknown extensions drop only the last extension.
    public static func baseName(of fileName: String) -> String {
        let lower = fileName.lowercased()
        for s in compoundSuffixes where lower.hasSuffix(s) && lower.count > s.count {
            return String(fileName.dropLast(s.count))
        }
        let ns = fileName as NSString
        return ns.pathExtension.isEmpty ? fileName : ns.deletingPathExtension
    }

    /// Role of `fileName` as a companion of a calculation with base name `base`, or nil when unrelated.
    static func role(of fileName: String, base: String) -> CompanionFile.Role? {
        let lower = fileName.lowercased(), b = base.lowercased()
        func ends(_ s: String) -> Bool { lower == b + s }
        if ends(".molden.input") || ends(".molden") || ends(".fchk") || ends(".fch") { return .wavefunction }
        if ends(".hess") { return .hessian }
        if ends(".engrad") { return .gradient }
        if ends("_trj.xyz") || ends(".trj.xyz") { return .trajectory }
        if ends(".chk") || ends(".gbw") { return .binary }
        if ends(".out") || ends(".log") { return .log }
        if lower.hasSuffix(".cube") || lower.hasSuffix(".cub") {
            if lower == b + ".cube" || lower == b + ".cub" { return .volume }
            if lower.hasPrefix(b + "_") || lower.hasPrefix(b + ".") || lower.hasPrefix(b + "-") { return .volume }
        }
        return nil
    }

    /// True when `directory` looks like an xtb working directory (xtb writes fixed file names).
    public static func isXTBRunDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        return ["xtbopt.xyz", "xtbopt.log", "xtbrestart", "xtbtopo.mol", "g98.out", "wbo"].contains {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Sibling files of `url` that may belong to the same calculation, with their roles (not yet read).
    /// Sorted by role (wavefunction, hessian, gradient, trajectory, volume, log, binary); wavefunction sources in
    /// preference order (.molden.input, .molden, .fchk, .fch); then by name.
    public static func candidates(for url: URL) -> [(url: URL, role: CompanionFile.Role)] {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let base = baseName(of: name)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(URL, CompanionFile.Role)] = []
        for e in entries.sorted() where e != name && !e.hasPrefix(".") {
            if let r = role(of: e, base: base) { out.append((dir.appendingPathComponent(e), r)) }
        }
        let wfRank = [".molden.input", ".molden", ".fchk", ".fch"]
        func rank(_ u: URL) -> Int {
            let l = u.lastPathComponent.lowercased()
            return wfRank.firstIndex { l.hasSuffix($0) } ?? wfRank.count
        }
        // merge order: dedicated companions first, the other log last (it only fills what is still missing)
        let roleOrder: [CompanionFile.Role] = [.wavefunction, .hessian, .gradient, .trajectory, .geometry, .volume, .log, .binary]
        out = out.enumerated().sorted { x, y in
            let (a, b) = (x.element, y.element)
            let ra = roleOrder.firstIndex(of: a.1)!, rb = roleOrder.firstIndex(of: b.1)!
            if ra != rb { return ra < rb }
            if a.1 == .wavefunction, rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            return x.offset < y.offset
        }.map(\.element)
        return out.map { (url: $0.0, role: $0.1) }
    }

    /// Maximum size of a cube companion that is loaded automatically (bytes).
    public static let maxCubeBytes = 64 * 1024 * 1024
    /// Maximum number of cube companions loaded automatically.
    public static let maxCubes = 8

    /// Read the companions of `url` and merge them into `loaded` (gaps only). Returns every file considered,
    /// with `used` and a note. Never throws: unreadable or inconsistent companions are reported, not fatal.
    @discardableResult
    public static func merge(into loaded: inout LoadedMolecularFile, primaryURL url: URL) -> [CompanionFile] {
        var report: [CompanionFile] = []
        let atomCount = loaded.molecule.atoms.count
        func compatible(_ n: Int) -> Bool { atomCount == 0 || n == atomCount }
        var cubes = 0
        for (u, role) in candidates(for: url) {
            func add(_ used: Bool, _ note: String) { report.append(CompanionFile(url: u, role: role, used: used, note: note)) }
            switch role {
            case .binary:
                let isChk = u.pathExtension.lowercased() == "chk"
                let stem = baseName(of: u.lastPathComponent)
                add(false, isChk ? "binary checkpoint; run `formchk \(u.lastPathComponent) \(stem).fchk` to view orbitals"
                                 : "binary ORCA wavefunction; run `orca_2mkl \(stem) -molden` to view orbitals")
            case .wavefunction:
                guard loaded.wavefunction == nil else { add(false, "skipped: wavefunction already loaded"); continue }
                do {
                    let l = u.lastPathComponent.lowercased()
                    let isFchk = l.hasSuffix(".fchk") || l.hasSuffix(".fch")
                    var wf: Wavefunction?
                    var orbs: [OrbitalInfo] = []
                    var n = 0
                    if isFchk {
                        let fc = try FormattedCheckpoint.read(url: u)
                        wf = fc.wavefunction; orbs = fc.calculationResult.orbitals; n = fc.molecule.atoms.count
                    } else {
                        let m = try MoldenFile.read(url: u)
                        wf = m.wavefunction; orbs = m.orbitals; n = m.molecule.atoms.count
                    }
                    guard let w = wf else { add(false, "no basis set / MOs in file"); continue }
                    guard compatible(n) else { add(false, "skipped: \(n) atoms, primary has \(atomCount)"); continue }
                    loaded.wavefunction = w
                    if var r = loaded.result {
                        if r.orbitals.isEmpty { r.orbitals = orbs }
                        loaded.result = r
                    }
                    add(true, "wavefunction (\(w.alpha.orbitalCount) MOs\(w.isUnrestricted ? ", unrestricted" : ""))")
                } catch { add(false, "unreadable: \(error)") }
            case .hessian:
                guard (loaded.result?.normalModes.isEmpty ?? true) else { add(false, "skipped: modes already present"); continue }
                do {
                    let h = try OrcaHessian.read(url: u)
                    guard !h.normalModes.isEmpty else { add(false, "no normal modes in file"); continue }
                    guard compatible(h.molecule.atoms.count) else { add(false, "skipped: atom count differs"); continue }
                    var r = loaded.result ?? CalculationResult()
                    r.normalModes = h.normalModes
                    if r.steps.isEmpty { r.steps = [loaded.molecule] }
                    loaded.result = r
                    add(true, "\(h.normalModes.count) normal modes")
                } catch { add(false, "unreadable: \(error)") }
            case .gradient:
                guard (loaded.result?.extras?.gradients.isEmpty ?? true) else { add(false, "skipped: gradient already present"); continue }
                do {
                    let g = try OrcaEngrad.read(url: u)
                    guard compatible(g.gradient.count) else { add(false, "skipped: atom count differs"); continue }
                    var r = loaded.result ?? CalculationResult()
                    var x = r.extrasOrEmpty
                    x.gradients = [g.gradient]
                    if x.finalEnergy == nil { x.finalEnergy = g.energy }
                    r.extras = x
                    loaded.result = r
                    add(true, "final gradient (\(g.gradient.count) atoms)")
                } catch { add(false, "unreadable: \(error)") }
            case .trajectory:
                guard loaded.molecules.count <= 1 else { add(false, "skipped: primary already has \(loaded.molecules.count) frames"); continue }
                do {
                    let frames = try XYZFormat.read(url: u).filter { !$0.atoms.isEmpty }
                    guard frames.count > 1 else { add(false, "fewer than two frames"); continue }
                    guard compatible(frames[0].atoms.count) else { add(false, "skipped: atom count differs"); continue }
                    var fs = frames
                    // keep the primary's (bonded, charged) final structure as the last frame's topology
                    let prim = loaded.molecule
                    if !prim.atoms.isEmpty {
                        for k in fs.indices {
                            var m = prim
                            for i in m.atoms.indices { m.atoms[i].position = fs[k].atoms[i].position }
                            fs[k] = m
                        }
                    }
                    loaded.molecules = fs
                    if var r = loaded.result, r.steps.count <= 1 {
                        r.steps = fs
                        let es = frames.map { trajectoryEnergy($0.title) }
                        if es.allSatisfy({ $0 != nil }) { r.energies = es.map { $0! } }
                        loaded.result = r
                    }
                    add(true, "\(frames.count) frames")
                } catch { add(false, "unreadable: \(error)") }
            case .volume:
                guard cubes < maxCubes else { add(false, "skipped: more than \(maxCubes) cube files"); continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                guard size <= maxCubeBytes else { add(false, "skipped: larger than \(maxCubeBytes / 1_048_576) MB (open it directly)"); continue }
                do {
                    let c = try CubeFile.read(url: u)
                    guard compatible(c.molecule.atoms.count) else { add(false, "skipped: atom count differs"); continue }
                    loaded.volumes += c.grids
                    if var r = loaded.result {
                        for (k, g) in c.grids.enumerated() {
                            let key = c.grids.count == 1 ? u.lastPathComponent : "\(u.lastPathComponent)#\(k + 1)"
                            if r.volumes[key] == nil { r.volumes[key] = g }
                        }
                        loaded.result = r
                    }
                    cubes += 1
                    add(true, "\(c.grids.count) volume grid\(c.grids.count == 1 ? "" : "s")")
                } catch { add(false, "unreadable: \(error)") }
            case .log:
                // two logs: ignore silently (fchk / hess / molden primaries still take data from the log)
                guard ![.gaussianOutput, .orcaOutput, .qchemOutput, .xtbOutput].contains(loaded.format) else { continue }
                do {
                    let other = try MolecularFileLoader.load(url: u)
                    guard other.format.isCalculationOutput, let orr = other.result else { continue }
                    guard compatible(other.molecule.atoms.count) else { add(false, "skipped: atom count differs"); continue }
                    var r = loaded.result ?? CalculationResult()
                    var took: [String] = []
                    if r.normalModes.isEmpty && !orr.normalModes.isEmpty { r.normalModes = orr.normalModes; took.append("modes") }
                    if r.orbitals.isEmpty && !orr.orbitals.isEmpty { r.orbitals = orr.orbitals; took.append("orbital energies") }
                    if r.excitedStates.isEmpty && !orr.excitedStates.isEmpty { r.excitedStates = orr.excitedStates; took.append("excited states") }
                    if r.energies.isEmpty && !orr.energies.isEmpty { r.energies = orr.energies; took.append("energies") }
                    if r.mullikenCharges.isEmpty && !orr.mullikenCharges.isEmpty { r.mullikenCharges = orr.mullikenCharges }
                    if r.dipole == nil { r.dipole = orr.dipole }
                    if r.routeSection.isEmpty { r.routeSection = orr.routeSection }
                    if !r.normalTermination { r.normalTermination = orr.normalTermination }
                    if let ox = orr.extras {
                        var x = r.extrasOrEmpty
                        if x.program == nil { x.program = ox.program }
                        if x.programVersion == nil { x.programVersion = ox.programVersion }
                        if x.finalEnergy == nil { x.finalEnergy = ox.finalEnergy }
                        if x.info == nil, ox.info != nil { x.info = ox.info; took.append("setup") }
                        if x.thermochemistry == nil { x.thermochemistry = ox.thermochemistry }
                        for (k, v) in ox.charges where x.charges[k] == nil { x.charges[k] = v }
                        r.extras = x
                    }
                    if r.steps.isEmpty { r.steps = [loaded.molecule] }
                    loaded.result = r
                    if loaded.molecules.count <= 1 && other.molecules.count > 1 && atomCount == other.molecule.atoms.count {
                        loaded.molecules = other.molecules; took.append("\(other.molecules.count) frames")
                    }
                    if loaded.program == nil { loaded.program = other.program }
                    add(!took.isEmpty, took.isEmpty ? "nothing new" : took.joined(separator: ", "))
                } catch { add(false, "unreadable: \(error)") }
            case .geometry:
                break
            }
        }
        if loaded.format == .xtbOutput { report += mergeXTB(into: &loaded, directory: url.deletingLastPathComponent()) }
        return report
    }

    /// xtb writes fixed names (not the input's stem): read them when the primary is an xtb log.
    static func mergeXTB(into loaded: inout LoadedMolecularFile, directory dir: URL) -> [CompanionFile] {
        var report: [CompanionFile] = []
        let fm = FileManager.default
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        var r = loaded.result ?? CalculationResult()
        for n in ["xtbopt.xyz", "xtbopt.coord.xyz", "xtblast.xyz"] where fm.fileExists(atPath: u(n).path) {
            // `MolecularFileLoader.load(url:)` already takes the geometry from here when the log has none
            report.append(CompanionFile(url: u(n), role: .geometry, used: true, note: "optimized geometry"))
            break
        }
        if fm.fileExists(atPath: u("xtbopt.log").path) {
            if r.steps.count <= 1, let t = try? readText(u("xtbopt.log")), let tr = try? XTBTrajectory.parse(t), tr.molecules.count > 1 {
                r.steps = tr.molecules; r.energies = tr.energies
                loaded.molecules = tr.molecules
                report.append(CompanionFile(url: u("xtbopt.log"), role: .trajectory, used: true, note: "\(tr.molecules.count) optimization frames"))
            } else {
                report.append(CompanionFile(url: u("xtbopt.log"), role: .trajectory, used: false, note: "skipped"))
            }
        }
        if fm.fileExists(atPath: u("g98.out").path) {
            if r.normalModes.isEmpty, let modes = try? XTBG98Frequencies.read(url: u("g98.out")), !modes.isEmpty {
                r.normalModes = modes
                report.append(CompanionFile(url: u("g98.out"), role: .hessian, used: true, note: "\(modes.count) normal modes"))
            } else {
                report.append(CompanionFile(url: u("g98.out"), role: .hessian, used: false, note: "skipped"))
            }
        }
        if loaded.result != nil || !report.isEmpty { loaded.result = r }
        return report
    }

    /// Energy from an ORCA trajectory comment ("Coordinates from ORCA-job x E -74.96").
    static func trajectoryEnergy(_ title: String) -> Double? {
        let t = title.split(separator: " ")
        guard let k = t.lastIndex(of: "E"), k + 1 < t.count else { return nil }
        return Double(t[k + 1])
    }
}

extension MolecularFileLoader {
    /// Load `url` and merge its companion files (same directory, same base name; see `CompanionFiles`).
    /// Returns the loaded file and the list of companions considered (`used` marks the ones merged).
    /// The primary file's data always wins; companions fill gaps only.
    public static func loadWithCompanions(url: URL) throws -> (file: LoadedMolecularFile, companions: [CompanionFile]) {
        var out = try load(url: url)
        let comps = CompanionFiles.merge(into: &out, primaryURL: url)
        out.companions = comps
        return (out, comps)
    }
}
