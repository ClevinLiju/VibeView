import Foundation
import MolCore
import simd

// Model of a Gaussian-style input file ("job"). Public file-format knowledge only.

/// One "charge multiplicity" pair from the charge/multiplicity line (several for ONIOM / fragments).
public struct ChargeMultiplicity: Sendable, Codable, Equatable {
    public var charge: Int
    public var multiplicity: Int
    public init(charge: Int, multiplicity: Int) { self.charge = charge; self.multiplicity = multiplicity }
}

/// Link 0 commands (lines starting with "%").
public struct Link0: Sendable, Codable, Equatable {
    public var checkpoint: String? = nil      // %chk
    public var oldCheckpoint: String? = nil   // %oldchk
    public var memory: String? = nil          // %mem, raw e.g. "16GB"
    public var nprocShared: Int? = nil        // %nprocshared / %nproc
    public var cpu: String? = nil             // %cpu, raw e.g. "0-7"
    public var other: [String] = []           // other raw "%key=value" lines, in order

    public init(checkpoint: String? = nil, oldCheckpoint: String? = nil, memory: String? = nil,
                nprocShared: Int? = nil, cpu: String? = nil, other: [String] = []) {
        self.checkpoint = checkpoint; self.oldCheckpoint = oldCheckpoint; self.memory = memory
        self.nprocShared = nprocShared; self.cpu = cpu; self.other = other
    }

    /// Link 0 lines as written in a file (each starting with "%").
    public var lines: [String] {
        var out: [String] = []
        if let v = oldCheckpoint { out.append("%oldchk=\(v)") }
        if let v = checkpoint { out.append("%chk=\(v)") }
        if let v = memory { out.append("%mem=\(v)") }
        if let v = nprocShared { out.append("%nprocshared=\(v)") }
        if let v = cpu { out.append("%cpu=\(v)") }
        out.append(contentsOf: other)
        return out
    }

    /// Parse one Link 0 line (with or without trailing "!" comment). Unknown lines go to `other`.
    public mutating func absorb(_ rawLine: String) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if let bang = line.firstIndex(of: "!") { line = String(line[..<bang]).trimmingCharacters(in: .whitespaces) }
        guard line.hasPrefix("%") else { return }
        guard let eq = line.firstIndex(of: "=") else { other.append(line); return }
        let key = line[line.index(after: line.startIndex)..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "chk": checkpoint = value
        case "oldchk": oldCheckpoint = value
        case "mem": memory = value
        case "nproc", "nprocs", "nprocshared":
            if let n = Int(value), n > 0 { nprocShared = n } else { other.append(line) }
        case "cpu": cpu = value
        default: other.append(line)
        }
    }
}

/// Per-atom information from the geometry section that does not fit in `Atom`.
public struct AtomSpec: Sendable, Codable, Equatable {
    public var label: String                 // raw first field, e.g. "C", "C-CA-0.1", "C(Fragment=1)", "6"
    public var fragment: Int? = nil          // from "(Fragment=n)"
    public var freeze: Int = 0               // 0 = free, -1 = frozen
    public var layer: String? = nil          // ONIOM layer "H", "M" or "L"
    public var linkAtom: String? = nil       // raw link-atom spec after the layer, e.g. "H-HA 3"
    public var parameters: [String] = []     // other raw trailing fields (e.g. Z-matrix format flag)

    public init(label: String, fragment: Int? = nil, freeze: Int = 0, layer: String? = nil,
                linkAtom: String? = nil, parameters: [String] = []) {
        self.label = label; self.fragment = fragment; self.freeze = freeze; self.layer = layer
        self.linkAtom = linkAtom; self.parameters = parameters
    }
}

/// Z-matrix geometry kept verbatim so a writer can reproduce it.
public struct GaussianZMatrix: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var symbol: String            // raw label ("O", "X", "C1", "6")
        public var references: [String] = [] // atom numbers or labels: [bond, angle, dihedral] (prefix)
        public var values: [String] = []     // distance/angle/dihedral tokens (numbers or variable names, may start with "-")
        public var trailing: [String] = []   // raw extra fields (format flag, ONIOM layer, ...)
        public var isCartesian: Bool = false // a Cartesian line mixed into the Z-matrix: values = x y z
        public var freeze: Int? = nil        // freeze code of a Cartesian line, when written
        public init(symbol: String, references: [String] = [], values: [String] = [], trailing: [String] = [],
                    isCartesian: Bool = false, freeze: Int? = nil) {
            self.symbol = symbol; self.references = references; self.values = values
            self.trailing = trailing; self.isCartesian = isCartesian; self.freeze = freeze
        }
        /// Dummy atom ("X", "X1"; not "Xe").
        public var isDummy: Bool {
            let letters = symbol.prefix { $0.isLetter }
            return letters.count == 1 && (letters == "X" || letters == "x")
        }
    }
    public struct Variable: Sendable, Codable, Equatable {
        public var name: String
        public var value: Double
        public var isConstant: Bool = false
        public var extra: [String] = []      // raw fields after the value (scan steps, "F", ...)
        public init(name: String, value: Double, isConstant: Bool = false, extra: [String] = []) {
            self.name = name; self.value = value; self.isConstant = isConstant; self.extra = extra
        }
    }
    public var entries: [Entry] = []
    public var variables: [Variable] = []
    public init(entries: [Entry] = [], variables: [Variable] = []) { self.entries = entries; self.variables = variables }

    struct RowError: Error { var row: Int; var message: String }

    /// Names of variables used by rows but not defined.
    func undefinedVariables() -> [String] {
        let defined = Set(variables.map { $0.name.lowercased() })
        var seen = Set<String>(), out: [String] = []
        for e in entries {
            for t in e.values {
                if parseFortranDouble(t) != nil { continue }
                var n = t
                if n.hasPrefix("-") || n.hasPrefix("+") { n.removeFirst() }
                let k = n.lowercased()
                if !defined.contains(k) && !seen.contains(k) { seen.insert(k); out.append(n) }
            }
        }
        return out
    }

    /// Cartesian positions (Å) of ALL rows including dummies, standard placement (atom 1 at the origin,
    /// atom 2 on +z from its reference, atom 3 in the xz-plane when no Cartesian atoms precede it).
    public func rowPositions() throws -> [Vec3] {
        var lookup: [String: Double] = [:]
        for v in variables { lookup[v.name.lowercased()] = v.value }
        func value(_ tok: String, _ row: Int) throws -> Double {
            if let d = parseFortranDouble(tok), d.isFinite { return d }
            var name = tok[...], sign = 1.0
            if name.hasPrefix("-") { sign = -1; name = name.dropFirst() } else if name.hasPrefix("+") { name = name.dropFirst() }
            guard let d = lookup[name.lowercased()] else { throw RowError(row: row, message: "undefined variable '\(name)'") }
            return sign * d
        }
        var labelIndex: [String: Int] = [:]
        var pos: [Vec3] = []
        pos.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() {
            defer { labelIndex[e.symbol.lowercased()] = labelIndex[e.symbol.lowercased()] ?? i }
            if e.isCartesian {
                guard e.values.count == 3 else { throw RowError(row: i, message: "Cartesian line needs 3 coordinates") }
                pos.append(Vec3(try value(e.values[0], i), try value(e.values[1], i), try value(e.values[2], i)))
                continue
            }
            let need = min(i, 3)
            guard e.references.count == need, e.values.count == need else {
                throw RowError(row: i, message: "Z-matrix atom \(i + 1) needs \(need) reference(s) and \(need) value(s)")
            }
            var refs: [Int] = []
            for r in e.references {
                if let k = Int(r) {
                    guard k >= 1, k <= i else { throw RowError(row: i, message: "reference atom \(k) is not an earlier atom") }
                    refs.append(k - 1)
                } else if let k = labelIndex[r.lowercased()] {
                    refs.append(k)
                } else {
                    throw RowError(row: i, message: "undefined atom reference '\(r)'")
                }
            }
            if Set(refs).count != refs.count { throw RowError(row: i, message: "duplicate reference atoms") }
            switch need {
            case 0:
                pos.append(.zero)
            case 1:
                let r = try value(e.values[0], i)
                pos.append(pos[refs[0]] + Vec3(0, 0, r))
            case 2:
                let r = try value(e.values[0], i), th = try value(e.values[1], i) * .pi / 180
                let a = pos[refs[0]], b = pos[refs[1]]
                let d = Self.unit(b - a, fallback: Vec3(0, 0, 1))
                let ex = Vec3(1, 0, 0)
                let perp = Self.unit(ex - simd_dot(ex, d) * d, fallback: Self.anyPerp(d))
                pos.append(a + r * (cos(th) * d + sin(th) * perp))
            default:
                let r = try value(e.values[0], i), th = try value(e.values[1], i) * .pi / 180
                let ph = try value(e.values[2], i) * .pi / 180
                let a = pos[refs[0]], b = pos[refs[1]], c = pos[refs[2]]
                let e1 = Self.unit(b - a, fallback: Vec3(0, 0, 1))
                let v = c - b
                let m = Self.unit(v - simd_dot(v, e1) * e1, fallback: Self.anyPerp(e1))
                let n = simd_cross(m, e1)
                pos.append(a + r * (cos(th) * e1 + sin(th) * (cos(ph) * m + sin(ph) * n)))
            }
        }
        return pos
    }

    /// Cartesian positions (Å) of the non-dummy atoms.
    public func positions() throws -> [Vec3] {
        do {
            let all = try rowPositions()
            return zip(all, entries).compactMap { $1.isDummy ? nil : $0 }
        } catch let e as RowError {
            throw MolIOError.parse(format: "Gaussian input", line: nil, message: "Z-matrix row \(e.row + 1): \(e.message)")
        }
    }

    static func unit(_ v: Vec3, fallback: Vec3) -> Vec3 {
        let l = simd_length(v)
        return l > 1e-10 ? v / l : fallback
    }
    static func anyPerp(_ d: Vec3) -> Vec3 {
        let t = abs(d.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        return unit(t - simd_dot(t, d) * d, fallback: Vec3(0, 1, 0))
    }
}

/// One Gaussian job step (one input between `--Link1--` separators).
public struct GaussianJob: Sendable, Codable, Equatable {
    public var link0: Link0 = Link0()
    public var route: GaussianRoute
    public var title: String = ""
    /// Charge/multiplicity of the whole system, Cartesian coordinates in Å, bonds from a connectivity section.
    public var molecule: Molecule = Molecule()
    public var chargeMultiplicities: [ChargeMultiplicity] = []
    public var atomSpecs: [AtomSpec] = []            // parallel to molecule.atoms
    public var zMatrix: GaussianZMatrix? = nil
    public var modRedundant: [String] = []
    public var extraSections: [String] = []

    public init(link0: Link0 = Link0(), route: GaussianRoute, title: String = "", molecule: Molecule = Molecule(),
                chargeMultiplicities: [ChargeMultiplicity]? = nil, atomSpecs: [AtomSpec]? = nil,
                zMatrix: GaussianZMatrix? = nil, modRedundant: [String] = [], extraSections: [String] = []) {
        self.link0 = link0; self.route = route; self.title = title
        self.molecule = molecule
        self.chargeMultiplicities = chargeMultiplicities ?? [ChargeMultiplicity(charge: molecule.charge, multiplicity: molecule.multiplicity)]
        self.atomSpecs = atomSpecs ?? molecule.atoms.map { AtomSpec(label: $0.label ?? IOElements.symbol($0.atomicNumber)) }
        self.zMatrix = zMatrix; self.modRedundant = modRedundant; self.extraSections = extraSections
    }

    /// Convenience: a Cartesian job for `molecule`.
    public init(molecule: Molecule, route: GaussianRoute, title: String? = nil) {
        var m = molecule
        let t = title ?? molecule.title
        if !t.isEmpty { m.title = t }
        self.init(route: route, title: t, molecule: m)
    }

    /// The text of this job as a Gaussian input file.
    public var inputText: String { GaussianInputWriter.write([self]) }
}
