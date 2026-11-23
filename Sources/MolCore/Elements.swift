import Foundation
import simd

// STUB — Worker A replaces the data table with the full periodic table (Z = 0...118),
// keeping every public signature below unchanged.

public struct Element: Sendable, Hashable {
    public let atomicNumber: Int          // 0 = dummy/ghost "X"
    public let symbol: String
    public let name: String
    public let mass: Double               // standard atomic weight, u
    public let covalentRadius: Double     // Å (single-bond)
    public let vdwRadius: Double          // Å
    public let color: SIMD3<Double>       // Jmol-style RGB, 0...1
    public let cpkColor: SIMD3<Double>    // classic CPK RGB, 0...1
    public let valences: [Int]            // typical valences, most common first ([] if none)
    public let electronegativity: Double? // Pauling

    public init(atomicNumber: Int, symbol: String, name: String, mass: Double, covalentRadius: Double,
                vdwRadius: Double, color: SIMD3<Double>, cpkColor: SIMD3<Double>, valences: [Int],
                electronegativity: Double?) {
        self.atomicNumber = atomicNumber; self.symbol = symbol; self.name = name; self.mass = mass
        self.covalentRadius = covalentRadius; self.vdwRadius = vdwRadius; self.color = color
        self.cpkColor = cpkColor; self.valences = valences; self.electronegativity = electronegativity
    }

    /// Most common valence (0 if none).
    public var defaultValence: Int { valences.first ?? 0 }
}

public enum Elements {
    /// Table indexed by atomic number: all[0] is the dummy "X", all[z] for z in 1...118.
    public static let all: [Element] = table

    public static var maxAtomicNumber: Int { all.count - 1 }

    /// Element for atomic number `z`; out-of-range values return the dummy entry.
    public static func element(_ z: Int) -> Element { (z >= 0 && z < all.count) ? all[z] : all[0] }

    /// Case-insensitive symbol lookup ("c", "Cl", "CL"). Also accepts "X"/"Bq"/"Gh" -> 0.
    public static func element(symbol: String) -> Element? { atomicNumber(symbol: symbol).map { all[$0] } }

    public static func atomicNumber(symbol: String) -> Int? {
        let s = symbol.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "x" || s == "bq" || s == "gh" { return 0 }
        return bySymbol[s]
    }

    /// Normalized symbol for an atomic number ("C", "Cl"); "X" for 0/out of range.
    public static func symbol(_ z: Int) -> String { element(z).symbol }

    private static let bySymbol: [String: Int] = {
        var d: [String: Int] = [:]
        for e in all where e.atomicNumber > 0 { d[e.symbol.lowercased()] = e.atomicNumber }
        return d
    }()

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
        SIMD3(Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    private static func hex(_ h: Int) -> SIMD3<Double> {
        SIMD3(Double((h >> 16) & 255) / 255, Double((h >> 8) & 255) / 255, Double(h & 255) / 255)
    }

    private static func e(_ z: Int, _ sym: String, _ name: String, _ mass: Double, _ cov: Double, _ vdw: Double,
                          _ jmol: Int, _ cpk: Int, _ val: [Int], _ en: Double?) -> Element {
        Element(atomicNumber: z, symbol: sym, name: name, mass: mass, covalentRadius: cov, vdwRadius: vdw,
                color: hex(jmol), cpkColor: hex(cpk), valences: val, electronegativity: en)
    }

    private static let table: [Element] = [
        e(0, "X", "Dummy", 0, 0, 0, 0xFF1493, 0xFF1493, [], nil),
        e(1, "H", "Hydrogen", 1.008, 0.31, 1.20, 0xFFFFFF, 0xFFFFFF, [1], 2.2),
        e(2, "He", "Helium", 4.0026, 0.28, 1.40, 0xD9FFFF, 0xFFC0CB, [0], nil),
        e(3, "Li", "Lithium", 6.94, 1.28, 1.82, 0xCC80FF, 0xB22222, [1], 0.98),
        e(4, "Be", "Beryllium", 9.0122, 0.96, 1.53, 0xC2FF00, 0xC2FF00, [2], 1.57),
        e(5, "B", "Boron", 10.81, 0.84, 1.92, 0xFFB5B5, 0x00FF00, [3], 2.04),
        e(6, "C", "Carbon", 12.011, 0.76, 1.70, 0x909090, 0xC8C8C8, [4], 2.55),
        e(7, "N", "Nitrogen", 14.007, 0.71, 1.55, 0x3050F8, 0x8F8FFF, [3, 5], 3.04),
        e(8, "O", "Oxygen", 15.999, 0.66, 1.52, 0xFF0D0D, 0xF00000, [2], 3.44),
        e(9, "F", "Fluorine", 18.998, 0.57, 1.47, 0x90E050, 0xDAA520, [1], 3.98),
        e(10, "Ne", "Neon", 20.180, 0.58, 1.54, 0xB3E3F5, 0xFFC0CB, [0], nil),
        e(11, "Na", "Sodium", 22.990, 1.66, 2.27, 0xAB5CF2, 0x0000FF, [1], 0.93),
        e(12, "Mg", "Magnesium", 24.305, 1.41, 1.73, 0x8AFF00, 0x228B22, [2], 1.31),
        e(13, "Al", "Aluminium", 26.982, 1.21, 1.84, 0xBFA6A6, 0x808090, [3], 1.61),
        e(14, "Si", "Silicon", 28.085, 1.11, 2.10, 0xF0C8A0, 0xDAA520, [4], 1.9),
        e(15, "P", "Phosphorus", 30.974, 1.07, 1.80, 0xFF8000, 0xFFA500, [3, 5], 2.19),
        e(16, "S", "Sulfur", 32.06, 1.05, 1.80, 0xFFFF30, 0xFFC832, [2, 4, 6], 2.58),
        e(17, "Cl", "Chlorine", 35.45, 1.02, 1.75, 0x1FF01F, 0x00FF00, [1, 3, 5, 7], 3.16),
        e(18, "Ar", "Argon", 39.948, 1.06, 1.88, 0x80D1E3, 0xFFC0CB, [0], nil),
        e(19, "K", "Potassium", 39.098, 2.03, 2.75, 0x8F40D4, 0x8F40D4, [1], 0.82),
        e(20, "Ca", "Calcium", 40.078, 1.76, 2.31, 0x3DFF00, 0x808090, [2], 1.0),
        e(21, "Sc", "Scandium", 44.956, 1.70, 2.11, 0xE6E6E6, 0xE6E6E6, [3], 1.36),
        e(22, "Ti", "Titanium", 47.867, 1.60, 2.00, 0xBFC2C7, 0x808090, [4, 3, 2], 1.54),
        e(23, "V", "Vanadium", 50.942, 1.53, 2.00, 0xA6A6AB, 0xA6A6AB, [5, 4, 3, 2], 1.63),
        e(24, "Cr", "Chromium", 51.996, 1.39, 2.00, 0x8A99C7, 0x808090, [3, 6, 2], 1.66),
        e(25, "Mn", "Manganese", 54.938, 1.39, 2.00, 0x9C7AC7, 0x808090, [2, 4, 7, 3], 1.55),
        e(26, "Fe", "Iron", 55.845, 1.32, 2.00, 0xE06633, 0xFFA500, [2, 3], 1.83),
        e(27, "Co", "Cobalt", 58.933, 1.26, 2.00, 0xF090A0, 0xF090A0, [2, 3], 1.88),
        e(28, "Ni", "Nickel", 58.693, 1.24, 1.63, 0x50D050, 0xA52A2A, [2], 1.91),
        e(29, "Cu", "Copper", 63.546, 1.32, 1.40, 0xC88033, 0xA52A2A, [2, 1], 1.9),
        e(30, "Zn", "Zinc", 65.38, 1.22, 1.39, 0x7D80B0, 0xA52A2A, [2], 1.65),
        e(31, "Ga", "Gallium", 69.723, 1.22, 1.87, 0xC28F8F, 0xC28F8F, [3], 1.81),
        e(32, "Ge", "Germanium", 72.630, 1.20, 2.11, 0x668F8F, 0x668F8F, [4, 2], 2.01),
        e(33, "As", "Arsenic", 74.922, 1.19, 1.85, 0xBD80E3, 0xBD80E3, [3, 5], 2.18),
        e(34, "Se", "Selenium", 78.971, 1.20, 1.90, 0xFFA100, 0xFFA100, [2, 4, 6], 2.55),
        e(35, "Br", "Bromine", 79.904, 1.20, 1.85, 0xA62929, 0xA52A2A, [1, 3, 5, 7], 2.96),
        e(36, "Kr", "Krypton", 83.798, 1.16, 2.02, 0x5CB8D1, 0xFFC0CB, [0, 2], 3.0),
        e(37, "Rb", "Rubidium", 85.468, 2.20, 3.03, 0x702EB0, 0x702EB0, [1], 0.82),
        e(38, "Sr", "Strontium", 87.62, 1.95, 2.49, 0x00FF00, 0x00FF00, [2], 0.95),
        e(39, "Y", "Yttrium", 88.906, 1.90, 2.00, 0x94FFFF, 0x94FFFF, [3], 1.22),
        e(40, "Zr", "Zirconium", 91.224, 1.75, 2.00, 0x94E0E0, 0x94E0E0, [4], 1.33),
        e(41, "Nb", "Niobium", 92.906, 1.64, 2.00, 0x73C2C9, 0x73C2C9, [5, 3], 1.6),
        e(42, "Mo", "Molybdenum", 95.95, 1.54, 2.00, 0x54B5B5, 0x54B5B5, [6, 4], 2.16),
        e(43, "Tc", "Technetium", 98, 1.47, 2.00, 0x3B9E9E, 0x3B9E9E, [7, 4], 1.9),
        e(44, "Ru", "Ruthenium", 101.07, 1.46, 2.00, 0x248F8F, 0x248F8F, [3, 4, 2], 2.2),
        e(45, "Rh", "Rhodium", 102.91, 1.42, 2.00, 0x0A7D8C, 0x0A7D8C, [3], 2.28),
        e(46, "Pd", "Palladium", 106.42, 1.39, 1.63, 0x006985, 0x006985, [2, 4], 2.2),
        e(47, "Ag", "Silver", 107.87, 1.45, 1.72, 0xC0C0C0, 0x808090, [1], 1.93),
        e(48, "Cd", "Cadmium", 112.41, 1.44, 1.58, 0xFFD98F, 0xFFD98F, [2], 1.69),
        e(49, "In", "Indium", 114.82, 1.42, 1.93, 0xA67573, 0xA67573, [3], 1.78),
        e(50, "Sn", "Tin", 118.71, 1.39, 2.17, 0x668080, 0x668080, [4, 2], 1.96),
        e(51, "Sb", "Antimony", 121.76, 1.39, 2.06, 0x9E63B5, 0x9E63B5, [3, 5], 2.05),
        e(52, "Te", "Tellurium", 127.60, 1.38, 2.06, 0xD47A00, 0xD47A00, [2, 4, 6], 2.1),
        e(53, "I", "Iodine", 126.90, 1.39, 1.98, 0x940094, 0xA020F0, [1, 3, 5, 7], 2.66),
        e(54, "Xe", "Xenon", 131.29, 1.40, 2.16, 0x429EB0, 0xFFC0CB, [0, 2, 4, 6], 2.6),
        e(55, "Cs", "Caesium", 132.91, 2.44, 3.43, 0x57178F, 0x57178F, [1], 0.79),
        e(56, "Ba", "Barium", 137.33, 2.15, 2.68, 0x00C900, 0xFFA500, [2], 0.89),
        e(57, "La", "Lanthanum", 138.91, 2.07, 2.00, 0x70D4FF, 0x70D4FF, [3], 1.1),
        e(58, "Ce", "Cerium", 140.12, 2.04, 2.00, 0xFFFFC7, 0xFFFFC7, [3], 1.12),
        e(59, "Pr", "Praseodymium", 140.91, 2.03, 2.00, 0xD9FFC7, 0xD9FFC7, [3], 1.13),
        e(60, "Nd", "Neodymium", 144.24, 2.01, 2.00, 0xC7FFC7, 0xC7FFC7, [3], 1.14),
        e(61, "Pm", "Promethium", 145, 1.99, 2.00, 0xA3FFC7, 0xA3FFC7, [3], 1.13),
        e(62, "Sm", "Samarium", 150.36, 1.98, 2.00, 0x8FFFC7, 0x8FFFC7, [3], 1.17),
        e(63, "Eu", "Europium", 151.96, 1.98, 2.00, 0x61FFC7, 0x61FFC7, [3], 1.2),
        e(64, "Gd", "Gadolinium", 157.25, 1.96, 2.00, 0x45FFC7, 0x45FFC7, [3], 1.2),
        e(65, "Tb", "Terbium", 158.93, 1.94, 2.00, 0x30FFC7, 0x30FFC7, [3], 1.1),
        e(66, "Dy", "Dysprosium", 162.50, 1.92, 2.00, 0x1FFFC7, 0x1FFFC7, [3], 1.22),
        e(67, "Ho", "Holmium", 164.93, 1.92, 2.00, 0x00FF9C, 0x00FF9C, [3], 1.23),
        e(68, "Er", "Erbium", 167.26, 1.89, 2.00, 0x00E675, 0x00E675, [3], 1.24),
        e(69, "Tm", "Thulium", 168.93, 1.90, 2.00, 0x00D452, 0x00D452, [3], 1.25),
        e(70, "Yb", "Ytterbium", 173.05, 1.87, 2.00, 0x00BF38, 0x00BF38, [3], 1.1),
        e(71, "Lu", "Lutetium", 174.97, 1.87, 2.00, 0x00AB24, 0x00AB24, [3], 1.27),
        e(72, "Hf", "Hafnium", 178.49, 1.75, 2.00, 0x4DC2FF, 0x4DC2FF, [4], 1.3),
        e(73, "Ta", "Tantalum", 180.95, 1.70, 2.00, 0x4DA6FF, 0x4DA6FF, [5], 1.5),
        e(74, "W", "Tungsten", 183.84, 1.62, 2.00, 0x2194D6, 0x2194D6, [6, 4], 2.36),
        e(75, "Re", "Rhenium", 186.21, 1.51, 2.00, 0x267DAB, 0x267DAB, [7, 4], 1.9),
        e(76, "Os", "Osmium", 190.23, 1.44, 2.00, 0x266696, 0x266696, [4, 3], 2.2),
        e(77, "Ir", "Iridium", 192.22, 1.41, 2.00, 0x175487, 0x175487, [3, 4], 2.2),
        e(78, "Pt", "Platinum", 195.08, 1.36, 1.72, 0xD0D0E0, 0xD0D0E0, [2, 4], 2.28),
        e(79, "Au", "Gold", 196.97, 1.36, 1.66, 0xFFD123, 0xDAA520, [3, 1], 2.54),
        e(80, "Hg", "Mercury", 200.59, 1.32, 1.55, 0xB8B8D0, 0xB8B8D0, [2, 1], 2.0),
        e(81, "Tl", "Thallium", 204.38, 1.45, 1.96, 0xA6544D, 0xA6544D, [1, 3], 1.62),
        e(82, "Pb", "Lead", 207.2, 1.46, 2.02, 0x575961, 0x575961, [2, 4], 2.33),
        e(83, "Bi", "Bismuth", 208.98, 1.48, 2.07, 0x9E4FB5, 0x9E4FB5, [3, 5], 2.02),
        e(84, "Po", "Polonium", 209, 1.40, 1.97, 0xAB5C00, 0xAB5C00, [2, 4], 2.0),
        e(85, "At", "Astatine", 210, 1.50, 2.02, 0x754F45, 0x754F45, [1], 2.2),
        e(86, "Rn", "Radon", 222, 1.50, 2.20, 0x428296, 0xFFC0CB, [0], 2.2),
        e(87, "Fr", "Francium", 223, 2.60, 3.48, 0x420066, 0x420066, [1], 0.7),
        e(88, "Ra", "Radium", 226, 2.21, 2.83, 0x007D00, 0x007D00, [2], 0.9),
        e(89, "Ac", "Actinium", 227, 2.15, 2.00, 0x70ABFA, 0x70ABFA, [3], 1.1),
        e(90, "Th", "Thorium", 232.04, 2.06, 2.00, 0x00BAFF, 0x00BAFF, [4], 1.3),
        e(91, "Pa", "Protactinium", 231.04, 2.00, 2.00, 0x00A1FF, 0x00A1FF, [5, 4], 1.5),
        e(92, "U", "Uranium", 238.03, 1.96, 1.86, 0x008FFF, 0x008FFF, [6, 4, 3], 1.38),
        e(93, "Np", "Neptunium", 237, 1.90, 2.00, 0x0080FF, 0x0080FF, [5, 4, 3], 1.36),
        e(94, "Pu", "Plutonium", 244, 1.87, 2.00, 0x006BFF, 0x006BFF, [4, 3, 6], 1.28),
        e(95, "Am", "Americium", 243, 1.80, 2.00, 0x545CF2, 0x545CF2, [3], 1.3),
        e(96, "Cm", "Curium", 247, 1.69, 2.00, 0x785CE3, 0x785CE3, [3], 1.3),
        e(97, "Bk", "Berkelium", 247, 1.5, 2.00, 0x8A4FE3, 0x8A4FE3, [3], 1.3),
        e(98, "Cf", "Californium", 251, 1.5, 2.00, 0xA136D4, 0xA136D4, [3], 1.3),
        e(99, "Es", "Einsteinium", 252, 1.5, 2.00, 0xB31FD4, 0xB31FD4, [3], 1.3),
        e(100, "Fm", "Fermium", 257, 1.5, 2.00, 0xB31FBA, 0xB31FBA, [3], 1.3),
        e(101, "Md", "Mendelevium", 258, 1.5, 2.00, 0xB30DA6, 0xB30DA6, [3], 1.3),
        e(102, "No", "Nobelium", 259, 1.5, 2.00, 0xBD0D87, 0xBD0D87, [3], 1.3),
        e(103, "Lr", "Lawrencium", 266, 1.5, 2.00, 0xC70066, 0xC70066, [3], nil),
        e(104, "Rf", "Rutherfordium", 267, 1.5, 2.00, 0xCC0059, 0xCC0059, [3], nil),
        e(105, "Db", "Dubnium", 268, 1.5, 2.00, 0xD1004F, 0xD1004F, [3], nil),
        e(106, "Sg", "Seaborgium", 269, 1.5, 2.00, 0xD90045, 0xD90045, [3], nil),
        e(107, "Bh", "Bohrium", 270, 1.5, 2.00, 0xE00038, 0xE00038, [3], nil),
        e(108, "Hs", "Hassium", 277, 1.5, 2.00, 0xE6002E, 0xE6002E, [3], nil),
        e(109, "Mt", "Meitnerium", 278, 1.5, 2.00, 0xEB0026, 0xEB0026, [3], nil),
        e(110, "Ds", "Darmstadtium", 281, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(111, "Rg", "Roentgenium", 282, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(112, "Cn", "Copernicium", 285, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(113, "Nh", "Nihonium", 286, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(114, "Fl", "Flerovium", 289, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(115, "Mc", "Moscovium", 290, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(116, "Lv", "Livermorium", 293, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(117, "Ts", "Tennessine", 294, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
        e(118, "Og", "Oganesson", 294, 1.5, 2.00, 0xFF1493, 0xFF1493, [3], nil),
    ]
}

extension Element {
    /// Period (row) of the periodic table; 0 for the dummy.
    public var period: Int {
        let z = atomicNumber
        switch z {
        case 1...2: return 1
        case 3...10: return 2
        case 11...18: return 3
        case 19...36: return 4
        case 37...54: return 5
        case 55...86: return 6
        case 87...118: return 7
        default: return 0
        }
    }

    /// True for metallic elements (everything except H, He, B, C, N, O, F, Ne, Si, P, S, Cl, Ar, Ge, As, Se, Br, Kr, Sb, Te, I, Xe, At, Rn and the halogen/noble-gas superheavies).
    public var isMetal: Bool {
        let nonMetalLike: Set<Int> = [0, 1, 2, 5, 6, 7, 8, 9, 10, 14, 15, 16, 17, 18, 32, 33, 34, 35, 36, 51, 52, 53, 54, 85, 86, 117, 118]
        return !nonMetalLike.contains(atomicNumber)
    }
}

extension Atom {
    public var element: Element { Elements.element(atomicNumber) }
    public var symbol: String { Elements.symbol(atomicNumber) }
}
