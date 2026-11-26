import Foundation
import simd
import MolCore
import MolBuild

private func jcWater() -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.117)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.757, -0.469)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.757, -0.469))])
    m.bonds = [Bond(0, 1), Bond(0, 2)]
    return m
}

extension Checks {
    /// Editable input preview (calc setup) and the xtb command-line + XYZ preview format.
    static let buildCalcDraft: [Check] = [
        Check("build.calc.draft.followsFormUntilEdited") {
            var d = CalcInputDraft(generated: "A")
            try expect(!d.isEdited && d.text == "A")
            d.updateGenerated("B")
            try expect(d.text == "B", "unedited preview follows the form")
            d.setText("B")
            try expect(!d.isEdited, "typing the generated text back is not an edit")
            d.setText("B edited")
            try expect(d.isEdited && d.text == "B edited" && !d.formChangedSinceEdit)
            d.updateGenerated("C")
            try expect(d.text == "B edited", "form changes never overwrite an edit")
            try expect(d.formChangedSinceEdit && d.generated == "C", "detached state is reported")
            d.setText("B edited twice")
            try expect(d.formChangedSinceEdit, "still detached from the newer form")
            d.revert()
            try expect(!d.isEdited && d.text == "C" && !d.formChangedSinceEdit, "revert follows the form again")
        },
        Check("build.calc.draft.allProgramsEditedTextIsExact") {
            let m = jcWater()
            for p in QCProgram.allCases where p != .xtb {
                var s = CalcSetup(molecule: m, program: p)
                s.jobType = .energy
                var d = CalcInputDraft(generated: s.inputText(molecule: m))
                let edited = d.generated + "! extra line typed by hand\n"
                d.setText(edited)
                s.charge = 1   // a later form change
                d.updateGenerated(s.inputText(molecule: m))
                try expect(d.text == edited, "\(p): edited text used as typed")
                try expect(d.formChangedSinceEdit, "\(p): detached after form change")
            }
        },
        Check("build.calc.xtbPreview.roundTrip") {
            let m = jcWater()
            var s = CalcSetup(molecule: m, program: .xtb)
            s.jobType = .optimize; s.nprocs = 2
            let args = s.commandArguments(inputFileName: "job.xyz")
            let xyz = s.inputText(molecule: m)
            let text = XTBInputPreview.compose(arguments: args, inputFileName: "job.xyz", xyz: xyz)
            try expect(text.hasPrefix("# xtb job.xyz --opt"), text)
            let p = try XTBInputPreview.parse(text, inputFileName: "job.xyz")
            try expect(p.arguments == args, "\(p.arguments) vs \(args)")
            try expect(p.xyz == xyz, "xyz round trip:\n\(p.xyz)\nvs\n\(xyz)")
            // Hand edits: new flags (quoted value), changed geometry comment.
            let edited = text.replacingOccurrences(of: "--opt", with: "--opt tight --etemp 500 --namespace 'my run'")
            let q = try XTBInputPreview.parse(edited, inputFileName: "job.xyz")
            try expect(q.arguments.prefix(6) == ["job.xyz", "--opt", "tight", "--etemp", "500", "--namespace"], "\(q.arguments)")
            try expect(q.arguments.contains("my run"), "quoted argument kept as one word: \(q.arguments)")
            try expect(XTBInputPreview.shellSplit(XTBInputPreview.shellJoin(["a b", "it's", "x"])) == ["a b", "it's", "x"])
        },
        Check("build.calc.xtbPreview.errors") {
            func err(_ t: String) -> XTBInputPreview.ParseError? {
                do { _ = try XTBInputPreview.parse(t, inputFileName: "job.xyz"); return nil } catch { return error as? XTBInputPreview.ParseError }
            }
            try expect(err("3\n\nO 0 0 0\n") == .missingCommandLine)
            try expect(err("# orca job.xyz\n3\n") == .notXTB("orca"))
            try expect(err("# xtb other.xyz --opt\n# job.xyz:\n\n1\n\nO 0 0 0\n") == .missingInputFile("job.xyz"))
            try expect(err("# xtb job.xyz --opt\n# job.xyz:\n\n") == .emptyGeometry)
        },
    ]

    /// Pre-flight geometry warnings before a job runs.
    static let buildPreflight: [Check] = [
        Check("build.preflight.cleanWaterHasNoWarnings") {
            try expect(GeometryPreflight.check(jcWater()).isEmpty, "\(GeometryPreflight.check(jcWater()))")
            try expect(GeometryPreflight.confirmationText([]) == nil)
            try expect(GeometryPreflight.check(Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: .zero)])).isEmpty, "single atom")
            let benz = FragmentLibrary.fragment(id: "benzene")!.molecule
            try expect(GeometryPreflight.check(benz).isEmpty, "benzene \(GeometryPreflight.check(benz).map(\.message))")
        },
        Check("build.preflight.draggedAtom") {
            // O–H dragged 5.2 Å away from O: isolated H and an over-stretched bond.
            var m = jcWater()
            m.atoms[1].position = m.atoms[0].position + Vec3(0, 5.2, 0)
            let w = GeometryPreflight.check(m)
            let isolated = w.compactMap { if case .isolatedAtom(let a, let d) = $0.kind { return (a, d) } else { return nil } }
            try expect(isolated.count == 1 && isolated[0].0 == 1, "\(w.map(\.message))")
            try expect(abs(isolated[0].1 - 5.2) < 1e-9, "nearest neighbour (O) distance \(isolated[0].1)")
            try expect(w.contains { $0.message == "Atom H2 is 5.2 Å from its nearest neighbour." }, "\(w.map(\.message))")
            try expect(w.contains { if case .stretchedBond(0, 1, let d, let r) = $0.kind { return abs(d - 5.2) < 1e-9 && r > 1.6 } else { return false } }, "\(w.map(\.message))")
            try expect(w.contains { $0.message.hasPrefix("Atom H2 is ") && $0.message.contains("from its nearest neighbour") }, "\(w.map(\.message))")
            try expect(GeometryPreflight.confirmationText(w)?.hasSuffix("Run anyway?") == true)
        },
        Check("build.preflight.stretchedBondOnly") {
            // C–C at 2.6 Å (1.7× 2×0.76) with no other problem: only the bond is reported.
            var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 6, position: .zero), Atom(id: 1, atomicNumber: 6, position: Vec3(2.6, 0, 0))])
            m.bonds = [Bond(0, 1)]
            let w = GeometryPreflight.check(m)
            try expect(w.count == 1, "\(w.map(\.message))")
            guard case .stretchedBond = w[0].kind else { throw CheckFailure(description: "\(w)") }
        },
        Check("build.preflight.fragments") {
            // Two waters 3.5 Å apart: no isolated atom (H…H within 3 Å) but two fragments.
            let a = jcWater()
            var b = jcWater()
            for i in b.atoms.indices { b.atoms[i].position += Vec3(2.8, 0, 0) }
            var m = a
            m.atoms += b.atoms.enumerated().map { var x = $0.element; x.id = 3 + $0.offset; return x }
            m.bonds += b.bonds.map { Bond($0.a + 3, $0.b + 3) }
            let w = GeometryPreflight.check(m)
            try expect(w.count == 1, "\(w.map(\.message))")
            guard case .fragments(let sizes) = w[0].kind, sizes == [3, 3] else { throw CheckFailure(description: "\(w)") }
            try expect(w[0].message.contains("2 disconnected fragments"), w[0].message)
            // Without stored bonds, fragments are found from distances.
            m.bonds = []
            try expect(GeometryPreflight.check(m).contains { if case .fragments = $0.kind { return true } else { return false } })
        },
    ]
}
