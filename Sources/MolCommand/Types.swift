import Foundation
import MolCore
import MolIO

/// Error raised by command handlers; the executor turns it into an error message.
public struct CommandError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum MessageLevel: String, Sendable, Equatable { case info, warning, error }

public struct CommandMessage: Sendable, Equatable {
    public var level: MessageLevel
    public var text: String
    public init(_ level: MessageLevel, _ text: String) { self.level = level; self.text = text }
}

/// Machine-readable result of a command. Atom sets are 0-BASED internally.
public enum CommandValue: Sendable, Equatable {
    case number(Double, unit: String)
    case text(String)
    /// 0-based atom indices.
    case atoms(Set<Int>)
}

public struct CommandResult: Sendable, Equatable {
    public var command: String
    public var success: Bool
    public var messages: [CommandMessage]
    public var value: CommandValue?
    public init(command: String, success: Bool, messages: [CommandMessage] = [], value: CommandValue? = nil) {
        self.command = command; self.success = success; self.messages = messages; self.value = value
    }
    /// All message texts joined by newlines.
    public var text: String { messages.map(\.text).joined(separator: "\n") }
}

public enum DisplayStyleName: String, Sendable, CaseIterable { case ball, stick, spacefill, wire, cartoon }
public enum LabelKind: String, Sendable, CaseIterable { case atoms, charges }
public enum Axis: String, Sendable, CaseIterable { case x, y, z }

/// Orbital choice: `.homo(offset)` / `.lumo(offset)` are relative (`homo-2` = `.homo(-2)`, `lumo+1` = `.lumo(1)`),
/// `.index(n)` is a 1-based orbital number.
public enum OrbitalSelector: Sendable, Equatable {
    case homo(Int), lumo(Int), index(Int)

    /// Parses `homo`, `lumo`, `homo-2`, `lumo+1`, or `7`.
    public static func parse(_ s: String) -> OrbitalSelector? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        if let n = Int(t), n >= 1 { return .index(n) }
        for (prefix, make) in [("homo", { OrbitalSelector.homo($0) }), ("lumo", { OrbitalSelector.lumo($0) })] as [(String, (Int) -> OrbitalSelector)] {
            guard t.hasPrefix(prefix) else { continue }
            let rest = t.dropFirst(prefix.count)
            if rest.isEmpty { return make(0) }
            if let n = Int(rest), rest.first == "+" || rest.first == "-" { return make(n) }
        }
        return nil
    }
}

/// RGBA colour with components in 0...1.
public struct CommandColor: Sendable, Equatable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    static let named: [String: (Int, Int, Int)] = [
        "red": (230, 25, 25), "green": (30, 170, 60), "blue": (40, 80, 230), "yellow": (250, 220, 40),
        "orange": (255, 140, 0), "purple": (150, 60, 190), "magenta": (230, 40, 200), "cyan": (30, 200, 220),
        "white": (255, 255, 255), "black": (0, 0, 0), "gray": (128, 128, 128), "grey": (128, 128, 128),
        "pink": (255, 150, 190), "brown": (140, 90, 40), "teal": (0, 128, 128), "gold": (212, 175, 55),
    ]
    public static var namedColors: [String] { named.keys.sorted() }

    /// Parses a colour name (`red`) or hex literal (`#rgb`, `#rrggbb`, `#rrggbbaa`; `#` optional).
    public static func parse(_ s: String) -> CommandColor? {
        var t = s.lowercased()
        if let n = named[t] { return CommandColor(r: Double(n.0) / 255, g: Double(n.1) / 255, b: Double(n.2) / 255) }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.allSatisfy({ $0.isHexDigit }) else { return nil }
        let h = Array(t)
        func v(_ a: Character, _ b: Character) -> Double { Double(Int(String([a, b]), radix: 16)!) / 255 }
        switch h.count {
        case 3: return CommandColor(r: v(h[0], h[0]), g: v(h[1], h[1]), b: v(h[2], h[2]))
        case 6: return CommandColor(r: v(h[0], h[1]), g: v(h[2], h[3]), b: v(h[4], h[5]))
        case 8: return CommandColor(r: v(h[0], h[1]), g: v(h[2], h[3]), b: v(h[4], h[5]), a: v(h[6], h[7]))
        default: return nil
        }
    }
}
