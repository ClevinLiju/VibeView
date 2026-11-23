import SwiftUI
import MolCore
import MolBuild

/// Self-contained element display data (symbols, colours, grid layout) for the app shell.
enum ElementInfo {
    static let symbols: [String] = ["X",
        "H","He","Li","Be","B","C","N","O","F","Ne","Na","Mg","Al","Si","P","S","Cl","Ar",
        "K","Ca","Sc","Ti","V","Cr","Mn","Fe","Co","Ni","Cu","Zn","Ga","Ge","As","Se","Br","Kr",
        "Rb","Sr","Y","Zr","Nb","Mo","Tc","Ru","Rh","Pd","Ag","Cd","In","Sn","Sb","Te","I","Xe",
        "Cs","Ba","La","Ce","Pr","Nd","Pm","Sm","Eu","Gd","Tb","Dy","Ho","Er","Tm","Yb","Lu",
        "Hf","Ta","W","Re","Os","Ir","Pt","Au","Hg","Tl","Pb","Bi","Po","At","Rn",
        "Fr","Ra","Ac","Th","Pa","U","Np","Pu","Am","Cm","Bk","Cf","Es","Fm","Md","No","Lr",
        "Rf","Db","Sg","Bh","Hs","Mt","Ds","Rg","Cn","Nh","Fl","Mc","Lv","Ts","Og"]

    static func symbol(_ z: Int) -> String { (z >= 0 && z < symbols.count) ? symbols[z] : "X" }

    static func covalentRadius(_ z: Int) -> Double {
        z <= 86 ? BuildElements.covalentRadius(z) : 1.6
    }
    static func vdwRadius(_ z: Int) -> Double {
        switch z { case 1: 1.2; case 6: 1.7; case 7: 1.55; case 8: 1.52; case 9: 1.47; case 15: 1.8; case 16: 1.8; case 17: 1.75
        default: covalentRadius(z) * 1.55 + 0.1 }
    }

    private static let overrides: [Int: UInt32] = [
        1: 0xFFFFFF, 2: 0xD9FFFF, 3: 0xCC80FF, 4: 0xC2FF00, 5: 0xFFB5B5, 6: 0x909090, 7: 0x3050F8, 8: 0xFF0D0D, 9: 0x90E050,
        10: 0xB3E3F5, 11: 0xAB5CF2, 12: 0x8AFF00, 13: 0xBFA6A6, 14: 0xF0C8A0, 15: 0xFF8000, 16: 0xFFFF30, 17: 0x1FF01F,
        18: 0x80D1E3, 19: 0x8F40D4, 20: 0x3DFF00, 26: 0xE06633, 29: 0xC88033, 30: 0x7D80B0, 35: 0xA62929, 53: 0x940094,
        47: 0xC0C0C0, 79: 0xFFD123, 80: 0xB8B8D0, 78: 0xD0D0E0, 82: 0x575961,
    ]

    static func rgb(_ z: Int) -> (r: Double, g: Double, b: Double) {
        let hex: UInt32
        if let h = overrides[z] { hex = h }
        else if z == 0 { hex = 0xFF1493 }
        else if (57...71).contains(z) || (89...103).contains(z) { hex = 0x70D4A8 }
        else if (21...30).contains(z) || (39...48).contains(z) || (72...80).contains(z) || z >= 104 { hex = 0x7FA6C8 }
        else if [33, 34, 14, 32, 51, 52, 85].contains(z) { hex = 0x9CAF88 }
        else if [3, 11, 19, 37, 55, 87].contains(z) { hex = 0xAB5CF2 }
        else if [4, 12, 20, 38, 56, 88].contains(z) { hex = 0x8AD400 }
        else if [10, 18, 36, 54, 86, 118].contains(z) { hex = 0x80D1E3 }
        else { hex = 0xB0B0C0 }
        return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
    static func color(_ z: Int) -> Color { let c = rgb(z); return Color(red: c.r, green: c.g, blue: c.b) }

    /// (row, column) in the standard 18-column table, rows 0...6 main body; lanthanides row 8, actinides row 9.
    static func gridPosition(_ z: Int) -> (row: Int, col: Int)? {
        switch z {
        case 1: return (0, 0)
        case 2: return (0, 17)
        case 3...4: return (1, z - 3)
        case 5...10: return (1, z - 5 + 12)
        case 11...12: return (2, z - 11)
        case 13...18: return (2, z - 13 + 12)
        case 19...36: return (3, z - 19)
        case 37...54: return (4, z - 37)
        case 55...56: return (5, z - 55)
        case 57...70: return (8, z - 57 + 2)
        case 71...86: return (5, z - 71 + 2)
        case 87...88: return (6, z - 87)
        case 89...102: return (9, z - 89 + 2)
        case 103...118: return (6, z - 103 + 2)
        default: return nil
        }
    }
}

func hillFormula(_ m: Molecule) -> String {
    var counts: [Int: Int] = [:]
    for a in m.atoms { counts[a.atomicNumber, default: 0] += 1 }
    if counts.isEmpty { return "—" }
    func part(_ z: Int) -> String { let n = counts[z]!; return ElementInfo.symbol(z) + (n > 1 ? "\(n)" : "") }
    var out = ""
    let hasC = counts[6] != nil
    var rest = counts.keys.filter { !(hasC && ($0 == 6 || $0 == 1)) }
    rest.sort { ElementInfo.symbol($0) < ElementInfo.symbol($1) }
    if hasC { out += part(6); if counts[1] != nil { out += part(1) } }
    if !hasC { out += rest.map(part).joined() } else { out += rest.map(part).joined() }
    return out
}

/// Replacement for @State (the SwiftUI macro plugin is unavailable in this toolchain).
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
