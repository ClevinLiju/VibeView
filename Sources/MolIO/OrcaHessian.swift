import Foundation
import MolCore

/// ORCA `.hess` file (`$hessian`, `$vibrational_frequencies`, `$normal_modes`, `$atoms`, `$ir_spectrum`).
/// Policy: a file cut inside `$hessian` / `$normal_modes` / `$atoms` / the frequency list throws
/// `MolIOError.parse`; a file lacking a later optional section (e.g. `$ir_spectrum`) parses without it.
public struct OrcaHessian: Sendable, Codable, Equatable {
    public var atomCount: Int
    public var molecule: Molecule
    public var masses: [Double]
    /// Cartesian Hessian, Hartree/Bohr^2, 3N x 3N row-major.
    public var hessian: [[Double]]
    /// All 3N frequencies (translation/rotation zeros included).
    public var frequencies: [Double]
    /// All 3N modes (zeros included); IR intensity filled from `$ir_spectrum` when present.
    public var allNormalModes: [NormalMode]
    public var energy: Double?
    public var multiplicity: Int?

    /// Vibrational modes only (leading ~0 cm-1 entries dropped).
    public var normalModes: [NormalMode] {
        Array(allNormalModes.dropFirst(frequencies.prefix { abs($0) < 0.01 }.count))
    }

    public static func read(url: URL) throws -> OrcaHessian { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> OrcaHessian {
        func fail(_ m: String) -> MolIOError { .parse(format: "orca-hess", line: nil, message: m) }
        let L = splitLines(text).map { $0.trimmingCharacters(in: .whitespaces) }
        guard L.contains(where: { $0.hasPrefix("$orca_hessian_file") }) || L.contains("$hessian") else { throw fail("not an ORCA hessian file") }
        func section(_ name: String) -> Int? { L.firstIndex(of: name) }
        // A section is complete only if a later "$" header (e.g. $end) follows it; otherwise it may be cut.
        func isHeader(_ s: String) -> Bool { s.hasPrefix("$") }
        func bounds(_ name: String) throws -> (start: Int, end: Int)? {
            guard let s = section(name) else { return nil }
            var e = s + 1
            while e < L.count, !isHeader(L[e]) { e += 1 }
            guard e < L.count else { throw fail("section \(name) is not terminated (truncated file)") }
            return (s + 1, e)
        }
        func matrixColumns(_ lines: [String], rows: Int, cols: Int, _ what: String) throws -> [[Double]] {
            var m = Array(repeating: [Double](repeating: 0, count: cols), count: rows)
            var k = 0
            var c0 = 0
            while c0 < cols {
                guard k < lines.count else { throw fail("truncated \(what)") }
                let head = tokens(lines[k])
                guard !head.isEmpty, head.allSatisfy({ Int($0) != nil }), Int(head[0]) == c0 else { throw fail("bad column header in \(what): '\(lines[k])'") }
                let nc = head.count
                guard k + rows < lines.count else { throw fail("truncated \(what)") }
                for r in 0..<rows {
                    let t = tokens(lines[k + 1 + r])
                    guard t.count == nc + 1, Int(t[0]) == r else { throw fail("bad row in \(what): '\(lines[k + 1 + r])'") }
                    for c in 0..<nc {
                        guard let v = parseFortranDouble(t[c + 1]) else { throw fail("bad number in \(what)") }
                        m[r][c0 + c] = v
                    }
                }
                k += rows + 1; c0 += nc
            }
            return m
        }
        func body(_ name: String) throws -> [String]? {
            guard let b = try bounds(name) else { return nil }
            return Array(L[b.start..<b.end]).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        // atoms
        guard let ab = try body("$atoms"), let nAtoms = ab.first.flatMap({ Int($0) }), nAtoms > 0 else { throw fail("missing $atoms") }
        guard ab.count == nAtoms + 1 else { throw fail("$atoms has \(ab.count - 1) rows, expected \(nAtoms)") }
        var atoms: [Atom] = []
        var masses: [Double] = []
        for k in 0..<nAtoms {
            let t = tokens(ab[k + 1])
            guard t.count >= 5, let z = IOElements.atomicNumber(label: String(t[0])), let ms = Double(t[1]),
                  let x = Double(t[2]), let y = Double(t[3]), let w = Double(t[4]) else { throw fail("bad atom row '\(ab[k + 1])'") }
            atoms.append(Atom(id: k, atomicNumber: z, position: Vec3(x, y, w) * bohrToAngstrom))
            masses.append(ms)
        }
        let n3 = 3 * nAtoms
        guard let hb = try body("$hessian"), let hn = hb.first.flatMap({ Int($0) }), hn == n3 else { throw fail("missing or inconsistent $hessian") }
        let hess = try matrixColumns(Array(hb.dropFirst()), rows: n3, cols: n3, "$hessian")
        guard let fb = try body("$vibrational_frequencies"), fb.first.flatMap({ Int($0) }) == n3, fb.count == n3 + 1 else {
            throw fail("missing or truncated $vibrational_frequencies")
        }
        var freqs: [Double] = []
        for r in fb.dropFirst() {
            let t = tokens(r)
            guard t.count >= 2, let v = Double(t[1]) else { throw fail("bad frequency row '\(r)'") }
            freqs.append(v)
        }
        guard let nb = try body("$normal_modes"), let first = nb.first else { throw fail("missing $normal_modes") }
        let dims = tokens(first).compactMap { Int($0) }
        guard dims.count == 2, dims[0] == n3, dims[1] == n3 else { throw fail("bad $normal_modes dimensions") }
        let nm = try matrixColumns(Array(nb.dropFirst()), rows: n3, cols: n3, "$normal_modes")
        var modes: [NormalMode] = []
        for j in 0..<n3 {
            let d = (0..<nAtoms).map { Vec3(nm[3 * $0][j], nm[3 * $0 + 1][j], nm[3 * $0 + 2][j]) }
            modes.append(NormalMode(frequency: freqs[j], irIntensity: 0, displacements: d))
        }
        if let ir = try? body("$ir_spectrum"), ir.first.flatMap({ Int($0) }) == n3, ir.count == n3 + 1 {
            for (j, r) in ir.dropFirst().enumerated() {
                let t = tokens(r)
                if t.count >= 3, let v = Double(t[2]) { modes[j].irIntensity = v }
            }
        }
        var mult: Int?
        if let b = try? body("$multiplicity"), let f = b.first { mult = Int(f) }
        var en: Double?
        if let b = try? body("$act_energy"), let f = b.first { en = Double(f) }
        var m = Molecule(atoms: atoms, multiplicity: mult ?? 1)
        m.perceiveBonds()
        return OrcaHessian(atomCount: nAtoms, molecule: m, masses: masses, hessian: hess, frequencies: freqs,
                           allNormalModes: modes, energy: en, multiplicity: mult)
    }
}
