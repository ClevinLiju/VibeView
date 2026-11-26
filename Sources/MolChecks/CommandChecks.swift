import Foundation
import MolCore
import MolIO
import MolCommand

private final class MockContext: CommandContext {
    var molecule: Molecule
    var selection: Set<Int> = []
    var currentDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    var calls: [String] = []
    var undoStack: [Molecule] = []
    var redoStack: [Molecule] = []
    init(_ m: Molecule) { molecule = m }
    func open(urls: [URL]) throws { calls.append("open:" + urls.map { $0.lastPathComponent }.joined(separator: ",")) }
    func setMolecule(_ m: Molecule, actionName: String) { undoStack.append(molecule); redoStack = []; molecule = m; calls.append("set:\(actionName)") }
    func setHydrogensVisible(_ v: Bool) { calls.append("hyd:\(v)") }
    func setHidden(_ atoms: Set<Int>, hidden: Bool) { calls.append("hidden:\(hidden):\(atoms.sorted())") }
    func setStyle(_ s: DisplayStyleName) { calls.append("style:\(s.rawValue)") }
    func setColor(_ c: CommandColor, atoms: Set<Int>) { calls.append("color:\(Int(c.r * 255)),\(Int(c.g * 255)),\(Int(c.b * 255)):\(atoms.sorted())") }
    func setLabels(_ k: LabelKind?) { calls.append("labels:\(k?.rawValue ?? "off")") }
    func addMeasurement(atoms: [Int]) { calls.append("measure:\(atoms)") }
    func rotate(axis: Axis, degrees: Double) { calls.append("turn:\(axis.rawValue):\(degrees)") }
    func showOrbital(_ w: OrbitalSelector) throws { calls.append("orb:\(w)") }
    func showVibration(_ m: Int?) throws { calls.append("vib:\(m.map(String.init) ?? "off")") }
    func exportImage(to url: URL, width: Int?, height: Int?) throws { calls.append("img:\(url.lastPathComponent):\(width ?? 0)x\(height ?? 0)") }
    func undo() -> Bool { guard let m = undoStack.popLast() else { return false }; redoStack.append(molecule); molecule = m; return true }
    func redo() -> Bool { guard let m = redoStack.popLast() else { return false }; undoStack.append(molecule); molecule = m; return true }
}

private func water() -> Molecule {
    Molecule(atoms: [
        Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0)),
        Atom(id: 1, atomicNumber: 1, position: Vec3(0.9572, 0, 0)),
        Atom(id: 2, atomicNumber: 1, position: Vec3(-0.239987, 0.926627, 0)),
    ], bonds: [Bond(0, 1), Bond(0, 2)])
}

/// Water plus a far-away helium atom (two fragments).
private func waterHe() -> Molecule {
    var m = water()
    m.atoms.append(Atom(id: 3, atomicNumber: 2, position: Vec3(10, 0, 0)))
    return m
}

private func ethanol() -> Molecule {
    // C1 C2 O3 H4 (hydroxyl) H5 H6 on C1 ... a rough hand-built geometry
    Molecule(atoms: [
        Atom(id: 0, atomicNumber: 6, position: Vec3(0, 0, 0)),
        Atom(id: 1, atomicNumber: 6, position: Vec3(1.52, 0, 0)),
        Atom(id: 2, atomicNumber: 8, position: Vec3(2.0, 1.35, 0)),
        Atom(id: 3, atomicNumber: 1, position: Vec3(2.95, 1.35, 0)),
        Atom(id: 4, atomicNumber: 1, position: Vec3(-0.4, 1.0, 0)),
    ], bonds: [Bond(0, 1), Bond(1, 2), Bond(2, 3), Bond(0, 4)])
}

private func ex(_ ctx: MockContext, _ line: String) -> [CommandResult] { CommandExecutor(context: ctx).execute(line) }
private func spec(_ s: String, _ m: Molecule, sel: Set<Int> = []) throws -> Set<Int> {
    try AtomSpec.parse(s).evaluate(in: m, selection: sel)
}

extension Checks {
    static let command: [Check] = [
        Check("command.tokenizer.basic") {
            let c = try CommandTokenizer.parse("Open  a.xyz   b.xyz")
            try expect(c.count == 1 && c[0].name == "open" && c[0].arguments == ["a.xyz", "b.xyz"], "\(c)")
        },
        Check("command.tokenizer.quotes") {
            let c = try CommandTokenizer.parse(#"open "my file.xyz" 'x y' plain"#)
            try expect(c[0].arguments == ["my file.xyz", "x y", "plain"], "\(c[0].arguments)")
        },
        Check("command.tokenizer.escapes") {
            let c = try CommandTokenizer.parse(#"echo "a\"b" "t\\x" a\ b"#)
            try expect(c[0].arguments == ["a\"b", "t\\x", "a b"], "\(c[0].arguments)")
        },
        Check("command.tokenizer.comments") {
            let c = try CommandTokenizer.parse("select C # pick carbons\n# whole line\npwd")
            try expect(c.count == 2 && c[0].arguments == ["C"] && c[1].name == "pwd", "\(c)")
            try expect(c[0].raw == "select C", c[0].raw)
            let q = try CommandTokenizer.parse(#"open "a#b""#)
            try expect(q[0].arguments == ["a#b"], "\(q)")
        },
        Check("command.tokenizer.hexColor") {
            let c = try CommandTokenizer.parse("color all #ff8800 ; pwd")
            try expect(c.count == 2 && c[0].arguments == ["all", "#ff8800"], "\(c)")
        },
        Check("command.tokenizer.separators") {
            let c = try CommandTokenizer.parse("pwd; ls ;;\n\n info")
            try expect(c.map(\.name) == ["pwd", "ls", "info"], "\(c.map(\.name))")
        },
        Check("command.tokenizer.unterminated") {
            do { _ = try CommandTokenizer.parse("open ok \"bad"); try expect(false, "should throw") }
            catch let e as TokenizerError { try expect(e.column == 9, "column \(e.column)") }
        },
        Check("command.paths.resolve") {
            #if os(Windows)
            // Same cases with drive-letter paths; expectations are built with URL APIs so separators match.
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL
            let cwd = root.appendingPathComponent("a/b", isDirectory: true)
            func p(_ rel: String) -> String { root.appendingPathComponent(rel).standardizedFileURL.path }
            try expect(CommandPaths.resolve("c.xyz", cwd: cwd).path == p("a/b/c.xyz"), CommandPaths.resolve("c.xyz", cwd: cwd).path)
            try expect(CommandPaths.resolve("../c.xyz", cwd: cwd).path == p("a/c.xyz"), CommandPaths.resolve("../c.xyz", cwd: cwd).path)
            let abs = URL(fileURLWithPath: "C:\\etc\\x").standardizedFileURL.path
            try expect(CommandPaths.resolve("C:\\etc\\x", cwd: cwd).path == abs, CommandPaths.resolve("C:\\etc\\x", cwd: cwd).path)
            try expect(CommandPaths.resolve("C:/etc/x", cwd: cwd).path == abs, CommandPaths.resolve("C:/etc/x", cwd: cwd).path)
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
            try expect(CommandPaths.resolve("~/foo", cwd: cwd).path == home.appendingPathComponent("foo").standardizedFileURL.path,
                       CommandPaths.resolve("~/foo", cwd: cwd).path)
            try expect(CommandPaths.resolve("~", cwd: cwd).path == home.path, CommandPaths.resolve("~", cwd: cwd).path)
            try expect(CommandPaths.resolve("./x/../y", cwd: cwd).path == p("a/b/y"), CommandPaths.resolve("./x/../y", cwd: cwd).path)
            try expect(CommandPaths.resolve(".\\x\\..\\y", cwd: cwd).path == p("a/b/y"), CommandPaths.resolve(".\\x\\..\\y", cwd: cwd).path)
            #else
            let cwd = URL(fileURLWithPath: "/tmp/a/b")
            try expect(CommandPaths.resolve("c.xyz", cwd: cwd).path == "/tmp/a/b/c.xyz")
            try expect(CommandPaths.resolve("../c.xyz", cwd: cwd).path == "/tmp/a/c.xyz")
            try expect(CommandPaths.resolve("/etc/x", cwd: cwd).path == "/etc/x")
            try expect(CommandPaths.resolve("~/foo", cwd: cwd).path == NSHomeDirectory() + "/foo")
            try expect(CommandPaths.resolve("~", cwd: cwd).path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
            try expect(CommandPaths.resolve("./x/../y", cwd: cwd).path == "/tmp/a/b/y")
            #endif
        },
        Check("command.paths.glob") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("molcmd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for n in ["b.xyz", "a.xyz", "c.pdb", "a1.xyz", ".hidden.xyz"] { try "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
            try expect(CommandPaths.expand("*.xyz", cwd: dir).map(\.lastPathComponent) == ["a.xyz", "b.xyz"] || CommandPaths.expand("*.xyz", cwd: dir).map(\.lastPathComponent) == ["a.xyz", "a1.xyz", "b.xyz"] , "star")
            try expect(CommandPaths.expand("*.xyz", cwd: dir).count == 3)
            try expect(CommandPaths.expand("?.xyz", cwd: dir).map(\.lastPathComponent) == ["a.xyz", "b.xyz"])
            try expect(CommandPaths.expand("[ab].xyz", cwd: dir).count == 2)
            try expect(CommandPaths.expand("*.nothing", cwd: dir).isEmpty)
            try expect(CommandPaths.expand("plain.txt", cwd: dir).count == 1)
            let ctx = MockContext(water()); ctx.currentDirectory = dir
            let r = ex(ctx, "open ?.xyz c.pdb")
            try expect(r[0].success && ctx.calls == ["open:a.xyz,b.xyz,c.pdb"], "\(r) \(ctx.calls)")
            let r2 = ex(ctx, "open *.zzz")
            try expect(!r2[0].success)
        },
        Check("command.spec.basic") {
            let m = water()
            try expect(try spec("all", m) == [0, 1, 2])
            try expect(try spec("none", m).isEmpty)
            try expect(try spec("H", m) == [1, 2])
            try expect(try spec("h", m) == [1, 2])
            try expect(try spec("O,H", m) == [0, 1, 2])
            try expect(try spec("1", m) == [0])
            try expect(try spec("2-3", m) == [1, 2])
            try expect(try spec("1,3", m) == [0, 2])
        },
        Check("command.spec.combinators") {
            let m = ethanol()
            try expect(try spec("C | O", m) == [0, 1, 2])
            try expect(try spec("C or O", m) == [0, 1, 2])
            try expect(try spec("C&1-1", m) == [0])
            try expect(try spec("1-3 and not C", m) == [2])
            try expect(try spec("~H", m) == [0, 1, 2])
            try expect(try spec("(C | H) & ~4", m) == [0, 1, 4])
        },
        Check("command.spec.selectionFragmentWithin") {
            let m = waterHe()
            try expect(try spec("sel", m, sel: [2]) == [2])
            try expect(try spec("selection", m) == [])
            try expect(try spec("fragment 1", m) == [0, 1, 2])
            try expect(try spec("fragment 2", m) == [3])
            try expect(try spec("within 1.0 of O", m) == [0, 1, 2])
            try expect(try spec("within 1.0 of 2", m) == [0, 1])  // O-H 0.957 Å in, H-H 1.51 Å out
            try expect(try spec("within 0.5 of 2", m) == [1])
            try expect(try spec("within 1.0 of He", m) == [3])
            try expect(try spec("within 12 of He", m) == [0, 1, 2, 3])
            try expect(try spec("within 1.0 of sel", m, sel: [1]) == [0, 1])
        },
        Check("command.spec.errors") {
            for bad in ["", "0", "5-3", "Xx", "within", "within 2 of", "( C", "C |", "fragment", "fragment 0"] {
                do { _ = try AtomSpec.parse(bad); try expect(false, "'\(bad)' should fail") } catch is CommandError {}
            }
            do { _ = try AtomSpec.parse("9").evaluateChecked(in: water(), selection: []); try expect(false, "range") } catch is CommandError {}
            do { _ = try AtomSpec.parse("fragment 3").evaluateChecked(in: water(), selection: []); try expect(false, "frag") } catch is CommandError {}
        },
        Check("command.exec.select") {
            let ctx = MockContext(water())
            let r = ex(ctx, "select O,1-2")
            try expect(r.count == 1 && r[0].success && ctx.selection == [0, 1], "\(r)")
            try expect(r[0].value == .atoms([0, 1]))
            _ = ex(ctx, "select H & ~sel")
            try expect(ctx.selection == [2], "\(ctx.selection)")
        },
        Check("command.exec.measureDistance") {
            let ctx = MockContext(water())
            let r = ex(ctx, "measure distance 1 2")
            guard case .number(let v, let u)? = r[0].value else { throw CheckFailure(description: "no value \(r)") }
            try expectClose(v, 0.9572, tol: 1e-9); try expect(u == "Å")
            try expect(ctx.calls == ["measure:[0, 1]"], "\(ctx.calls)")
        },
        Check("command.exec.measureAngle") {
            let ctx = MockContext(water())
            let r = ex(ctx, "measure angle 2 1 3")
            guard case .number(let v, let u)? = r[0].value else { throw CheckFailure(description: "no value") }
            try expectClose(v, 104.52, tol: 0.02); try expect(u == "°")
        },
        Check("command.exec.measureDihedralAndErrors") {
            let ctx = MockContext(ethanol())
            let r = ex(ctx, "measure dihedral 5 1 2 3")
            guard case .number(_, "°")? = r[0].value else { throw CheckFailure(description: "\(r)") }
            try expect(!ex(ctx, "measure distance 1")[0].success)
            try expect(!ex(ctx, "measure angle 1 2 3 4")[0].success)
            try expect(!ex(ctx, "measure distance 1 1")[0].success)
            try expect(!ex(ctx, "measure volume 1 2")[0].success)
        },
        Check("command.exec.invalidAtom") {
            let ctx = MockContext(water())
            let r = ex(ctx, "measure distance 1 9")
            try expect(!r[0].success && r[0].text.contains("atom 9"), r[0].text)
            let r2 = ex(ctx, "select 7")
            try expect(!r2[0].success && ctx.selection.isEmpty)
            try expect(!ex(ctx, "bond 0 2")[0].success)
        },
        Check("command.exec.bondUnbondElement") {
            let ctx = MockContext(ethanol())
            let r = ex(ctx, "bond 1 3 double")
            try expect(r[0].success && ctx.molecule.areBonded(0, 2) && ctx.molecule.bond(between: 0, and: 2)?.order == .double, "\(r)")
            try expect(ctx.calls.last == "set:Bond")
            _ = ex(ctx, "bond 1 3 1.5")
            try expect(ctx.molecule.bond(between: 0, and: 2)?.order == .aromatic)
            try expect(ex(ctx, "unbond 1 3")[0].success && !ctx.molecule.areBonded(0, 2))
            try expect(!ex(ctx, "unbond 1 3")[0].success)
            try expect(ex(ctx, "element 5 F")[0].success && ctx.molecule.atoms[4].atomicNumber == 9)
            try expect(!ex(ctx, "element 5 Qq")[0].success)
            try expect(!ex(ctx, "bond 1 2 quadruple")[0].success)
        },
        Check("command.exec.undoRedo") {
            let ctx = MockContext(ethanol())
            let orig = ctx.molecule
            _ = ex(ctx, "element 1 N")
            try expect(ctx.molecule != orig)
            try expect(ex(ctx, "undo")[0].success && ctx.molecule == orig)
            _ = ex(ctx, "redo")
            try expect(ctx.molecule.atoms[0].atomicNumber == 7)
            let r = ex(ctx, "redo")
            try expect(r[0].success && r[0].messages.first?.level == .warning)
        },
        Check("command.exec.unknownCommand") {
            let ctx = MockContext(water())
            let r = ex(ctx, "selct all")
            try expect(!r[0].success && r[0].text.contains("select"), r[0].text)
            let r2 = ex(ctx, "frobnicate")
            try expect(!r2[0].success && r2[0].messages[0].level == .error)
        },
        Check("command.exec.prefixAbbrev") {
            let ctx = MockContext(water())
            try expect(ex(ctx, "meas dist 1 2")[0].success)
            try expect(ex(ctx, "SELECT ALL")[0].success && ctx.selection.count == 3)
            let r = ex(ctx, "s all")   // select/show/style/save/... ambiguous
            try expect(!r[0].success && r[0].text.contains("ambiguous"), r[0].text)
        },
        Check("command.exec.multiCommand") {
            let ctx = MockContext(water())
            let r = ex(ctx, "style stick; select H; color sel red\nlabel on charges # done")
            try expect(r.count == 4 && r.allSatisfy(\.success), "\(r)")
            try expect(ctx.calls == ["style:stick", "color:230,25,25:[1, 2]", "labels:charges"], "\(ctx.calls)")
            let r2 = ex(ctx, "style ball; bogus; style wire")
            try expect(r2.count == 2 && !r2[1].success, "\(r2.count)")
            try expect(!ctx.calls.contains("style:wire"))
        },
        Check("command.exec.syntaxError") {
            let r = ex(MockContext(water()), "open \"x")
            try expect(r.count == 1 && !r[0].success && r[0].text.contains("column"), r[0].text)
        },
        Check("command.exec.viewShowHideMisc") {
            let ctx = MockContext(water())
            _ = ex(ctx, "hide H; show hydrogens; hide 1-2; turn y 90; export image out.png 800 600; orbital homo-1; vibration 3; vibration off")
            try expect(ctx.calls == ["hyd:false", "hyd:true", "hidden:true:[0, 1]", "turn:y:90.0", "img:out.png:800x600", "orb:homo(-1)", "vib:3", "vib:off"], "\(ctx.calls)")
            try expect(!ex(ctx, "turn q 5")[0].success)
            try expect(!ex(ctx, "style cube")[0].success)
            try expect(!ex(ctx, "color all notacolor")[0].success)
            try expect(!ex(ctx, "export image a.png 800")[0].success)
        },
        Check("command.exec.defaultsUnsupported") {
            let ctx = MockContext(water())
            let r = ex(ctx, "addh")
            try expect(!r[0].success && r[0].text.contains("not supported"), r[0].text)
            try expect(!ex(ctx, "xtb opt")[0].success)
            try expect(!ex(ctx, "xtb freq")[0].success)
        },
        Check("command.exec.info") {
            let r = ex(MockContext(water()), "info")
            try expect(r[0].success && r[0].text.contains("H2O") && r[0].text.contains("atoms: 3"), r[0].text)
        },
        Check("command.exec.cdPwdLs") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("molcmd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "x".write(to: dir.appendingPathComponent("f.xyz"), atomically: true, encoding: .utf8)
            let ctx = MockContext(water())
            try expect(ex(ctx, "cd \"\(dir.path)\"")[0].success)
            try expect(ex(ctx, "pwd")[0].text == ctx.currentDirectory.path)
            let ls = ex(ctx, "ls")[0]
            try expect(ls.messages.map(\.text) == ["f.xyz", "sub/"], "\(ls.messages)")
            try expect(ex(ctx, "cd sub")[0].success && ctx.currentDirectory.lastPathComponent == "sub")
            try expect(ex(ctx, "cd ..")[0].success && ctx.currentDirectory.lastPathComponent == dir.lastPathComponent)
            try expect(!ex(ctx, "cd nonexistent")[0].success)
            try expect(!ex(ctx, "cd f.xyz")[0].success)
        },
        Check("command.exec.help") {
            let ctx = MockContext(water())
            let all = ex(ctx, "help")[0]
            for n in ["open", "select", "measure", "bond", "undo", "xtb", "export"] { try expect(all.text.contains(n), "help lacks \(n)") }
            let one = ex(ctx, "help measure")[0]
            try expect(one.success && one.text.contains("usage: measure distance"), one.text)
            try expect(!ex(ctx, "help zzzzzz")[0].success)
        },
        Check("command.color.parse") {
            try expect(CommandColor.parse("#ff0000") == CommandColor(r: 1, g: 0, b: 0))
            try expect(CommandColor.parse("#f00") == CommandColor(r: 1, g: 0, b: 0))
            try expect(CommandColor.parse("Red") != nil && CommandColor.parse("#12") == nil && CommandColor.parse("nope") == nil)
        },
        Check("command.orbital.parse") {
            try expect(OrbitalSelector.parse("homo") == .homo(0))
            try expect(OrbitalSelector.parse("HOMO-2") == .homo(-2))
            try expect(OrbitalSelector.parse("lumo+1") == .lumo(1))
            try expect(OrbitalSelector.parse("12") == .index(12))
            try expect(OrbitalSelector.parse("homo2") == nil)
        },
        Check("command.history.basics") {
            var h = CommandHistory(maxCount: 3)
            h.add("a"); h.add("a"); h.add("  "); h.add("b"); h.add("c"); h.add("d")
            try expect(h.entries == ["b", "c", "d"], "\(h.entries)")
            try expect(h.previous() == "d" && h.previous() == "c" && h.previous() == "b" && h.previous() == "b")
            try expect(h.next() == "c" && h.next() == "d" && h.next() == nil)
        },
        Check("command.history.roundTrip") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("molcmd-hist-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: url) }
            var h = CommandHistory()
            h.add("select H"); h.add("measure distance 1 2"); h.add("open \"a b.xyz\"")
            try h.save(to: url)
            var g = CommandHistory()
            try g.load(from: url)
            try expect(g.entries == h.entries, "\(g.entries)")
        },
        Check("command.completion.commands") {
            let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
            let c = CommandCompleter.candidates(for: "se", cwd: cwd)
            try expect(c == ["select"], "\(c)")
            let all = CommandCompleter.candidates(for: "", cwd: cwd)
            try expect(all.contains("open") && all.contains("undo"))
            try expect(CommandCompleter.candidates(for: "pwd; und", cwd: cwd) == ["undo"])
        },
        Check("command.completion.keywords") {
            let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
            try expect(CommandCompleter.candidates(for: "style s", cwd: cwd) == ["spacefill", "stick"])
            try expect(CommandCompleter.candidates(for: "measure ", cwd: cwd) == ["angle", "dihedral", "distance"])
            try expect(CommandCompleter.candidates(for: "view ", cwd: cwd) == ["x", "y", "z"])
            try expect(CommandCompleter.candidates(for: "label on c", cwd: cwd) == ["charges"])
            try expect(CommandCompleter.candidates(for: "orbital h", cwd: cwd).contains("homo-1"))
            let el = CommandCompleter.candidates(for: "element 3 C", cwd: cwd)
            try expect(el.contains("C") && el.contains("Cl") && el.contains("Ca"), "\(el)")
            let sel = CommandCompleter.candidates(for: "select ", cwd: cwd, molecule: water())
            try expect(sel.contains("O") && sel.contains("H") && !sel.contains("Cl") && sel.contains("within"), "\(sel)")
        },
        Check("command.completion.paths") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("molcmd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "x".write(to: dir.appendingPathComponent("dna.xyz"), atomically: true, encoding: .utf8)
            try "x".write(to: dir.appendingPathComponent("data/w.pdb"), atomically: true, encoding: .utf8)
            try expect(CommandCompleter.candidates(for: "open d", cwd: dir) == ["data/", "dna.xyz"], "\(CommandCompleter.candidates(for: "open d", cwd: dir))")
            try expect(CommandCompleter.candidates(for: "cd d", cwd: dir) == ["data/"])
            try expect(CommandCompleter.candidates(for: "open data/", cwd: dir) == ["data/w.pdb"])
            try expect(CommandCompleter.candidates(for: "ls ", cwd: dir).count == 2)
            try expect(CommandCompleter.candidates(for: "export image ", cwd: dir).count == 2)
        },
    ]
}
