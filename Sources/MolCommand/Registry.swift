import Foundation
import MolCore
import MolIO

/// What a handler receives.
public struct CommandInvocation {
    public let context: CommandContext
    public let arguments: [String]
    public let registry: CommandRegistry
    /// Resolves a path argument against the context's current directory.
    public func url(_ s: String) -> URL { CommandPaths.resolve(s, cwd: context.currentDirectory) }
    /// Evaluates the atom spec formed by `words` (1-based text, checked) against the context.
    public func atoms(_ words: [String]) throws -> Set<Int> {
        try AtomSpec.parse(words).evaluateChecked(in: context.molecule, selection: context.selection)
    }
    /// Parses a 1-based atom number and returns it 0-based, validating against the molecule.
    public func atomIndex(_ s: String) throws -> Int {
        guard let n = Int(s) else { throw CommandError("'\(s)' is not an atom number") }
        let c = context.molecule.atoms.count
        guard n >= 1, n <= c else { throw CommandError("atom \(n) does not exist (molecule has \(c) atoms)") }
        return n - 1
    }
}

/// What a handler returns.
public struct CommandOutput: Sendable {
    public var messages: [CommandMessage]
    public var value: CommandValue?
    public init(_ messages: [CommandMessage] = [], value: CommandValue? = nil) { self.messages = messages; self.value = value }
    public init(_ text: String, value: CommandValue? = nil) { self.init([CommandMessage(.info, text)], value: value) }
    public static let empty = CommandOutput()
}

public struct CommandDefinition: Sendable {
    public var name: String
    public var aliases: [String]
    public var usage: String
    public var summary: String
    public var handler: @Sendable (CommandInvocation) throws -> CommandOutput
    public init(name: String, aliases: [String] = [], usage: String, summary: String,
                handler: @escaping @Sendable (CommandInvocation) throws -> CommandOutput) {
        self.name = name; self.aliases = aliases; self.usage = usage; self.summary = summary; self.handler = handler
    }
}

public struct CommandRegistry: Sendable {
    public private(set) var commands: [CommandDefinition]
    public init(commands: [CommandDefinition] = []) { self.commands = commands }
    public mutating func register(_ c: CommandDefinition) { commands.removeAll { $0.name == c.name }; commands.append(c) }

    /// All command names plus aliases, sorted.
    public var allNames: [String] { Array(Set(commands.flatMap { [$0.name] + $0.aliases })).sorted() }

    /// Exact name/alias match (case-insensitive), else a unique prefix match.
    public func lookup(_ word: String) -> CommandDefinition? {
        let w = word.lowercased()
        if let c = commands.first(where: { $0.name == w || $0.aliases.contains(w) }) { return c }
        let m = prefixMatches(w)
        return m.count == 1 ? m[0] : nil
    }

    func prefixMatches(_ w: String) -> [CommandDefinition] {
        commands.filter { $0.name.hasPrefix(w) || $0.aliases.contains { $0.hasPrefix(w) } }
    }

    /// Error text for a word that did not resolve, with a suggestion when one is close.
    public func unknownMessage(_ word: String) -> String {
        let w = word.lowercased()
        let pm = prefixMatches(w)
        if pm.count > 1 { return "ambiguous command '\(word)': could be " + pm.map(\.name).sorted().joined(separator: ", ") }
        let best = allNames.map { ($0, Self.distance($0, w)) }.min { $0.1 < $1.1 }
        if let b = best, b.1 <= max(2, w.count / 3) { return "unknown command '\(word)'. Did you mean '\(b.0)'?" }
        return "unknown command '\(word)'. Type 'help' for a list."
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }
}
