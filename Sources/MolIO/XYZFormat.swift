import Foundation
import MolCore

/// XYZ (and multi-frame XYZ trajectory) reader/writer. Coordinates in Angstrom.
public enum XYZFormat {
    private static func fail(_ line: Int?, _ msg: String) -> MolIOError {
        .parse(format: "xyz", line: line, message: msg)
    }

    public static func read(url: URL) throws -> [Molecule] { try parse(try readText(url)) }

    /// Parse one or more frames. Line 1 = atom count, line 2 = comment (becomes `title`),
    /// then `symbol|Z x y z [extra columns ignored]`. Blank lines between/after frames are skipped.
    public static func parse(_ text: String) throws -> [Molecule] {
        let lines = splitLines(text)
        var frames: [Molecule] = []
        var i = 0
        while i < lines.count {
            if lines[i].allSatisfy({ $0 == " " || $0 == "\t" }) { i += 1; continue }
            let head = tokens(lines[i])
            guard head.count >= 1, let n = Int(head[0]), n >= 0 else {
                throw fail(i + 1, "expected atom count, found '\(lines[i])'")
            }
            guard i + 1 < lines.count else { throw fail(i + 2, "missing comment line") }
            guard i + 1 + n < lines.count || n == 0 else {
                throw fail(lines.count, "truncated frame: expected \(n) atoms")
            }
            let title = lines[i + 1].trimmingCharacters(in: .whitespaces)
            var atoms: [Atom] = []
            atoms.reserveCapacity(n)
            for k in 0..<n {
                let ln = i + 2 + k
                guard ln < lines.count else { throw fail(lines.count, "truncated frame: expected \(n) atoms, got \(k)") }
                let t = tokens(lines[ln])
                guard t.count >= 4 else { throw fail(ln + 1, "atom line needs symbol and 3 coordinates") }
                guard let z = IOElements.atomicNumber(label: String(t[0])) else {
                    throw fail(ln + 1, "unknown element '\(t[0])'")
                }
                guard let x = parseFortranDouble(t[1]), let y = parseFortranDouble(t[2]), let zc = parseFortranDouble(t[3]),
                      x.isFinite, y.isFinite, zc.isFinite else {
                    throw fail(ln + 1, "bad coordinate")
                }
                var a = Atom(id: k, atomicNumber: z, position: Vec3(x, y, zc))
                if Int(t[0]) == nil, t[0] != Substring(IOElements.symbol(z)), IOElements.atomicNumber(exact: String(t[0])) == nil {
                    a.label = String(t[0])
                }
                atoms.append(a)
            }
            frames.append(Molecule(atoms: atoms, title: title))
            i += 2 + n
        }
        if frames.isEmpty { throw fail(nil, "no frames found") }
        return frames
    }

    /// Energy (Hartree, as written) stated in a trajectory frame's comment line, or nil. Understands
    /// xtb ("energy: -5.07 gnorm: …"), ORCA _trj.xyz ("Coordinates from ORCA-job x E -74.96"), "E=-76.01",
    /// "Energy = -76.01" / "energy=-76.01", and a comment that is a single number.
    public static func commentEnergy(_ title: String) -> Double? {
        let tk = title.replacingOccurrences(of: "=", with: " = ").replacingOccurrences(of: ":", with: " : ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
        // A lone integer is a frame/step counter, not an energy.
        if tk.count == 1 { return tk[0].contains(".") ? parseFortranDouble(tk[0]).flatMap { $0.isFinite ? $0 : nil } : nil }
        for (k, t) in tk.enumerated() {
            let w = t.lowercased()
            guard w == "e" || w == "energy" || w == "etot" || w == "e_tot" || w == "total_energy" else { continue }
            var j = k + 1
            if j < tk.count, tk[j] == "=" || tk[j] == ":" { j += 1 }
            if j < tk.count, let v = parseFortranDouble(tk[j]), v.isFinite { return v }
        }
        return nil
    }

    /// Gradient norm in a trajectory comment ("gnorm: 0.0123", xtb), or nil.
    public static func commentGradientNorm(_ title: String) -> Double? {
        let tk = title.replacingOccurrences(of: ":", with: " : ").replacingOccurrences(of: "=", with: " = ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let k = tk.firstIndex(where: { $0.lowercased() == "gnorm" }) else { return nil }
        var j = k + 1
        if j < tk.count, tk[j] == ":" || tk[j] == "=" { j += 1 }
        return j < tk.count ? parseFortranDouble(tk[j]) : nil
    }

    public static func write(_ molecule: Molecule) -> String { write([molecule]) }

    public static func write(_ molecules: [Molecule]) -> String {
        var out = ""
        for m in molecules {
            out += "\(m.atoms.count)\n"
            out += m.title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\n"
            for a in m.atoms {
                out += IOElements.symbol(a.atomicNumber).padding(toLength: 3, withPad: " ", startingAt: 0)
                out += String(format: " %16.8f %16.8f %16.8f\n", a.position.x, a.position.y, a.position.z)
            }
        }
        return out
    }
}
