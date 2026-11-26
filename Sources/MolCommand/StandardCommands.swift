import Foundation
import MolCore
import MolIO

private func need(_ inv: CommandInvocation, _ n: Int, _ usage: String) throws {
    if inv.arguments.count < n { throw CommandError("usage: \(usage)") }
}
private func fmt(_ v: Double, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", v) }
private func parseAxis(_ s: String) throws -> Axis {
    guard let a = Axis(rawValue: s.lowercased()) else { throw CommandError("axis must be x, y or z (got '\(s)')") }
    return a
}
private func parseFormat(_ s: String) throws -> MoleculeFileFormat {
    let l = s.lowercased()
    if let f = MoleculeFileFormat.allCases.first(where: { $0.rawValue.lowercased() == l }) { return f }
    if let f = MoleculeFileFormat.format(forExtension: l) { return f }
    throw CommandError("unknown file format '\(s)'")
}
private func parseBondOrder(_ s: String) throws -> BondOrder {
    switch s.lowercased() {
    case "single", "1": return .single
    case "double", "2": return .double
    case "triple", "3": return .triple
    case "aromatic", "1.5": return .aromatic
    default: throw CommandError("bond order must be single, double, triple, aromatic, 1, 2, 3 or 1.5 (got '\(s)')")
    }
}

extension CommandRegistry {
    /// The built-in command set. Atom numbers in all commands are 1-based.
    public static let standard: CommandRegistry = {
        var r = CommandRegistry()
        func add(_ name: String, _ aliases: [String] = [], _ usage: String, _ summary: String,
                 _ h: @escaping @Sendable (CommandInvocation) throws -> CommandOutput) {
            r.register(CommandDefinition(name: name, aliases: aliases, usage: usage, summary: summary, handler: h))
        }

        add("open", ["load"], "open <path...>", "Open files (globs like *.xyz allowed).") { inv in
            try need(inv, 1, "open <path...>")
            var urls: [URL] = []
            for a in inv.arguments {
                let m = CommandPaths.expand(a, cwd: inv.context.currentDirectory)
                if CommandPaths.hasWildcard(a) && m.isEmpty { throw CommandError("no files match '\(a)'") }
                urls += m
            }
            for u in urls where !FileManager.default.fileExists(atPath: u.path) { throw CommandError("file not found: \(u.path)") }
            try inv.context.open(urls: urls)
            return CommandOutput("opened \(urls.count) file(s)")
        }
        add("save", ["write"], "save <path> [format]", "Save the molecule; format is guessed from the extension.") { inv in
            try need(inv, 1, "save <path> [format]")
            let fmtName = inv.arguments.count > 1 ? try parseFormat(inv.arguments[1]) : nil
            let url = inv.url(inv.arguments[0])
            if let f = fmtName ?? MoleculeFileFormat.detect(url: url), !f.canWrite { throw CommandError("\(f.displayName) files cannot be written") }
            try inv.context.save(to: url, format: fmtName)
            return CommandOutput("saved \(url.path)")
        }
        add("cd", [], "cd [path]", "Change the working directory (no argument: home).") { inv in
            let u = inv.arguments.isEmpty ? URL(fileURLWithPath: NSHomeDirectory()) : inv.url(inv.arguments[0])
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else {
                throw CommandError("not a directory: \(u.path)")
            }
            inv.context.currentDirectory = u
            return CommandOutput(u.path, value: .text(u.path))
        }
        add("pwd", [], "pwd", "Print the working directory.") { inv in
            CommandOutput(inv.context.currentDirectory.path, value: .text(inv.context.currentDirectory.path))
        }
        add("ls", ["dir"], "ls [path]", "List a directory (or glob).") { inv in
            let cwd = inv.context.currentDirectory
            let target = inv.arguments.first ?? "."
            var names: [String] = []
            if CommandPaths.hasWildcard(target) {
                names = CommandPaths.expand(target, cwd: cwd).map { $0.lastPathComponent }
            } else {
                let u = CommandPaths.resolve(target, cwd: cwd)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw CommandError("no such path: \(u.path)") }
                if isDir.boolValue {
                    names = ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                    names = names.map { n in
                        var d: ObjCBool = false
                        FileManager.default.fileExists(atPath: u.appendingPathComponent(n).path, isDirectory: &d)
                        return d.boolValue ? n + "/" : n
                    }
                } else { names = [u.lastPathComponent] }
            }
            return CommandOutput(names.map { CommandMessage(.info, $0) }, value: .text(names.joined(separator: "\n")))
        }
        add("close", [], "close", "Close the current molecule.") { inv in inv.context.close(); return CommandOutput("closed") }

        add("select", ["sel"], "select <spec>", "Set the selection. Spec: all, none, C,O, 1-5,8, fragment N, within R of SPEC, sel; combine with | & ~ (or/and/not). Atom numbers are 1-based.") { inv in
            if inv.arguments.isEmpty {
                let n = inv.context.selection.count
                return CommandOutput("\(n) atom(s) selected", value: .atoms(inv.context.selection))
            }
            let s = try inv.atoms(inv.arguments)
            inv.context.selection = s
            return CommandOutput("\(s.count) atom(s) selected", value: .atoms(s))
        }
        for (name, hidden) in [("hide", true), ("show", false)] {
            add(name, [], "\(name) hydrogens | <spec>", "\(hidden ? "Hide" : "Show") hydrogens or the given atoms (no argument: all atoms).") { inv in
                if inv.arguments.count == 1, ["h", "hydrogens", "hydrogen"].contains(inv.arguments[0].lowercased()) {
                    inv.context.setHydrogensVisible(!hidden)
                    return CommandOutput("hydrogens \(hidden ? "hidden" : "shown")")
                }
                let s = inv.arguments.isEmpty ? Set(0..<inv.context.molecule.atoms.count) : try inv.atoms(inv.arguments)
                inv.context.setHidden(s, hidden: hidden)
                return CommandOutput("\(hidden ? "hid" : "showed") \(s.count) atom(s)", value: .atoms(s))
            }
        }
        add("style", [], "style ball|stick|spacefill|wire|cartoon", "Set the display style (cartoon: protein ribbons).") { inv in
            try need(inv, 1, "style ball|stick|spacefill|wire|cartoon")
            guard let s = DisplayStyleName(rawValue: inv.arguments[0].lowercased()) else {
                throw CommandError("unknown style '\(inv.arguments[0])'; choose " + DisplayStyleName.allCases.map(\.rawValue).joined(separator: ", "))
            }
            inv.context.setStyle(s)
            return CommandOutput("style \(s.rawValue)")
        }
        add("color", ["colour"], "color <spec|sel> <color>", "Colour atoms; color is a name or #rrggbb.") { inv in
            try need(inv, 2, "color <spec|sel> <color>")
            guard let c = CommandColor.parse(inv.arguments.last!) else { throw CommandError("unknown color '\(inv.arguments.last!)'") }
            let s = try inv.atoms(Array(inv.arguments.dropLast()))
            inv.context.setColor(c, atoms: s)
            return CommandOutput("coloured \(s.count) atom(s)", value: .atoms(s))
        }
        add("label", [], "label on|off [atoms|charges]", "Show or hide atom labels.") { inv in
            try need(inv, 1, "label on|off [atoms|charges]")
            let a = inv.arguments.map { $0.lowercased() }
            if a[0] == "off" || a[0] == "none" { inv.context.setLabels(nil); return CommandOutput("labels off") }
            var kind = LabelKind.atoms
            let k = a[0] == "on" ? a.dropFirst().first : a[0]
            if let k = k {
                guard let kk = LabelKind(rawValue: k) else { throw CommandError("label kind must be atoms or charges (got '\(k)')") }
                kind = kk
            } else if a[0] != "on" { throw CommandError("usage: label on|off [atoms|charges]") }
            inv.context.setLabels(kind)
            return CommandOutput("labels \(kind.rawValue)")
        }
        add("measure", [], "measure distance i j | angle i j k | dihedral i j k l", "Measure geometry (1-based atoms). Returns Å or degrees.") { inv in
            try need(inv, 1, "measure distance i j | angle i j k | dihedral i j k l")
            let word = inv.arguments[0].lowercased()
            let counts = ["distance": 2, "angle": 3, "dihedral": 4, "torsion": 4]
            // full name or a unique prefix ("dist", "ang", "dih")
            let hits = counts.keys.filter { $0.hasPrefix(word) && $0 != "torsion" || $0 == word }
            guard hits.count == 1, let kindName = hits.first, let n = counts[kindName] else {
                throw CommandError("measure kind must be distance, angle or dihedral (got '\(word)')")
            }
            let kind = kindName == "torsion" ? "dihedral" : kindName
            let rest = Array(inv.arguments.dropFirst())
            guard rest.count == n else { throw CommandError("measure \(kind) needs \(n) atoms, got \(rest.count)") }
            let ix = try rest.map { try inv.atomIndex($0) }
            guard Set(ix).count == n else { throw CommandError("measure \(kind) needs \(n) different atoms") }
            let m = inv.context.molecule
            let v: Double, unit: String
            switch n {
            case 2: v = m.distance(ix[0], ix[1]); unit = "Å"
            case 3: v = m.angle(ix[0], ix[1], ix[2]); unit = "°"
            default: v = m.dihedral(ix[0], ix[1], ix[2], ix[3]); unit = "°"
            }
            inv.context.addMeasurement(atoms: ix)
            return CommandOutput("\(kind) \(rest.joined(separator: "-")) = \(fmt(v, n == 2 ? 4 : 2)) \(unit)", value: .number(v, unit: unit))
        }
        add("turn", ["rotate"], "turn x|y|z <degrees>", "Rotate the view about a screen axis.") { inv in
            try need(inv, 2, "turn x|y|z <degrees>")
            let a = try parseAxis(inv.arguments[0])
            guard let d = Double(inv.arguments[1]) else { throw CommandError("'\(inv.arguments[1])' is not a number of degrees") }
            inv.context.rotate(axis: a, degrees: d)
            return CommandOutput("turned \(a.rawValue) by \(d)°")
        }
        add("view", [], "view [x|y|z]", "Fit the molecule in view, or look along an axis.") { inv in
            if let a = inv.arguments.first {
                let ax = try parseAxis(a); inv.context.viewAlong(ax); return CommandOutput("looking along \(ax.rawValue)")
            }
            inv.context.fitView(); return CommandOutput("view fitted")
        }
        add("bond", [], "bond i j [single|double|triple|aromatic|1|2|3|1.5]", "Create a bond or change its order (1-based atoms).") { inv in
            try need(inv, 2, "bond i j [order]")
            let i = try inv.atomIndex(inv.arguments[0]), j = try inv.atomIndex(inv.arguments[1])
            guard i != j else { throw CommandError("cannot bond an atom to itself") }
            let order = inv.arguments.count > 2 ? try parseBondOrder(inv.arguments[2]) : .single
            var m = inv.context.molecule
            if m.areBonded(i, j) { m.setBondOrder(i, j, order) } else { _ = m.addBond(i, j, order: order) }
            inv.context.setMolecule(m, actionName: "Bond")
            return CommandOutput("bond \(i + 1)-\(j + 1) \(order)")
        }
        add("unbond", [], "unbond i j", "Remove a bond (1-based atoms).") { inv in
            try need(inv, 2, "unbond i j")
            let i = try inv.atomIndex(inv.arguments[0]), j = try inv.atomIndex(inv.arguments[1])
            var m = inv.context.molecule
            guard m.removeBond(i, j) else { throw CommandError("atoms \(i + 1) and \(j + 1) are not bonded") }
            inv.context.setMolecule(m, actionName: "Remove Bond")
            return CommandOutput("removed bond \(i + 1)-\(j + 1)")
        }
        add("element", [], "element i Sym", "Change the element of atom i (1-based).") { inv in
            try need(inv, 2, "element i Sym")
            let i = try inv.atomIndex(inv.arguments[0])
            guard let z = Elements.atomicNumber(symbol: inv.arguments[1]), z > 0 else { throw CommandError("unknown element '\(inv.arguments[1])'") }
            var m = inv.context.molecule
            m.atoms[i].atomicNumber = z
            inv.context.setMolecule(m, actionName: "Change Element")
            return CommandOutput("atom \(i + 1) is now \(Elements.symbol(z))")
        }
        add("addh", ["addhydrogens"], "addh", "Add hydrogens.") { inv in try inv.context.addHydrogens(); return CommandOutput("hydrogens added") }
        add("info", [], "info", "Formula, atom count, weight, charge, multiplicity.") { inv in
            let m = inv.context.molecule
            let lines = ["formula: \(m.formula)", "atoms: \(m.atoms.count)", "bonds: \(m.bonds.count)",
                         "molecular weight: \(fmt(m.molecularWeight, 3))", "charge: \(m.charge)", "multiplicity: \(m.multiplicity)"]
            return CommandOutput(lines.map { CommandMessage(.info, $0) }, value: .text(m.formula))
        }
        add("xtb", [], "xtb opt [options...]", "Run an xtb geometry optimisation.") { inv in
            guard inv.arguments.first?.lowercased() == "opt" else { throw CommandError("usage: xtb opt [options...]") }
            try inv.context.runXTBOptimization(options: Array(inv.arguments.dropFirst()))
            return CommandOutput("xtb optimisation started")
        }
        add("orbital", ["mo"], "orbital homo|lumo|homo-N|lumo+N|N", "Show a molecular orbital.") { inv in
            try need(inv, 1, "orbital homo|lumo|homo-N|lumo+N|N")
            guard let o = OrbitalSelector.parse(inv.arguments.joined()) else { throw CommandError("bad orbital '\(inv.arguments.joined(separator: " "))'") }
            try inv.context.showOrbital(o)
            return CommandOutput("showing orbital \(inv.arguments.joined())")
        }
        add("vibration", ["vib"], "vibration N|off", "Animate vibrational mode N (1-based) or stop.") { inv in
            try need(inv, 1, "vibration N|off")
            let a = inv.arguments[0].lowercased()
            if a == "off" || a == "0" { try inv.context.showVibration(nil); return CommandOutput("vibration off") }
            guard let n = Int(a), n >= 1 else { throw CommandError("mode must be a number from 1 or 'off'") }
            try inv.context.showVibration(n)
            return CommandOutput("showing mode \(n)")
        }
        add("export", [], ExportCommand.usage,
            "Export a picture of the view, an animation (GIF/MP4), a structure file or a results table (CSV). With no image size the picture is the view at 2× its on-screen size.") { inv in
            let cmd = try ExportCommand.parse(inv.arguments)
            switch cmd {
            case let .image(path, req):
                let url = inv.url(path)
                try inv.context.exportImage(req, to: url)
                return CommandOutput("exported \(url.path)")
            case let .animation(path, req):
                let url = inv.url(path)
                let info = try inv.context.exportAnimation(req, to: url)
                return CommandOutput("exported \(url.path)" + (info.isEmpty ? "" : " (\(info))"))
            case let .csv(path, table):
                let url = inv.url(path)
                try inv.context.exportTable(table, to: url)
                return CommandOutput("exported \(table.rawValue) to \(url.path)")
            case let .structure(path, all, selected):
                let url = inv.url(path)
                if let f = MoleculeFileFormat.detect(url: url), !f.canWrite { throw CommandError("\(f.displayName) files cannot be written") }
                let info = try inv.context.exportStructure(to: url, allFrames: all, selectedOnly: selected)
                return CommandOutput("exported \(url.path)" + (info.isEmpty ? "" : " (\(info))"))
            }
        }
        add("undo", [], "undo", "Undo the last edit.") { inv in
            inv.context.undo() ? CommandOutput("undone") : CommandOutput([CommandMessage(.warning, "nothing to undo")])
        }
        add("redo", [], "redo", "Redo the last undone edit.") { inv in
            inv.context.redo() ? CommandOutput("redone") : CommandOutput([CommandMessage(.warning, "nothing to redo")])
        }
        add("help", ["?"], "help [command]", "List commands or show usage for one.") { inv in
            if let w = inv.arguments.first {
                guard let c = inv.registry.lookup(w) else { throw CommandError(inv.registry.unknownMessage(w)) }
                let al = c.aliases.isEmpty ? "" : " (aliases: \(c.aliases.joined(separator: ", ")))"
                return CommandOutput(["usage: \(c.usage)", c.summary + al].map { CommandMessage(.info, $0) }, value: .text(c.usage))
            }
            let lines = inv.registry.commands.sorted { $0.name < $1.name }.map { "\($0.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.summary)" }
            return CommandOutput(lines.map { CommandMessage(.info, $0) }, value: .text(lines.joined(separator: "\n")))
        }
        return r
    }()
}
