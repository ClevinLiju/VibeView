import Foundation
import MolCore
import MolIO
import MolAnalysis

// Protein residues / secondary structure (cartoon data), structure export and CSV result tables.
// Fixture: hemoglobin 4HHB chains A and B (TestData/io/pdb_4hhb_ab.pdb, trimmed from the RCSB entry).
enum ProteinFixture {
    static let url = testDataURL("io/pdb_4hhb_ab.pdb")
    static var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    /// The molecule as the app shows it: PDB atoms with perceived bonds.
    static func molecule() throws -> Molecule {
        var m = try PDBFormat.parse(text).models[0]
        m.renumberAtomIDs()
        if m.bonds.isEmpty { m.perceiveBonds() } else {
            var stated = Set(m.bonds.map { Int64($0.a) << 32 | Int64($0.b) })
            for b in m.perceivedBonds() where stated.insert(Int64(b.a) << 32 | Int64(b.b)).inserted { m.bonds.append(b) }
        }
        return m
    }
}

extension Checks {
    static let analysisProtein: [Check] = [
        Check("analysis.protein.4hhb.fromRecords") {
            let m = try ProteinFixture.molecule()
            let rec = PDBProteinRecords.parse(ProteinFixture.text)
            try expect(rec.models.count == 1 && rec.models[0].count == m.atoms.count, "records \(rec.models.map(\.count)) atoms \(m.atoms.count)")
            let helixRecords = ProteinFixture.text.split(separator: "\n").filter { $0.hasPrefix("HELIX") }.count
            try expect(rec.ranges.count == helixRecords && helixRecords > 10, "ranges \(rec.ranges.count)")
            let p = ProteinAnalysis.analyze(m, records: rec)
            try expect(p.residueSource == .file && p.ssSource == .file)
            try expect(p.residueCount == 141 + 146, "residues \(p.residueCount)")
            try expect(p.chains == ["A", "B"], "chains \(p.chains)")
            try expect(p.segments.count == 2 && p.segments.allSatisfy { $0.count > 140 }, "segments \(p.segments)")
            try expect(p.residues.allSatisfy { $0.n >= 0 && $0.ca >= 0 && $0.c >= 0 && $0.o >= 0 })
            try expect(p.residues.allSatisfy { m.atoms[$0.ca].atomicNumber == 6 && m.atoms[$0.n].atomicNumber == 7 })
            try expect(p.helixCount >= 10 && p.strandCount == 0, "helices \(p.helixCount) strands \(p.strandCount)")
            let helixFrac = Double(p.ss.filter { $0.kind == .helix }.count) / Double(p.residueCount)
            try expect(helixFrac > 0.65 && helixFrac < 0.85, "helix fraction \(helixFrac)")
            // Waters (113 HOH in A+B), hemes (2 × 43 atoms) and a phosphate P are not polymer.
            try expect(p.waterAtoms.filter { $0 }.count == 113, "water \(p.waterAtoms.filter { $0 }.count)")
            let hetero = m.atoms.indices.filter { !p.polymerAtoms[$0] && !p.waterAtoms[$0] }
            try expect(hetero.count == 2 * 43 + 1, "non-polymer, non-water atoms \(hetero.count)")
            try expect(hetero.contains { m.atoms[$0].atomicNumber == 26 }, "Fe in a heme")
        },
        Check("analysis.protein.4hhb.topologyAndDSSP") {
            let m = try ProteinFixture.molecule()
            let file = ProteinAnalysis.analyze(m, records: PDBProteinRecords.parse(ProteinFixture.text))
            let t0 = CFAbsoluteTimeGetCurrent()
            let p = ProteinAnalysis.analyze(m)          // no records: backbone from bonds, DSSP
            let dt = CFAbsoluteTimeGetCurrent() - t0
            try expect(p.residueSource == .topology && p.ssSource == .computed)
            // 4HHB (1984) has a few distorted residues (C=O up to 1.8 Å, a missing CA–C bond, a 3.3 Å peptide gap), so the
            // bond-graph backbone misses a residue or two and splits a chain there.
            try expect(p.residueCount >= file.residueCount - 3 && p.residueCount <= file.residueCount, "topology residues \(p.residueCount) vs \(file.residueCount)")
            try expect(p.chains.count >= 2 && p.chains.count <= 6, "chains \(p.chains)")
            // DSSP helices agree with the deposited HELIX records on most residues (match by CA atom).
            let fileHelixCA = Set(file.residues.indices.filter { file.ss[$0].kind == .helix }.map { file.residues[$0].ca })
            let dsspHelixCA = Set(p.residues.indices.filter { p.ss[$0].kind == .helix }.map { p.residues[$0].ca })
            let agree = Double(fileHelixCA.intersection(dsspHelixCA).count) / Double(fileHelixCA.count)
            let extra = Double(dsspHelixCA.subtracting(fileHelixCA).count) / Double(max(1, dsspHelixCA.count))
            try expect(agree > 0.8 && extra < 0.2, "DSSP vs HELIX records: recall \(agree), extra \(extra)")
            try expect(p.strandCount == 0, "hemoglobin has no strands, got \(p.strandCount)")
            print("    4HHB A+B DSSP (\(p.residueCount) residues, debug build): \(String(format: "%.1f", dt * 1000)) ms; helix recall \(String(format: "%.2f", agree))")
            // Forced modes.
            try expect(ProteinAnalysis.analyze(m, records: PDBProteinRecords.parse(ProteinFixture.text), mode: .computed).ssSource == .computed)
        },
        Check("analysis.protein.recordsSurviveEdits") {
            var m = try ProteinFixture.molecule()
            let rec = PDBProteinRecords.parse(ProteinFixture.text)
            // Delete a water and move one side-chain atom: the other residues still match by position.
            let water = ProteinAnalysis.analyze(m, records: rec).waterAtoms.firstIndex(of: true)!
            m.atoms.remove(at: water)
            m.bonds = m.bonds.filter { $0.a != water && $0.b != water }.map { Bond($0.a > water ? $0.a - 1 : $0.a, $0.b > water ? $0.b - 1 : $0.b, order: $0.order) }
            let p = ProteinAnalysis.analyze(m, records: rec)
            try expect(p.residueCount == 287 && p.ssSource == .file && p.atomCount == m.atoms.count)
        },
        Check("analysis.protein.smallMoleculeIsNotProtein") {
            // N-methylacetamide: one amide, no protein.
            var m = Molecule()
            let pos: [(Int, Vec3)] = [(6, Vec3(0, 0, 0)), (6, Vec3(1.5, 0, 0)), (8, Vec3(2.1, 1.0, 0)), (7, Vec3(2.2, -1.2, 0)), (6, Vec3(3.6, -1.3, 0))]
            for (i, p) in pos.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: p.0, position: p.1)) }
            m.bonds = [Bond(0, 1), Bond(1, 2, order: .double), Bond(1, 3), Bond(3, 4)]
            let p = ProteinAnalysis.analyze(m)
            try expect(p.isEmpty && p.polymerAtoms.count == 5 && !ProteinAnalysis.looksLikeProtein(m))
            // DSSP energy: a textbook N–H···O=C geometry is a strong H-bond, a far one is not.
            let e = ProteinAnalysis.hbondEnergy(n: Vec3(0, 0, 0), h: Vec3(1, 0, 0), c: Vec3(4.1, 0, 0), o: Vec3(2.9, 0, 0))
            try expect(e < -2, "E = \(e)")
            try expect(ProteinAnalysis.hbondEnergy(n: .zero, h: Vec3(1, 0, 0), c: Vec3(9, 0, 0), o: Vec3(8, 0, 0)) > -0.5)
        },

        // MARK: Structure export
        Check("io.export.structure.multiFrame") {
            let frames = try XYZFormat.parse(String(contentsOf: testDataURL("io/xyz_traj.xyz"), encoding: .utf8))
            try expect(frames.count >= 2)
            let energies = StructureExport.frameEnergies([-1, -2, -3, -4, -5].map(Double.init), frameCount: frames.count)
            try expect(energies.count == frames.count && energies.last! == -5)
            let xyz = try StructureExport.text(frames: frames, format: .xyz, energies: energies, title: "traj")
            let back = try XYZFormat.parse(xyz.text)
            try expect(back.count == frames.count && xyz.frameCount == frames.count, "xyz frames \(back.count)")
            try expect(back[0].title.contains("traj frame 1") && back[0].title.contains("E ="), back[0].title)
            let pdb = try StructureExport.text(frames: frames, format: .pdb)
            try expect(try PDBFormat.parse(pdb.text).models.count == frames.count, "pdb models")
            let sdf = try StructureExport.text(frames: frames, format: .sdf, energies: energies)
            let recs = try MDLMolFormat.parse(sdf.text)
            try expect(recs.count == frames.count && recs[1].properties.contains { $0.name == "FRAME" && $0.value == "2" }, "sdf records")
            try expect(recs[0].properties.contains { $0.name == "ENERGY_HARTREE" })
            // Single-structure formats get the last frame.
            let mol = try StructureExport.text(frames: frames, format: .mol)
            try expect(mol.frameCount == 1)
        },
        Check("io.export.structure.selection") {
            let m = try ProteinFixture.molecule()
            let p = ProteinAnalysis.analyze(m, records: PDBProteinRecords.parse(ProteinFixture.text))
            let heme = m.atoms.indices.filter { !p.polymerAtoms[$0] && !p.waterAtoms[$0] }
            let out = try StructureExport.text(frames: [m], format: .xyz, atoms: heme)
            let back = try XYZFormat.parse(out.text)
            try expect(back.count == 1 && back[0].atoms.count == heme.count && out.atomCount == heme.count)
            let sub = StructureExport.subset(m, atoms: heme)
            try expect(sub.bonds.allSatisfy { $0.a < heme.count && $0.b < heme.count } && !sub.bonds.isEmpty)
            do { _ = try StructureExport.text(frames: [m], format: .xyz, atoms: [m.atoms.count + 5]); throw CheckFailure(description: "bad index accepted") }
            catch is MolIOError {}
        },

        // MARK: CSV tables
        Check("analysis.tables.orcaTDDFT") {
            let r = try OrcaOutput.parse(String(contentsOf: testDataURL("io/orca/h2co_tddft.out"), encoding: .utf8)).result
            let avail = ResultTables.available(r)
            try expect(avail.contains(.orbitals) && avail.contains(.states) && avail.contains(.energies), "tables \(avail)")
            let orb = try ResultTables.csv(.orbitals, result: r)
            let lines = orb.split(separator: "\n")
            try expect(lines[0] == "spin,orbital,energy (Eh),energy (eV),occupation,label" && lines.count == r.orbitals.count + 1)
            try expect(orb.contains(",HOMO\n") && orb.contains(",LUMO\n"), "HOMO/LUMO labels")
            let st = try ResultTables.csv(.states, result: r)
            try expect(st.split(separator: "\n").count == r.excitedStates.count + 1)
            let en = try ResultTables.csv(.energies, result: r)
            try expect(en.hasPrefix("step,energy (Eh),relative (kcal/mol)\n1,"))
            if avail.contains(.charges) { try expect(try ResultTables.csv(.charges, result: r).hasPrefix("atom,element,")) }
        },
        Check("analysis.tables.frequenciesAndQuoting") {
            var r = CalculationResult()
            r.normalModes = [NormalMode(frequency: -120.5, irIntensity: 3, symmetry: "B\"2", displacements: []),
                             NormalMode(frequency: 1750, irIntensity: 80, ramanActivity: 12, displacements: [])]
            r.mullikenCharges = [-0.4, 0.2, 0.2]
            let f = try ResultTables.csv(.frequencies, result: r)
            let rows = f.split(separator: "\n")
            try expect(rows.count == 3 && rows[1].hasPrefix("1,-120.5000,3.0000,,\"B\"\"2\""), String(rows[1]))
            try expect(rows[2].hasPrefix("2,1750.0000,80.0000,12.0000,"))
            let c = try ResultTables.csv(.charges, result: r, molecule: RenderFixtures.water)
            try expect(c.split(separator: "\n")[1] == "1,O,-0.400000", c)
            do { _ = try ResultTables.csv(.states, result: r); throw CheckFailure(description: "empty table accepted") }
            catch is ResultTables.TableError {}
        },
    ]
}
