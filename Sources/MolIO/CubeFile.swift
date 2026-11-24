import Foundation
import MolCore

/// Gaussian-style volumetric "cube" data (public cube format).
///
/// Layout: 2 comment lines; line 3 = natoms (negative => a DSET_IDS line follows the atom block)
/// + origin [+ optional nval]; lines 4-6 = N + axis vector (N > 0 => Bohr, N < 0 => Angstrom);
/// atom lines `Z charge x y z`; then values (x slowest, z fastest; datasets interleaved per point).
/// In memory everything is converted to Angstrom.
public struct CubeFile: Sendable, Codable, Equatable {
    public var title: String
    public var comment: String
    public var molecule: Molecule
    /// Per-atom "charge" column of the file (effective nuclear charge; differs from Z with ECPs).
    public var nuclearCharges: [Double]
    /// One grid per dataset (MO/density); all share origin/axes/counts. Angstrom.
    public var grids: [VolumeGrid]
    /// MO numbers from the DSET_IDS line (empty when the file has none).
    public var orbitalIndices: [Int]

    public init(title: String = "", comment: String = "", molecule: Molecule, grids: [VolumeGrid],
                orbitalIndices: [Int] = [], nuclearCharges: [Double]? = nil) {
        self.title = title
        self.comment = comment
        self.molecule = molecule
        self.grids = grids
        self.orbitalIndices = orbitalIndices
        self.nuclearCharges = nuclearCharges ?? molecule.atoms.map { Double($0.atomicNumber) }
    }

    public static func read(url: URL) throws -> CubeFile { try parse(try readText(url)) }

    // MARK: parse

    private struct Cursor {
        let bytes: [UInt8]   // NUL-terminated
        var pos = 0
        var line = 0
        var atEnd: Bool { pos >= bytes.count - 1 }
        mutating func nextLine() -> String? {
            guard !atEnd else { return nil }
            let n = bytes.count - 1
            var e = pos
            while e < n, bytes[e] != 10, bytes[e] != 13 { e += 1 }
            let s = String(decoding: bytes[pos..<e], as: UTF8.self)
            if e < n {
                if bytes[e] == 13, e + 1 < n, bytes[e + 1] == 10 { e += 1 }
                e += 1
            }
            pos = e
            line += 1
            return s
        }
    }

    private static func fail(_ line: Int?, _ msg: String) -> MolIOError {
        .parse(format: "cube", line: line, message: msg)
    }

    public static func parse(_ text: String) throws -> CubeFile {
        var cur = Cursor(bytes: Array(text.utf8) + [0])
        guard let title = cur.nextLine(), let comment = cur.nextLine() else {
            throw fail(nil, "file too short for cube header")
        }
        guard let l3 = cur.nextLine() else { throw fail(3, "missing atom-count line") }
        let t3 = tokens(l3)
        guard t3.count >= 4, let nAtomsRaw = Int(t3[0]),
              let ox = parseFortranDouble(t3[1]), let oy = parseFortranDouble(t3[2]), let oz = parseFortranDouble(t3[3]) else {
            throw fail(3, "bad atom-count/origin line")
        }
        var nvals = 1
        if nAtomsRaw > 0, t3.count >= 5 {
            guard let nv = Int(t3[4]), nv >= 0 else { throw fail(3, "bad nval field") }
            nvals = max(nv, 1)
        }
        let nAtoms = abs(nAtomsRaw)
        guard nAtoms < 10_000_000 else { throw fail(3, "unreasonable atom count") }

        // axes
        var counts = [Int](), axes = [Vec3](), axisInAngstrom = [Bool]()
        for k in 0..<3 {
            guard let l = cur.nextLine() else { throw fail(4 + k, "missing grid axis line") }
            let t = tokens(l)
            guard t.count >= 4, let n = Int(t[0]), n != 0,
                  let vx = parseFortranDouble(t[1]), let vy = parseFortranDouble(t[2]), let vz = parseFortranDouble(t[3]) else {
                throw fail(4 + k, "bad grid axis line")
            }
            counts.append(abs(n))
            axisInAngstrom.append(n < 0)
            axes.append(Vec3(vx, vy, vz))
        }
        // A negative count on the first axis means the whole header (origin, axes, atoms) is in Å,
        // which is how the writer emits it and how common cube producers use the sign.
        let headerInAngstrom = axisInAngstrom[0]
        let posScale = headerInAngstrom ? 1.0 : bohrToAngstrom
        // atoms
        var atoms = [Atom](), charges = [Double]()
        atoms.reserveCapacity(nAtoms)
        for i in 0..<nAtoms {
            guard let l = cur.nextLine() else { throw fail(7 + i, "truncated atom block") }
            let t = tokens(l)
            guard t.count >= 5, let z = Int(t[0]), z >= 0, z <= 200,
                  let q = parseFortranDouble(t[1]), let x = parseFortranDouble(t[2]),
                  let y = parseFortranDouble(t[3]), let zz = parseFortranDouble(t[4]) else {
                throw fail(7 + i, "bad atom line")
            }
            atoms.append(Atom(id: i, atomicNumber: z, position: Vec3(x, y, zz) * posScale))
            charges.append(q)
        }
        var orbitalIndices: [Int] = []
        if nAtomsRaw < 0 {
            var needed = -1
            var got: [Int] = []
            while needed < 0 || got.count < needed {
                guard let l = cur.nextLine() else { throw fail(cur.line + 1, "truncated DSET_IDS line") }
                for tk in tokens(l) {
                    guard let v = Int(tk) else { throw fail(cur.line, "bad DSET_IDS entry") }
                    if needed < 0 {
                        guard v >= 1, v < 1_000_000 else { throw fail(cur.line, "bad DSET_IDS count") }
                        needed = v
                    } else if got.count < needed { got.append(v) }
                }
            }
            orbitalIndices = got
            nvals = needed
        }

        let nx = counts[0], ny = counts[1], nz = counts[2]
        let (p1, o1) = nx.multipliedReportingOverflow(by: ny)
        let (npts, o2) = p1.multipliedReportingOverflow(by: nz)
        let (total, o3) = npts.multipliedReportingOverflow(by: nvals)
        guard !o1, !o2, !o3 else { throw fail(nil, "grid dimensions overflow") }
        let remaining = cur.bytes.count - 1 - cur.pos
        guard total <= (remaining + 1) / 2 else {
            throw fail(nil, "value count mismatch: header needs \(total) values but the file is too short")
        }

        var flat = [Float](repeating: 0, count: total)
        var failure: String? = nil
        let bytes = cur.bytes
        let n = bytes.count - 1
        let startPos = cur.pos
        bytes.withUnsafeBufferPointer { buf in
            guard let raw = buf.baseAddress else { return }
            let base = UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)
            flat.withUnsafeMutableBufferPointer { out in
                var i = startPos
                var k = 0
                while true {
                    while i < n, bytes[i] <= 32 { i += 1 }
                    if i >= n { break }
                    if k >= total { failure = "value count mismatch: more than \(total) values"; return }
                    var endp: UnsafeMutablePointer<CChar>? = nil
                    var v = strtod(base + i, &endp)
                    var j = i
                    if let e = endp { j = i + (UnsafePointer(e) - (base + i)) }
                    if j == i || bytes[j] > 32 {
                        // Fortran exponent or junk: examine whole token
                        var e = i
                        while e < n, bytes[e] > 32 { e += 1 }
                        var tok = Array(bytes[i..<e])
                        for q in 0..<tok.count where tok[q] == 68 || tok[q] == 100 { tok[q] = 69 }
                        guard let d = Double(String(decoding: tok, as: UTF8.self)) else {
                            failure = "bad numeric value '\(String(decoding: bytes[i..<e], as: UTF8.self))' (value \(k + 1))"
                            return
                        }
                        v = d
                        j = e
                    }
                    guard v.isFinite else { failure = "non-finite value (value \(k + 1))"; return }
                    out[k] = Float(v)
                    k += 1
                    i = j
                }
                if k != total { failure = "value count mismatch: expected \(total), found \(k)" }
            }
        }
        if let f = failure { throw fail(nil, f) }

        let origin = Vec3(ox, oy, oz) * posScale
        var axesA = [Vec3]()
        for k in 0..<3 { axesA.append(axes[k] * (axisInAngstrom[k] ? 1 : bohrToAngstrom)) }
        var grids = [VolumeGrid]()
        if nvals == 1 {
            grids = [VolumeGrid(origin: origin, axes: axesA, counts: counts, values: flat)]
        } else {
            for d in 0..<nvals {
                var vals = [Float](repeating: 0, count: npts)
                for p in 0..<npts { vals[p] = flat[p * nvals + d] }
                grids.append(VolumeGrid(origin: origin, axes: axesA, counts: counts, values: vals))
            }
        }
        var mol = Molecule(atoms: atoms, title: title.trimmingCharacters(in: .whitespaces))
        mol.title = title.trimmingCharacters(in: .whitespaces)
        return CubeFile(title: title, comment: comment, molecule: mol, grids: grids,
                        orbitalIndices: orbitalIndices, nuclearCharges: charges)
    }

    // MARK: write

    /// Write in Bohr (default, positive counts) or Angstrom (negative counts).
    public func write(unitsAngstrom: Bool = false) -> String {
        var out = ""
        let atoms = molecule.atoms
        out += title.replacingOccurrences(of: "\n", with: " ") + "\n"
        out += comment.replacingOccurrences(of: "\n", with: " ") + "\n"
        let g0 = grids.first
        let nd = grids.count
        let useDset = !orbitalIndices.isEmpty
        let natomsField = useDset ? -atoms.count : atoms.count
        let len = unitsAngstrom ? 1.0 : angstromToBohr
        let o = (g0?.origin ?? .zero) * len
        var l3 = String(format: "%5d%12.6f%12.6f%12.6f", natomsField, o.x, o.y, o.z)
        if !useDset, nd > 1 { l3 += String(format: "%5d", nd) }
        out += l3 + "\n"
        let counts = g0?.counts ?? [0, 0, 0]
        for k in 0..<3 {
            let n = k < counts.count ? counts[k] : 0
            let ax = ((g0?.axes.count ?? 0) > k ? g0!.axes[k] : .zero) * len
            out += String(format: "%5d%12.6f%12.6f%12.6f\n", unitsAngstrom ? -n : n, ax.x, ax.y, ax.z)
        }
        for (i, a) in atoms.enumerated() {
            let p = a.position * len
            let q = i < nuclearCharges.count ? nuclearCharges[i] : Double(a.atomicNumber)
            out += String(format: "%5d%12.6f%12.6f%12.6f%12.6f\n", a.atomicNumber, q, p.x, p.y, p.z)
        }
        if useDset {
            out += String(format: "%5d", orbitalIndices.count)
            for v in orbitalIndices { out += String(format: "%5d", v) }
            out += "\n"
        }
        guard let g = g0, counts.count == 3 else { return out }
        let nx = counts[0], ny = counts[1], nz = counts[2]
        out.reserveCapacity(out.utf8.count + nx * ny * nz * nd * 14)
        var col = 0
        for ix in 0..<nx {
            for iy in 0..<ny {
                for iz in 0..<nz {
                    let p = (ix * ny + iy) * nz + iz
                    for d in 0..<nd {
                        let vals = grids[d].values
                        let v: Float = p < vals.count ? vals[p] : 0
                        out += String(format: "%13.5E", Double(v))
                        col += 1
                        if col == 6 { out += "\n"; col = 0 }
                    }
                }
                if col != 0 { out += "\n"; col = 0 }
            }
        }
        _ = g
        return out
    }
}
