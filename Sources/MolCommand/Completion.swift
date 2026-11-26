import Foundation
import MolCore

/// Tab-completion candidates. Each candidate is the full replacement for the word being completed.
public enum CommandCompleter {
    public static func candidates(for line: String, cursor: Int? = nil, cwd: URL, molecule: Molecule? = nil,
                                  registry: CommandRegistry = .standard) -> [String] {
        let chars = Array(line)
        let upTo = String(chars.prefix(min(max(cursor ?? chars.count, 0), chars.count)))
        // Current command segment, naive split (quotes ignored).
        let seg = upTo.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ";" || $0 == "\n" }).last.map(String.init) ?? ""
        let endsWithSpace = seg.last?.isWhitespace ?? false
        var words = seg.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let partial = endsWithSpace || words.isEmpty ? "" : words.removeLast()
        func filter(_ xs: [String]) -> [String] {
            let p = partial.lowercased()
            return Array(Set(xs.filter { $0.lowercased().hasPrefix(p) })).sorted()
        }
        if words.isEmpty {
            // canonical names first; aliases only when no canonical name matches
            let names = filter(registry.commands.map(\.name))
            return names.isEmpty ? filter(registry.allNames) : names
        }
        guard let def = registry.lookup(words[0]) else { return [] }
        let n = words.count  // number of completed words including the command
        let elements = elementSymbols(molecule)
        let specWords = ["all", "none", "sel", "selection", "fragment", "within", "of", "and", "or", "not"]
        switch def.name {
        case "open": return paths(partial, cwd)
        case "cd": return paths(partial, cwd, dirsOnly: true)
        case "ls": return paths(partial, cwd)
        case "save": return n == 1 ? paths(partial, cwd) : filter(["xyz", "pdb", "mol", "sdf", "cml", "gaussianInput", "orcaInput", "qchemInput"])
        case "export": return n == 1 ? filter(["image"]) : (n == 2 ? paths(partial, cwd) : [])
        case "style": return n == 1 ? filter(DisplayStyleName.allCases.map(\.rawValue)) : []
        case "measure": return n == 1 ? filter(["distance", "angle", "dihedral"]) : []
        case "view": return n == 1 ? filter(["x", "y", "z"]) : []
        case "turn": return n == 1 ? filter(["x", "y", "z"]) : []
        case "label": return n == 1 ? filter(["on", "off"]) : (n == 2 ? filter(["atoms", "charges"]) : [])
        case "element": return n == 2 ? filter(elementSymbols(nil)) : []
        case "bond": return n == 3 ? filter(["single", "double", "triple", "aromatic"]) : []
        case "xtb": return n == 1 ? filter(["opt"]) : []
        case "vibration": return n == 1 ? filter(["off"]) : []
        case "orbital":
            return n == 1 ? filter(["homo", "lumo", "homo-1", "homo-2", "lumo+1", "lumo+2"]) : []
        case "help": return n == 1 ? filter(registry.allNames) : []
        case "select": return filter(specWords + elements)
        case "hide", "show": return filter(specWords + elements + (n == 1 ? ["hydrogens"] : []))
        case "color": return filter(specWords + elements + CommandColor.namedColors)
        default: return []
        }
    }

    private static func elementSymbols(_ m: Molecule?) -> [String] {
        if let m = m, !m.atoms.isEmpty {
            return Array(Set(m.atoms.map { Elements.symbol($0.atomicNumber) })).sorted()
        }
        return (1..<Elements.all.count).map { Elements.all[$0].symbol }
    }

    private static func paths(_ partial: String, _ cwd: URL, dirsOnly: Bool = false) -> [String] {
        let slash = partial.lastIndex(where: CommandPaths.isSeparator)
        let dirText = slash.map { String(partial[...$0]) } ?? ""
        let namePrefix = slash.map { String(partial[partial.index(after: $0)...]) } ?? partial
        let dirURL = dirText.isEmpty ? cwd : CommandPaths.resolve(dirText, cwd: cwd)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? []
        var out: [String] = []
        for n in names.sorted() where n.hasPrefix(namePrefix) && (namePrefix.hasPrefix(".") || !n.hasPrefix(".")) {
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(n).path, isDirectory: &d)
            if dirsOnly && !d.boolValue { continue }
            out.append(dirText + n + (d.boolValue ? "/" : ""))
        }
        return out
    }
}
