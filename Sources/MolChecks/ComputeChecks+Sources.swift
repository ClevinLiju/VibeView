import Foundation
import MolCore
import MolIO
import MolCompute

// Lookup sources beyond PubChem (StructureSources.swift, StructureLookup.swift): source guessing, fixture parsing
// for RCSB PDB / ChEMBL / mmCIF, the DrugBank relabelling, and live checks that skip when offline.

private let aspirinMolfile = """
aspirin
     RDKit          2D

 13 13  0  0  0  0  0  0  0  0999 V2000
    2.5981   -0.7500    0.0000 C   0  0
    1.2990   -0.0000    0.0000 C   0  0
    1.2990    1.5000    0.0000 O   0  0
    0.0000   -0.7500    0.0000 O   0  0
   -1.2990   -0.0000    0.0000 C   0  0
   -1.2990    1.5000    0.0000 C   0  0
   -2.5981    2.2500    0.0000 C   0  0
   -3.8971    1.5000    0.0000 C   0  0
   -3.8971   -0.0000    0.0000 C   0  0
   -2.5981   -0.7500    0.0000 C   0  0
   -2.5981   -2.2500    0.0000 C   0  0
   -3.8971   -3.0000    0.0000 O   0  0
   -1.2990   -3.0000    0.0000 O   0  0
  1  2  1  0
  2  3  2  0
  2  4  1  0
  4  5  1  0
  5  6  2  0
  6  7  1  0
  7  8  2  0
  8  9  1  0
  9 10  2  0
 10  5  1  0
 10 11  1  0
 11 12  1  0
 11 13  2  0
M  END
"""

extension Checks {
    static let computeSources: [Check] = [
        Check("compute.sources.guess") {
            func g(_ s: String) -> LookupSource { LookupSourceGuess.guess(s).source }
            try expect(g("1CRN") == .pdb && g("4hhb") == .pdb && g("pdb:1crn") == .pdb && g("pdb_00001crn") == .pdb)
            try expect(LookupSourceGuess.guess("4hhb").query == "4HHB")
            try expect(g("2244") == .pubchem && g("1234") == .pubchem, "all-digit IDs are CIDs")
            try expect(g("CHEMBL25") == .chembl && g("chembl 25") == .chembl)
            try expect(g("DB00945") == .drugbank && g("db00945") == .drugbank && g("DB0094") == .pubchem)
            try expect(g("50-78-2") == .pubchem && g("CC(=O)Oc1ccccc1C(=O)O") == .pubchem && g("aspirin") == .pubchem)
            try expect(g("hemoglobin") == .pubchem, "names: PubChem, plus PDB text search")
            try expect(LookupSourceGuess.pdbID("ABCD") == nil && LookupSourceGuess.pdbID("12345") == nil)
            let c = StructureLookup.bareCandidate("pdb:1crn")
            try expect(c?.identifier == "1CRN" && c?.isMacromolecule == true && c?.id == "pdb:1CRN")
            try expect(StructureLookup.bareCandidate("pubchem:2244")?.cid == 2244)
            try expect(StructureLookup.bareCandidate("pubchem:abc") == nil && StructureLookup.bareCandidate("nope:1") == nil)
        },
        Check("compute.sources.rcsb.parse") {
            let search = Data(#"{"query_id":"x","result_type":"entry","total_count":2,"result_set":[{"identifier":"4HHB","score":1.0},{"identifier":"2HHB","score":0.9}]}"#.utf8)
            try expect(RCSBClient.parseSearch(search) == ["4HHB", "2HHB"])
            try expect(RCSBClient.parseSearch(Data("{}".utf8)).isEmpty)
            let gql = Data("""
            {"data":{"entries":[{"rcsb_id":"1CRN","struct":{"title":"WATER STRUCTURE OF A HYDROPHOBIC PROTEIN AT ATOMIC RESOLUTION"},
            "exptl":[{"method":"X-RAY DIFFRACTION"}],"rcsb_entry_info":{"resolution_combined":[1.5],"deposited_atom_count":327},
            "polymer_entities":[{"rcsb_entity_source_organism":[{"ncbi_scientific_name":"Crambe hispanica subsp. abyssinica"}]}],
            "rcsb_accession_info":{"initial_release_date":"1981-04-30T00:00:00Z"}}]}}
            """.utf8)
            let e = RCSBClient.parseEntries(gql)
            try expect(e.count == 1 && e[0].id == "1CRN" && e[0].atomCount == 327 && e[0].releaseDate == "1981-04-30", "\(e)")
            try expectClose(e[0].resolution ?? 0, 1.5)
            let c = RCSBClient.candidate(e[0], matched: "1CRN", kind: .exact)
            try expect(c.id == "pdb:1CRN" && c.isMacromolecule && c.thumbnailMIME == "image/jpeg")
            try expect(c.title == "Water structure of a hydrophobic protein at atomic resolution", c.title)
            try expect(c.details.count == 2 && c.details[0].contains("1.50 Å") && c.details[1].hasPrefix("Crambe"), "\(c.details)")
            try expect(c.webURL?.absoluteString == "https://www.rcsb.org/structure/1CRN")
            let body = RCSBClient.searchBody("hemoglobin", rows: 5)
            try expect(JSONSerialization.isValidJSONObject(body) && JSONSerialization.isValidJSONObject(RCSBClient.graphqlBody(["1CRN"])))
        },
        Check("compute.sources.mmcif") {
            let cif = """
            data_1ABC
            _struct.title 'TEST PROTEIN'
            #
            loop_
            _atom_site.group_PDB
            _atom_site.id
            _atom_site.type_symbol
            _atom_site.label_atom_id
            _atom_site.label_alt_id
            _atom_site.label_comp_id
            _atom_site.label_asym_id
            _atom_site.label_seq_id
            _atom_site.pdbx_PDB_ins_code
            _atom_site.Cartn_x
            _atom_site.Cartn_y
            _atom_site.Cartn_z
            _atom_site.occupancy
            _atom_site.B_iso_or_equiv
            _atom_site.auth_seq_id
            _atom_site.auth_comp_id
            _atom_site.auth_asym_id
            _atom_site.auth_atom_id
            _atom_site.pdbx_PDB_model_num
            ATOM   1 N N   . GLY A 1 ? 1.000 2.000 3.000 1.00 10.00 1 GLY A N   1
            ATOM   2 C CA  . GLY A 1 ? 2.400 2.000 3.000 1.00 10.00 1 GLY A CA  1
            ATOM   3 C C   . GLY A 1 ? 3.000 3.300 3.000 1.00 10.00 1 GLY A C   1
            ATOM   4 O O   . GLY A 1 ? 2.400 4.300 3.000 1.00 10.00 1 GLY A O   1
            HETATM 5 O O   . HOH B . ? 8.000 8.000 8.000 1.00 20.00 101 HOH A O 1
            ATOM   6 N N   . GLY A 1 ? 1.100 2.000 3.000 1.00 10.00 1 GLY A N   2
            #
            """
            // Downloaded mmCIF (entries too large for the PDB format) is read like a PDB file: first model.
            let m = try StructureLookup.loadPDB(cif, fileName: "1ABC.cif")
            try expect(m.atoms.count == 5 && m.title == "TEST PROTEIN", "atoms \(m.atoms.count) title \(m.title)")
            try expectClose(m.atoms[1].position.x, 2.4)
            try expect((try? StructureLookup.loadPDB("data_x\n_cell.length_a 1\n", fileName: "x.cif")) == nil)
        },
        Check("compute.sources.chembl.parse") {
            let mol = Data("""
            {"molecule_chembl_id":"CHEMBL25","pref_name":"ASPIRIN","max_phase":"4.0","molecule_type":"Small molecule",
             "molecule_properties":{"full_molformula":"C9H8O4","full_mwt":"180.16"},
             "molecule_structures":{"canonical_smiles":"CC(=O)Oc1ccccc1C(=O)O","molfile":"x","standard_inchi_key":"BSYNRYMUTXBXSQ-UHFFFAOYSA-N"},
             "molecule_synonyms":[{"molecule_synonym":"Aspirin"},{"molecule_synonym":"ASPIRIN"},{"molecule_synonym":"Acetylsalicylic acid"}]}
            """.utf8)
            guard let m = ChEMBLClient.parseMolecule(mol) else { throw CheckFailure(description: "no molecule") }
            try expect(m.id == "CHEMBL25" && m.formula == "C9H8O4" && m.maxPhase == "4.0" && m.synonyms == ["Aspirin", "Acetylsalicylic acid"], "\(m)")
            try expectClose(m.molecularWeight ?? 0, 180.16)
            let c = ChEMBLClient.candidate(m, matched: "CHEMBL25", kind: .exact)
            try expect(c.title == "Aspirin" && c.id == "chembl:CHEMBL25" && c.chemblID == "CHEMBL25" && !c.isMacromolecule)
            try expect(c.details.first?.contains("approved drug") == true, "\(c.details)")
            let search = Data(#"{"molecules":[{"molecule_chembl_id":"CHEMBL1","pref_name":null},{"pref_name":"no id"}],"page_meta":{}}"#.utf8)
            let s = ChEMBLClient.parseSearch(search)
            try expect(s.count == 1 && s[0].id == "CHEMBL1" && s[0].name == nil)
            try expect(ChEMBLClient.candidate(s[0], matched: "x", kind: .ambiguous).title == "CHEMBL1")
            // A biologic: no molfile, so it can't be opened as a small molecule.
            var bio = m; bio.molfile = nil; bio.type = "Protein"
            try expect(ChEMBLClient.candidate(bio, matched: "x", kind: .exact).isMacromolecule)
            // ChEMBL molfiles are 2D without hydrogens: hydrogens added, coordinates embedded in 3D.
            let a = try StructureLookup.moleculeFromMolfile(aspirinMolfile)
            try expect(a.atoms.count == 21 && a.atoms.filter { $0.atomicNumber == 1 }.count == 8, "atoms \(a.atoms.count)")
            let zs = a.atoms.map(\.position.z)
            try expect((zs.max()! - zs.min()!) > 0.05, "still flat")
        },
        Check("compute.sources.drugbank") {
            var p = LookupCandidate(cid: 2244, title: "Aspirin", depictionURL: URL(string: "https://example.org")!, matchKind: .exact, matchedQuery: "aspirin")
            try expect(StructureLookup.drugBankCandidate(p) == nil, "no DrugBank ID")
            p.drugBankID = "DB00945"
            guard let d = StructureLookup.drugBankCandidate(p) else { throw CheckFailure(description: "nil") }
            try expect(d.id == "drugbank:DB00945" && d.cid == 2244 && d.source == .drugbank, d.id)
            try expect(d.sourceNote?.contains("through PubChem") == true && d.webURL?.absoluteString == "https://go.drugbank.com/drugs/DB00945")
            try expect(StructureLookup.sciFinderNote.contains("CAS subscription") || StructureLookup.sciFinderNote.contains("institutional"))
        },
        Check("compute.sources.live") {
            let probe: Bool = try computeRunAsync(timeout: 30) {
                do { _ = try await LookupHTTP(timeout: 10).get(URL(string: "https://search.rcsb.org/")!); return true }
                catch let e as ComputeError where e == .offline || e == .timeout { return false }
                catch { return true }   // reachable (an HTTP error status is fine)
            }
            if !probe { print("    SKIP (offline)"); return }
            let s = StructureLookup()
            func timed(_ q: String, _ src: LookupSource) throws -> StructureLookupResult {
                let t0 = Date()
                let r = try computeRunAsync(timeout: 90) { await s.suggest(q, source: src, limit: 6) }
                print("    \(q) [\(src.rawValue)]: \(String(format: "%.2f", Date().timeIntervalSince(t0))) s -> " +
                      r.candidates.prefix(4).map { "\($0.id) \($0.title.prefix(40))" }.joined(separator: "; ") + (r.error.map { " error \($0)" } ?? ""))
                return r
            }
            let crn = try timed("1CRN", .auto)
            guard let c = crn.candidates.first else { throw CheckFailure(description: "1CRN: nothing") }
            try expect(c.id == "pdb:1CRN" && c.isMacromolecule && c.details.joined().contains("Crambe"), "\(c.details)")
            try expect(c.thumbnail.map { $0.first == 0xFF } == true, "no JPEG thumbnail")
            let hb = try timed("hemoglobin", .pdb)
            try expect(hb.candidates.count >= 3 && hb.candidates.allSatisfy { $0.source == .pdb }, "hemoglobin PDB hits")
            let hbAuto = try timed("hemoglobin", .auto)
            try expect(hbAuto.candidates.contains { $0.source == .pdb }, "auto: PDB hits for a protein name")
            let ch = try timed("CHEMBL25", .auto)
            if case .httpStatus(let c)? = ch.error, c >= 500 { print("    SKIP ChEMBL (server error \(c))") }
            else if ch.error == .timeout { print("    SKIP ChEMBL (timeout)") }
            else { try expect(ch.candidates.first?.id == "chembl:CHEMBL25" && ch.candidates.first?.formula == "C9H8O4", "\(ch.candidates.first?.formula ?? "nil")") }
            let db = try timed("DB00945", .auto)
            try expect(db.candidates.first?.id == "drugbank:DB00945" && db.candidates.first?.cid == 2244, "\(db.candidates.map(\.id))")
            let asp = try timed("aspirin", .auto)
            try expect(asp.candidates.first?.cid == 2244, "\(asp.candidates.map(\.id))")
            let aspDB = try timed("aspirin", .drugbank)
            try expect(aspDB.candidates.first?.id == "drugbank:DB00945", "\(aspDB.candidates.map(\.id))")
            // Structures.
            if ch.error == nil {
                let m1 = try computeRunAsync(timeout: 120) { try await s.structure(id: "chembl:CHEMBL25") }
                try expect(m1.atoms.count == 21, "CHEMBL25 atoms \(m1.atoms.count)")
            }
            let m2 = try computeRunAsync(timeout: 120) { try await s.structure(id: "drugbank:DB00945") }
            try expect(m2.atoms.count == 21, "DB00945 atoms \(m2.atoms.count)")
            let m3 = try computeRunAsync(timeout: 120) { try await s.structure(id: "pdb:1CRN") }
            try expect(m3.atoms.count == 327, "1CRN atoms \(m3.atoms.count)")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vv-pdb-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: dir) }
            let f = try computeRunAsync(timeout: 120) { try await s.downloadPDB(id: "pdb:1CRN", directory: dir) }
            try expect(f.url.lastPathComponent == "1CRN.pdb" && f.format == "pdb")
            // CACTUS is optional (often slow or down): report, don't fail.
            let ca = try computeRunAsync(timeout: 90) { await s.suggest("aspirin", source: .cactus) }
            print("    cactus aspirin: \(ca.candidates.first?.canonicalSMILES ?? "unavailable: \(String(describing: ca.error))")")
        },
    ]
}
