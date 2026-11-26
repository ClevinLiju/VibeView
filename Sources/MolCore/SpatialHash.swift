import Foundation
import MolSIMD

/// Uniform-grid spatial index for fixed-radius neighbor queries.
public struct NeighborGrid: Sendable {
    private let positions: [Vec3]
    private let cellSize: Double
    private let inv: Double
    private let order: [Int]                       // point indices sorted by cell key
    private let ranges: [Int64: (Int, Int)]        // key -> (start, count) into `order`

    private static let bias = 1 << 20
    @inline(__always) private static func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        Int64(x + bias) << 42 | Int64(y + bias) << 21 | Int64(z + bias)
    }
    @inline(__always) private func cell(_ p: Vec3) -> (Int, Int, Int)? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
        let lim = Double(NeighborGrid.bias - 1)
        func c(_ v: Double) -> Int { Int(max(-lim, min(lim, (v * inv).rounded(.down)))) }
        return (c(p.x), c(p.y), c(p.z))
    }

    public init(positions: [Vec3], cellSize: Double) {
        let cs = (cellSize.isFinite && cellSize > 1e-6) ? cellSize : 1.0
        self.positions = positions
        self.cellSize = cs
        self.inv = 1.0 / cs
        let invLocal = 1.0 / cs
        let lim = Double(NeighborGrid.bias - 1)
        var keyed: [(Int64, Int)] = []
        keyed.reserveCapacity(positions.count)
        for (i, p) in positions.enumerated() where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            func c(_ v: Double) -> Int { Int(max(-lim, min(lim, (v * invLocal).rounded(.down)))) }
            keyed.append((NeighborGrid.key(c(p.x), c(p.y), c(p.z)), i))
        }
        keyed.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var ord = [Int](); ord.reserveCapacity(keyed.count)
        var rng: [Int64: (Int, Int)] = [:]
        var s = 0
        while s < keyed.count {
            var e = s
            while e < keyed.count && keyed[e].0 == keyed[s].0 { e += 1 }
            rng[keyed[s].0] = (ord.count, e - s)
            for k in s..<e { ord.append(keyed[k].1) }
            s = e
        }
        self.order = ord
        self.ranges = rng
    }

    /// Indices of points within `radius` of `point` (inclusive), ascending. The query point
    /// itself is included if it is one of the stored points.
    public func neighbors(of point: Vec3, within radius: Double) -> [Int] {
        guard radius >= 0, radius.isFinite, let (cx, cy, cz) = cell(point) else { return [] }
        let span = Int((radius * inv).rounded(.up))
        let r2 = radius * radius
        var out: [Int] = []
        for x in (cx - span)...(cx + span) {
            for y in (cy - span)...(cy + span) {
                for z in (cz - span)...(cz + span) {
                    guard let (st, n) = ranges[NeighborGrid.key(x, y, z)] else { continue }
                    for k in st..<(st + n) {
                        let j = order[k]
                        let d = positions[j] - point
                        if simd_length_squared(d) <= r2 { out.append(j) }
                    }
                }
            }
        }
        out.sort()
        return out
    }

    /// All index pairs (i < j) with distance <= radius, each once, sorted.
    public func pairs(within radius: Double) -> [(Int, Int)] {
        guard radius >= 0, radius.isFinite else { return [] }
        let span = max(1, Int((radius * inv).rounded(.up)))
        let r2 = radius * radius
        var out: [(Int, Int)] = []
        var tmp: [Int] = []
        for i in 0..<positions.count {
            let p = positions[i]
            guard let (cx, cy, cz) = cell(p) else { continue }
            tmp.removeAll(keepingCapacity: true)
            for x in (cx - span)...(cx + span) {
                for y in (cy - span)...(cy + span) {
                    for z in (cz - span)...(cz + span) {
                        guard let (st, n) = ranges[NeighborGrid.key(x, y, z)] else { continue }
                        for k in st..<(st + n) {
                            let j = order[k]
                            if j > i && simd_length_squared(positions[j] - p) <= r2 { tmp.append(j) }
                        }
                    }
                }
            }
            tmp.sort()
            for j in tmp { out.append((i, j)) }
        }
        return out
    }
}
