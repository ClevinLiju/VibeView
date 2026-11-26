import Foundation
import MolCore
import MolIO
import MolSIMD

// analysis.secondaryStructure: protein residues, backbone atoms and secondary structure for the cartoon view.
//
// Residues come from the PDB file's ATOM/HETATM records when the document was opened from a PDB file (atoms are
// matched to records by their coordinates, so edits that add, delete or reorder atoms keep the residues of the
// untouched atoms). Otherwise the backbone is perceived from the bond graph (N–CA–C(=O) linked by C–N peptide
// bonds). Secondary structure comes from the file's HELIX/SHEET records when present, else from a simplified DSSP
// (backbone N–H···O=C electrostatic H-bond energies, i→i+3/i+4 turns, parallel/antiparallel bridges and ladders).

extension Engine {
    func analysisSecondaryStructure(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let frame = p.optInt("frame")
        let mol: Molecule
        if let f = frame {
            if f == 0 && d.frames.isEmpty { mol = d.molecule } else {
                guard let fm = d.frame(f) else { throw RPCError.badRequest("frame \(f) is out of range") }
                mol = fm
            }
        } else { mol = d.molecule }
        let mode = p.optString("source") ?? "auto"
        guard ["auto", "file", "computed"].contains(mode) else { throw RPCError.badRequest("source must be auto, file or computed") }
        let pdbPath = d.format == .pdb ? d.path : nil
        let input = AsyncCapture(Unchecked((mol, pdbPath, frame ?? 0, mode)))
        let out = try await Offload.run(input) { box, cancelled -> JSON? in
            let (m, path, f, mode) = box.value.value
            return SecondaryStructure.analyze(m, pdbPath: path, model: f, mode: mode, cancelled: cancelled)
        }
        return out
    }
}

enum SecondaryStructure {
    struct Residue {
        var chain: String
        var seq: Int
        var iCode: String
        var name: String
        var n = -1, ca = -1, c = -1, o = -1, h = -1
        var atoms: [Int] = []
        var isProline = false
    }

    struct FileRange { var chain: String; var startSeq: Int; var startICode: String; var endSeq: Int; var endICode: String; var ss: Character }

    static let waterNames: Set<String> = ["HOH", "WAT", "DOD", "H2O", "SOL", "TIP", "TIP3", "TP3", "SPC"]

    // MARK: Entry

    static func analyze(_ m: Molecule, pdbPath: String?, model: Int, mode: String, cancelled: () -> Bool) -> JSON? {
        var residues: [Residue] = []
        var waters: [Int] = []
        var ranges: [FileRange] = []
        var residueSource = "topology"
        if let path = pdbPath, let parsed = PDBCache.shared.get(path) {
            ranges = parsed.ranges
            if !parsed.models.isEmpty {
                (residues, waters) = fromRecords(m, records: parsed.models[min(model, parsed.models.count - 1)])
                if !residues.isEmpty { residueSource = "file" }
            }
        }
        if cancelled() { return nil }
        if residues.isEmpty { residues = fromTopology(m) }
        if cancelled() { return nil }

        // Continuous backbone segments (peptide C–N bond length) and chain breaks.
        let R = residues.count
        var segment = [Int](repeating: 0, count: R)
        var segments: [[Int]] = []
        var start = 0
        for r in 0..<R {
            if r > 0 {
                let a = residues[r - 1], b = residues[r]
                let linked = a.chain == b.chain && simd_distance(m.atoms[a.c].position, m.atoms[b.n].position) < 2.0
                if !linked { segments.append([start, r]); start = r }
            }
            segment[r] = segments.count
        }
        if R > 0 { segments.append([start, R]) }

        var ss = [Character](repeating: "L", count: R)
        var ssSource = "none"
        if R > 0 {
            if mode != "computed" && !ranges.isEmpty && residueSource == "file" {
                applyFileRanges(ranges, residues: residues, ss: &ss)
                ssSource = "file"
            } else if mode != "file" {
                guard let computed = dssp(m, residues: residues, segment: segment, cancelled: cancelled) else { return nil }
                ss = computed
                ssSource = "computed"
            }
        }

        // Atoms covered by the cartoon: residue atoms plus hydrogens bonded to them that have no record.
        var polymer = [Bool](repeating: false, count: m.atoms.count)
        for r in residues { for a in r.atoms { polymer[a] = true } }
        var isWater = [Bool](repeating: false, count: m.atoms.count)
        for w in waters { isWater[w] = true }
        for b in m.bonds where b.a < m.atoms.count && b.b < m.atoms.count {
            for (x, y) in [(b.a, b.b), (b.b, b.a)] where m.atoms[x].atomicNumber == 1 && !polymer[x] && polymer[y] && !isWater[x] {
                polymer[x] = true
            }
            for (x, y) in [(b.a, b.b), (b.b, b.a)] where m.atoms[x].atomicNumber == 1 && !isWater[x] && isWater[y] {
                isWater[x] = true
            }
        }

        var helices = 0, strands = 0
        for r in 0..<R {
            let s = ss[r]
            let prev: Character = r > 0 && segment[r - 1] == segment[r] ? ss[r - 1] : "-"
            if (s == "H" || s == "G" || s == "I") && !(prev == "H" || prev == "G" || prev == "I") { helices += 1 }
            if s == "E" && prev != "E" { strands += 1 }
        }

        return obj([
            "atomCount": m.atoms.count,
            "residueCount": R,
            "residueSource": residueSource,
            "source": ssSource,
            "ss": String(ss),
            "chain": residues.map { $0.chain },
            "seq": residues.map { $0.seq },
            "iCode": residues.map { $0.iCode },
            "name": residues.map { $0.name },
            "n": residues.map { $0.n }, "ca": residues.map { $0.ca }, "c": residues.map { $0.c }, "o": residues.map { $0.o },
            "segments": JSON.array(segments.map { .array($0.map { .number(Double($0)) }) }),
            "polymerAtoms": polymer.indices.filter { polymer[$0] },
            "waterAtoms": isWater.indices.filter { isWater[$0] },
            "helixCount": helices, "strandCount": strands,
        ])
    }

    // MARK: Residues from PDB records

    static func posKey(_ v: Vec3) -> Int64 {
        let x = Int64((v.x * 1000).rounded()) & 0x1FFFFF, y = Int64((v.y * 1000).rounded()) & 0x1FFFFF
        let z = Int64((v.z * 1000).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }

    /// The ATOM/HETATM columns this method needs (read without the full PDBFormat parse, which is much slower).
    struct AtomRecord { var name: String; var resName: String; var chainID: String; var resSeq: Int; var iCode: String; var position: Vec3 }

    static func readAtomRecords(_ text: String) -> [[AtomRecord]] {
        var models: [[AtomRecord]] = []
        var cur: [AtomRecord] = []
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
            guard b.count >= 6 else { continue }
            let rec = field(b, 1, 6)
            if rec == "ATOM" || rec == "HETATM" {
                guard b.count >= 54, let x = Double(field(b, 31, 38)), let y = Double(field(b, 39, 46)),
                      let z = Double(field(b, 47, 54)) else { continue }
                cur.append(AtomRecord(name: field(b, 13, 16), resName: field(b, 18, 20), chainID: field(b, 22, 22),
                                      resSeq: Int(field(b, 23, 26)) ?? 0, iCode: field(b, 27, 27), position: Vec3(x, y, z)))
            } else if rec == "ENDMDL" || rec == "END" {
                if !cur.isEmpty { models.append(cur); cur = [] }
                if rec == "END" { break }
            }
        }
        if !cur.isEmpty { models.append(cur) }
        return models
    }

    static func fromRecords(_ m: Molecule, records: [AtomRecord]) -> ([Residue], [Int]) {
        var byPos: [Int64: Int] = [:]
        byPos.reserveCapacity(records.count)
        for (k, a) in records.enumerated() { byPos[posKey(a.position)] = k }
        // Residues are runs of consecutive records with the same chain/number/insertion code/name (the PDB convention),
        // so repeated chain IDs (large assemblies) stay apart.
        var run = [Int](repeating: 0, count: records.count)
        var runs = 0
        for k in records.indices {
            if k > 0 {
                let a = records[k - 1], b = records[k]
                if a.resSeq != b.resSeq || a.chainID != b.chainID || a.iCode != b.iCode || a.resName != b.resName { runs += 1 }
            }
            run[k] = runs
        }
        var groups = [Residue?](repeating: nil, count: records.isEmpty ? 0 : runs + 1)
        var names = [[String]](repeating: [], count: groups.count)
        var waters: [Int] = []
        for (i, a) in m.atoms.enumerated() {
            guard let k = byPos[posKey(a.position)] else { continue }
            let rec = records[k]
            if waterNames.contains(rec.resName.uppercased()) { waters.append(i); continue }
            let g = run[k]
            if groups[g] == nil {
                groups[g] = Residue(chain: rec.chainID, seq: rec.resSeq, iCode: rec.iCode, name: rec.resName)
                groups[g]!.isProline = rec.resName.uppercased() == "PRO"
            }
            // First alternate location of each atom name wins.
            if names[g].contains(rec.name) { continue }
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

    static func fromTopology(_ m: Molecule) -> [Residue] {
        let n = m.atoms.count
        guard n >= 4, !m.bonds.isEmpty else { return [] }
        let adj = m.adjacency()
        let z = m.atoms.map { $0.atomicNumber }
        func heavy(_ i: Int) -> [Int] { adj[i].filter { z[$0] > 1 } }
        // Backbone candidates: carbonyl C (bonded to a terminal O and to a CA that is bonded to an N).
        var resOfC: [Int: Residue] = [:]
        var cOfN: [Int: Int] = [:]   // N atom -> carbonyl C of the same residue
        for c in 0..<n where z[c] == 6 {
            let hn = heavy(c)
            guard let o = hn.first(where: { z[$0] == 8 && heavy($0).count == 1 }) else { continue }
            for ca in hn where z[ca] == 6 && ca != c {
                guard heavy(ca).count <= 4, let nn = heavy(ca).first(where: { z[$0] == 7 }) else { continue }
                var r = Residue(chain: "", seq: 0, iCode: "", name: "UNK")
                r.n = nn; r.ca = ca; r.c = c; r.o = o
                r.h = adj[nn].first(where: { z[$0] == 1 }) ?? -1
                r.isProline = heavy(nn).filter { $0 != ca && z[$0] == 6 }.count >= 2 && r.h < 0
                resOfC[c] = r
                cOfN[nn] = c
                break
            }
        }
        guard !resOfC.isEmpty else { return [] }
        // Peptide links C(i) -> N(i+1).
        var nextC: [Int: Int] = [:], hasPrev = Set<Int>()
        for (c, _) in resOfC {
            for nb in adj[c] where z[nb] == 7 {
                if let c2 = cOfN[nb], c2 != c, resOfC[c2]?.n == nb { nextC[c] = c2; hasPrev.insert(c2); break }
            }
        }
        // Order chains by their first atom index; residue order follows the links.
        let starts = resOfC.keys.filter { !hasPrev.contains($0) }.sorted { resOfC[$0]!.n < resOfC[$1]!.n }
        var out: [Residue] = []
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
                // Residue atoms: backbone + side chain reached from CA without crossing the backbone (capped).
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

    static func parseRanges(_ text: String) -> [FileRange] {
        var out: [FileRange] = []
        func field(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
            guard from <= b.count else { return "" }
            return String(decoding: b[(from - 1)..<min(to, b.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        text.enumerateLines { line, _ in
            guard line.hasPrefix("HELIX ") || line.hasPrefix("SHEET ") else { return }
            let b = Array(line.utf8)
            if line.hasPrefix("HELIX"), let s = Int(field(b, 22, 25)), let e = Int(field(b, 34, 37)) {
                let cls = Int(field(b, 39, 40)) ?? 1
                out.append(FileRange(chain: field(b, 20, 20), startSeq: s, startICode: field(b, 26, 26), endSeq: e,
                                     endICode: field(b, 38, 38), ss: cls == 5 ? "G" : (cls == 3 ? "I" : "H")))
            } else if line.hasPrefix("SHEET"), let s = Int(field(b, 23, 26)), let e = Int(field(b, 34, 37)) {
                out.append(FileRange(chain: field(b, 22, 22), startSeq: s, startICode: field(b, 27, 27), endSeq: e,
                                     endICode: field(b, 38, 38), ss: "E"))
            }
        }
        return out
    }

    static func applyFileRanges(_ ranges: [FileRange], residues: [Residue], ss: inout [Character]) {
        var index: [String: Int] = [:]
        for (k, r) in residues.enumerated() { index["\(r.chain)|\(r.seq)|\(r.iCode)"] = k }
        for g in ranges {
            guard let a = index["\(g.chain)|\(g.startSeq)|\(g.startICode)"], let b = index["\(g.chain)|\(g.endSeq)|\(g.endICode)"],
                  a <= b else { continue }
            for k in a...b where residues[k].chain == g.chain { ss[k] = g.ss }
        }
    }

    // MARK: Simplified DSSP

    /// Squared distance with plain scalar math (the generic SIMD helpers are slow in debug builds).
    @inline(__always) static func dist2(_ a: Vec3, _ b: Vec3) -> Double {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return x * x + y * y + z * z
    }

    static func dssp(_ m: Molecule, residues res: [Residue], segment: [Int], cancelled: () -> Bool) -> [Character]? {
        let R = res.count
        let P = m.atoms.map { $0.position }
        let ca = res.map { P[$0.ca] }
        // Grid on CA positions (cell 9 Å, the DSSP H-bond cutoff).
        let cell = 9.0
        func key(_ v: Vec3) -> Int64 {
            let x = Int64((v.x / cell).rounded(.down)) & 0x1FFFFF, y = Int64((v.y / cell).rounded(.down)) & 0x1FFFFF
            let z = Int64((v.z / cell).rounded(.down)) & 0x1FFFFF
            return (x << 42) | (y << 21) | z
        }
        var grid: [Int64: [Int]] = [:]
        for r in 0..<R { grid[key(ca[r]), default: []].append(r) }
        func near(_ r: Int, _ cutoff: Double, _ body: (Int) -> Void) {
            let c = ca[r]
            let bx = Int64((c.x / cell).rounded(.down)), by = Int64((c.y / cell).rounded(.down)), bz = Int64((c.z / cell).rounded(.down))
            let c2 = cutoff * cutoff
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                let k = (((bx + Int64(dx)) & 0x1FFFFF) << 42) | (((by + Int64(dy)) & 0x1FFFFF) << 21) | ((bz + Int64(dz)) & 0x1FFFFF)
                guard let list = grid[k] else { continue }
                for j in list where j != r && dist2(ca[j], c) < c2 { body(j) }
            } } }
        }
        // Amide H: the file's H, else placed 1.0 Å from N opposite the previous carbonyl (DSSP).
        var hPos = [Vec3?](repeating: nil, count: R)
        for r in 0..<R {
            if res[r].isProline { continue }
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
            if j % 512 == 0 && cancelled() { return nil }
            guard let H = hPos[j] else { continue }
            let N = P[res[j].n]
            near(j, 9.0) { i in
                guard abs(i - j) >= 2 || segment[i] != segment[j], res[i].o >= 0 else { return }
                let C = P[res[i].c], O = P[res[i].o]
                let on2 = dist2(O, N)
                guard on2 < 30.25 else { return }   // O···N > 5.5 Å can't reach -0.5 kcal/mol
                let dON = on2.squareRoot(), dCH = dist2(C, H).squareRoot(), dOH = dist2(O, H).squareRoot(), dCN = dist2(C, N).squareRoot()
                guard dON > 0.5, dCH > 0.5, dOH > 0.5, dCN > 0.5 else { return }
                let e = max(-9.9, 27.888 * (1 / dON + 1 / dCH - 1 / dOH - 1 / dCN))
                guard e < -0.5 else { return }
                if e < e1[j] { acc2[j] = acc1[j]; e2[j] = e1[j]; acc1[j] = i; e1[j] = e }
                else if e < e2[j] { acc2[j] = i; e2[j] = e }
            }
        }
        /// C=O of i accepts from N–H of j.
        func hb(_ i: Int, _ j: Int) -> Bool {
            guard i >= 0, j >= 0, i < R, j < R else { return false }
            return acc1[j] == i || acc2[j] == i
        }
        func contiguous(_ a: Int, _ b: Int) -> Bool { a >= 0 && b < R && a <= b && segment[a] == segment[b] }

        var ss = [Character](repeating: "L", count: R)
        // n-turns.
        func turn(_ i: Int, _ n: Int) -> Bool { contiguous(i, i + n) && hb(i, i + n) }
        var t4 = [Bool](repeating: false, count: R), t3 = [Bool](repeating: false, count: R), t5 = [Bool](repeating: false, count: R)
        for i in 0..<R { t3[i] = turn(i, 3); t4[i] = turn(i, 4); t5[i] = turn(i, 5) }
        for i in 1..<max(R, 1) where t4[i - 1] && t4[i] { for k in i..<min(i + 4, R) { ss[k] = "H" } }

        // Bridges.
        var partners = [[(Int, Bool)]](repeating: [], count: R)   // (partner, parallel)
        for i in 1..<max(R - 1, 1) {
            if i % 512 == 0 && cancelled() { return nil }
            guard contiguous(i - 1, i + 1) else { continue }
            near(i, 7.0) { j in
                guard j > i + 2 || segment[j] != segment[i], j > i, contiguous(j - 1, j + 1) else { return }
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
                var ladder = false
                for d in [-1, 1] {
                    let i2 = i + d, j2 = j + d * step
                    guard i2 >= 0, i2 < R, segment[i2] == segment[i] else { continue }
                    if partners[i2].contains(where: { $0.0 == j2 && $0.1 == par }) { ladder = true }
                }
                if ladder { isE[i] = true; isE[j] = true }
            }
        }
        // β-bulges: one- or two-residue gaps inside a strand whose flanks pair with the same, nearby stretch of the
        // partner strand on the far side (not a hairpin turn, where the flanks pair with each other).
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
        for i in 0..<R where ss[i] == "L" {
            if isE[i] { ss[i] = "E" } else if !partners[i].isEmpty { ss[i] = "B" }
        }
        // 3-10 and π helices where nothing stronger was assigned.
        for i in 1..<max(R, 1) where t3[i - 1] && t3[i] {
            let r = i..<min(i + 3, R)
            if r.allSatisfy({ ss[$0] == "L" || ss[$0] == "G" }) { for k in r { ss[k] = "G" } }
        }
        for i in 1..<max(R, 1) where t5[i - 1] && t5[i] {
            let r = i..<min(i + 5, R)
            if r.allSatisfy({ ss[$0] == "L" || ss[$0] == "I" }) { for k in r { ss[k] = "I" } }
        }
        for i in 0..<R where ss[i] == "L" && i > 0 && (t3[i - 1] || t4[i - 1]) { ss[i] = "T" }
        // Single strand residues look odd as arrows: demote to loop.
        for i in 0..<R where ss[i] == "E" {
            let left = i > 0 && ss[i - 1] == "E" && segment[i - 1] == segment[i]
            let right = i + 1 < R && ss[i + 1] == "E" && segment[i + 1] == segment[i]
            if !left && !right { ss[i] = "B" }
        }
        return ss
    }
}

/// Parsed PDB files by path (invalidated by size/modification date), so repeated requests don't re-read the file.
final class PDBCache: @unchecked Sendable {
    static let shared = PDBCache()
    struct Entry { var stamp: String; var models: [[SecondaryStructure.AtomRecord]]; var ranges: [SecondaryStructure.FileRange] }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func get(_ path: String) -> Entry? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = "\((attrs?[.size] as? NSNumber)?.int64Value ?? -1)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        lock.lock()
        if let e = entries[path], e.stamp == stamp { lock.unlock(); return e }
        lock.unlock()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let e = Entry(stamp: stamp, models: SecondaryStructure.readAtomRecords(text), ranges: SecondaryStructure.parseRanges(text))
        lock.lock()
        entries[path] = e
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > 4 { entries[order.removeFirst()] = nil }
        lock.unlock()
        return e
    }
}
