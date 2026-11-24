import Foundation
import MolCore

/// Reader for Gaussian-style input files (.gjf / .com). One job per `--Link1--` step.
public enum GaussianInputReader {
    static let fmt = "Gaussian input"

    public static func read(url: URL) throws -> [GaussianJob] { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> [GaussianJob] {
        let lines = splitLines(text)
        var jobs: [GaussianJob] = []
        var start = 0
        for i in 0...lines.count {
            let atEnd = i == lines.count
            if atEnd || lines[i].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("--link1--") {
                jobs.append(try parseStep(lines, start..<i))
                start = i + 1
            }
        }
        return jobs
    }

    // MARK: helpers

    private static func err(_ line: Int?, _ msg: String) -> MolIOError { .parse(format: fmt, line: line, message: msg) }

    private static func isBlank(_ s: Substring) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func stripComment(_ s: Substring) -> Substring {
        if let b = s.firstIndex(of: "!") { return s[..<b] }
        return s
    }

    /// Fields split on whitespace/commas outside parentheses.
    private static func fields(_ s: Substring) -> [Substring] {
        var out: [Substring] = []
        var depth = 0
        var begin: Substring.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            let sep = depth == 0 && (c == " " || c == "\t" || c == ",")
            if sep {
                if let b = begin { out.append(s[b..<i]); begin = nil }
            } else if begin == nil { begin = i }
            i = s.index(after: i)
        }
        if let b = begin { out.append(s[b...]) }
        return out
    }

    private static func num(_ t: Substring) -> Double? {
        guard let d = parseFortranDouble(t), d.isFinite else { return nil }
        return d
    }

    private static func isLayer(_ t: Substring) -> Bool { t == "H" || t == "M" || t == "L" || t == "h" || t == "m" || t == "l" }

    private static func looksLikeName(_ t: Substring) -> Bool {
        var s = t
        if s.hasPrefix("-") || s.hasPrefix("+") { s = s.dropFirst() }
        guard let f = s.first else { return false }
        return f.isLetter || f == "_"
    }

    private static func fragmentIndex(_ label: Substring) -> Int? {
        guard label.contains("("), let r = label.range(of: "fragment=", options: .caseInsensitive) else { return nil }
        let digits = label[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func atomicNumber(_ label: Substring, line: Int) throws -> Int {
        guard let z = IOElements.atomicNumber(label: String(label)) else { throw err(line, "unknown element '\(label)'") }
        return z
    }

    private static func isDummyLabel(_ label: Substring) -> Bool {
        let l = label.prefix { $0.isLetter }
        return l.count == 1 && (l == "X" || l == "x")
    }

    // MARK: step

    private struct Block { var range: Range<Int> }

    private static func parseStep(_ lines: [Substring], _ range: Range<Int>) throws -> GaussianJob {
        var i = range.lowerBound
        let end = range.upperBound
        // Link 0 + leading blanks/comments.
        var link0 = Link0()
        while i < end {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("!") { i += 1; continue }
            if t.hasPrefix("%") { link0.absorb(t); i += 1; continue }
            break
        }
        guard i < end else { throw err(end > 0 ? end : nil, "missing route section (no '#' line found)") }
        guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
            throw err(i + 1, "missing route section: expected a line starting with '#'")
        }
        var routeText = ""
        while i < end, !isBlank(lines[i]) {
            let s = stripComment(lines[i])
            routeText += s; routeText += "\n"
            i += 1
        }
        let route = GaussianRoute(parsing: routeText)
        var job = GaussianJob(route: route)
        var zRowLines: [Int] = []
        job.link0 = link0
        job.atomSpecs = []
        job.chargeMultiplicities = []
        let allCheck = route.readsEverythingFromCheckpoint
        let geomCheck = route.readsGeometryFromCheckpoint

        // Blank line after the route.
        if i >= end {
            if allCheck { return job }
            throw err(end, "unexpected end of file after the route section")
        }
        i += 1  // blank

        func nextBlock() -> Range<Int>? {
            while i < end, isBlank(lines[i]) { i += 1 }
            guard i < end else { return nil }
            let s = i
            while i < end, !isBlank(lines[i]) { i += 1 }
            return s..<i
        }

        if !allCheck {
            // Title.
            guard i < end, !isBlank(lines[i]) else { throw err(i < end ? i + 1 : end, i < end ? "missing title section" : "unexpected end of file: missing title section") }
            var titleLines: [String] = []
            while i < end, !isBlank(lines[i]) { titleLines.append(String(lines[i])); i += 1 }
            job.title = titleLines.joined(separator: "\n")
            guard i < end else { throw err(end, "unexpected end of file: missing charge/multiplicity") }
            i += 1
            // Charge/multiplicity.
            if i < end, isBlank(lines[i]) { throw err(i + 1, "missing charge/multiplicity line") }
            guard i < end else { throw err(end, "unexpected end of file: missing charge/multiplicity") }
            let cmFields = fields(stripComment(lines[i]))
            guard cmFields.count >= 2, cmFields.count % 2 == 0 else { throw err(i + 1, "malformed charge/multiplicity line") }
            var pairs: [ChargeMultiplicity] = []
            var k = 0
            while k < cmFields.count {
                guard let c = Int(cmFields[k]), let m = Int(cmFields[k + 1]), m >= 1 else {
                    throw err(i + 1, "malformed charge/multiplicity '\(cmFields[k]) \(cmFields[k + 1])'")
                }
                pairs.append(ChargeMultiplicity(charge: c, multiplicity: m))
                k += 2
            }
            job.chargeMultiplicities = pairs
            i += 1
            if !geomCheck {
                guard i < end, !isBlank(lines[i]) else { throw err(i < end ? i + 1 : end, "missing molecule specification (no atoms)") }
                zRowLines = try parseGeometry(lines, i..<end, &job)
                while i < end, !isBlank(lines[i]) { i += 1 }
            } else if i < end, isBlank(lines[i]) {
                // empty molecule specification terminated by its blank line
            }
            // Z-matrix variables / constants.
            if var z = job.zMatrix {
                var undefined = z.undefinedVariables()
                var mode = false  // false: variables, true: constants
                while true {
                    var j = i
                    while j < end, isBlank(lines[j]) { j += 1 }
                    guard j < end else { break }
                    let first = lines[j].trimmingCharacters(in: .whitespaces).lowercased()
                    let isHeader = first.hasPrefix("variables") || first.hasPrefix("constants")
                    guard isHeader || !undefined.isEmpty else { break }
                    guard let b = nextBlock() else { break }
                    for li in b {
                        let t = stripComment(lines[li]).trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { continue }
                        let low = t.lowercased()
                        if low.hasPrefix("variables") && (low.dropFirst(9).allSatisfy { $0 == ":" || $0 == " " }) { mode = false; continue }
                        if low.hasPrefix("constants") && (low.dropFirst(9).allSatisfy { $0 == ":" || $0 == " " }) { mode = true; continue }
                        var f = fields(Substring(t.replacingOccurrences(of: "=", with: " ")))
                        guard f.count >= 2, looksLikeName(f[0]), !f[0].hasPrefix("-"), !f[0].hasPrefix("+"), let v = num(f[1]) else {
                            throw err(li + 1, "malformed variable definition '\(t)'")
                        }
                        let name = String(f[0])
                        f.removeFirst(2)
                        z.variables.append(.init(name: name, value: v, isConstant: mode, extra: f.map(String.init)))
                    }
                    undefined = z.undefinedVariables()
                }
                job.zMatrix = z
                do { _ = try z.rowPositions() } catch let e as GaussianZMatrix.RowError {
                    throw err(e.row < zRowLines.count ? zRowLines[e.row] : nil, "Z-matrix: \(e.message)")
                }
                let pos = try z.positions()
                guard pos.count == job.molecule.atoms.count else { throw err(nil, "internal Z-matrix size mismatch") }
                for k in 0..<pos.count where !job.molecule.atoms.isEmpty { job.molecule.atoms[k].position = pos[k] }
            }
        }

        // Connectivity.
        if !geomCheck && route.readsConnectivity {
            guard let b = nextBlock() else { throw err(end, "unexpected end of file: missing connectivity section") }
            // Input numbering -> molecule index (dummy atoms are dropped).
            var map: [Int?]
            if let z = job.zMatrix {
                map = []
                var n = 0
                for e in z.entries { if e.isDummy { map.append(nil) } else { map.append(n); n += 1 } }
            } else {
                map = (0..<job.molecule.atoms.count).map { $0 }
            }
            var seen = Set<Bond>()
            var bonds: [Bond] = []
            for li in b {
                let f = fields(stripComment(lines[li]))
                guard !f.isEmpty else { continue }
                guard let a = Int(f[0]), a >= 1, a <= map.count else { throw err(li + 1, "bad atom number '\(f[0])' in connectivity") }
                guard (f.count - 1) % 2 == 0 else { throw err(li + 1, "connectivity entries must be 'atom order' pairs") }
                var k = 1
                while k < f.count {
                    guard let nb = Int(f[k]), nb >= 1, nb <= map.count, nb != a else { throw err(li + 1, "bad bonded atom '\(f[k])' in connectivity") }
                    guard let o = num(f[k + 1]) else { throw err(li + 1, "bad bond order '\(f[k + 1])'") }
                    let order: BondOrder
                    switch o {
                    case 1: order = .single
                    case 1.5: order = .aromatic
                    case 2: order = .double
                    case 3: order = .triple
                    default: throw err(li + 1, "unsupported bond order \(f[k + 1])")
                    }
                    if let x = map[a - 1], let y = map[nb - 1] {
                        let bond = Bond(x, y, order: order)
                        let key = Bond(x, y, order: .single)
                        if !seen.contains(key) { seen.insert(key); bonds.append(bond) }
                    }
                    k += 2
                }
            }
            job.molecule.bonds = bonds
        }

        // ModRedundant.
        if route.readsModRedundant, let b = nextBlock() {
            job.modRedundant = b.map { lines[$0].trimmingCharacters(in: .whitespaces) }
        }
        // Everything else.
        while let b = nextBlock() {
            job.extraSections.append(b.map { String(lines[$0]) }.joined(separator: "\n"))
        }
        if let c = job.chargeMultiplicities.first {
            job.molecule.charge = c.charge
            job.molecule.multiplicity = c.multiplicity
        }
        job.molecule.title = job.title
        return job
    }

    // MARK: geometry

    private struct Row {
        var label: Substring
        var line: Int
        var z: Int
        var isCartesian: Bool
        var refs: [String] = []
        var vals: [String] = []
        var freeze: Int? = nil
        var spec: AtomSpec
        var trailing: [String] = []
    }

    /// Parse the molecule specification starting at `r.lowerBound` (ends at the first blank line).
    /// Returns the 1-based source line of each Z-matrix row (empty for pure Cartesian input).
    private static func parseGeometry(_ lines: [Substring], _ r: Range<Int>, _ job: inout GaussianJob) throws -> [Int] {
        var rows: [Row] = []
        var li = r.lowerBound
        var anyZ = false, anyVariableCart = false
        while li < r.upperBound, !isBlank(lines[li]) {
            let lineNo = li + 1
            let f = fields(stripComment(lines[li]))
            li += 1
            guard !f.isEmpty else { continue }
            let label = f[0]
            let rest = Array(f.dropFirst())
            let n = rest.count
            var spec = AtomSpec(label: String(label))
            spec.fragment = fragmentIndex(label)
            let z = try atomicNumber(label, line: lineNo)

            var cartOffset: Int? = nil   // 0: "x y z ...", 1: "freeze x y z ..."
            if n >= 4, isLayer(rest[3]) { cartOffset = 0 }
            else if n >= 4, rest[0] == "0" || rest[0] == "-1", n == 4 || isLayer(rest[4]) { cartOffset = 1 }
            else if n == 3 { cartOffset = 0 }

            func tailInfo(_ tail: ArraySlice<String>) {
                if let l = tail.first, l.count == 1, isLayer(Substring(l)) {
                    spec.layer = l.uppercased()
                    let t = tail.dropFirst()
                    if !t.isEmpty { spec.linkAtom = t.joined(separator: " ") }
                } else { spec.parameters = Array(tail) }
            }
            let restS = rest.map(String.init)

            if let off = cartOffset {
                var freeze: Int? = nil
                if off == 1 { freeze = restS[0] == "-1" ? -1 : 0; spec.freeze = freeze! }
                let c = Array(restS[off..<(off + 3)])
                for t in c {
                    if num(Substring(t)) == nil {
                        guard looksLikeName(Substring(t)) else { throw err(lineNo, "bad coordinate '\(t)'") }
                        anyVariableCart = true
                    }
                }
                let tail = restS[(off + 3)...]
                tailInfo(tail)
                rows.append(Row(label: label, line: lineNo, z: z, isCartesian: true, vals: c, freeze: freeze, spec: spec, trailing: Array(tail)))
            } else {
                let base = n >= 6 ? 6 : (n >= 4 ? 4 : (n >= 2 ? 2 : 0))
                guard n == base || n > base else { throw err(lineNo, "malformed atom line") }
                if n == 1 || n == 3 { throw err(lineNo, "malformed atom line '\(lines[li - 1].trimmingCharacters(in: .whitespaces))'") }
                let need = min(rows.count, 3)
                guard base / 2 == need else {
                    throw err(lineNo, "atom \(rows.count + 1) needs \(need) reference(s) and value(s), found \(base / 2)")
                }
                var refs: [String] = [], vals: [String] = []
                for k in 0..<need {
                    refs.append(restS[2 * k])
                    let v = rest[2 * k + 1]
                    guard num(v) != nil || looksLikeName(v) else { throw err(lineNo, "bad Z-matrix value '\(v)'") }
                    vals.append(String(v))
                }
                let tail = restS[base...]
                // Only complete rows (atom 4+) may carry a trailing format flag; on atoms 2-3 any extra
                // field other than an ONIOM layer means an odd/garbled field count.
                if need < 3, let t = tail.first, !(t.count == 1 && isLayer(Substring(t))) {
                    throw err(lineNo, "atom \(rows.count + 1): unexpected extra field '\(t)' (odd field count)")
                }
                tailInfo(tail)
                anyZ = true
                rows.append(Row(label: label, line: lineNo, z: z, isCartesian: false, refs: refs, vals: vals, spec: spec, trailing: Array(tail)))
            }
        }
        guard !rows.isEmpty else { throw err(r.lowerBound + 1, "molecule specification has no atoms") }

        if !anyZ && !anyVariableCart {
            var atoms: [Atom] = [], specs: [AtomSpec] = []
            atoms.reserveCapacity(rows.count); specs.reserveCapacity(rows.count)
            for (k, row) in rows.enumerated() {
                guard let x = num(Substring(row.vals[0])), let y = num(Substring(row.vals[1])), let zz = num(Substring(row.vals[2])) else {
                    throw err(row.line, "bad coordinates")
                }
                var a = Atom(id: k, atomicNumber: row.z, position: Vec3(x, y, zz))
                a.label = labelFor(row.label, z: row.z)
                atoms.append(a); specs.append(row.spec)
            }
            job.molecule.atoms = atoms
            job.atomSpecs = specs
            return []
        }
        // Z-matrix (possibly mixed with Cartesian rows).
        var z = GaussianZMatrix()
        var atoms: [Atom] = [], specs: [AtomSpec] = []
        for row in rows {
            z.entries.append(.init(symbol: String(row.label), references: row.refs, values: row.vals, trailing: row.trailing,
                                   isCartesian: row.isCartesian, freeze: row.freeze))
            if isDummyLabel(row.label) { continue }
            var a = Atom(id: atoms.count, atomicNumber: row.z, position: .zero)
            a.label = labelFor(row.label, z: row.z)
            atoms.append(a); specs.append(row.spec)
        }
        job.molecule.atoms = atoms
        job.atomSpecs = specs
        job.zMatrix = z
        return rows.map { $0.line }
    }

    private static func labelFor(_ raw: Substring, z: Int) -> String? {
        raw.caseInsensitiveCompare(IOElements.symbol(z)) == .orderedSame ? nil : String(raw)
    }
}
