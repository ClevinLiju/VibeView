import Foundation
import MolCore
import MolIO

/// Data model for an orbital energy-level diagram (Lead C draws it). Energies in Hartree, with eV helpers.
public struct OrbitalLevelDiagram: Sendable, Equatable {
    public struct Level: Sendable, Equatable, Identifiable {
        public var id: Int { orbitalIndices.first ?? 0 }
        public var energy: Double                 // Hartree (mean of the group)
        public var energyEV: Double { energy * PhysConst.hartreeToEV }
        /// 0-based orbital indices in this (near-)degenerate group.
        public var orbitalIndices: [Int]
        /// Electrons per orbital in the group (2 restricted, 1 spin-resolved, 0 virtual).
        public var occupation: Double
        public var isHOMO: Bool
        public var isLUMO: Bool
        public var degeneracy: Int { orbitalIndices.count }
        public var isOccupied: Bool { occupation > 0 }
        /// Short label, e.g. "HOMO", "LUMO+1", "HOMO−2".
        public var label: String
    }

    public struct Column: Sendable, Equatable {
        public enum Spin: String, Sendable { case restricted, alpha, beta }
        public var spin: Spin
        public var levels: [Level]
        public var homo: Level? { levels.first(where: \.isHOMO) }
        public var lumo: Level? { levels.first(where: \.isLUMO) }
        public var homoLumoGapEV: Double? {
            guard let h = homo, let l = lumo else { return nil }
            return (l.energy - h.energy) * PhysConst.hartreeToEV
        }
    }

    public var columns: [Column]
    public var degeneracyTolerance: Double

    /// Smallest HOMO–LUMO gap over all columns (eV); for UHF this is min(α, β) gaps.
    public var homoLumoGapEV: Double? { columns.compactMap(\.homoLumoGapEV).min() }

    /// Builds a column from energies (Hartree, ascending or not) and per-orbital occupations.
    public static func column(energies: [Double], occupations: [Double], spin: Column.Spin,
                              tolerance: Double = 1e-3) -> Column {
        let order = energies.indices.sorted { energies[$0] < energies[$1] }
        var groups: [[Int]] = []
        for i in order {
            // Degenerate groups never mix occupied and virtual orbitals (keeps HOMO/LUMO well defined).
            if let last = groups.last?.last, abs(energies[i] - energies[last]) <= tolerance,
               (occupations[i] > 0) == (occupations[last] > 0) {
                groups[groups.count - 1].append(i)
            } else { groups.append([i]) }
        }
        let homoG = groups.lastIndex { g in g.contains { occupations[$0] > 0 } }
        let lumoG = homoG.map { $0 + 1 < groups.count ? $0 + 1 : nil } ?? (groups.isEmpty ? nil : 0)
        var levels: [Level] = []
        for (gi, g) in groups.enumerated() {
            let e = g.map { energies[$0] }.reduce(0, +) / Double(g.count)
            let occ = g.map { occupations[$0] }.max() ?? 0
            var label = ""
            if let h = homoG, gi <= h { label = gi == h ? "HOMO" : "HOMO−\(h - gi)" }
            else if let l = lumoG { label = gi == l ? "LUMO" : "LUMO+\(gi - l)" }
            levels.append(Level(energy: e, orbitalIndices: g, occupation: occ,
                                isHOMO: gi == homoG, isLUMO: gi == lumoG, label: label))
        }
        return Column(spin: spin, levels: levels)
    }

    public init(columns: [Column], degeneracyTolerance: Double = 1e-3) {
        self.columns = columns; self.degeneracyTolerance = degeneracyTolerance
    }

    /// From a wavefunction: one restricted column, or alpha + beta columns when unrestricted.
    public init(wavefunction wf: Wavefunction, tolerance: Double = 1e-3) {
        if let b = wf.beta, wf.isUnrestricted {
            let nA = wf.alphaElectrons, nB = wf.betaElectrons
            columns = [
                Self.column(energies: wf.alpha.energies, occupations: wf.alpha.energies.indices.map { $0 < nA ? 1 : 0 }, spin: .alpha, tolerance: tolerance),
                Self.column(energies: b.energies, occupations: b.energies.indices.map { $0 < nB ? 1 : 0 }, spin: .beta, tolerance: tolerance),
            ]
        } else {
            let nA = wf.alphaElectrons, nB = wf.betaElectrons
            let occ = wf.alpha.energies.indices.map { Double(($0 < nA ? 1 : 0) + ($0 < nB ? 1 : 0)) }
            columns = [Self.column(energies: wf.alpha.energies, occupations: occ, spin: .restricted, tolerance: tolerance)]
        }
        degeneracyTolerance = tolerance
    }

    /// From parsed orbital tables (`CalculationResult.orbitals`). `OrbitalInfo.index` is 1-based; output indices are 0-based.
    public init(orbitals: [OrbitalInfo], tolerance: Double = 1e-3) {
        var cols: [Column] = []
        for spin in [OrbitalInfo.Spin.restricted, .alpha, .beta] {
            let os = orbitals.filter { $0.spin == spin }.sorted { $0.index < $1.index }
            guard !os.isEmpty else { continue }
            var e = [Double](repeating: 0, count: (os.map(\.index).max() ?? 0))
            var o = [Double](repeating: 0, count: e.count)
            for x in os where x.index >= 1 { e[x.index - 1] = x.energy; o[x.index - 1] = x.occupied ? (spin == .restricted ? 2 : 1) : 0 }
            // Indices that were not printed stay at 0 energy; drop them by building from the printed set only.
            let printed = Set(os.map { $0.index - 1 })
            var c = Self.column(energies: e, occupations: o, spin: spin == .restricted ? .restricted : (spin == .alpha ? .alpha : .beta),
                                tolerance: tolerance)
            c.levels = c.levels.compactMap { lv in
                let keep = lv.orbitalIndices.filter(printed.contains)
                guard !keep.isEmpty else { return nil }
                var l = lv; l.orbitalIndices = keep; return l
            }
            cols.append(c)
        }
        self.init(columns: cols, degeneracyTolerance: tolerance)
    }

    /// Levels within `window` eV below HOMO and above LUMO of each column (for a compact default view).
    public func energyRange(window: Double = 10) -> ClosedRange<Double> {
        let h = columns.compactMap { $0.homo?.energyEV }.max() ?? 0
        let l = columns.compactMap { $0.lumo?.energyEV }.min() ?? h
        return (h - window)...(l + window)
    }
}

/// Density of states: broadened orbital energies.
public enum DensityOfStates {
    /// Total DOS. x = energy (eV), y = states/eV (area-normalized line shapes, so ∫ y dE = Σ weights).
    /// `weights` default to 1 per orbital (use 2 for a restricted closed shell if you want electron-weighted).
    /// Sticks mark the levels (height = weight), `sourceIndex` = orbital index.
    public static func compute(energies: [Double], weights: [Double]? = nil, fwhmEV: Double = 0.3,
                               shape: LineShape = .gaussian, rangeEV: ClosedRange<Double>? = nil,
                               pointCount: Int = 1500) -> Spectrum {
        let ev = energies.map { $0 * PhysConst.hartreeToEV }
        let w = weights ?? Array(repeating: 1, count: ev.count)
        let lo = rangeEV?.lowerBound ?? ((ev.min() ?? -20) - 5 * fwhmEV)
        let hi = rangeEV?.upperBound ?? ((ev.max() ?? 5) + 5 * fwhmEV)
        let n = max(2, pointCount)
        let step = (hi - lo) / Double(n - 1)
        var y = [Double](repeating: 0, count: n)
        let reach = (shape == .gaussian ? 4 : 60) * fwhmEV
        for (k, e) in ev.enumerated() where w[k] != 0 {
            let i0 = max(0, Int(((e - reach) - lo) / step)), i1 = min(n - 1, Int(((e + reach) - lo) / step) + 1)
            guard i0 <= i1 else { continue }
            for i in i0...i1 { y[i] += w[k] * Broadening.area(shape, x: lo + Double(i) * step, center: e, fwhm: fwhmEV) }
        }
        let pts = (0..<n).map { SpectrumPoint(x: lo + Double($0) * step, y: y[$0]) }
        let sticks = ev.enumerated().filter { lo...hi ~= $0.element }.map { SpectrumStick(x: $0.element, height: w[$0.offset], sourceIndex: $0.offset) }
        return Spectrum(points: pts, sticks: sticks, xLabel: "Energy (eV)", yLabel: "DOS (states/eV)")
    }

    /// Total and occupied-only DOS for a wavefunction (alpha + beta orbitals; restricted orbitals count twice).
    public static func compute(_ wf: Wavefunction, fwhmEV: Double = 0.3, shape: LineShape = .gaussian,
                               rangeEV: ClosedRange<Double>? = nil, pointCount: Int = 1500) -> (total: Spectrum, occupied: Spectrum) {
        var e: [Double] = [], w: [Double] = [], occ: [Double] = []
        let nA = wf.alphaElectrons, nB = wf.betaElectrons
        if let b = wf.beta, wf.isUnrestricted {
            e = wf.alpha.energies + b.energies
            w = Array(repeating: 1, count: e.count)
            occ = wf.alpha.energies.indices.map { $0 < nA ? 1 : 0 } + b.energies.indices.map { $0 < nB ? 1 : 0 }
        } else {
            e = wf.alpha.energies
            w = Array(repeating: 2, count: e.count)
            occ = e.indices.map { Double(($0 < nA ? 1 : 0) + ($0 < nB ? 1 : 0)) }
        }
        let evs = e.map { $0 * PhysConst.hartreeToEV }
        let range = rangeEV ?? (((evs.min() ?? -20) - 5 * fwhmEV)...((evs.max() ?? 5) + 5 * fwhmEV))
        return (compute(energies: e, weights: w, fwhmEV: fwhmEV, shape: shape, rangeEV: range, pointCount: pointCount),
                compute(energies: e, weights: occ, fwhmEV: fwhmEV, shape: shape, rangeEV: range, pointCount: pointCount))
    }
}
