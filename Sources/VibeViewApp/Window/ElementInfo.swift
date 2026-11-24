import SwiftUI
import MolCore

/// Self-contained element display data (symbols, colours, grid layout) for the app shell.
enum ElementInfo {
    static func symbol(_ z: Int) -> String { Elements.symbol(z) }
    static func name(_ z: Int) -> String { Elements.element(z).name }
    static func rgb(_ z: Int) -> (r: Double, g: Double, b: Double) {
        let c = Elements.element(z).color
        return (c.x, c.y, c.z)
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

func hillFormula(_ m: Molecule) -> String { m.atoms.isEmpty ? "—" : m.formula }

/// Replacement for @State (the SwiftUI macro plugin is unavailable in this toolchain).
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
