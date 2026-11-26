import Foundation
import MolCore
import MolSIMD

// Thermochemistry, orbital energies, population analyses, dipole and excited states.

extension GaussianLogParser {

    // MARK: Thermochemistry

    mutating func handleTemperature(_ t: Substring) {
        // Temperature   298.150 Kelvin.  Pressure   1.00000 Atm.
        recognized = true
        let tk = tokens(t)
        var th = GaussianLog.Thermochemistry()
        if tk.count > 1 { th.temperature = Double(tk[1]) }
        if let pi = tk.firstIndex(of: "Pressure"), pi + 1 < tk.count { th.pressure = Double(tk[pi + 1]) }
        log.thermochemistries.append(th)
    }

    private mutating func setThermo(_ kp: WritableKeyPath<GaussianLog.Thermochemistry, Double?>, _ v: Double) {
        if log.thermochemistries.isEmpty || log.thermochemistries[log.thermochemistries.count - 1][keyPath: kp] != nil {
            log.thermochemistries.append(GaussianLog.Thermochemistry())
        }
        log.thermochemistries[log.thermochemistries.count - 1][keyPath: kp] = v
    }

    mutating func handleThermoLine(_ t: Substring) {
        guard let eq = t.firstIndex(of: "=") else { return }
        let key = glTrim(t[..<eq])
        guard let v = parseFortranDouble(tokens(t[t.index(after: eq)...]).first ?? "") else { return }
        recognized = true
        switch key {
        case "Zero-point correction": setThermo(\.zeroPointCorrection, v)
        case "Thermal correction to Energy": setThermo(\.thermalCorrectionEnergy, v)
        case "Thermal correction to Enthalpy": setThermo(\.thermalCorrectionEnthalpy, v)
        case "Thermal correction to Gibbs Free Energy": setThermo(\.thermalCorrectionGibbs, v)
        case "Sum of electronic and zero-point Energies": setThermo(\.sumElectronicZeroPoint, v)
        case "Sum of electronic and thermal Energies": setThermo(\.sumElectronicThermalEnergy, v)
        case "Sum of electronic and thermal Enthalpies": setThermo(\.sumElectronicThermalEnthalpy, v)
        case "Sum of electronic and thermal Free Energies": setThermo(\.sumElectronicThermalGibbs, v)
        default: break
        }
    }

    // MARK: Orbital energies

    mutating func handleEigenvalues(_ i: Int, _ t: Substring, alpha: Bool) throws {
        recognized = true
        let occ = t.contains(" occ.")
        guard occ || t.contains(" virt.") else { return }
        var vals: [Double] = []
        for s in glNumberTokens(glAfterDashes(t)) {
            guard let v = parseFortranDouble(s) else { throw err(i, "non-numeric orbital energy") }
            vals.append(v)
        }
        if alpha {
            if occ && alphaLastVirtual {      // a new SCF set starts
                log.orbitals = GaussianLog.Orbitals(); alphaLastVirtual = false; betaLastVirtual = false
            }
            if occ { log.orbitals.alphaOccupied += vals } else { log.orbitals.alphaVirtual += vals; alphaLastVirtual = true }
        } else {
            if occ && betaLastVirtual { log.orbitals.betaOccupied = []; log.orbitals.betaVirtual = []; betaLastVirtual = false }
            if occ { log.orbitals.betaOccupied += vals } else { log.orbitals.betaVirtual += vals; betaLastVirtual = true }
        }
    }

    // MARK: Atom tables (Mulliken, APT)

    /// Reads "idx Sym v1 [v2]" rows after a header line. Returns rows and the next index, or nil when
    /// the block is truncated (no closing "Sum of" line and fewer rows than atoms).
    private func atomRows(_ start: Int, minValues: Int) throws -> (rows: [[Double]], next: Int, complete: Bool) {
        var j = start
        if j < n {
            let tk = tokens(lines[j])
            if !tk.isEmpty, tk.allSatisfy({ Int($0) != nil }), tk.count <= 2 { j += 1 }
        }
        var rows: [[Double]] = []
        var closed = false
        while j < n {
            let u = glTrim(lines[j])
            if u.hasPrefix("Sum of") { closed = true; j += 1; break }
            let tk = tokens(u)
            guard tk.count >= 2 + minValues, Int(tk[0]) != nil, Int(tk[1]) == nil else { break }
            var vals: [Double] = []
            for s in tk.dropFirst(2) {
                guard let v = parseFortranDouble(s) else { throw err(j, "non-numeric value in atom table") }
                vals.append(v)
            }
            rows.append(vals)
            j += 1
        }
        let complete = closed || (natoms > 0 && rows.count == natoms && j >= n)
        return (rows, j, complete || (natoms > 0 && rows.count == natoms))
    }

    mutating func handleMulliken(_ i: Int, _ t: Substring) throws -> Int {
        if t.contains("summed") { return i + 1 }
        let withSpin = t.hasPrefix("Mulliken charges and spin densities")
        guard t == "Mulliken charges:" || t == "Mulliken atomic charges:" || withSpin else { return i + 1 }
        recognized = true
        let r = try atomRows(i + 1, minValues: withSpin ? 2 : 1)
        guard r.complete, !r.rows.isEmpty else { return max(r.next, i + 1) }
        log.mullikenCharges = r.rows.map { $0[0] }
        if withSpin { log.mullikenSpinDensities = r.rows.map { $0[1] } }
        return r.next
    }

    mutating func handleAPT(_ i: Int) throws -> Int {
        recognized = true
        let r = try atomRows(i + 1, minValues: 1)
        guard r.complete, !r.rows.isEmpty else { return max(r.next, i + 1) }
        log.aptCharges = r.rows.map { $0[0] }
        return r.next
    }

    /// "Summary of Natural Population Analysis:" table; closed by a "====" rule.
    mutating func handleNaturalPopulation(_ i: Int) throws -> Int {
        recognized = true
        var j = i + 1
        var seenRule = false
        var guardCount = 0
        while j < n, !seenRule {
            if glIsDashed(lines[j]) { seenRule = true }
            j += 1; guardCount += 1
            if guardCount > 8 { return i + 1 }
        }
        guard seenRule else { return n }
        var charges: [Double] = []
        var closed = false
        while j < n {
            let u = glTrim(lines[j])
            if u.hasPrefix("=") { closed = true; j += 1; break }
            let tk = tokens(u)
            guard tk.count >= 3, Int(tk[0]) == nil, Int(tk[1]) != nil else {
                if isTail(j) { break }
                throw err(j, "malformed natural population row")
            }
            guard let q = Double(tk[2]) else { throw err(j, "non-numeric natural charge") }
            charges.append(q)
            j += 1
        }
        if closed, !charges.isEmpty { log.naturalCharges = charges }
        return max(j, i + 1)
    }

    mutating func handleHirshfeld(_ i: Int) throws -> Int {
        recognized = true
        var j = i + 1
        var skipped = 0
        var q: [Double] = [], s: [Double] = [], cm5: [Double] = []
        while j < n {
            let u = glTrim(lines[j])
            let tk = tokens(u)
            if tk.count >= 3, Int(tk[0]) != nil, Int(tk[1]) == nil {
                guard let qv = Double(tk[2]) else { throw err(j, "non-numeric Hirshfeld charge") }
                q.append(qv)
                if tk.count >= 8 {
                    if let sv = Double(tk[3]) { s.append(sv) }
                    if let cv = Double(tk[7]) { cm5.append(cv) }
                }
                j += 1
            } else if q.isEmpty {
                skipped += 1; j += 1
                if skipped > 3 { return i + 1 }
            } else { break }
        }
        let expected = natoms
        if !q.isEmpty, expected == 0 || q.count == expected {
            log.hirshfeldCharges = q
            log.hirshfeldSpinDensities = s.count == q.count ? s : []
            log.cm5Charges = cm5.count == q.count ? cm5 : []
        }
        return max(j, i + 1)
    }

    // MARK: Dipole

    mutating func handleDipole(_ i: Int) throws -> Int {
        guard i + 1 < n else { return n }
        let kv = glKeyedValues(lines[i + 1])
        guard let x = kv["X"], let y = kv["Y"], let z = kv["Z"] else {
            if isTail(i + 1) { return n }
            return i + 1
        }
        recognized = true
        log.dipole = Vec3(x, y, z)
        log.dipoleMagnitude = kv["Tot"] ?? simd_length(Vec3(x, y, z))
        return i + 2
    }

    // MARK: Excited states

    mutating func handleTotalEnergy(_ t: Substring) {
        guard !log.excitedStates.isEmpty, let eq = t.lastIndex(of: "="),
              let v = parseFortranDouble(tokens(t[t.index(after: eq)...]).first ?? "") else { return }
        log.excitedStates[log.excitedStates.count - 1].totalEnergy = v
    }

    mutating func handleExcitedState(_ i: Int, _ t: Substring) throws -> Int {
        // Excited State   1:      Singlet-A"     3.9000 eV  317.90 nm  f=0.0000  <S**2>=0.000
        let tk = tokens(t.replacingOccurrences(of: "f=", with: "f= ").replacingOccurrences(of: "<S**2>=", with: "<S**2>= "))
        guard tk.count >= 3, tk[1] == "State" else { return i + 1 }
        recognized = true
        func bad() throws -> Int {
            if isTail(i) { return n }
            throw err(i, "malformed Excited State line")
        }
        guard let idx = Int(tk[2].replacingOccurrences(of: ":", with: "")),
              let evi = tk.firstIndex(of: "eV"), evi >= 5, let nmi = tk.firstIndex(of: "nm"), nmi >= 1,
              let e = Double(tk[evi - 1]), let nm = Double(tk[nmi - 1]) else { return try bad() }
        let label = tk[3..<(evi - 1)].joined(separator: " ")
        var f: Double? = nil, s2: Double? = nil
        for (k, s) in tk.enumerated() where k + 1 < tk.count {
            if s == "f=" { f = Double(tk[k + 1]) }
            else if s == "<S**2>=" { s2 = Double(tk[k + 1]) }
        }
        guard let fv = f else { return try bad() }
        var mult: Int? = nil
        var sym: String? = nil
        let mnames = ["Singlet": 1, "Doublet": 2, "Triplet": 3, "Quartet": 4, "Quintet": 5, "Sextet": 6]
        if let dash = label.firstIndex(of: "-") {
            mult = mnames[String(label[..<dash])]
            sym = String(label[label.index(after: dash)...])
        } else { mult = mnames[label] }
        if idx == 1 { log.excitedStates = [] }

        var trans: [GaussianLog.Transition] = []
        var j = i + 1
        while j < n {
            let u = glTrim(lines[j])
            var arrow: Range<Substring.Index>? = u.range(of: "->")
            var de = false
            if arrow == nil { arrow = u.range(of: "<-"); de = arrow != nil }
            guard let a = arrow else { break }
            let left = glTrim(u[..<a.lowerBound])
            let right = tokens(u[a.upperBound...])
            func parseOrb(_ s: Substring) -> (Int, GaussianLog.Transition.Spin?)? {
                if let v = Int(s) { return (v, nil) }
                if s.hasSuffix("A"), let v = Int(s.dropLast()) { return (v, .alpha) }
                if s.hasSuffix("B"), let v = Int(s.dropLast()) { return (v, .beta) }
                return nil
            }
            guard right.count >= 2, let from = parseOrb(left), let to = parseOrb(right[0]), let c = parseFortranDouble(right[1]) else {
                if isTail(j) { break }
                throw err(j, "malformed transition line")
            }
            trans.append(.init(from: from.0, to: to.0, coefficient: c, spin: from.1 ?? to.1, isDeexcitation: de))
            j += 1
        }
        log.excitedStates.append(.init(index: idx, label: label, multiplicity: mult, symmetry: sym, energyEV: e,
                                       wavelengthNM: nm, oscillatorStrength: fv, s2: s2, totalEnergy: nil, transitions: trans))
        return j
    }
}
