import Foundation
import simd
import MolCore

// Protein residues, backbone atoms and secondary structure for the cartoon view.
//
// Residues come from the PDB file's ATOM/HETATM records when the structure was opened from a PDB file (atoms are
// matched to records by their coordinates, so edits that add, delete or reorder atoms keep the residues of the
// untouched atoms). Otherwise the backbone is perceived from the bond graph (N–CA–C(=O) linked by C–N peptide
// bonds). Secondary structure comes from the file's HELIX/SHEET records when present, else from a simplified DSSP
// (backbone N–H···O=C electrostatic H-bond energies, i→i+3/i+4/i+5 turns, parallel/antiparallel bridges, ladders).

/// DSSP-like secondary-structure letter of one residue.
public enum SecondaryStructure: Character, Sendable, Hashable, CaseIterable {
    case alphaHelix = "H", helix310 = "G", piHelix = "I", strand = "E", bridge = "B", turn = "T", loop = "L"

    /// The three cartoon shapes.
    public enum Kind: String, Sendable, Hashable, CaseIterable { case helix, strand, loop }
    public var kind: Kind {
        switch self {
        case .alphaHelix, .helix310, .piHelix: return .helix
        case .strand: return .strand
        default: return .loop
        }
    }
}

/// One amino-acid residue with its backbone atom indices (-1 = absent).
public struct ProteinResidue: Sendable, Hashable {
    public var chain: String
    public var seq: Int
    public var iCode: String
    public var name: String
    public var n = -1, ca = -1, c = -1, o = -1, h = -1
    /// Every atom of the residue (backbone + side chain).
    public var atoms: [Int] = []
    public var isProline = false
    public init(chain: String, seq: Int, iCode: String = "", name: String) {
        self.chain = chain; self.seq = seq; self.iCode = iCode; self.name = name
    }
}

/// HELIX / SHEET record range.
public struct SecondaryStructureRange: Sendable, Hashable {
    public var chain: String, startSeq: Int, startICode: String, endSeq: Int, endICode: String
    public var ss: SecondaryStructure
}

/// The parts of a PDB file the protein analysis needs, read without the full `PDBFormat` parse.
public struct PDBProteinRecords: Sendable {
    public struct AtomRecord: Sendable, Hashable {
        public var name: String, resName: String, chainID: String, resSeq: Int, iCode: String
        public var position: Vec3
    }
    /// One array per MODEL.
    public var models: [[AtomRecord]]
    public var ranges: [SecondaryStructureRange]

    public init(models: [[AtomRecord]], ranges: [SecondaryStructureRange]) { self.models = models; self.ranges = ranges }

    /// Reads ATOM/HETATM coordinates, residue fields and HELIX/SHEET records.
    public static func parse(_ text: String) -> PDBProteinRecords {
        var models: [[AtomRecord]] = []
        var cur: [AtomRecord] = []
        var ranges: [SecondaryStructureRange] = []
        func field(_ b: ArraySlice<UInt8>, _ from: Int, _ to: Int) -> String {
            let lo = b.startIndex + from - 1, hi = min(b.startIndex + to, b.endIndex)
            guard lo < hi else { return "" }
            return String(decoding: b[lo..<hi], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        let bytes = Array(text.utf8)
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 10 { end += 1 }
            var lineEnd = end
            if lineEnd > start && bytes[lineEnd - 1] == 13 { lineEnd -= 1 }
            let b = bytes[start..<lineEnd]
            start = end + 1
            guard b.count >= 3 else { continue }
            let rec = field(b, 1, 6)
            switch rec {
            case "ATOM", "HETATM":
                guard b.count >= 54, let x = Double(field(b, 31, 38)), let y = Double(field(b, 39, 46)),
                      let z = Double(field(b, 47, 54)) else { continue }
                cur.append(AtomRecord(name: field(b, 13, 16), resName: field(b, 18, 20), chainID: field(b, 22, 22),
                                      resSeq: Int(field(b, 23, 26)) ?? 0, iCode: field(b, 27, 27), position: Vec3(x, y, z)))
            case "ENDMDL", "END":
                if !cur.isEmpty { models.append(cur); cur = [] }
            case "HELIX":
                if let s = Int(field(b, 22, 25)), let e = Int(field(b, 34, 37)) {
                    let cls = Int(field(b, 39, 40)) ?? 1
                    ranges.append(SecondaryStructureRange(chain: field(b, 20, 20), startSeq: s, startICode: field(b, 26, 26), endSeq: e,
                                                          endICode: field(b, 38, 38),
                                                          ss: cls == 5 ? .helix310 : (cls == 3 ? .piHelix : .alphaHelix)))
                }
            case "SHEET":
                if let s = Int(field(b, 23, 26)), let e = Int(field(b, 34, 37)) {
                    ranges.append(SecondaryStructureRange(chain: field(b, 22, 22), startSeq: s, startICode: field(b, 27, 27), endSeq: e,
                                                          endICode: field(b, 38, 38), ss: .strand))
                }
            default: break
            }
        }
        if !cur.isEmpty { models.append(cur) }
        return PDBProteinRecords(models: models, ranges: ranges)
    }
}

/// Result of `ProteinAnalysis.analyze`. Residue arrays are parallel; atom indices refer to the analysed molecule.
public struct ProteinStructure: Sendable, Equatable {
    public enum Source: String, Sendable { case file, topology, computed, none }
    public var atomCount: Int
    public var residues: [ProteinResidue]
    public var ss: [SecondaryStructure]
    /// Continuous backbone segments (half-open residue ranges); chain breaks split segments.
    public var segments: [Range<Int>]
    /// Atoms drawn by the cartoon (residue atoms plus hydrogens bonded to them).
    public var polymerAtoms: [Bool]
    /// Water atoms (residue names HOH, WAT, …; from the file records only).
    public var waterAtoms: [Bool]
    /// Where the residues came from (`file` or `topology`) and where the secondary structure came from
    /// (`file`, `computed` or `none`).
    public var residueSource: Source
    public var ssSource: Source

    public var residueCount: Int { residues.count }
    public var isEmpty: Bool { residues.isEmpty }
    public var helixCount: Int { count(.helix) }
    public var strandCount: Int { count(.strand) }
    public var chains: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in residues where seen.insert(r.chain).inserted { out.append(r.chain) }
        return out
    }
    private func count(_ k: SecondaryStructure.Kind) -> Int {
        var n = 0
        for seg in segments { for r in seg where ss[r].kind == k && (r == seg.lowerBound || ss[r - 1].kind != k) { n += 1 } }
        return n
    }
    public var ssString: String { String(ss.map(\.rawValue)) }

    public static let empty = ProteinStructure(atomCount: 0, residues: [], ss: [], segments: [], polymerAtoms: [], waterAtoms: [],
                                               residueSource: .none, ssSource: .none)
}

public enum ProteinAnalysis {
    public enum Mode: String, Sendable { case auto, file, computed }
    static let waterNames: Set<String> = ["HOH", "WAT", "DOD", "H2O", "SOL", "TIP", "TIP3", "TP3", "SPC"]

    /// Cheap pre-test: enough atoms and some nitrogen. Avoids running the analysis on small molecules.
    public static func looksLikeProtein(_ m: Molecule) -> Bool {
        m.atoms.count >= 20 && m.atoms.contains { $0.atomicNumber == 7 }
    }

    /// Residues and secondary structure. `records` are the PDB records of the file the molecule came from (nil:
    /// perceive from bonds). `mode`: auto (file records, else DSSP), file (records only), computed (always DSSP).
    public static func analyze(_ m: Molecule, records: PDBProteinRecords? = nil, mode: Mode = .auto) -> ProteinStructure {
        var residues: [ProteinResidue] = []
        var waters = [Bool](repeating: false, count: m.atoms.count)
        var residueSource = ProteinStructure.Source.topology
        if let rec = records, !rec.models.isEmpty {
            // The model whose coordinates match best (trajectory frames of a multi-model file).
            var order = Array(rec.models.indices)
            if let same = order.firstIndex(where: { rec.models[$0].count == m.atoms.count }) { order.swapAt(0, same) }
            for k in order.prefix(4) {
                let (r, w) = fromRecords(m, records: rec.models[k])
                if !r.isEmpty { residues = r; waters = w; residueSource = .file; break }
            }
        }
        if residues.isEmpty { residues = fromTopology(m) }
        let R = residues.count
        guard R > 0 else {
            var e = ProteinStructure.empty
            e.atomCount = m.atoms.count; e.polymerAtoms = [Bool](repeating: false, count: m.atoms.count); e.waterAtoms = waters
            return e
        }
        // Continuous backbone segments: same chain and a peptide C–N distance.
        var segments: [Range<Int>] = []
        var segOf = [Int](repeating: 0, count: R)
        var start = 0
        for r in 1..<max(R, 1) {
            let a = residues[r - 1], b = residues[r]
            let linked = a.chain == b.chain && simd_distance(m.atoms[a.c].position, m.atoms[b.n].position) < 2.0
            if !linked { segments.append(start..<r); start = r }
            segOf[r] = segments.count
        }
        segments.append(start..<R)

        var ss = [SecondaryStructure](repeating: .loop, count: R)
        var ssSource = ProteinStructure.Source.none
        if let rec = records, mode != .computed, !rec.ranges.isEmpty, residueSource == .file {
            applyRanges(rec.ranges, residues: residues, ss: &ss)
            ssSource = .file
        } else if mode != .file {
            ss = dssp(m, residues: residues, segment: segOf)
            ssSource = .computed
        }

        var polymer = [Bool](repeating: false, count: m.atoms.count)
        for r in residues { for a in r.atoms { polymer[a] = true } }
        for b in m.bonds where b.a < m.atoms.count && b.b < m.atoms.count {
            for (x, y) in [(b.a, b.b), (b.b, b.a)] where m.atoms[x].atomicNumber == 1 {
                if !polymer[x] && polymer[y] && !waters[x] { polymer[x] = true }
                if waters[y] && !waters[x] { waters[x] = true }
            }
        }
        return ProteinStructure(atomCount: m.atoms.count, residues: residues, ss: ss, segments: segments, polymerAtoms: polymer,
                                waterAtoms: waters, residueSource: residueSource, ssSource: ssSource)
    }

    // MARK: Residues from PDB records

    static func posKey(_ v: Vec3) -> Int64 {
        let x = Int64((v.x * 1000).rounded()) & 0x1FFFFF, y = Int64((v.y * 1000).rounded()) & 0x1FFFFF
        let z = Int64((v.z * 1000).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }

    static func fromRecords(_ m: Molecule, records: [PDBProteinRecords.AtomRecord]) -> ([ProteinResidue], [Bool]) {
        var byPos: [Int64: Int] = [:]
        byPos.reserveCapacity(records.count)
        for (k, a) in records.enumerated() { byPos[posKey(a.position)] = k }
        // Residues are runs of consecutive records with the same chain/number/insertion code/name.
        var run = [Int](repeating: 0, count: records.count)
        var runs = 0
        for k in records.indices where k > 0 {
            let a = records[k - 1], b = records[k]
            if a.resSeq != b.resSeq || a.chainID != b.chainID || a.iCode != b.iCode || a.resName != b.resName { runs += 1 }
            run[k] = runs
        }
        var groups = [ProteinResidue?](repeating: nil, count: records.isEmpty ? 0 : runs + 1)
        var names = [[String]](repeating: [], count: groups.count)
        var waters = [Bool](repeating: false, count: m.atoms.count)
        for (i, a) in m.atoms.enumerated() {
            guard let k = byPos[posKey(a.position)] else { continue }
            let rec = records[k]
            if waterNames.contains(rec.resName.uppercased()) { waters[i] = true; continue }
            let g = run[k]
            if groups[g] == nil {
                groups[g] = ProteinResidue(chain: rec.chainID, seq: rec.resSeq, iCode: rec.iCode, name: rec.resName)
                groups[g]!.isProline = rec.resName.uppercased() == "PRO"
            }
            if names[g].contains(rec.name) { continue }   // first alternate location wins
            names[g].append(rec.name)
            groups[g]!.atoms.append(i)
            switch rec.name {
            case "N": groups[g]!.n = i
            case "CA" where a.atomicNumber == 6: groups[g]!.ca = i
            case "C": groups[g]!.c = i
            case "O", "OT1", "O1": if groups[g]!.o < 0 { groups[g]!.o = i }
            case "H", "HN": groups[g]!.h = i
            default: break
            }
        }
        let residues = groups.compactMap { $0 }.filter { $0.n >= 0 && $0.ca >= 0 && $0.c >= 0 }
        return (residues, waters)
    }

    // MARK: Residues from the bond graph

    static func fromTopology(_ m: Molecule) -> [ProteinResidue] {
        let n = m.atoms.count
        guard n >= 4, !m.bonds.isEmpty else { return [] }
        let adj = m.adjacency()
        let z = m.atoms.map(\.atomicNumber)
        func heavy(_ i: Int) -> [Int] { adj[i].filter { z[$0] > 1 } }
        // Backbone candidates: carbonyl C bonded to a terminal O and to a CA that is bonded to an N. One residue per
        // CA: a Ser/Thr CB–OG looks the same locally, so prefer a C with three heavy neighbours (peptide N or OXT),
        // then the shorter C–O.
        var best: [Int: (c: Int, o: Int, n: Int, score: Double)] = [:]
        for c in 0..<n where z[c] == 6 {
            let hn = heavy(c)
            guard let o = hn.filter({ z[$0] == 8 && heavy($0).count == 1 })
                .min(by: { m.distance(c, $0) < m.distance(c, $1) }), m.distance(c, o) < 1.85 else { continue }
            for ca in hn where z[ca] == 6 && ca != c {
                guard heavy(ca).count <= 4, let nn = heavy(ca).first(where: { z[$0] == 7 }) else { continue }
                let score = (hn.count == 3 ? 0.0 : 10.0) + m.distance(c, o)
                if let b = best[ca], b.score <= score { break }
                best[ca] = (c, o, nn, score)
                break
            }
        }
        var resOfC: [Int: ProteinResidue] = [:]
        var cOfN: [Int: Int] = [:]
        for (ca, b) in best {
            var r = ProteinResidue(chain: "", seq: 0, name: "UNK")
            r.n = b.n; r.ca = ca; r.c = b.c; r.o = b.o
            r.h = adj[b.n].first(where: { z[$0] == 1 }) ?? -1
            r.isProline = heavy(b.n).filter { $0 != ca && z[$0] == 6 }.count >= 2 && r.h < 0
            resOfC[b.c] = r
            cOfN[b.n] = b.c
        }
        guard !resOfC.isEmpty else { return [] }
        var nextC: [Int: Int] = [:], hasPrev = Set<Int>()
        for (c, _) in resOfC {
            for nb in adj[c] where z[nb] == 7 {
                if let c2 = cOfN[nb], c2 != c, resOfC[c2]?.n == nb { nextC[c] = c2; hasPrev.insert(c2); break }
            }
        }
        let starts = resOfC.keys.filter { !hasPrev.contains($0) }.sorted { resOfC[$0]!.n < resOfC[$1]!.n }
        var out: [ProteinResidue] = []
        var visited = Set<Int>()
        var inBackbone = [Bool](repeating: false, count: n)
        for r in resOfC.values { for a in [r.n, r.ca, r.c, r.o] { inBackbone[a] = true } }
        let chainNames = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        var chainIndex = 0
        var claimed = [Bool](repeating: false, count: n)
        for s in starts + resOfC.keys.sorted() where !visited.contains(s) {   // the second list catches cycles
            var cur: Int? = s, seq = 1
            let chain = chainIndex < chainNames.count ? chainNames[chainIndex] : "\(chainIndex + 1)"
            chainIndex += 1
            while let c = cur, !visited.contains(c), var r = resOfC[c] {
                visited.insert(c)
                r.chain = chain; r.seq = seq; seq += 1
                var atoms = [r.n, r.ca, r.c, r.o]
                for a in atoms { claimed[a] = true }
                var stack = adj[r.ca].filter { !inBackbone[$0] }
                stack += adj[r.n].filter { z[$0] == 1 } + adj[r.c].filter { z[$0] == 8 && !inBackbone[$0] && heavy($0).count == 1 }
                while let a = stack.popLast(), atoms.count < 40 {
                    if claimed[a] || inBackbone[a] { continue }
                    claimed[a] = true; atoms.append(a)
                    for nb in adj[a] where !claimed[nb] && !inBackbone[nb] { stack.append(nb) }
                }
                r.atoms = atoms
                out.append(r)
                cur = nextC[c]
            }
        }
        // A lone "residue" is most likely an amide in a small molecule, not a protein.
        return out.count >= 3 ? out : []
    }

    // MARK: HELIX / SHEET records

    static func applyRanges(_ ranges: [SecondaryStructureRange], residues: [ProteinResidue], ss: inout [SecondaryStructure]) {
        var index: [String: Int] = [:]
        for (k, r) in residues.enumerated() { index["\(r.chain)|\(r.seq)|\(r.iCode)"] = k }
        for g in ranges {
            guard let a = index["\(g.chain)|\(g.startSeq)|\(g.startICode)"], let b = index["\(g.chain)|\(g.endSeq)|\(g.endICode)"],
                  a <= b else { continue }
            for k in a...b where residues[k].chain == g.chain { ss[k] = g.ss }
        }
    }

    // MARK: Simplified DSSP

    @inline(__always) static func dist2(_ a: Vec3, _ b: Vec3) -> Double {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return x * x + y * y + z * z
    }

    /// DSSP electrostatic H-bond energy (kcal/mol) of N–H(donor)···O=C(acceptor).
    public static func hbondEnergy(n: Vec3, h: Vec3, c: Vec3, o: Vec3) -> Double {
        let dON = dist2(o, n).squareRoot(), dCH = dist2(c, h).squareRoot(), dOH = dist2(o, h).squareRoot(), dCN = dist2(c, n).squareRoot()
        guard dON > 0.5, dCH > 0.5, dOH > 0.5, dCN > 0.5 else { return -9.9 }
        return max(-9.9, 27.888 * (1 / dON + 1 / dCH - 1 / dOH - 1 / dCN))
    }

    static func dssp(_ m: Molecule, residues res: [ProteinResidue], segment: [Int]) -> [SecondaryStructure] {
        let R = res.count
        let P = m.atoms.map(\.position)
        let ca = res.map { P[$0.ca] }
        let cell = 9.0
        func cellOf(_ v: Vec3) -> (Int64, Int64, Int64) {
            (Int64((v.x / cell).rounded(.down)), Int64((v.y / cell).rounded(.down)), Int64((v.z / cell).rounded(.down)))
        }
        func key(_ x: Int64, _ y: Int64, _ z: Int64) -> Int64 { ((x & 0x1FFFFF) << 42) | ((y & 0x1FFFFF) << 21) | (z & 0x1FFFFF) }
        var grid: [Int64: [Int]] = [:]
        for r in 0..<R { let c = cellOf(ca[r]); grid[key(c.0, c.1, c.2), default: []].append(r) }
        func near(_ r: Int, _ cutoff: Double, _ body: (Int) -> Void) {
            let c = cellOf(ca[r]), c2 = cutoff * cutoff
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                guard let list = grid[key(c.0 + Int64(dx), c.1 + Int64(dy), c.2 + Int64(dz))] else { continue }
                for j in list where j != r && dist2(ca[j], ca[r]) < c2 { body(j) }
            } } }
        }
        // Amide H: the file's H, else placed 1.0 Å from N opposite the previous carbonyl (DSSP).
        var hPos = [Vec3?](repeating: nil, count: R)
        for r in 0..<R where !res[r].isProline {
            if res[r].h >= 0 { hPos[r] = P[res[r].h]; continue }
            guard r > 0, segment[r - 1] == segment[r], res[r - 1].o >= 0 else { continue }
            let d = P[res[r - 1].c] - P[res[r - 1].o]
            let len = simd_length(d)
            if len > 1e-6 { hPos[r] = P[res[r].n] + d / len }
        }
        // Two best acceptors (C=O residue) per donor (N–H residue), E < -0.5 kcal/mol.
        var acc1 = [Int](repeating: -1, count: R), acc2 = [Int](repeating: -1, count: R)
        var e1 = [Double](repeating: 0, count: R), e2 = [Double](repeating: 0, count: R)
        for j in 0..<R {
            guard let H = hPos[j] else { continue }
            let N = P[res[j].n]
            near(j, 9.0) { i in
                guard abs(i - j) >= 2 || segment[i] != segment[j], res[i].o >= 0 else { return }
                let C = P[res[i].c], O = P[res[i].o]
                guard dist2(O, N) < 30.25 else { return }
                let e = hbondEnergy(n: N, h: H, c: C, o: O)
                guard e < -0.5 else { return }
                if e < e1[j] { acc2[j] = acc1[j]; e2[j] = e1[j]; acc1[j] = i; e1[j] = e }
                else if e < e2[j] { acc2[j] = i; e2[j] = e }
            }
        }
        func hb(_ i: Int, _ j: Int) -> Bool {   // C=O of i accepts from N–H of j
            guard i >= 0, j >= 0, i < R, j < R else { return false }
            return acc1[j] == i || acc2[j] == i
        }
        func contiguous(_ a: Int, _ b: Int) -> Bool { a >= 0 && b < R && a <= b && segment[a] == segment[b] }

        var ss = [SecondaryStructure](repeating: .loop, count: R)
        func turn(_ i: Int, _ n: Int) -> Bool { contiguous(i, i + n) && hb(i, i + n) }
        var t3 = [Bool](repeating: false, count: R), t4 = t3, t5 = t3
        for i in 0..<R { t3[i] = turn(i, 3); t4[i] = turn(i, 4); t5[i] = turn(i, 5) }
        for i in 1..<max(R, 1) where t4[i - 1] && t4[i] { for k in i..<min(i + 4, R) { ss[k] = .alphaHelix } }

        // Bridges.
        var partners = [[(Int, Bool)]](repeating: [], count: R)   // (partner, parallel)
        for i in 1..<max(R - 1, 1) {
            guard contiguous(i - 1, i + 1) else { continue }
            near(i, 7.0) { j in
                guard j > i, j > i + 2 || segment[j] != segment[i], contiguous(j - 1, j + 1) else { return }
                let parallel = (hb(i - 1, j) && hb(j, i + 1)) || (hb(j - 1, i) && hb(i, j + 1))
                let anti = (hb(i, j) && hb(j, i)) || (hb(i - 1, j + 1) && hb(j - 1, i + 1))
                if parallel || anti {
                    partners[i].append((j, parallel && !anti))
                    partners[j].append((i, parallel && !anti))
                }
            }
        }
        // Ladders: a bridge with a neighbouring bridge in register makes both strands E; isolated ones are B.
        var isE = [Bool](repeating: false, count: R)
        for i in 0..<R {
            for (j, par) in partners[i] {
                let step = par ? 1 : -1
                for d in [-1, 1] {
                    let i2 = i + d, j2 = j + d * step
                    guard i2 >= 0, i2 < R, segment[i2] == segment[i] else { continue }
                    if partners[i2].contains(where: { $0.0 == j2 && $0.1 == par }) { isE[i] = true; isE[j] = true }
                }
            }
        }
        // β-bulges: one- or two-residue gaps inside a strand whose flanks pair with the same stretch of the partner.
        for i in 1..<max(R, 1) where !isE[i] && isE[i - 1] {
            for gap in 1...2 where i + gap < R && isE[i + gap] && contiguous(i - 1, i + gap) {
                let a = i - 1, b = i + gap
                let bulge = partners[a].contains { pa in
                    partners[b].contains { pb in abs(pa.0 - pb.0) <= 5 && (min(pa.0, pb.0) > b || max(pa.0, pb.0) < a) }
                }
                if bulge { for k in i..<b { isE[k] = true } }
                break
            }
        }
        for i in 0..<R where ss[i] == .loop {
            if isE[i] { ss[i] = .strand } else if !partners[i].isEmpty { ss[i] = .bridge }
        }
        for i in 1..<max(R, 1) where t3[i - 1] && t3[i] {
            let r = i..<min(i + 3, R)
            if r.allSatisfy({ ss[$0] == .loop || ss[$0] == .helix310 }) { for k in r { ss[k] = .helix310 } }
        }
        for i in 1..<max(R, 1) where t5[i - 1] && t5[i] {
            let r = i..<min(i + 5, R)
            if r.allSatisfy({ ss[$0] == .loop || ss[$0] == .piHelix }) { for k in r { ss[k] = .piHelix } }
        }
        for i in 1..<max(R, 1) where ss[i] == .loop && (t3[i - 1] || t4[i - 1]) { ss[i] = .turn }
        // Single strand residues look odd as arrows: demote to bridge.
        for i in 0..<R where ss[i] == .strand {
            let left = i > 0 && ss[i - 1] == .strand && segment[i - 1] == segment[i]
            let right = i + 1 < R && ss[i + 1] == .strand && segment[i + 1] == segment[i]
            if !left && !right { ss[i] = .bridge }
        }
        return ss
    }
}
