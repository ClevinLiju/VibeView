import Foundation
import MolCore

// Per-program input generators for CalcSetup: ORCA, Q-Chem and xtb. (Gaussian lives in CalcSetup.swift.)
//
// ORCA   : "! METHOD BASIS <job> [CPCM(solvent)] [extra]", %pal / %maxcore / job blocks, "* xyz charge mult" ... "*".
//          Scan atom indices are 0-based in the file.
// Q-Chem : "$molecule" / "$rem" (+ "$solvent" or "$smx", "$scan"); Opt+Freq is two jobs separated by "@@@".
// xtb    : the input file is an XYZ; the job is selected with command-line flags (see commandArguments).

public enum QCProgram: String, CaseIterable, Identifiable, Sendable, Codable {
    case gaussian, orca, qchem, xtb
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gaussian: "Gaussian"; case .orca: "ORCA"; case .qchem: "Q-Chem"; case .xtb: "xtb" }
    }
    public var inputExtension: String {
        switch self { case .gaussian: "gjf"; case .orca: "inp"; case .qchem: "in"; case .xtb: "xyz" }
    }
    public var outputExtension: String {
        switch self { case .gaussian: "log"; case .orca: "out"; case .qchem: "out"; case .xtb: "out" }
    }
}

public enum XTBMethod: String, CaseIterable, Identifiable, Sendable, Codable {
    case gfn2, gfn1, gfnff
    public var id: String { rawValue }
    public var title: String { switch self { case .gfn2: "GFN2-xTB"; case .gfn1: "GFN1-xTB"; case .gfnff: "GFN-FF" } }
}

extension CalcSetup {
    private var trimmedExtra: String { extraKeywords.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func moleculeTitle(_ molecule: Molecule) -> String {
        let t = displayTitle
        if !t.isEmpty { return t }
        let mt = molecule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return mt.isEmpty ? "MolScope calculation" : mt
    }

    private func symbol(_ a: Atom) -> String { BuildElements.symbol(a.atomicNumber) }

    private func coordLines(_ molecule: Molecule) -> [String] {
        molecule.atoms.map { a in
            let sym = symbol(a)
            let pad = String(repeating: " ", count: max(0, 2 - sym.count))
            return " \(sym)\(pad) " + Self.fixed(a.position.x, 8, 14) + " " + Self.fixed(a.position.y, 8, 14) + " " + Self.fixed(a.position.z, 8, 14)
        }
    }

    /// (start, end, points) for a relaxed scan coordinate, starting from the current geometry.
    private func scanRange(_ c: ScanCoordinate, molecule: Molecule) -> (start: Double, end: Double, points: Int) {
        let start = c.currentValue(in: molecule) ?? 0
        return (start, start + Double(c.steps) * c.stepSize, c.steps + 1)
    }

    // MARK: ORCA

    public func orcaInputText(molecule: Molecule) -> String {
        var simple: [String] = [method]
        if !basis.isEmpty && !Self.basisOptional(method) { simple.append(basis) }   // composites/semiempirical bring their own
        var blocks: [String] = []
        switch jobType {
        case .energy: simple.append("SP")
        case .optimize: simple.append("Opt")
        case .frequency: simple.append("Freq")
        case .optFreq: simple.append("Opt"); simple.append("Freq")
        case .scan:
            simple.append("Opt")
            var b = ["%geom", "  Scan"]
            for c in scanCoordinates {
                let r = scanRange(c, molecule: molecule)
                let idx = c.atoms.map { String($0 - 1) }.joined(separator: " ")
                b.append("    \(c.kind.letter) \(idx) = \(Self.fixed(r.start, 4)), \(Self.fixed(r.end, 4)), \(r.points)")
            }
            b += ["  end", "end"]
            blocks.append(b.joined(separator: "\n"))
        case .irc:
            simple.append("IRC")
            let dir = ircDirection == .both ? "both" : (ircDirection == .forward ? "forward" : "backward")
            var b = ["%irc", "  MaxIter \(ircMaxPoints)", "  Direction \(dir)"]
            if ircCalcFC { b.append("  InitHess calc_anfreq") }
            b.append("end")
            blocks.append(b.joined(separator: "\n"))
        case .transitionState:
            simple.append("OptTS")
            if tsCalcFC { blocks.append("%geom\n  Calc_Hess true\nend") }
        case .excitedStates:
            var b = ["%tddft", "  nroots \(tdStates)"]
            if tdSpin == .triplets { b.append("  triplets true") }
            b.append("end")
            blocks.append(b.joined(separator: "\n"))
        case .nmr: simple.append("NMR")
        }
        switch solvation {
        case .none: break
        case .pcm(let s): simple.append("CPCM(\(Self.solventKeyword(s, program: .orca)))")
        case .smd(let s):
            simple.append("CPCM")
            blocks.append("%cpcm\n  smd true\n  SMDsolvent \"\(Self.solventKeyword(s, program: .orca).lowercased())\"\nend")
        }
        if !trimmedExtra.isEmpty { simple.append(trimmedExtra) }

        var out = ["# " + moleculeTitle(molecule), "! " + simple.joined(separator: " ")]
        if nprocs > 1 { out.append("%pal nprocs \(nprocs) end") }
        if memoryMB > 0 { out.append("%maxcore \(max(1, memoryMB / max(1, nprocs)))") }
        out += blocks
        out.append("* xyz \(charge) \(multiplicity)")
        out += coordLines(molecule)
        out.append("*")
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Q-Chem

    private func qchemRem(job: String, molecule: Molecule, readGuess: Bool) -> [String] {
        var r: [String] = ["JOBTYPE \(job)", "METHOD \(method)"]
        if !basis.isEmpty { r.append("BASIS \(basis)") }
        if memoryMB > 0 { r.append("MEM_TOTAL \(memoryMB)") }
        if multiplicity > 1 { r.append("UNRESTRICTED TRUE") }
        if readGuess { r.append("SCF_GUESS READ") }
        switch solvation {
        case .none: break
        case .pcm: r.append("SOLVENT_METHOD pcm")
        case .smd: r.append("SOLVENT_METHOD smd")
        }
        return r
    }

    public func qchemInputText(molecule: Molecule) -> String {
        func moleculeBlock(read: Bool) -> [String] {
            read ? ["$molecule", "read", "$end"]
                 : ["$molecule", "\(charge) \(multiplicity)"] + coordLines(molecule) + ["$end"]
        }
        func solventBlock() -> [String] {
            switch solvation {
            case .none: return []
            case .pcm(let s): return ["", "$solvent", "SolventName \(Self.solventKeyword(s, program: .qchem))", "$end"]
            case .smd(let s): return ["", "$smx", "solvent \(Self.solventKeyword(s, program: .qchem))", "$end"]
            }
        }
        func extraLines() -> [String] { trimmedExtra.isEmpty ? [] : trimmedExtra.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        func job(_ type: String, read: Bool, rem extra: [String] = [], tail: [String] = []) -> [String] {
            var l = ["$comment", moleculeTitle(molecule), "$end", ""]
            l += moleculeBlock(read: read)
            l += ["", "$rem"] + qchemRem(job: type, molecule: molecule, readGuess: read) + extra + extraLines() + ["$end"]
            l += solventBlock()
            l += tail
            return l
        }
        var lines: [String]
        switch jobType {
        case .energy: lines = job("sp", read: false)
        case .optimize: lines = job("opt", read: false)
        case .frequency: lines = job("freq", read: false)
        case .optFreq: lines = job("opt", read: false) + ["", "@@@", ""] + job("freq", read: true)
        case .transitionState: lines = job("ts", read: false)
        case .nmr: lines = job("nmr", read: false)
        case .irc:
            var ex = ["RPATH_MAX_CYCLES \(ircMaxPoints)"]
            if ircDirection == .forward { ex.append("RPATH_DIRECTION 1") } else if ircDirection == .reverse { ex.append("RPATH_DIRECTION -1") }
            lines = job("rpath", read: false, rem: ex)
        case .excitedStates:
            var ex = ["CIS_N_ROOTS \(tdStates)", "RPA TRUE"]
            switch tdSpin {
            case .unspecified: break
            case .singlets: ex += ["CIS_SINGLETS TRUE", "CIS_TRIPLETS FALSE"]
            case .triplets: ex += ["CIS_SINGLETS FALSE", "CIS_TRIPLETS TRUE"]
            case .fiftyFifty: ex += ["CIS_SINGLETS TRUE", "CIS_TRIPLETS TRUE"]
            }
            lines = job("sp", read: false, rem: ex)
        case .scan:
            var t = ["", "$scan"]
            for c in scanCoordinates {
                let r = scanRange(c, molecule: molecule)
                let kw = c.kind == .bond ? "stre" : (c.kind == .angle ? "bend" : "tors")
                t.append("\(kw) " + c.atoms.map(String.init).joined(separator: " ")
                         + " \(Self.fixed(r.start, 4)) \(Self.fixed(r.end, 4)) \(Self.fixed(c.stepSize, 4))")
            }
            t.append("$end")
            lines = job("pes_scan", read: false, tail: t)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: xtb

    public func xtbInputText(molecule: Molecule) -> String {
        var out = ["\(molecule.atoms.count)", moleculeTitle(molecule).replacingOccurrences(of: "\n", with: " ")]
        for a in molecule.atoms {
            out.append(symbol(a).padding(toLength: 2, withPad: " ", startingAt: 0) + " " + Self.fixed(a.position.x, 8, 14) + " " + Self.fixed(a.position.y, 8, 14) + " " + Self.fixed(a.position.z, 8, 14))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Arguments for the xtb executable, e.g. ["job.xyz", "--ohess", "--chrg", "0", "--uhf", "0", "--gfn", "2", "--alpb", "water", "-P", "4"].
    public func commandArguments(inputFileName: String) -> [String] {
        var a = [inputFileName]
        switch jobType {
        case .optimize: a.append("--opt")
        case .frequency: a.append("--hess")
        case .optFreq: a.append("--ohess")
        default: break   // energy: plain single point
        }
        a += ["--chrg", "\(charge)", "--uhf", "\(max(0, multiplicity - 1))"]
        switch xtbMethod {
        case .gfn2: a += ["--gfn", "2"]
        case .gfn1: a += ["--gfn", "1"]
        case .gfnff: a.append("--gfnff")
        }
        if let s = solvation.solvent { a += ["--alpb", Self.solventKeyword(s, program: .xtb)] }
        if nprocs > 0 { a += ["-P", "\(nprocs)"] }
        a += trimmedExtra.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        return a
    }

    /// Human-readable command line for previews.
    public func commandLine(program exe: String, inputFileName: String) -> String {
        #if os(Windows)
        // Windows paths often contain spaces (C:\Program Files\...): quote those for a copy-pasteable preview.
        return ([exe] + commandArguments(inputFileName: inputFileName))
            .map { $0.contains(" ") && !$0.hasPrefix("\"") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        #else
        return ([exe] + commandArguments(inputFileName: inputFileName)).joined(separator: " ")
        #endif
    }
}
