import Foundation
import MolCore

// Geometry-related blocks of a Gaussian log: orientation tables, optimization convergence,
// relaxed scans and IRC paths.

extension GaussianLogParser {

    // MARK: Orientation tables

    /// Parses "Input/Standard/Z-Matrix orientation:" tables. A table that is not closed before EOF
    /// (truncated log) is dropped; non-numeric rows inside a closed table throw.
    mutating func handleOrientation(_ i: Int, standard: Bool) throws -> Int {
        recognized = true
        // header, dashed, 2 column-header lines, dashed, rows..., dashed
        var j = i + 1
        guard j < n else { return n }
        guard glIsDashed(lines[j]) else { return i + 1 }
        j += 1
        // the two header lines (contain "Center"/"Number" words) then a rule
        var guardCount = 0
        while j < n, !glIsDashed(lines[j]) {
            j += 1; guardCount += 1
            if guardCount > 4 { return i + 1 }     // not a real table
        }
        guard j < n else { return n }              // truncated inside the header
        let first = j + 1
        var end = first
        while end < n, !glIsDashed(lines[end]) { end += 1 }
        guard end < n else { return n }            // table never closed: truncated, drop it
        var atoms: [Atom] = []
        atoms.reserveCapacity(end - first)
        for k in first..<end {
            let tk = tokens(lines[k])
            guard tk.count >= 5, Int(tk[0]) != nil, let z = Int(tk[1]) else {
                throw err(k, "malformed row in orientation table")
            }
            let m = tk.count
            guard let x = Double(tk[m - 3]), let y = Double(tk[m - 2]), let zc = Double(tk[m - 1]) else {
                throw err(k, "non-numeric coordinates in orientation table")
            }
            atoms.append(Atom(id: atoms.count, atomicNumber: max(0, z), position: Vec3(x, y, zc)))
        }
        guard !atoms.isEmpty else { throw err(i, "empty orientation table") }
        natoms = atoms.count
        let mol = Molecule(atoms: atoms, bonds: [], charge: charge, multiplicity: multiplicity, title: title)
        ensureJob()
        if standard, var last = log.geometrySteps.last, last.standard == nil, last.input != nil, last.energy == nil {
            last.standard = mol
            log.geometrySteps[log.geometrySteps.count - 1] = last
        } else if standard {
            log.geometrySteps.append(.init(input: nil, standard: mol, energy: nil))
        } else {
            log.geometrySteps.append(.init(input: mol, standard: nil, energy: nil))
        }
        return end + 1
    }

    // MARK: Optimization

    mutating func handleStepNumber(_ t: Substring) {
        let tk = tokens(t)
        if tk.count > 2, let s = Int(tk[2]) { pendingStepNumber = s }
        if t.contains("on scan point") { handleScanPointText(t) }
    }

    mutating func handleScanPointText(_ t: Substring) {
        let tk = tokens(t)
        guard let pi = tk.firstIndex(of: "point"), pi + 1 < tk.count, let p = Int(tk[pi + 1]) else { return }
        currentScanPoint = p
        if pi + 4 < tk.count, let tot = Int(tk[pi + 4]) { currentScanTotal = tot }
    }

    mutating func handleConvergence(_ i: Int) throws -> Int {
        recognized = true
        let names = ["Maximum Force", "RMS Force", "Maximum Displacement", "RMS Displacement"]
        var crit: [GaussianLog.ConvergenceCriterion] = []
        var j = i + 1
        for expected in names {
            guard j < n else { return n }          // truncated table: drop
            let tk = tokens(lines[j])
            if tk.count < 5 {
                if j == n - 1 || isTail(j) { return n }
                throw err(j, "malformed convergence row")
            }
            let name = "\(tk[0]) \(tk[1])"
            guard name == expected else { throw err(j, "unexpected convergence criterion '\(name)'") }
            guard let v = glConvValue(tk[2]), let th = glConvValue(tk[3]) else { throw err(j, "non-numeric convergence value") }
            let yn = tk[4]
            guard yn == "YES" || yn == "NO" else {
                if isTail(j) { return n }
                throw err(j, "expected YES/NO in convergence row")
            }
            let display = tk[0] == "RMS" ? "RMS     \(tk[1])" : name
            crit.append(.init(name: display, value: v, threshold: th, converged: yn == "YES"))
            j += 1
        }
        let gi = log.geometrySteps.isEmpty ? nil : log.geometrySteps.count - 1
        runningOptCount += 1
        let num = pendingStepNumber ?? runningOptCount
        pendingStepNumber = nil
        log.optimizationSteps.append(.init(
            stepNumber: num, scanPoint: currentScanPoint, geometryIndex: gi,
            energy: gi.flatMap { log.geometrySteps[$0].energy }, criteria: crit,
            predictedEnergyChange: nil, converged: crit.allSatisfy(\.converged)))
        return j
    }

    mutating func handlePredicted(_ i: Int, _ t: Substring) {
        guard let eq = t.firstIndex(of: "=") else { return }
        let s = t[t.index(after: eq)...]
        guard let v = parseFortranDouble(tokens(s).first ?? "") else { return }
        if var last = log.optimizationSteps.last, last.predictedEnergyChange == nil {
            last.predictedEnergyChange = v
            log.optimizationSteps[log.optimizationSteps.count - 1] = last
        }
    }

    mutating func handleOptimizationCompleted() {
        log.optimizationCompleted = true
        if let sp = currentScanPoint, !(log.scanPoints.last?.index == sp) {
            let gi = log.geometrySteps.isEmpty ? nil : log.geometrySteps.count - 1
            let g = gi.flatMap { log.geometrySteps[$0] }
            log.scanPoints.append(.init(index: sp, total: currentScanTotal, energy: g?.energy,
                                        geometry: g?.molecule, geometryIndex: gi))
        }
    }

    // MARK: Scan summary

    /// "Summary of the potential surface scan:" with rows "N  coord...  SCF".
    mutating func handleScanSummary(_ i: Int) -> Int {
        recognized = true
        var j = i + 1
        var rows: [GaussianLog.ScanSummaryRow] = []
        var skipped = 0
        while j < n {
            let u = glTrim(lines[j])
            let tk = tokens(u)
            var row: GaussianLog.ScanSummaryRow? = nil
            if tk.count >= 3, let idx = Int(tk[0]) {
                let vals = tk.dropFirst().compactMap { parseFortranDouble($0) }
                if vals.count == tk.count - 1, vals.count >= 2 {
                    row = .init(index: idx, coordinates: Array(vals.dropLast()), energy: vals[vals.count - 1])
                }
            }
            if let r = row { rows.append(r); j += 1; continue }
            if !rows.isEmpty { break }
            skipped += 1
            if skipped > 4 { break }
            j += 1
        }
        if !rows.isEmpty { log.scanSummary = rows }
        return max(j, i + 1)
    }

    // MARK: IRC

    mutating func handlePointNumber(_ t: Substring) {
        // "Point Number:   3          Path Number:   1"
        let tk = tokens(t)
        guard tk.count >= 6, let p = Int(tk[2]), let path = Int(tk[5]) else { return }
        currentIRC = (p, path)
    }

    mutating func handleIRCNet(_ t: Substring) {
        recognized = true
        guard let eq = t.firstIndex(of: "="), let v = parseFortranDouble(tokens(t[t.index(after: eq)...]).first ?? "") else { return }
        guard let cur = currentIRC else { return }
        let g = log.geometrySteps.last
        log.ircPoints.append(.init(path: cur.path, point: cur.point, reactionCoordinate: v,
                                   energy: g?.energy, geometry: g?.molecule))
    }
}

/// Convergence values may be "********" when the number overflows its field.
func glConvValue(_ s: Substring) -> Double? {
    if let v = parseFortranDouble(s) { return v }
    if s.allSatisfy({ $0 == "*" }) { return Double.greatestFiniteMagnitude }
    return nil
}
