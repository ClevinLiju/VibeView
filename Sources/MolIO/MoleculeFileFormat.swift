import Foundation
import MolCore

/// Registry of supported molecule file formats with extension- and content-based detection.
public enum MoleculeFileFormat: String, CaseIterable, Sendable, Codable {
    case gaussianInput, gaussianOutput, formattedCheckpoint, cube, xyz, pdb, mol, sdf, cml
    // round 2 (Lead A): other programs. Their outputs usually end in .out/.log, so they are found by content.
    case orcaInput, orcaOutput, orcaHessian, qchemInput, qchemOutput, xtbOutput, molden

    public var fileExtensions: [String] {
        switch self {
        case .gaussianInput: return ["gjf", "com", "gau"]
        case .gaussianOutput: return ["log", "out"]
        case .formattedCheckpoint: return ["fchk", "fch"]
        case .cube: return ["cube", "cub"]
        case .xyz: return ["xyz"]
        case .pdb: return ["pdb", "ent", "cif", "mmcif"]   // .cif/.mmcif: PDBx/mmCIF (MMCIFFormat)
        case .mol: return ["mol"]
        case .sdf: return ["sdf", "sd"]
        case .cml: return ["cml"]
        case .orcaInput: return ["inp"]
        case .orcaOutput: return ["orcaout"]
        case .orcaHessian: return ["hess"]
        case .qchemInput: return ["qcin", "in"]
        case .qchemOutput: return ["qcout"]
        case .xtbOutput: return ["xtbout"]
        case .molden: return ["molden", "mold"]
        }
    }

    public var displayName: String {
        switch self {
        case .gaussianInput: return "Gaussian Input"
        case .gaussianOutput: return "Gaussian Output"
        case .formattedCheckpoint: return "Formatted Checkpoint"
        case .cube: return "Gaussian Cube"
        case .xyz: return "XYZ"
        case .pdb: return "Protein Data Bank (PDB)"
        case .mol: return "MDL Molfile"
        case .sdf: return "MDL SD File"
        case .cml: return "Chemical Markup Language (CML)"
        case .orcaInput: return "ORCA Input"
        case .orcaOutput: return "ORCA Output"
        case .orcaHessian: return "ORCA Hessian"
        case .qchemInput: return "Q-Chem Input"
        case .qchemOutput: return "Q-Chem Output"
        case .xtbOutput: return "xtb Output"
        case .molden: return "Molden"
        }
    }

    public var canRead: Bool { true }
    public var canWrite: Bool {
        switch self {
        case .gaussianOutput, .orcaOutput, .orcaHessian, .qchemOutput, .xtbOutput, .formattedCheckpoint: return false
        default: return true
        }
    }

    /// Output of a quantum-chemistry program (results, possibly several geometries).
    public var isCalculationOutput: Bool { [.gaussianOutput, .orcaOutput, .qchemOutput, .xtbOutput, .formattedCheckpoint, .orcaHessian, .molden].contains(self) }

    /// Extensions whose content is not decisive on its own; the content is sniffed first.
    private static let ambiguousExtensions: Set<String> = ["out", "log", "txt", "dat", "input", "inp", "in", ""]

    public static func format(forExtension ext: String) -> MoleculeFileFormat? {
        let e = ext.lowercased()
        return allCases.first { $0.fileExtensions.contains(e) }
    }

    /// Extension first; if unknown or ambiguous (.out, .txt, none) the first ~4 KB are sniffed.
    public static func detect(url: URL) -> MoleculeFileFormat? {
        let ext = url.pathExtension.lowercased()
        if !ambiguousExtensions.contains(ext), let f = format(forExtension: ext) { return f }
        var head = ""
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 4096) {
                let b = [UInt8](d.prefix(2))
                if b.count == 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF),
                   let s = String(data: d.prefix(d.count & ~1), encoding: .utf16) {
                    head = s   // UTF-16 with BOM (Windows Notepad "Unicode")
                } else {
                    head = String(decoding: d, as: UTF8.self)
                    // a UTF-8 sequence cut at the 4 KB boundary decodes to a replacement char: harmless
                }
                if head.hasPrefix("\u{FEFF}") { head.removeFirst() }   // UTF-8 / UTF-16 byte-order mark
            }
        }
        if let f = detect(contents: head) { return f }
        return format(forExtension: ext)
    }

    public static func detect(contents: String, fileName: String? = nil) -> MoleculeFileFormat? {
        if let f = sniff(contents) { return f }
        if let n = fileName {
            return format(forExtension: (n as NSString).pathExtension)
        }
        return nil
    }

    private static func isInt(_ s: Substring) -> Bool { Int(s) != nil }
    private static func isFloat(_ s: Substring) -> Bool { parseFortranDouble(s) != nil }

    private static func sniff(_ contents: String) -> MoleculeFileFormat? {
        let head = String((contents.hasPrefix("\u{FEFF}") ? contents.dropFirst() : Substring(contents)).prefix(4096))
        let lines = splitLines(head)
        if head.contains("Entering Gaussian System") || head.contains("Gaussian, Inc.") { return .gaussianOutput }
        if head.contains("* O   R   C   A *") || head.contains("O   R   C   A") { return .orcaOutput }
        if head.contains("Welcome to Q-Chem") || head.contains("Q-Chem, Inc.") { return .qchemOutput }
        if head.contains("x T B") || head.contains("* xtb version") { return .xtbOutput }
        if head.range(of: "[Molden Format]", options: .caseInsensitive) != nil { return .molden }
        if head.contains("$orca_hessian_file") { return .orcaHessian }
        // fchk: title, "type method basis", then "Number of atoms   I   n"
        for k in 2..<max(2, min(5, lines.count)) where lines[k].hasPrefix("Number of atoms") {
            let t = tokens(lines[k])
            if t.count >= 5, t[3] == "I" { return .formattedCheckpoint }
        }
        guard let firstIdx = lines.firstIndex(where: { !$0.allSatisfy({ $0 == " " || $0 == "\t" }) }) else { return nil }
        let first = lines[firstIdx].drop { $0 == " " || $0 == "\t" }
        if first.lowercased().hasPrefix("data_") { return .pdb }   // PDBx/mmCIF, read by MMCIFFormat
        if first.hasPrefix("<?xml") || first.hasPrefix("<cml") || first.hasPrefix("<molecule") {
            if head.contains("<molecule") || head.contains("cml") { return .cml }
        }
        // ORCA input: "!" keyword lines, or a "%block ... end" followed by "* xyz"; Q-Chem: $molecule / $rem
        let lower = head.lowercased()
        if lower.contains("$molecule") && lower.contains("$rem") { return .qchemInput }
        if first.hasPrefix("!") { return .orcaInput }
        if first.hasPrefix("%"), lower.contains("* xyz") || lower.contains("*xyz") || lower.contains("* int") || lower.contains("* gzmt") { return .orcaInput }
        if first.hasPrefix("#") {
            // ORCA uses '#' for comments, so a leading '#' line is a Gaussian route only when nothing marks the
            // file as ORCA: an ORCA .engrad ("#" / "# Number of atoms" ...) is no molecule format, and an ORCA input
            // has a "!" keyword line or a "* xyz" style coordinate block once the '#' comment lines are skipped.
            let trimmed = lines[firstIdx...].map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmed.prefix(4).contains(where: { $0.hasPrefix("#") && $0.contains("Number of atoms") }) { return nil }
            let body = trimmed.filter { !$0.hasPrefix("#") }
            if let b = body.first(where: { !$0.isEmpty }), b.hasPrefix("!") { return .orcaInput }
            let coordStarts = ["* xyz", "*xyz", "* int", "*int", "* gzmt", "*gzmt"]
            if body.contains(where: { l in let x = l.lowercased(); return coordStarts.contains { x.hasPrefix($0) } }) { return .orcaInput }
            return .gaussianInput
        }
        if first.hasPrefix("%") || first.hasPrefix("--Link1--") { return .gaussianInput }
        if lines.count >= 4 {
            if lines[3].contains("V2000") || lines[3].contains("V3000") {
                return head.contains("$$$$") ? .sdf : .mol
            }
        }
        if lines.contains(where: { $0.hasPrefix("$$$$") }) { return .sdf }
        for l in lines {
            if l.hasPrefix("ATOM  ") || l.hasPrefix("HETATM") || l.hasPrefix("HEADER") || l.hasPrefix("CRYST1")
                || l.hasPrefix("MODEL ") { return .pdb }
        }
        // cube: line 3 = int + 3 floats (+ optional int), lines 4-6 = int + 3 floats
        if lines.count >= 6 {
            let t3 = tokens(lines[2])
            var ok = (t3.count == 4 || t3.count == 5) && isInt(t3[0]) && t3[1...3].allSatisfy(isFloat)
            if ok, t3.count == 5, !isInt(t3[4]) { ok = false }
            if ok {
                for k in 3..<6 {
                    let t = tokens(lines[k])
                    if !(t.count == 4 && isInt(t[0]) && t[1...3].allSatisfy(isFloat)) { ok = false; break }
                }
            }
            if ok { return .cube }
        }
        // xyz: line 1 a single integer, atom lines "Sym x y z"
        if lines.count >= 3 {
            let t1 = tokens(lines[0])
            if t1.count == 1, isInt(t1[0]) {
                let t3 = tokens(lines[2])
                if t3.count >= 4, t3[1...3].allSatisfy(isFloat) { return .xyz }
                if Int(t1[0]) == 0 { return .xyz }
            }
        }
        return nil
    }
}
