import Foundation
import MolSIMD
import MolCore
import MolIO

// PDBx/mmCIF reader (MMCIFFormat): the 1CRN entry from RCSB as fixture, plus small inline cases for multi-character
// chains, alternate locations, several models, text fields and assembly operator expressions.

extension Checks {
    static let ioMMCIF: [Check] = [
        Check("io.mmcif.1crn") {
            let url = testDataURL("io/mmcif_1crn.cif")
            try expect(MoleculeFileFormat.detect(url: url) == .pdb, "cif is read by the PDB loader")
            let text = try String(contentsOf: url, encoding: .utf8)
            try expect(MoleculeFileFormat.detect(contents: text) == .pdb && MMCIFFormat.looksLikeMMCIF(text))
            let f = try MMCIFFormat.parse(text)
            try expect(f.entryID == "1CRN" && f.title.hasPrefix("WATER STRUCTURE OF A HYDROPHOBIC PROTEIN"), f.title)
            try expect(f.pdb.models.count == 1 && f.pdb.models[0].atoms.count == 327, "\(f.pdb.models.map(\.atoms.count))")
            let r = f.pdb.atomRecords[0]
            try expect(r[0].name == "N" && r[0].resName == "THR" && r[0].chainID == "A" && r[0].resSeq == 1 && !r[0].isHetero)
            try expect(Set(r.map(\.resSeq)).count == 46 && r.last?.resName == "ASN", "46 residues")
            try expectClose(f.pdb.models[0].atoms[0].position.x, 17.047, tol: 1e-6)
            try expect(f.pdb.cell.map { abs($0.a - 40.96) < 1e-6 && $0.spaceGroup == "P 1 21 1" } == true, "\(String(describing: f.pdb.cell))")
            let helices = f.secondary.filter { $0.kind == "H" }, strands = f.secondary.filter { $0.kind == "E" }
            try expect(helices.count == 2 && helices[0].startSeq == 7 && helices[0].endSeq == 19 && helices[1].startSeq == 23, "\(helices)")
            try expect(strands.count == 2 && strands.allSatisfy { $0.chain == "A" }, "\(strands)")
            try expect(f.pdb.assemblies.count == 1 && f.pdb.assemblies[0].chains == ["A"]
                       && f.pdb.assemblies[0].parts[0].operators.count == 1 && PDBAssembly.isIdentity(f.pdb.assemblies[0].parts[0].operators[0]))
            // Through the file loader: same atoms, residue bond orders (backbone C=O double bonds after perception).
            let loaded = try MolecularFileLoader.load(url: url)
            try expect(loaded.format == .pdb && loaded.molecules[0].atoms.count == 327)
            let m = loaded.molecules[0]
            let doubles = m.bonds.filter { $0.order == .double }.count
            try expect(doubles >= 46, "C=O / side-chain double bonds: \(doubles)")
        },
        Check("io.mmcif.features") {
            let cif = """
            data_TEST
            _struct.title
            ;Multi-line
             title
            ;
            loop_
            _atom_site.group_PDB
            _atom_site.id
            _atom_site.type_symbol
            _atom_site.label_atom_id
            _atom_site.label_alt_id
            _atom_site.label_comp_id
            _atom_site.label_asym_id
            _atom_site.label_seq_id
            _atom_site.Cartn_x
            _atom_site.Cartn_y
            _atom_site.Cartn_z
            _atom_site.occupancy
            _atom_site.auth_seq_id
            _atom_site.auth_asym_id
            _atom_site.pdbx_PDB_model_num
            ATOM   1 N  N   . GLY A 1 0.0 0.0 0.0 1.00 10 AA 1
            ATOM   2 C  CA  . GLY A 1 1.4 0.0 0.0 1.00 10 AA 1
            ATOM   3 O  OG  A SER A 2 2.0 1.0 0.0 0.60 11 AA 1
            ATOM   4 O  OG  B SER A 2 2.0 -1.0 0.0 0.40 11 AA 1
            HETATM 5 FE FE  . HEM B . 5.0 5.0 5.0 1.00 101 BB 1
            ATOM   6 N  N   . GLY A 1 0.1 0.0 0.0 1.00 10 AA 2
            ATOM   7 C  "C'" . GLY A 1 1.5 0.0 0.0 1.00 10 AA 2
            #
            loop_
            _pdbx_struct_oper_list.id
            _pdbx_struct_oper_list.matrix[1][1]
            _pdbx_struct_oper_list.matrix[1][2]
            _pdbx_struct_oper_list.matrix[1][3]
            _pdbx_struct_oper_list.vector[1]
            _pdbx_struct_oper_list.matrix[2][1]
            _pdbx_struct_oper_list.matrix[2][2]
            _pdbx_struct_oper_list.matrix[2][3]
            _pdbx_struct_oper_list.vector[2]
            _pdbx_struct_oper_list.matrix[3][1]
            _pdbx_struct_oper_list.matrix[3][2]
            _pdbx_struct_oper_list.matrix[3][3]
            _pdbx_struct_oper_list.vector[3]
            1 1 0 0 0 0 1 0 0 0 0 1 0
            2 1 0 0 10 0 1 0 0 0 0 1 0
            3 1 0 0 0 0 1 0 5 0 0 1 0
            #
            _pdbx_struct_assembly_gen.assembly_id 1
            _pdbx_struct_assembly_gen.oper_expression '(1-2)(3)'
            _pdbx_struct_assembly_gen.asym_id_list A,B
            """
            let f = try MMCIFFormat.parse(cif)
            try expect(f.title == "Multi-line\n title", "title '\(f.title)'")
            try expect(f.pdb.models.count == 2 && f.pdb.models[0].atoms.count == 4 && f.pdb.droppedAltLocAtoms == 1, "\(f.pdb.models.map(\.atoms.count))")
            let r = f.pdb.atomRecords[0]
            try expect(r.map(\.chainID) == ["AA", "AA", "AA", "BB"] && r[2].altLoc == "A" && r[3].isHetero && r[3].resSeq == 101, "\(r.map(\.chainID))")
            try expect(f.pdb.models[0].atoms[3].atomicNumber == 26)
            try expect(f.pdb.atomRecords[1][1].name == "C'", "quoted atom name")
            let a = f.pdb.assemblies
            try expect(a.count == 1 && a[0].chains == ["AA", "BB"] && a[0].parts[0].operators.count == 2, "\(a)")
            try expectClose(a[0].parts[0].operators[1][3], 10)   // (2) after (3): x + 10
            try expectClose(a[0].parts[0].operators[1][7], 5)    // y + 5
            try expect(MMCIFFormat.operatorFactors("1,2,5") == [["1", "2", "5"]] && MMCIFFormat.operatorFactors("(X0)(1-3)") == [["X0"], ["1", "2", "3"]])
            // Small-molecule CIF (fractional coordinates) is refused with a clear message.
            let small = "data_x\n_cell.length_a 5\nloop_\n_atom_site_label\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nC1 0.1 0.2 0.3\n"
            do { _ = try MMCIFFormat.parse(small); throw CheckFailure(description: "small-molecule CIF accepted") }
            catch let e as MolIOError { try expect("\(e)".contains("fractional"), "\(e)") }
        },
    ]
}
