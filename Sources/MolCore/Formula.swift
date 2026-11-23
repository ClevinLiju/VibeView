import Foundation

extension Molecule {
    /// Atomic number -> count (dummy atoms excluded).
    public var elementCounts: [Int: Int] {
        var d: [Int: Int] = [:]
        for a in atoms where a.atomicNumber > 0 { d[a.atomicNumber, default: 0] += 1 }
        return d
    }

    /// Hill-order formula: C, H, then alphabetical; without carbon, all alphabetical.
    public var formula: String {
        let counts = elementCounts
        var parts: [(String, Int)] = counts.map { (Elements.symbol($0.key), $0.value) }
        if counts[6] != nil {
            parts.sort {
                func rank(_ s: String) -> Int { s == "C" ? 0 : (s == "H" ? 1 : 2) }
                let ra = rank($0.0), rb = rank($1.0)
                return ra != rb ? ra < rb : $0.0 < $1.0
            }
        } else {
            parts.sort { $0.0 < $1.0 }
        }
        return parts.map { $0.1 == 1 ? $0.0 : "\($0.0)\($0.1)" }.joined()
    }

    /// Formula with a trailing charge, e.g. "H4N+", "O4S2-". Neutral gives the plain formula.
    public func formula(withCharge: Bool) -> String {
        guard withCharge, charge != 0 else { return formula }
        let mag = abs(charge)
        return formula + (mag == 1 ? "" : "\(mag)") + (charge > 0 ? "+" : "-")
    }

    /// Average molecular weight in u.
    public var molecularWeight: Double {
        atoms.reduce(0) { $0 + ($1.atomicNumber > 0 ? $1.element.mass : 0) }
    }

    /// Monoisotopic mass in u (most abundant isotope); average mass where unknown.
    public var monoisotopicMass: Double {
        atoms.reduce(0) { $0 + ($1.atomicNumber > 0 ? Molecule.monoMass($1.atomicNumber) : 0) }
    }

    static func monoMass(_ z: Int) -> Double { monoisotopicTable[z] ?? Elements.element(z).mass }

    private static let monoisotopicTable: [Int: Double] = [
        1: 1.00782503207, 2: 4.00260325415, 3: 7.016004548, 4: 9.012182201, 5: 11.009305406,
        6: 12.0, 7: 14.00307400478, 8: 15.99491461956, 9: 18.99840322, 10: 19.99244017542,
        11: 22.989769282, 12: 23.985041697, 13: 26.98153863, 14: 27.97692653246, 15: 30.97376163,
        16: 31.972071174, 17: 34.968852682, 18: 39.9623831225, 19: 38.96370668, 20: 39.96259098,
        21: 44.9559119, 22: 47.9479463, 23: 50.9439595, 24: 51.9405075, 25: 54.9380451,
        26: 55.9349375, 27: 58.933195, 28: 57.9353429, 29: 62.9295975, 30: 63.9291422,
        31: 68.9255736, 32: 73.9211778, 33: 74.9215965, 34: 79.9165213, 35: 78.9183371,
        36: 83.911507, 37: 84.911789738, 38: 87.9056121, 39: 88.9058483, 40: 89.9047044,
        41: 92.9063781, 42: 97.9054082, 44: 101.9043493, 45: 102.905504, 46: 105.903486,
        47: 106.905097, 48: 113.9033585, 49: 114.903878, 50: 119.9021947, 51: 120.9038157,
        52: 129.9062244, 53: 126.904473, 54: 131.9041535, 55: 132.905451933, 56: 137.905247,
        74: 183.95093092, 78: 194.964791, 79: 196.966568, 80: 201.970643, 81: 204.974427,
        82: 207.9766525, 83: 208.9803991, 92: 238.0507882,
    ]
}
