import Foundation
import MolCore
import simd

// Q-Chem output parser, written from the public Q-Chem output layout (no program output was
// available to calibrate against; fixtures are hand-written to the documented format).

public struct QChemOutput: Sendable {
    public struct OrbitalEnergy: Sendable, Equatable {
        public var energy: Double
        public var occupied: Bool
    }

    public struct Job: Sendable {
        /// Geometries from "Standard Nuclear Orientation (Angstroms)" tables, in order (charge/mult applied).
        public var geometries: [Molecule] = []
        /// "Total energy in the final basis set" values in order of appearance.
        public var scfEnergies: [Double] = []
        public var finalEnergy: Double?
        public var optimizationCycles: Int = 0
        public var optimizationConverged: Bool?
        public var normalModes: [NormalMode] = []
        public var alphaOrbitals: [OrbitalEnergy] = []
        public var betaOrbitals: [OrbitalEnergy] = []
        public var mullikenCharges: [Double] = []
        public var mullikenSpins: [Double] = []
        public var dipoleDebye: Vec3?
        public var excitedStates: [ExcitedState] = []
        public var zeroPointKcal: Double?
        public var enthalpyKcal: Double?
        public var entropyCalPerMolK: Double?
        public var temperature: Double?
        public var pressure: Double?
        public var rem: [String: String] = [:]
        public var charge: Int = 0
        public var multiplicity: Int = 1
        public var jobType: String { (rem["JOBTYPE"] ?? "").lowercased() }
    }

    public var jobs: [Job] = []
    public var version: String?
    public var normalTermination: Bool = false
    public var messages: [String] = []
    public var result: CalculationResult = CalculationResult()

    static func fail(_ m: String) -> MolIOError { .parse(format: "Q-Chem output", line: nil, message: m) }

    public static func read(url: URL) throws -> QChemOutput { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> QChemOutput {
        let lines = splitLines(text)
        guard lines.contains(where: { $0.contains("Q-Chem") || $0.contains("Nuclear Orientation") || $0.contains("Total energy in the final basis set") }) else {
            throw fail("not a Q-Chem output (no recognizable content)")
        }
        var out = QChemOutput()
        for l in lines.prefix(400) {
            if let r = l.range(of: "Q-Chem "), let v = l[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," }).first,
               let c = v.first, c.isNumber { out.version = String(v); break }
        }
        // Split into jobs at "Running Job N of M".
        var starts: [Int] = []
        for (i, l) in lines.enumerated() where l.contains("Running Job") && l.contains(" of ") { starts.append(i) }
        var segments: [ArraySlice<Substring>] = []
        if starts.isEmpty { segments = [lines[...]] } else {
            for (k, s) in starts.enumerated() {
                let lo = k == 0 ? 0 : s
                segments.append(lines[lo..<(k + 1 < starts.count ? starts[k + 1] : lines.count)])
            }
        }
        out.jobs = segments.map { parseJob(Array($0)) }
        let tail = lines.suffix(80)
        out.normalTermination = tail.contains { $0.contains("Thank you very much for using Q-Chem") }
        for l in lines where l.contains("Q-Chem fatal error") || l.contains("Q-Chem error") {
            out.messages.append(l.trimmingCharacters(in: .whitespaces))
            if out.messages.count >= 5 { break }
        }
        out.buildResult()
        return out
    }

    private static func number(after marker: String, in l: Substring) -> Double? {
        guard let r = l.range(of: marker) else { return nil }
        let tk = tokens(l[r.upperBound...])
        return tk.first.flatMap { parseFortranDouble($0) }
    }

    private static func parseJob(_ lines: [Substring]) -> Job {
        var job = Job()
        var i = 0
        var inBeta = false
        var stateBlocks: [(n: Int, ev: Double, mult: Int?, f: Double)] = []
        var echoedMolecule = false
        func isDash(_ s: Substring) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("---") }
        func parseCharge(_ i: Int) {
            // "$molecule" echoed in the user input: next line "charge mult".
            guard i + 1 < lines.count else { return }
            let tk = tokens(lines[i + 1])
            if tk.count == 2, let q = Int(tk[0]), let m = Int(tk[1]) { job.charge = q; job.multiplicity = m }
        }
        while i < lines.count {
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if t.isEmpty { continue }
            if t.lowercased() == "$molecule" && !echoedMolecule { echoedMolecule = true; parseCharge(i); continue }
            if t.lowercased() == "$rem" && job.rem.isEmpty {
                var j = i + 1
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    if r.lowercased() == "$end" { break }
                    let tk = tokens(r.replacingOccurrences(of: "=", with: " "))
                    if tk.count >= 2 { job.rem[tk[0].uppercased()] = tk.dropFirst().joined(separator: " ") }
                    j += 1
                }
                i = j; continue
            }
            if t.contains("Nuclear Orientation (Angstroms)") {
                var j = i + 1
                while j < lines.count, !isDash(lines[j]) { j += 1 }
                j += 1
                var m = Molecule(atoms: [], bonds: [], charge: job.charge, multiplicity: job.multiplicity, title: "")
                while j < lines.count {
                    let tk = tokens(lines[j])
                    guard tk.count >= 5, Int(tk[0]) != nil, let x = parseFortranDouble(tk[2]), let y = parseFortranDouble(tk[3]),
                          let z = parseFortranDouble(tk[4]) else { break }
                    m.atoms.append(Atom(id: m.atoms.count, atomicNumber: IOElements.atomicNumber(label: String(tk[1])) ?? 0, position: Vec3(x, y, z)))
                    j += 1
                }
                if !m.atoms.isEmpty { job.geometries.append(m) }
                i = j - 1; continue
            }
            if t.contains("Total energy in the final basis set"), let v = number(after: "=", in: l) {
                job.scfEnergies.append(v); job.finalEnergy = v; continue
            }
            if t.hasPrefix("Optimization Cycle:") { job.optimizationCycles += 1; continue }
            if t.contains("OPTIMIZATION CONVERGED") { job.optimizationConverged = true; continue }
            if t.hasPrefix("Final energy is"), let v = number(after: "is", in: l) { job.finalEnergy = v; continue }
            if t.contains("Zero point vibrational energy:"), let v = number(after: ":", in: l) { job.zeroPointKcal = v; continue }
            if t.hasPrefix("Total Enthalpy:"), let v = number(after: ":", in: l) { job.enthalpyKcal = v; continue }
            if t.hasPrefix("Total Entropy:"), let v = number(after: ":", in: l) { job.entropyCalPerMolK = v; continue }
            if t.contains("STANDARD THERMODYNAMIC QUANTITIES AT") {
                let tk = tokens(t)
                if let k = tk.firstIndex(of: "AT"), k + 1 < tk.count { job.temperature = Double(tk[k + 1]) }
                if let k = tk.firstIndex(of: "AND"), k + 1 < tk.count { job.pressure = Double(tk[k + 1]) }
                continue
            }
            if t.hasPrefix("Orbital Energies (a.u.)") {
                job.alphaOrbitals = []; job.betaOrbitals = []
                inBeta = false
                var occ = true, seen = false
                var j = i + 1
                while j < lines.count {
                    let s = lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                    if s.isEmpty { continue }
                    if s.hasPrefix("---") { if seen { break } else { continue } }
                    if s.hasPrefix("Alpha MOs") { inBeta = false; continue }
                    if s.hasPrefix("Beta MOs") { inBeta = true; continue }
                    if s.hasPrefix("-- Occupied") { occ = true; continue }
                    if s.hasPrefix("-- Virtual") { occ = false; continue }
                    let tk = tokens(s)
                    guard let first = tk.first, parseFortranDouble(first) != nil else { break }
                    for x in tk { if let v = parseFortranDouble(x) {
                        if inBeta { job.betaOrbitals.append(OrbitalEnergy(energy: v, occupied: occ)) }
                        else { job.alphaOrbitals.append(OrbitalEnergy(energy: v, occupied: occ)) }
                        seen = true
                    } }
                }
                i = j - 2; continue
            }
            if t.contains("Ground-State Mulliken Net Atomic Charges") {
                job.mullikenCharges = []; job.mullikenSpins = []
                var j = i + 1, seen = false
                while j < lines.count {
                    let s = lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                    if s.hasPrefix("---") { if seen { break } else { continue } }
                    let tk = tokens(s)
                    if tk.count >= 3, Int(tk[0]) != nil, let c = parseFortranDouble(tk[2]) {
                        job.mullikenCharges.append(c); seen = true
                        if tk.count >= 4, let sp = parseFortranDouble(tk[3]) { job.mullikenSpins.append(sp) }
                    }
                }
                i = j - 2; continue
            }
            if t.hasPrefix("Dipole Moment (Debye)"), i + 1 < lines.count {
                let tk = tokens(lines[i + 1])
                if tk.count >= 6, let x = Double(tk[1]), let y = Double(tk[3]), let z = Double(tk[5]) { job.dipoleDebye = Vec3(x, y, z) }
                continue
            }
            if t.hasPrefix("Excited state"), let colon = t.firstIndex(of: ":"),
               let n = Int(t[t.index(t.startIndex, offsetBy: 13)..<colon].trimmingCharacters(in: .whitespaces)),
               let ev = number(after: "=", in: l) {
                var mult: Int? = nil, f = 0.0
                var j = i + 1
                while j < lines.count {
                    let s = lines[j].trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("Excited state") || s.hasPrefix("---") { break }
                    if s.hasPrefix("Multiplicity:") { mult = s.lowercased().contains("trip") ? 3 : (s.lowercased().contains("sing") ? 1 : nil) }
                    if s.hasPrefix("Strength"), let v = number(after: ":", in: lines[j]) { f = v }
                    j += 1
                }
                stateBlocks.append((n, ev, mult, f))
                i = j - 1; continue
            }
            if t.hasPrefix("Mode:") {
                var j = i
                var ms: [NormalMode] = []
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("Mode:") {
                    let r = parseVibBlock(lines, &j, natoms: job.geometries.last?.atoms.count)
                    ms += r
                }
                job.normalModes += ms
                i = j - 1; continue
            }
        }
        // Excited states: a new "state 1" of the same multiplicity as an earlier first state starts a fresh set.
        var current: [(n: Int, ev: Double, mult: Int?, f: Double)] = []
        var firstMults: [Int?] = []
        for b in stateBlocks {
            if b.n == 1 {
                if firstMults.contains(where: { $0 == b.mult }) { current = []; firstMults = [] }
                firstMults.append(b.mult)
            }
            current.append(b)
        }
        job.excitedStates = current.map {
            var s = ExcitedState(energyEV: $0.ev, wavelengthNM: $0.ev > 0 ? 1239.841984 / $0.ev : 0, oscillatorStrength: $0.f)
            s.multiplicity = $0.mult
            return s
        }
        if job.optimizationConverged == nil && job.optimizationCycles > 0 { job.optimizationConverged = false }
        return job
    }

    /// Parses one block of up to three modes starting at the "Mode:" line; advances `j` past it.
    private static func parseVibBlock(_ lines: [Substring], _ j: inout Int, natoms: Int?) -> [NormalMode] {
        let count = tokens(lines[j]).dropFirst().filter { Int($0) != nil }.count
        j += 1
        var freqs: [Double] = [], ir: [Double] = [], raman: [Double] = []
        while j < lines.count {
            let s = lines[j].trimmingCharacters(in: .whitespaces)
            let tk = tokens(s)
            if tk.first == "X" || tk.first == "Mode:" { break }
            func vals() -> [Double] { tk.dropFirst(tk.count > 1 && Double(tk[1]) == nil ? 2 : 1).compactMap { parseFortranDouble($0) } }
            if s.hasPrefix("Frequency:") { freqs = vals() }
            else if s.hasPrefix("IR Intens:") { ir = vals() }
            else if s.hasPrefix("Raman Intens:") || s.hasPrefix("Raman Activ:") { raman = vals() }
            j += 1
        }
        guard j < lines.count, tokens(lines[j]).first == "X" else { return [] }
        j += 1
        let n = min(count > 0 ? count : freqs.count, freqs.count)
        guard n > 0 else { return [] }
        var disp = [[Vec3]](repeating: [], count: n)
        while j < lines.count {
            let tk = tokens(lines[j])
            guard tk.count == 1 + 3 * n, Double(tk[0]) == nil else { break }
            let v = tk.dropFirst().compactMap { parseFortranDouble($0) }
            guard v.count == 3 * n else { break }
            for m in 0..<n { disp[m].append(Vec3(v[3 * m], v[3 * m + 1], v[3 * m + 2])) }
            j += 1
        }
        if let na = natoms, disp.contains(where: { $0.count != na }) { return [] }
        return (0..<n).map { m in
            NormalMode(frequency: freqs[m], irIntensity: m < ir.count ? ir[m] : 0,
                       ramanActivity: m < raman.count ? raman[m] : nil, displacements: disp[m])
        }
    }

    private mutating func buildResult() {
        var r = CalculationResult()
        var steps: [Molecule] = [], energies: [Double] = []
        for job in jobs {
            for (k, g) in job.geometries.enumerated() {
                let e = k < job.scfEnergies.count ? job.scfEnergies[k] : nil
                if let last = steps.last, last.atoms.count == g.atoms.count,
                   zip(last.atoms, g.atoms).allSatisfy({ simd_length($0.position - $1.position) < 1e-6 }) { continue }
                steps.append(g)
                if let e { energies.append(e) }
            }
        }
        r.steps = steps; r.energies = energies
        let jobsCopy = jobs
        func lastWith(_ p: (Job) -> Bool) -> Job? { jobsCopy.last(where: p) }
        if let j = lastWith({ !$0.normalModes.isEmpty }) { r.normalModes = j.normalModes }
        var ex = CalculationExtras()
        ex.program = "Q-Chem"; ex.programVersion = version
        if let j = lastWith({ !$0.alphaOrbitals.isEmpty }) {
            let unres = !j.betaOrbitals.isEmpty
            for (k, o) in j.alphaOrbitals.enumerated() {
                r.orbitals.append(OrbitalInfo(index: k + 1, energy: o.energy, occupied: o.occupied, spin: unres ? .alpha : .restricted))
            }
            for (k, o) in j.betaOrbitals.enumerated() { r.orbitals.append(OrbitalInfo(index: k + 1, energy: o.energy, occupied: o.occupied, spin: .beta)) }
            if let h = j.alphaOrbitals.last(where: { $0.occupied }), let l = j.alphaOrbitals.first(where: { !$0.occupied }) {
                ex.homoLumoGapEV = (l.energy - h.energy) * 27.211386245988
            }
        }
        if let j = lastWith({ !$0.excitedStates.isEmpty }) { r.excitedStates = j.excitedStates }
        if let j = lastWith({ !$0.mullikenCharges.isEmpty }) {
            r.mullikenCharges = j.mullikenCharges
            ex.charges["mulliken"] = j.mullikenCharges
            if !j.mullikenSpins.isEmpty { ex.spinDensities["mulliken"] = j.mullikenSpins }
        }
        r.dipole = jobs.last(where: { $0.dipoleDebye != nil })?.dipoleDebye
        ex.finalEnergy = jobs.last(where: { $0.finalEnergy != nil })?.finalEnergy
        if let j = jobs.first(where: { !$0.rem.isEmpty }) {
            r.routeSection = j.rem.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " ")
        }
        if let opt = jobs.last(where: { $0.optimizationConverged != nil }) { ex.optimizationConverged = opt.optimizationConverged }
        if let j = jobs.last(where: { $0.zeroPointKcal != nil || $0.enthalpyKcal != nil }) {
            let k = 627.5094740631
            var th = ThermochemistrySummary()
            th.temperature = j.temperature; th.pressure = j.pressure
            th.electronicEnergy = j.finalEnergy
            th.zeroPointEnergy = j.zeroPointKcal.map { $0 / k }
            th.enthalpyCorrection = j.enthalpyKcal.map { $0 / k }
            if let s = j.entropyCalPerMolK, let T = j.temperature {
                let ts = s * T / 1000 / k
                th.entropy = ts
                if let h = th.enthalpyCorrection { th.gibbsCorrection = h - ts }
            }
            if let e = th.electronicEnergy {
                th.totalEnthalpy = th.enthalpyCorrection.map { e + $0 }
                th.totalGibbs = th.gibbsCorrection.map { e + $0 }
            }
            ex.thermochemistry = th
        }
        ex.messages = messages
        r.extras = ex
        r.normalTermination = normalTermination
        result = r
    }
}
