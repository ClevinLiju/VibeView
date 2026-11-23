import Foundation
import MolCore

// Harmonic frequency blocks: the standard 3-column layout and the 5-column high-precision
// ("Coord Atom Element:") layout of freq=HPModes.

extension GaussianLogParser {

    mutating func handleLowFrequencies(_ i: Int, _ t: Substring) throws {
        recognized = true
        var vals: [Double] = []
        for s in glNumberTokens(glAfterDashes(t)) {
            guard let v = parseFortranDouble(s) else { throw err(i, "non-numeric low frequency") }
            vals.append(v)
        }
        if lastLowFreqLine != i - 1 { log.lowFrequencies = [] }
        log.lowFrequencies += vals
        lastLowFreqLine = i
    }

    private func numbers(_ i: Int, _ t: Substring) throws -> [Double] {
        var vals: [Double] = []
        for s in glNumberTokens(glAfterDashes(t)) {
            guard let v = parseFortranDouble(s) else { throw err(i, "non-numeric value in frequency block") }
            vals.append(v)
        }
        return vals
    }

    /// Entered at a "Frequencies --" line. Returns the index after the block's last displacement row.
    mutating func handleVibrationBlock(_ i: Int, _ t: Substring) throws -> Int {
        recognized = true
        let freqs = try numbers(i, t)
        let k = freqs.count
        guard k > 0 else { throw err(i, "empty frequency line") }

        // Mode numbers and symmetry labels are on the two preceding lines.
        var firstIndex: Int? = nil
        var symmetry: [String]? = nil
        if i >= 2 {
            let idxTok = tokens(lines[i - 2])
            if idxTok.count == k, idxTok.allSatisfy({ Int($0) != nil }) { firstIndex = Int(idxTok[0]) }
            let symTok = tokens(lines[i - 1])
            if symTok.count == k { symmetry = symTok.map(String.init) }
        }

        var redMass: [Double]?, frc: [Double]?, ir: [Double]?, raman: [Double]?, depP: [Double]?, depU: [Double]?
        var j = i + 1
        var header: Substring? = nil
        while j < n {
            let u = glTrim(lines[j])
            if u.hasPrefix("Atom") && tokens(u).dropFirst().first == "AN" { header = u; break }
            if u.hasPrefix("Coord Atom Element:") { header = u; break }
            if u.hasPrefix("Red. masses") { redMass = try numbers(j, u) }
            else if u.hasPrefix("Frc consts") { frc = try numbers(j, u) }
            else if u.hasPrefix("IR Inten") { ir = try numbers(j, u) }
            else if u.hasPrefix("Raman Activ") { raman = try numbers(j, u) }
            else if u.hasPrefix("Depolar (P)") { depP = try numbers(j, u) }
            else if u.hasPrefix("Depolar (U)") { depU = try numbers(j, u) }
            else if u.contains(" --") { /* ignore */ }   // other per-mode properties (Rot. str., ...)
            else if u.isEmpty { /* skip */ }
            else { throw err(j, "unexpected line inside frequency block") }
            j += 1
            if j - i > 24 { throw err(i, "frequency block without displacement table") }
        }
        guard let h = header else { return n }     // truncated before the displacement table

        for arr in [redMass, frc, ir, raman, depP, depU] {
            if let a = arr, a.count != k { throw err(i, "property row length differs from frequency row") }
        }

        let isHP = h.hasPrefix("Coord")
        let expectedAtoms = natoms
        j += 1
        // displacement[mode][atom]
        var disp = [[Vec3]](repeating: [], count: k)

        if !isHP {
            var rows = 0
            while j < n {
                let tk = glNumberTokens(lines[j])
                guard tk.count == 2 + 3 * k, Int(tk[0]) != nil, Int(tk[1]) != nil else { break }
                for m in 0..<k {
                    guard let x = Double(tk[2 + 3 * m]), let y = Double(tk[3 + 3 * m]), let z = Double(tk[4 + 3 * m]) else {
                        throw err(j, "non-numeric displacement")
                    }
                    disp[m].append(Vec3(x, y, z))
                }
                rows += 1; j += 1
            }
            if rows == 0 || (expectedAtoms > 0 && rows < expectedAtoms) { return j }   // partial block: drop
        } else {
            var xyz = [[Double]](repeating: [], count: k)
            var rows = 0
            var atomsSeen = 0
            var lastAtom = -1
            while j < n {
                let tk = glNumberTokens(lines[j])
                guard tk.count == 3 + k, let ci = Int(tk[0]), let ai = Int(tk[1]), Int(tk[2]) != nil, ci > 0, ai > 0 else { break }
                for m in 0..<k {
                    guard let v = Double(tk[3 + m]) else { throw err(j, "non-numeric displacement") }
                    xyz[m].append(v)
                }
                if ai != lastAtom { atomsSeen += 1; lastAtom = ai }
                rows += 1; j += 1
            }
            let needed = expectedAtoms * 3
            if rows == 0 || rows % 3 != 0 || (expectedAtoms > 0 && rows < needed) { return j }
            for m in 0..<k {
                var c = 0
                while c + 2 < xyz[m].count { disp[m].append(Vec3(xyz[m][c], xyz[m][c + 1], xyz[m][c + 2])); c += 3 }
            }
        }

        var modes: [GaussianLog.Vibration] = []
        for m in 0..<k {
            modes.append(.init(frequency: freqs[m], reducedMass: redMass?[m], forceConstant: frc?[m],
                               irIntensity: ir?[m], ramanActivity: raman?[m],
                               depolarizationP: depP?[m], depolarizationU: depU?[m],
                               symmetry: symmetry?[m], displacements: disp[m]))
        }
        let starts = (firstIndex == nil) ? true : (firstIndex == 1)
        if isHP {
            if starts { hpModes = [] }
            hpModes += modes
        } else {
            if starts { stdModes = [] }
            stdModes += modes
        }
        return j
    }
}
