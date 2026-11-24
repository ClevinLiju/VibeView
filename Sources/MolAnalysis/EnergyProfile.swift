import Foundation
import MolCore
import MolIO

/// Energy versus a (reaction / scan / step) coordinate: relaxed scans, IRC paths, optimization histories.
public struct EnergyProfile: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case scan, irc, optimization, custom }

    public struct Point: Sendable, Equatable {
        public var coordinate: Double
        /// Hartree
        public var energy: Double
        public var geometryIndex: Int?
        public var label: String?
        public init(coordinate: Double, energy: Double, geometryIndex: Int? = nil, label: String? = nil) {
            self.coordinate = coordinate; self.energy = energy; self.geometryIndex = geometryIndex; self.label = label
        }
    }

    public enum Reference: Sendable, Equatable {
        case first, minimum
        case index(Int)
        case value(Double)   // Hartree
    }

    public var kind: Kind
    public var points: [Point]
    public var xLabel: String

    public init(kind: Kind = .custom, points: [Point], xLabel: String = "Point") {
        self.kind = kind; self.points = points; self.xLabel = xLabel
    }

    /// Builds a profile from energies (Hartree); coordinates default to 0, 1, 2…
    public init(energies: [Double], coordinates: [Double]? = nil, kind: Kind = .custom, xLabel: String = "Point") {
        self.kind = kind; self.xLabel = xLabel
        self.points = energies.enumerated().map { i, e in
            Point(coordinate: (coordinates != nil && i < coordinates!.count) ? coordinates![i] : Double(i), energy: e)
        }
    }

    func referenceEnergy(_ ref: Reference) -> Double {
        switch ref {
        case .first: return points.first?.energy ?? 0
        case .minimum: return points.map { $0.energy }.min() ?? 0
        case .index(let i): return points.indices.contains(i) ? points[i].energy : (points.first?.energy ?? 0)
        case .value(let v): return v
        }
    }

    /// Energies relative to the chosen reference, in `unit`.
    public func relativeEnergies(unit: EnergyUnit, reference: Reference = .first) -> [Double] {
        let r = referenceEnergy(reference)
        return points.map { ($0.energy - r) * unit.fromHartree }
    }

    /// Plot points (x = coordinate, y = relative energy in `unit`).
    public func points(unit: EnergyUnit, reference: Reference = .first) -> [SpectrumPoint] {
        zip(points, relativeEnergies(unit: unit, reference: reference)).map { SpectrumPoint(x: $0.coordinate, y: $1) }
    }

    /// Highest energy minus the first point, in `unit` (0 when empty).
    public func barrier(unit: EnergyUnit) -> Double {
        guard let f = points.first, let m = points.map({ $0.energy }).max() else { return 0 }
        return (m - f.energy) * unit.fromHartree
    }

    /// Relaxed scan: uses the scan summary table (coordinate = first scanned value) when present,
    /// otherwise the per-point energies (coordinate = point index).
    public static func fromScan(_ log: GaussianLog) -> EnergyProfile? {
        var pts: [Point] = []
        if !log.scanSummary.isEmpty {
            for row in log.scanSummary {
                let gi = log.scanPoints.first { $0.index == row.index }?.geometryIndex
                pts.append(Point(coordinate: row.coordinates.first ?? Double(row.index), energy: row.energy,
                                 geometryIndex: gi, label: "scan point \(row.index)"))
            }
        } else {
            for sp in log.scanPoints {
                guard let e = sp.energy else { continue }
                pts.append(Point(coordinate: Double(sp.index), energy: e, geometryIndex: sp.geometryIndex,
                                 label: "scan point \(sp.index)"))
            }
        }
        guard !pts.isEmpty else { return nil }
        return EnergyProfile(kind: .scan, points: pts, xLabel: log.scanSummary.isEmpty ? "Scan point" : "Scan coordinate")
    }

    /// IRC path: forward branch positive, reverse branch negated, sorted so the TS is at 0.
    public static func fromIRC(_ log: GaussianLog) -> EnergyProfile? {
        var pts: [(Double, Int, Point)] = []
        for (n, p) in log.ircPoints.enumerated() {
            guard let e = p.energy else { continue }
            let mag = abs(p.reactionCoordinate ?? Double(p.point))
            let x = p.path == 2 ? -mag : mag
            pts.append((x, n, Point(coordinate: x, energy: e, geometryIndex: nil,
                                    label: "path \(p.path) point \(p.point)")))
        }
        guard !pts.isEmpty else { return nil }
        pts.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return EnergyProfile(kind: .irc, points: pts.map { $0.2 }, xLabel: "Reaction coordinate")
    }

    /// Optimization history: step number versus energy.
    public static func fromOptimization(_ log: GaussianLog) -> EnergyProfile? {
        let pts = log.optimizationSteps.compactMap { s -> Point? in
            guard let e = s.energy else { return nil }
            return Point(coordinate: Double(s.stepNumber), energy: e, geometryIndex: s.geometryIndex,
                         label: "step \(s.stepNumber)")
        }
        guard !pts.isEmpty else { return nil }
        return EnergyProfile(kind: .optimization, points: pts, xLabel: "Optimization step")
    }
}
