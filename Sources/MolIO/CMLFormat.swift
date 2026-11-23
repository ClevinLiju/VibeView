import Foundation
import MolCore

/// Chemical Markup Language (CML) reader/writer for `<molecule>` with `<atomArray>`/`<bondArray>`.
///
/// Supports per-element `<atom id elementType x3 y3 z3 [x2 y2] formalCharge>` and the array form
/// (`<atomArray atomID="a1 a2" elementType="O H" x3="..." .../>`), `<bond atomRefs2 order>` and the
/// array form (`atomRef1`/`atomRef2`/`order` lists). Molecule `formalCharge`/`spinMultiplicity`
/// attributes and `title` (or a child `<name>`). Each `<molecule>` that has atoms yields one Molecule.
public enum CMLFormat {
    public static func read(url: URL) throws -> [Molecule] { try parse(try readText(url)) }

    public static func parse(_ text: String) throws -> [Molecule] {
        guard let data = text.data(using: .utf8) else { throw MolIOError.parse(format: "cml", line: nil, message: "not UTF-8") }
        let p = XMLParser(data: data)
        let d = Delegate()
        p.delegate = d
        p.shouldProcessNamespaces = true
        let ok = p.parse()
        if let e = d.error { throw e }
        if !ok || d.fatal {
            let line = p.lineNumber
            throw MolIOError.parse(format: "cml", line: line > 0 ? line : nil,
                                   message: p.parserError?.localizedDescription ?? "malformed XML")
        }
        if d.molecules.isEmpty { throw MolIOError.parse(format: "cml", line: nil, message: "no <molecule> with atoms found") }
        return d.molecules
    }

    private struct Builder {
        var title = ""
        var formalCharge: Int? = nil
        var multiplicity: Int? = nil
        var atoms: [Atom] = []
        var charges: [Int] = []
        var ids: [String: Int] = [:]
        var bonds: [(String, String, BondOrder, Int)] = []
        var hasName = false
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var molecules: [Molecule] = []
        var stack: [Builder] = []
        var path: [String] = []
        var text = ""
        var error: MolIOError?
        var fatal = false
        weak var parser: XMLParser?

        func bad(_ p: XMLParser, _ msg: String) {
            if error == nil { error = .parse(format: "cml", line: p.lineNumber > 0 ? p.lineNumber : nil, message: msg) }
            p.abortParsing()
        }

        func parser(_ p: XMLParser, parseErrorOccurred e: Error) { if error == nil { fatal = true } }

        func nums(_ s: String?) -> [String] { (s ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init) }

        func order(_ s: String) -> BondOrder? {
            switch s.trimmingCharacters(in: .whitespaces).uppercased() {
            case "1", "S": return .single
            case "2", "D": return .double
            case "3", "T": return .triple
            case "A", "1.5": return .aromatic
            default: return nil
            }
        }

        func addAtom(_ p: XMLParser, _ b: inout Builder, id: String?, elem: String?, x3: String?, y3: String?, z3: String?,
                     x2: String?, y2: String?, charge: String?) {
            guard let e = elem, !e.isEmpty else { bad(p, "atom without elementType"); return }
            let el = e.trimmingCharacters(in: .whitespaces)
            guard let z = IOElements.atomicNumber(exact: el) ?? (el == "Du" ? 0 : nil) else {
                bad(p, "unknown element '\(el)'"); return
            }
            var pos = Vec3.zero
            func num(_ s: String?, _ what: String) -> Double? {
                guard let s = s else { return 0 }
                guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite else { bad(p, "bad \(what) '\(s)'"); return nil }
                return v
            }
            if x3 != nil || y3 != nil || z3 != nil {
                guard let x = num(x3, "x3"), let y = num(y3, "y3"), let zz = num(z3, "z3") else { return }
                pos = Vec3(x, y, zz)
            } else if x2 != nil || y2 != nil {
                guard let x = num(x2, "x2"), let y = num(y2, "y2") else { return }
                pos = Vec3(x, y, 0)
            }
            var ch = 0
            if let c = charge?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
                guard let v = Int(c.hasPrefix("+") ? String(c.dropFirst()) : c) else { bad(p, "bad formalCharge '\(c)'"); return }
                ch = v
            }
            let idx = b.atoms.count
            b.atoms.append(Atom(id: idx, atomicNumber: z, position: pos))
            b.charges.append(ch)
            let key = id ?? "a\(idx + 1)"
            if b.ids[key] != nil { bad(p, "duplicate atom id '\(key)'"); return }
            b.ids[key] = idx
        }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            if error != nil { return }
            let parent = path.last
            path.append(name)
            switch name {
            case "molecule":
                var b = Builder()
                b.title = a["title"] ?? ""
                b.hasName = a["title"] != nil
                if let c = a["formalCharge"] {
                    guard let v = Int(c.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) else { bad(p, "bad molecule formalCharge"); return }
                    b.formalCharge = v
                }
                if let m = a["spinMultiplicity"] {
                    guard let v = Int(m.trimmingCharacters(in: .whitespaces)), v >= 1 else { bad(p, "bad spinMultiplicity"); return }
                    b.multiplicity = v
                }
                stack.append(b)
            case "atom":
                guard !stack.isEmpty else { return }
                addAtom(p, &stack[stack.count - 1], id: a["id"], elem: a["elementType"], x3: a["x3"], y3: a["y3"], z3: a["z3"],
                        x2: a["x2"], y2: a["y2"], charge: a["formalCharge"])
            case "atomArray":
                guard !stack.isEmpty, a["elementType"] != nil else { return }
                let el = nums(a["elementType"])
                let ids = nums(a["atomID"])
                let x3 = nums(a["x3"]), y3 = nums(a["y3"]), z3 = nums(a["z3"]), x2 = nums(a["x2"]), y2 = nums(a["y2"])
                let fc = nums(a["formalCharge"])
                for (name, arr) in [("atomID", ids), ("x3", x3), ("y3", y3), ("z3", z3), ("x2", x2), ("y2", y2), ("formalCharge", fc)]
                where !arr.isEmpty && arr.count != el.count {
                    bad(p, "atomArray attribute \(name) has \(arr.count) entries, expected \(el.count)"); return
                }
                for k in 0..<el.count {
                    addAtom(p, &stack[stack.count - 1], id: ids.isEmpty ? nil : ids[k], elem: el[k],
                            x3: x3.isEmpty ? nil : x3[k], y3: y3.isEmpty ? nil : y3[k], z3: z3.isEmpty ? nil : z3[k],
                            x2: x2.isEmpty ? nil : x2[k], y2: y2.isEmpty ? nil : y2[k], charge: fc.isEmpty ? nil : fc[k])
                    if error != nil { return }
                }
            case "bond":
                guard !stack.isEmpty else { return }
                let refs = nums(a["atomRefs2"])
                guard refs.count == 2 else { bad(p, "bond needs atomRefs2 with two atom ids"); return }
                let o = a["order"].map { order($0) } ?? .some(.single)
                guard let ord = o else { bad(p, "bad bond order '\(a["order"] ?? "")'"); return }
                stack[stack.count - 1].bonds.append((refs[0], refs[1], ord, p.lineNumber))
            case "bondArray":
                guard !stack.isEmpty, a["atomRef1"] != nil || a["atomRef2"] != nil else { return }
                let r1 = nums(a["atomRef1"]), r2 = nums(a["atomRef2"]), ord = nums(a["order"])
                guard r1.count == r2.count, ord.isEmpty || ord.count == r1.count else { bad(p, "bondArray lists differ in length"); return }
                for k in 0..<r1.count {
                    let o: BondOrder
                    if ord.isEmpty { o = .single } else {
                        guard let v = order(ord[k]) else { bad(p, "bad bond order '\(ord[k])'"); return }
                        o = v
                    }
                    stack[stack.count - 1].bonds.append((r1[k], r2[k], o, p.lineNumber))
                }
            case "name":
                if parent == "molecule" { text = "" }
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if path.last == "name" { text += s } }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if error != nil { return }
            defer { _ = path.popLast() }
            if name == "name", path.count >= 2, path[path.count - 2] == "molecule", !stack.isEmpty {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stack[stack.count - 1].hasName, !t.isEmpty {
                    stack[stack.count - 1].title = t; stack[stack.count - 1].hasName = true
                }
                text = ""
            }
            if name == "molecule", let b = stack.popLast() {
                guard !b.atoms.isEmpty else { return }
                var bonds: [Bond] = []
                for (r1, r2, o, ln) in b.bonds {
                    guard let i = b.ids[r1], let j = b.ids[r2] else {
                        error = .parse(format: "cml", line: ln > 0 ? ln : nil, message: "bond references unknown atom '\(b.ids[r1] == nil ? r1 : r2)'")
                        p.abortParsing(); return
                    }
                    guard i != j else {
                        error = .parse(format: "cml", line: ln > 0 ? ln : nil, message: "bond joins an atom to itself")
                        p.abortParsing(); return
                    }
                    bonds.append(Bond(i, j, order: o))
                }
                let q = b.formalCharge ?? b.charges.reduce(0, +)
                molecules.append(Molecule(atoms: b.atoms, bonds: bonds, charge: q, multiplicity: b.multiplicity ?? 1, title: b.title))
            }
        }
    }

    // MARK: write

    private static func esc(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "\n", "\r", "\t": o += " "
            default: o.append(ch)
            }
        }
        return o
    }

    public static func write(_ m: Molecule) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<cml xmlns=\"http://www.xml-cml.org/schema\">\n"
        out += "  <molecule id=\"m1\""
        if !m.title.isEmpty { out += " title=\"\(esc(m.title))\"" }
        out += " formalCharge=\"\(m.charge)\" spinMultiplicity=\"\(m.multiplicity)\">\n"
        out += "    <atomArray>\n"
        for (i, a) in m.atoms.enumerated() {
            out += "      <atom id=\"a\(i + 1)\" elementType=\"\(IOElements.symbol(a.atomicNumber))\""
            out += String(format: " x3=\"%.8f\" y3=\"%.8f\" z3=\"%.8f\"/>\n", a.position.x, a.position.y, a.position.z)
        }
        out += "    </atomArray>\n"
        if !m.bonds.isEmpty {
            out += "    <bondArray>\n"
            for b in m.bonds {
                let o: String
                switch b.order { case .single: o = "S"; case .double: o = "D"; case .triple: o = "T"; case .aromatic: o = "A" }
                out += "      <bond atomRefs2=\"a\(b.a + 1) a\(b.b + 1)\" order=\"\(o)\"/>\n"
            }
            out += "    </bondArray>\n"
        }
        out += "  </molecule>\n</cml>\n"
        return out
    }
}
