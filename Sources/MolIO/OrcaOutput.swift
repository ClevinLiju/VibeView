import Foundation
import MolCore

// ORCA output (.out) parser, written from the public ORCA output layout (ORCA 5/6 text).
//
// Truncation policy (documented for job monitoring):
//  * Text that does not look like an ORCA output (no ORCA banner / "Program Version" line) throws `MolIOError`.
//  * A log cut cleanly between blocks parses; `normalTermination` is false.
//  * A log cut inside a structured table (coordinates, orbital energies, charges, normal-mode column
//    blocks, frequency list, IR/Raman tables, excited-state spectrum, gradient) throws `MolIOError.parse`.
//  * A trailing line without newline terminator is treated as possibly cut and ignored (except for
//    the termination marker), so half-printed numbers never leak into results.

public struct OrcaConvergenceItem: Sendable, Codable, Equatable {
    public var name: String
    public var value: Double
    public var tolerance: Double
    public var converged: Bool
}

public struct OrcaOptimizationCycle: Sendable, Codable, Equatable {
    public var cycle: Int
    public var items: [OrcaConvergenceItem]
}

public struct OrcaTransition: Sendable, Codable, Equatable {
    public var from: String
    public var to: String
    public var weight: Double
}

public struct OrcaExcitedState: Sendable, Codable, Equatable {
    public var index: Int
    public var multiplicity: Int
    public var energyEV: Double
    public var energyCm1: Double
    public var wavelengthNM: Double?
    public var oscillatorStrength: Double?
    public var transitions: [OrcaTransition]
}

public struct OrcaScanPoint: Sendable, Codable, Equatable {
    public var coordinate: Double
    public var energy: Double
}

public struct OrcaOutput: Sendable, Codable, Equatable {
    public var programVersion: String?
    public var inputLines: [String] = []
    public var keywordLines: [String] = []
    public var charge: Int = 0
    public var multiplicity: Int = 1
    public var geometries: [Molecule] = []
    public var energies: [Double] = []
    public var finalEnergy: Double?
    public var optimizationCycles: [OrcaOptimizationCycle] = []
    public var optimizationConverged: Bool?
    /// All 3N frequencies including translation/rotation zeros.
    public var allFrequencies: [Double] = []
    /// All 3N modes (zeros included), displacements as printed (mass-weighted 1/sqrt(m) Cartesian).
    public var allNormalModes: [NormalMode] = []
    public var firstVibrationIndex: Int = 0
    public var orbitals: [OrbitalInfo] = []
    public var mullikenCharges: [Double] = []
    public var mullikenSpins: [Double] = []
    public var loewdinCharges: [Double] = []
    public var loewdinSpins: [Double] = []
    public var hirshfeldCharges: [Double] = []
    public var hirshfeldSpins: [Double] = []
    public var dipoleDebye: Vec3?
    public var spinSquared: Double?
    public var excitedStates: [OrcaExcitedState] = []
    public var thermochemistry: ThermochemistrySummary?
    public var gradients: [[Vec3]] = []
    public var scanSurface: [OrcaScanPoint] = []
    public var messages: [String] = []
    public var normalTermination = false
    public var errorTermination = false

    public static let debyePerAU = 2.541746

    public static func read(url: URL) throws -> OrcaOutput { try parse(try readText(url)) }

    /// Detailed vibrational modes without translation/rotation.
    public var vibrationalModes: [NormalMode] {
        Array(allNormalModes.dropFirst(min(firstVibrationIndex, allNormalModes.count)))
    }

    /// Program-neutral result.
    public var result: CalculationResult {
        var r = CalculationResult()
        var n = geometries.count
        if !energies.isEmpty { n = min(n, energies.count) }
        r.steps = Array(geometries.prefix(n))
        r.energies = Array(energies.prefix(n))
        r.normalModes = vibrationalModes
        r.orbitals = orbitals
        r.mullikenCharges = mullikenCharges
        r.dipole = dipoleDebye
        r.routeSection = keywordLines.joined(separator: "\n")
        r.normalTermination = normalTermination
        var ex: [ExcitedState] = []
        for s in excitedStates {
            guard let f = s.oscillatorStrength else { continue }
            var e = ExcitedState(energyEV: s.energyEV, wavelengthNM: s.wavelengthNM ?? (s.energyEV > 0 ? 1239.84193 / s.energyEV : 0), oscillatorStrength: f)
            e.multiplicity = s.multiplicity
            ex.append(e)
        }
        r.excitedStates = ex
        var x = CalculationExtras()
        x.program = "orca"
        x.programVersion = programVersion
        x.finalEnergy = finalEnergy
        if !mullikenCharges.isEmpty { x.charges["Mulliken"] = mullikenCharges }
        if !loewdinCharges.isEmpty { x.charges["Loewdin"] = loewdinCharges }
        if !hirshfeldCharges.isEmpty { x.charges["Hirshfeld"] = hirshfeldCharges }
        if !mullikenSpins.isEmpty { x.spinDensities["Mulliken"] = mullikenSpins }
        if !loewdinSpins.isEmpty { x.spinDensities["Loewdin"] = loewdinSpins }
        if !hirshfeldSpins.isEmpty, hirshfeldSpins.contains(where: { abs($0) > 1e-9 }) { x.spinDensities["Hirshfeld"] = hirshfeldSpins }
        x.gradients = gradients
        x.thermochemistry = thermochemistry
        x.optimizationConverged = optimizationConverged
        x.messages = messages
        if !orbitals.isEmpty {
            func gap(_ o: [OrbitalInfo]) -> Double? {
                guard let h = o.last(where: { $0.occupied }), let l = o.first(where: { !$0.occupied }) else { return nil }
                return (l.energy - h.energy) * 27.211386
            }
            let a = orbitals.filter { $0.spin != .beta }, b = orbitals.filter { $0.spin == .beta }
            if b.isEmpty { x.homoLumoGapEV = gap(a) }
            else if let ga = gap(a), let gb = gap(b) { x.homoLumoGapEV = min(ga, gb) }
        }
        r.extras = x
        return r
    }

    // MARK: parsing

    private static func fail(_ line: Int, _ msg: String) -> MolIOError { .parse(format: "orca", line: line + 1, message: msg) }

    private static func isDashes(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "-" }
    }

    public static func parse(_ text: String) throws -> OrcaOutput {
        var lines = splitLines(text)
        guard text.contains("O   R   C   A") || text.contains("Program Version") else {
            throw MolIOError.parse(format: "orca", line: nil, message: "not an ORCA output")
        }
        let lastTerminated = text.hasSuffix("\n") || text.hasSuffix("\r")
        let tailLine = lines.last.map(String.init) ?? ""
        if !lastTerminated, !lines.isEmpty { lines.removeLast() }
        var out = OrcaOutput()
        let L = lines
        var i = 0
        var inInput = false
        var inputDone = false
        var lastStatesMult = 1
        var spectrumRows: [String: (nm: Double?, f: Double, ev: Double?)] = [:]
        var energyForStepPending = false
        var thermo = ThermochemistrySummary()
        var haveThermo = false
        var vibCount = 0

        func trimmed(_ k: Int) -> String { L[k].trimmingCharacters(in: .whitespaces) }
        func header(_ k: Int, _ title: String) -> Bool {
            k + 1 < L.count && trimmed(k) == title && L[k + 1].hasPrefix("---")
        }
        func doubles(_ toks: [Substring]) -> [Double]? {
            var r: [Double] = []
            for t in toks { guard let d = parseFortranDouble(t) else { return nil }; r.append(d) }
            return r
        }
        func eh(_ s: String) -> Double? {
            let t = tokens(s)
            guard let k = t.firstIndex(of: "Eh"), k > 0 else { return nil }
            return parseFortranDouble(t[k - 1])
        }
        func chargeBlock(_ start: Int, spin: Bool) throws -> (q: [Double], s: [Double], next: Int) {
            var k = start
            var q: [Double] = [], s: [Double] = []
            while k < L.count {
                let t = tokens(L[k])
                if t.count >= 4, Int(t[0]) != nil, t[2] == ":", let c = parseFortranDouble(t[3]) {
                    q.append(c)
                    if t.count >= 5, let sp = parseFortranDouble(t[4]) { s.append(sp) }
                    k += 1
                } else if t.first == "Sum" || t.first == "Sum" { return (q, s, k) }
                else { return (q, s, k) }
            }
            throw fail(L.count - 1, "truncated atomic charge table")
        }
        func commitGeometry(_ m: Molecule) { out.geometries.append(m); energyForStepPending = true }

        while i < L.count {
            let line = L[i]
            // Input echo
            if line.contains("INPUT FILE") && !inputDone { inInput = true }
            if inInput {
                if line.contains("****END OF INPUT****") { inInput = false; inputDone = true }
                else if let r = line.range(of: "> "), line.hasPrefix("|") {
                    let content = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    out.inputLines.append(content)
                    if content.hasPrefix("!") { out.keywordLines.append(content) }
                }
            }
            if out.programVersion == nil, let r = line.range(of: "Program Version ") {
                out.programVersion = tokens(line[r.upperBound...]).first.map(String.init)
            }
            if line.hasPrefix(" Total Charge"), let v = tokens(line).last, let c = Int(v) { out.charge = c }
            if line.hasPrefix(" Multiplicity"), let v = tokens(line).last, let c = Int(v) { out.multiplicity = c }

            if header(i, "CARTESIAN COORDINATES (ANGSTROEM)") {
                var k = i + 2
                var atoms: [Atom] = []
                var closed = false
                while k < L.count {
                    let t = tokens(L[k])
                    if t.isEmpty { closed = true; break }
                    guard t.count >= 4, let x = Double(t[1]), let y = Double(t[2]), let z = Double(t[3]),
                          let z0 = IOElements.atomicNumber(label: String(t[0])) else {
                        throw fail(k, "bad coordinate line '\(L[k])'")
                    }
                    atoms.append(Atom(id: atoms.count, atomicNumber: z0, position: Vec3(x, y, z)))
                    k += 1
                }
                guard closed, !atoms.isEmpty else { throw fail(min(k, L.count - 1), "truncated or empty coordinate block") }
                var m = Molecule(atoms: atoms, charge: out.charge, multiplicity: out.multiplicity)
                m.perceiveBonds()
                commitGeometry(m)
                i = k; continue
            }
            if line.hasPrefix("FINAL SINGLE POINT ENERGY"), let v = tokens(line).last.flatMap({ Double($0) }) {
                out.finalEnergy = v
                if energyForStepPending { out.energies.append(v); energyForStepPending = false }
            }
            if line.contains("Geometry convergence|") {
                // header, "Item ..." row, dashes, items..., dashes
                var k = i + 1
                guard k + 2 < L.count else { throw fail(L.count - 1, "truncated convergence table") }
                k += 2
                var items: [OrcaConvergenceItem] = []
                var closed = false
                while k < L.count {
                    if isDashes(L[k]) || L[k].trimmingCharacters(in: .whitespaces).hasPrefix("....") { closed = true; break }
                    let t = tokens(L[k])
                    if t.count >= 4, let yn = t.last, yn == "YES" || yn == "NO",
                       let tol = Double(t[t.count - 2]), let val = Double(t[t.count - 3]) {
                        items.append(OrcaConvergenceItem(name: t[0..<(t.count - 3)].joined(separator: " "), value: val, tolerance: tol, converged: yn == "YES"))
                    }
                    k += 1
                }
                guard closed else { throw fail(L.count - 1, "truncated convergence table") }
                out.optimizationCycles.append(OrcaOptimizationCycle(cycle: out.optimizationCycles.count + 1, items: items))
                i = k; continue
            }
            if line.contains("THE OPTIMIZATION HAS CONVERGED") { out.optimizationConverged = true }
            if line.lowercased().contains("the optimization did not converge") { out.optimizationConverged = false }

            if header(i, "ORBITAL ENERGIES") {
                var k = i + 2
                var spin: OrbitalInfo.Spin = .restricted
                var rows: [OrbitalInfo] = []
                var ended = false
                var sawRows = false
                while k < L.count {
                    let s = trimmed(k)
                    if s.hasPrefix("SPIN UP") { spin = .alpha; k += 1; continue }
                    if s.hasPrefix("SPIN DOWN") { spin = .beta; k += 1; continue }
                    if s.hasPrefix("NO ") { k += 1; continue }
                    let t = tokens(L[k])
                    if t.count >= 3, let idx = Int(t[0]), let occ = Double(t[1]), let e = Double(t[2]) {
                        rows.append(OrbitalInfo(index: idx + 1, energy: e, occupied: occ > 0.0, spin: spin))
                        sawRows = true; k += 1; continue
                    }
                    if s.isEmpty && !sawRows { k += 1; continue }
                    if s.isEmpty, spin == .alpha, !rows.contains(where: { $0.spin == .beta }) {
                        // blank between spin-up and spin-down blocks (or before the *Only note)
                        var kk = k
                        while kk < L.count, trimmed(kk).isEmpty { kk += 1 }
                        if kk < L.count, trimmed(kk).hasPrefix("SPIN DOWN") { k = kk; continue }
                        if kk >= L.count { break }
                    }
                    ended = true; break
                }
                guard ended, !rows.isEmpty else { throw fail(L.count - 1, "truncated orbital energy table") }
                out.orbitals = rows
                i = k; continue
            }
            if header(i, "MULLIKEN ATOMIC CHARGES") || header(i, "MULLIKEN ATOMIC CHARGES AND SPIN POPULATIONS") {
                let b = try chargeBlock(i + 2, spin: true)
                guard b.next < L.count else { throw fail(L.count - 1, "truncated Mulliken table") }
                out.mullikenCharges = b.q; out.mullikenSpins = b.s; i = b.next; continue
            }
            if header(i, "LOEWDIN ATOMIC CHARGES") || header(i, "LOEWDIN ATOMIC CHARGES AND SPIN POPULATIONS") {
                let b = try chargeBlock(i + 2, spin: true)
                guard b.next < L.count else { throw fail(L.count - 1, "truncated Loewdin table") }
                out.loewdinCharges = b.q; out.loewdinSpins = b.s; i = b.next; continue
            }
            if header(i, "HIRSHFELD ANALYSIS") {
                var k = i + 2
                while k < L.count, !trimmed(k).hasPrefix("ATOM") { k += 1 }
                guard k < L.count else { throw fail(L.count - 1, "truncated Hirshfeld block") }
                k += 1
                var q: [Double] = [], s: [Double] = []
                var closed = false
                while k < L.count {
                    let t = tokens(L[k])
                    if t.count >= 4, Int(t[0]) != nil, let c = Double(t[2]), let sp = Double(t[3]) { q.append(c); s.append(sp); k += 1 }
                    else { closed = true; break }
                }
                guard closed else { throw fail(L.count - 1, "truncated Hirshfeld table") }
                out.hirshfeldCharges = q; out.hirshfeldSpins = s; i = k; continue
            }
            if line.hasPrefix("Expectation value of <S**2>"), let v = tokens(line).last.flatMap({ Double($0) }) { out.spinSquared = v }

            if header(i, "CARTESIAN GRADIENT") {
                var k = i + 2
                while k < L.count, trimmed(k).isEmpty { k += 1 }
                var g: [Vec3] = []
                var closed = false
                while k < L.count {
                    let t = tokens(L[k])
                    if t.isEmpty { closed = true; break }
                    guard t.count >= 6, t[2] == ":", let x = Double(t[3]), let y = Double(t[4]), let z = Double(t[5]) else {
                        throw fail(k, "bad gradient line '\(L[k])'")
                    }
                    g.append(Vec3(x, y, z)); k += 1
                }
                guard closed else { throw fail(L.count - 1, "truncated gradient block") }
                out.gradients.append(g); i = k; continue
            }
            if line.hasPrefix("Total Dipole Moment"), let c = line.firstIndex(of: ":") {
                let t = tokens(line[line.index(after: c)...])
                if t.count >= 3, let x = Double(t[0]), let y = Double(t[1]), let z = Double(t[2]) {
                    out.dipoleDebye = Vec3(x, y, z) * debyePerAU
                }
            }

            if header(i, "VIBRATIONAL FREQUENCIES") {
                var k = i + 2
                var f: [Double] = []
                var closed = false
                while k < L.count {
                    let t = tokens(L[k])
                    if t.count >= 2, t[0].hasSuffix(":"), Int(t[0].dropLast()) != nil {
                        guard let v = Double(t[1]) else { throw fail(k, "bad frequency line") }
                        f.append(v); k += 1
                    } else if t.isEmpty && !f.isEmpty { closed = true; break }
                    else if t.isEmpty || t.first == "Scaling" { k += 1
                    } else { closed = !f.isEmpty; break }
                }
                guard closed else { throw fail(L.count - 1, "truncated frequency list") }
                out.allFrequencies = f; vibCount = f.count
                out.firstVibrationIndex = f.prefix { abs($0) < 0.01 }.count
                i = k; continue
            }
            if header(i, "NORMAL MODES"), vibCount > 0 {
                var k = i + 2
                var cols: [[Double]] = Array(repeating: [], count: vibCount)
                var got = 0
                while k < L.count, got < vibCount {
                    let t = tokens(L[k])
                    if !t.isEmpty, t.count <= 6, t.allSatisfy({ Int($0) != nil }), Int(t[0]) == got {
                        let nc = t.count
                        guard k + vibCount < L.count else { throw fail(L.count - 1, "truncated normal mode block") }
                        for r in 0..<vibCount {
                            let rt = tokens(L[k + 1 + r])
                            guard rt.count == nc + 1, Int(rt[0]) == r else { throw fail(k + 1 + r, "bad normal mode row '\(L[k + 1 + r])'") }
                            for c in 0..<nc {
                                guard let v = Double(rt[c + 1]) else { throw fail(k + 1 + r, "bad normal mode value") }
                                cols[got + c].append(v)
                            }
                        }
                        got += nc; k += vibCount + 1
                    } else { k += 1 }
                }
                guard got == vibCount else { throw fail(L.count - 1, "truncated normal mode table") }
                let natoms = vibCount / 3
                out.allNormalModes = (0..<vibCount).map { j in
                    let d = (0..<natoms).map { Vec3(cols[j][3 * $0], cols[j][3 * $0 + 1], cols[j][3 * $0 + 2]) }
                    return NormalMode(frequency: out.allFrequencies[j], irIntensity: 0, displacements: d)
                }
                i = k; continue
            }
            if header(i, "IR SPECTRUM") || header(i, "RAMAN SPECTRUM") {
                let raman = trimmed(i) == "RAMAN SPECTRUM"
                var k = i + 2
                var closed = false
                var rows = 0
                while k < L.count {
                    let t = tokens(L[k])
                    if t.count >= 4, t[0].hasSuffix(":"), let idx = Int(t[0].dropLast()), let v = Double(raman ? t[2] : t[3]) {
                        if idx < out.allNormalModes.count {
                            if raman { out.allNormalModes[idx].ramanActivity = v } else { out.allNormalModes[idx].irIntensity = v }
                        }
                        rows += 1
                    } else if t.isEmpty, rows > 0 { closed = true; break }
                    k += 1
                }
                guard closed else { throw fail(L.count - 1, "truncated \(raman ? "Raman" : "IR") table") }
                i = k; continue
            }

            // Excited states
            if (trimmed(i).hasPrefix("TD-DFT/TDA EXCITED STATES") || trimmed(i).hasPrefix("TD-DFT EXCITED STATES")) && i + 1 < L.count && L[i + 1].hasPrefix("---") {
                lastStatesMult = trimmed(i).contains("TRIPLET") ? 3 : 1
                var k = i + 2
                var cur: OrcaExcitedState?
                while k < L.count {
                    let t = tokens(L[k])
                    if t.isEmpty { k += 1; continue }
                    if t.first == "STATE", t.count >= 3 {
                        if let c = cur { out.excitedStates.append(c) }
                        guard let idx = Int(t[1].dropLast()), let ie = t.firstIndex(of: "eV"), ie > 0, let ev = Double(t[ie - 1]) else {
                            throw fail(k, "bad STATE line")
                        }
                        var cm = ev * 8065.54429
                        if let ic = t.firstIndex(where: { $0.hasPrefix("cm**") }), ic > 0, let v = Double(t[ic - 1]) { cm = v }
                        var mult = lastStatesMult
                        if let im = t.firstIndex(of: "Mult"), im + 1 < t.count, let m = Int(t[im + 1]) { mult = m }
                        cur = OrcaExcitedState(index: idx, multiplicity: mult, energyEV: ev, energyCm1: cm, wavelengthNM: nil, oscillatorStrength: nil, transitions: [])
                    } else if t.count >= 5, t[1] == "->", t[3] == ":", let w = Double(t[4]), cur != nil {
                        cur?.transitions.append(OrcaTransition(from: String(t[0]), to: String(t[2]), weight: w))
                    } else if t[0] == "the" {
                    } else { break }
                    k += 1
                }
                if let c = cur { out.excitedStates.append(c) }
                i = k; continue
            }
            if trimmed(i).hasPrefix("ABSORPTION SPECTRUM VIA TRANSITION ELECTRIC DIPOLE MOMENTS") {
                var k = i + 1
                var hasEV = false
                var rowsSeen = 0
                var closed = false
                while k < L.count {
                    let s = L[k]
                    let t = tokens(s)
                    if s.contains("(eV)") { hasEV = true }
                    if t.isEmpty { if rowsSeen > 0 { closed = true; break }; k += 1; continue }
                    if isDashes(s) || !(t[0].first?.isNumber ?? false) { k += 1; continue }
                    var label: String; var rest: [Substring]
                    var mult = lastStatesMult
                    if t.count > 3, t[1] == "->" {
                        let dest = String(t[2])
                        let parts = dest.split(separator: "-")
                        label = String(parts.first ?? "")
                        if parts.count > 1, let m = Int(parts[1].prefix { $0.isNumber }) { mult = m }
                        rest = Array(t[3...])
                    } else { label = String(t[0]); rest = Array(t.dropFirst()) }
                    guard let idx = Int(label), let nums = doubles(Array(rest.prefix(hasEV ? 4 : 3))), nums.count == (hasEV ? 4 : 3) else {
                        throw fail(k, "bad spectrum row '\(s)'")
                    }
                    let ev: Double? = hasEV ? nums[0] : nil
                    let nm = hasEV ? nums[2] : nums[1]
                    let f = hasEV ? nums[3] : nums[2]
                    spectrumRows["\(mult)-\(idx)"] = (nm, f, ev)
                    rowsSeen += 1; k += 1
                }
                guard closed else { throw fail(L.count - 1, "truncated absorption spectrum") }
                for n in out.excitedStates.indices {
                    let key = "\(out.excitedStates[n].multiplicity)-\(out.excitedStates[n].index)"
                    if let r = spectrumRows[key] { out.excitedStates[n].wavelengthNM = r.nm; out.excitedStates[n].oscillatorStrength = r.f }
                }
                i = k; continue
            }

            // Thermochemistry (single-line items)
            if line.hasPrefix("Temperature         ..."), let v = tokens(line).dropLast().last.flatMap({ Double($0) }) { thermo.temperature = v; haveThermo = true }
            else if line.hasPrefix("Pressure            ..."), let v = tokens(line).dropLast().last.flatMap({ Double($0) }) { thermo.pressure = v }
            else if line.hasPrefix("Electronic energy  "), let v = eh(String(line)) { thermo.electronicEnergy = v }
            else if line.hasPrefix("Zero point energy"), let v = eh(String(line)) { thermo.zeroPointEnergy = v }
            else if line.hasPrefix("Total correction"), let v = eh(String(line)) { thermo.thermalEnergyCorrection = v }
            else if line.hasPrefix("Total Enthalpy"), let v = eh(String(line)) { thermo.totalEnthalpy = v }
            else if line.hasPrefix("Final entropy term"), let v = eh(String(line)) { thermo.entropy = v }
            else if line.hasPrefix("Final Gibbs free energy"), let v = eh(String(line)) { thermo.totalGibbs = v }
            else if line.hasPrefix("G-E(el)"), let v = eh(String(line)) { thermo.gibbsCorrection = v }

            if header(i, "RELAXED SURFACE SCAN RESULTS") {
                var k = i + 2
                var seen = false
                var pts: [OrcaScanPoint] = []
                var closed = false
                while k < L.count {
                    let s = trimmed(k)
                    if s.hasPrefix("The Calculated Surface using the 'Actual") { seen = true; k += 1; continue }
                    if seen {
                        let t = tokens(L[k])
                        if t.count == 2, let c = Double(t[0]), let e = Double(t[1]) { pts.append(OrcaScanPoint(coordinate: c, energy: e)) }
                        else if t.isEmpty, !pts.isEmpty { closed = true; break }
                    }
                    k += 1
                }
                guard closed else { throw fail(L.count - 1, "truncated scan surface table") }
                out.scanSurface = pts; i = k; continue
            }

            if line.contains("ORCA finished by error termination") || line.contains("aborting the run") {
                out.errorTermination = true
                let m = line.trimmingCharacters(in: .whitespaces)
                if !out.messages.contains(m) { out.messages.append(m) }
            }
            if line.contains("SCF NOT CONVERGED") || line.contains("SCF convergence failure") {
                let m = line.trimmingCharacters(in: CharacterSet(charactersIn: " *"))
                if !out.messages.contains(m) { out.messages.append(m) }
            }
            i += 1
        }
        if haveThermo || thermo.totalGibbs != nil {
            if let e = thermo.electronicEnergy {
                if let h = thermo.totalEnthalpy { thermo.enthalpyCorrection = h - e }
            }
            out.thermochemistry = thermo
        }
        out.normalTermination = (text.contains("ORCA TERMINATED NORMALLY") || tailLine.contains("ORCA TERMINATED NORMALLY")) && !out.errorTermination
        if out.optimizationConverged == nil, out.keywordLines.joined(separator: " ").uppercased().split(separator: " ").contains(where: { $0 == "OPT" || $0 == "TIGHTOPT" || $0 == "OPTTS" }) {
            out.optimizationConverged = false
        }
        guard !out.inputLines.isEmpty || !out.geometries.isEmpty || out.programVersion != nil else {
            throw MolIOError.parse(format: "orca", line: nil, message: "no recognizable ORCA content")
        }
        return out
    }
}

// MARK: - .engrad

/// ORCA `.engrad` file: energy, gradient (Hartree/Bohr) and atoms (positions converted Bohr -> Angstrom).
public struct OrcaEngrad: Sendable, Codable, Equatable {
    public var energy: Double
    public var gradient: [Vec3]
    public var molecule: Molecule

    public static func read(url: URL) throws -> OrcaEngrad { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> OrcaEngrad {
        func fail(_ m: String) -> MolIOError { .parse(format: "orca-engrad", line: nil, message: m) }
        // Sections are introduced by "# ..." comment lines; collect data lines per section.
        var sections: [[String]] = []
        var cur: [String] = []
        var inHeader = true
        for l in splitLines(text) {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") {
                if !inHeader { if !cur.isEmpty { sections.append(cur); cur = [] }; inHeader = true }
                continue
            }
            if s.isEmpty { continue }
            inHeader = false
            cur.append(s)
        }
        if !cur.isEmpty { sections.append(cur) }
        guard sections.count >= 4, let n = Int(sections[0][0]), n > 0, let e = Double(sections[1][0]) else { throw fail("not an engrad file") }
        let g = sections[2].compactMap { parseFortranDouble($0) }
        guard g.count == 3 * n, sections[2].count == 3 * n else { throw fail("gradient has \(g.count) values, expected \(3 * n)") }
        guard sections[3].count == n else { throw fail("atom block has \(sections[3].count) rows, expected \(n)") }
        var atoms: [Atom] = []
        for (k, row) in sections[3].enumerated() {
            let t = tokens(row)
            guard t.count >= 4, let z = Int(t[0]), let x = Double(t[1]), let y = Double(t[2]), let w = Double(t[3]) else { throw fail("bad atom row '\(row)'") }
            atoms.append(Atom(id: k, atomicNumber: z, position: Vec3(x, y, w) * bohrToAngstrom))
        }
        var m = Molecule(atoms: atoms)
        m.perceiveBonds()
        let grad = (0..<n).map { Vec3(g[3 * $0], g[3 * $0 + 1], g[3 * $0 + 2]) }
        return OrcaEngrad(energy: e, gradient: grad, molecule: m)
    }
}
