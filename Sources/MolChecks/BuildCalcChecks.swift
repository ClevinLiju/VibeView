import Foundation
import MolCore
import MolBuild

// Checks for CalcSetup (route + input generation + validation). Expected strings are hand-written.

private let wO  = " O      0.00000000     0.00000000     0.11779000"
private let wH1 = " H      0.00000000     0.75545300    -0.47116100"
private let wH2 = " H      0.00000000    -0.75545300    -0.47116100"

private func water(charge: Int = 0, mult: Int = 1) -> Molecule {
    Molecule(atoms: [
        Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.11779)),
        Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.755453, -0.471161)),
        Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.755453, -0.471161)),
    ], charge: charge, multiplicity: mult, title: "")
}

private func baseSpec(_ job: JobType) -> CalcSetup {
    var s = CalcSetup()
    s.jobType = job
    s.method = "B3LYP"; s.basis = "6-31G(d)"
    s.nprocs = 4; s.memoryMB = 4096; s.checkpoint = "water"
    s.title = "Water"
    return s
}

/// Expected file: Link0 (default set) + route + title block + atoms + trailer.
private func expected(_ route: String, trailer: [String] = [], link0: [String] = ["%nprocshared=4", "%mem=4GB", "%chk=water.chk"],
                      cm: String = "0 1") -> String {
    var l = link0
    l += [route, "", "Water", "", cm, wO, wH1, wH2, ""]
    if !trailer.isEmpty { l += trailer; l.append("") }
    return l.joined(separator: "\n") + "\n"
}

private func oh(charge: Int, mult: Int) -> Molecule {
    Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: .zero), Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0, 0.97))],
             charge: charge, multiplicity: mult)
}

extension Checks {
    static let buildCalc: [Check] = buildCalcGaussian + buildCalcPrograms

    static let buildCalcGaussian: [Check] = [
        Check("build.calc.input.energy") {
            let got = baseSpec(.energy).inputText(molecule: water())
            let want = "%nprocshared=4\n%mem=4GB\n%chk=water.chk\n#p B3LYP/6-31G(d) SP\n\nWater\n\n0 1\n" + wO + "\n" + wH1 + "\n" + wH2 + "\n\n"
            try expect(got == want, "got:\n\(got)")
        },
        Check("build.calc.input.opt") {
            let got = baseSpec(.optimize).inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt"), "got:\n\(got)")
        },
        Check("build.calc.input.freq") {
            let got = baseSpec(.frequency).inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Freq"), "got:\n\(got)")
        },
        Check("build.calc.input.optfreq") {
            let got = baseSpec(.optFreq).inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt Freq"), "got:\n\(got)")
        },
        Check("build.calc.input.scan") {
            var s = baseSpec(.scan)
            s.scanCoordinates = [
                MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 10, stepSize: 0.1),
                MolBuild.ScanCoordinate(kind: .angle, atoms: [2, 1, 3], steps: 10, stepSize: 5),
            ]
            let got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt=ModRedundant", trailer: ["B 1 2 S 10 0.100000", "A 2 1 3 S 10 5.000000"]), "got:\n\(got)")
            s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .dihedral, atoms: [1, 2, 3, 1], steps: 36, stepSize: 10)]
            try expect(s.trailerLines() == ["D 1 2 3 1 S 36 10.000000"], "\(s.trailerLines())")
        },
        Check("build.calc.input.irc") {
            var s = baseSpec(.irc)
            var got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) IRC=(CalcFC,MaxPoints=20)"), "got:\n\(got)")
            s.ircDirection = .forward; s.ircMaxPoints = 30
            got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) IRC=(CalcFC,MaxPoints=30,Forward)"), "got:\n\(got)")
            s.ircDirection = .reverse; s.ircCalcFC = false
            try expect(s.routeLine() == "#p B3LYP/6-31G(d) IRC=(MaxPoints=30,Reverse)", s.routeLine())
        },
        Check("build.calc.input.ts") {
            var s = baseSpec(.transitionState)
            let got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt=(TS,CalcFC,NoEigenTest)"), "got:\n\(got)")
            s.tsCalcFC = false
            try expect(s.routeLine() == "#p B3LYP/6-31G(d) Opt=(TS,NoEigenTest)", s.routeLine())
            s.tsNoEigenTest = false
            try expect(s.routeLine() == "#p B3LYP/6-31G(d) Opt=TS", s.routeLine())
        },
        Check("build.calc.input.td") {
            var s = baseSpec(.excitedStates)
            var got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) TD=(NStates=10)"), "got:\n\(got)")
            s.tdSpin = .triplets; s.tdStates = 6
            try expect(s.routeLine() == "#p B3LYP/6-31G(d) TD=(NStates=6,Triplets)", s.routeLine())
            s.tdSpin = .singlets
            try expect(s.routeLine() == "#p B3LYP/6-31G(d) TD=(NStates=6,Singlets)", s.routeLine())
            s.tdSpin = .fiftyFifty
            got = s.routeLine()
            try expect(got == "#p B3LYP/6-31G(d) TD=(NStates=6,50-50)", got)
        },
        Check("build.calc.input.nmr") {
            let got = baseSpec(.nmr).inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) NMR=GIAO"), "got:\n\(got)")
        },
        Check("build.calc.input.pcm") {
            var s = baseSpec(.optFreq)
            s.solvation = .pcm("Water")
            let got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt Freq SCRF=(PCM,Solvent=Water)"), "got:\n\(got)")
        },
        Check("build.calc.input.smd") {
            var s = baseSpec(.energy)
            s.method = "M06-2X"; s.basis = "def2-TZVP"
            s.solvation = .smd("Acetonitrile")
            let got = s.inputText(molecule: water())
            try expect(got == expected("#p M06-2X/def2-TZVP SP SCRF=(SMD,Solvent=Acetonitrile)"), "got:\n\(got)")
        },
        Check("build.calc.input.link0") {
            var s = baseSpec(.optimize)
            s.nprocs = 8; s.memoryMB = 16384; s.checkpoint = nil
            s.printLevel = .normal; s.extraKeywords = " Int=UltraFine  "
            var got = s.inputText(molecule: water())
            try expect(got == expected("# B3LYP/6-31G(d) Opt Int=UltraFine", link0: ["%nprocshared=8", "%mem=16GB"]), "got:\n\(got)")
            s.nprocs = 0; s.memoryMB = 0; s.checkpoint = "run1.chk"; s.printLevel = .terse
            got = s.inputText(molecule: water())
            try expect(got == expected("#n B3LYP/6-31G(d) Opt Int=UltraFine", link0: ["%chk=run1.chk"]), "got:\n\(got)")
        },
        Check("build.calc.input.titleAndCharge") {
            var s = baseSpec(.energy)
            s.title = ""; s.charge = 1; s.multiplicity = 2
            var m = water(); m.title = "From molecule"
            let want = "%nprocshared=4\n%mem=4GB\n%chk=water.chk\n#p B3LYP/6-31G(d) SP\n\nFrom molecule\n\n1 2\n" + wO + "\n" + wH1 + "\n" + wH2 + "\n\n"
            try expect(s.inputText(molecule: m) == want, "got:\n\(s.inputText(molecule: m))")
        },
        Check("build.calc.input.codableRoundTrip") {
            var s = baseSpec(.scan)
            s.solvation = .smd("Water")
            s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 5, stepSize: 0.2)]
            let d = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(CalcSetup.self, from: d)
            try expect(back == s, "round trip differs")
        },
        Check("build.calc.validate.waterSinglet") {
            try expect(baseSpec(.optimize).validate(molecule: water()).isEmpty, "\(baseSpec(.optimize).validate(molecule: water()))")
        },
        Check("build.calc.validate.waterTriplet") {
            var s = baseSpec(.optimize); s.multiplicity = 3
            try expect(s.validate(molecule: water()).isEmpty, "\(s.validate(molecule: water()))")
        },
        Check("build.calc.validate.waterDoublet") {
            var s = baseSpec(.optimize); s.multiplicity = 2
            let p = s.validate(molecule: water())
            try expect(p.count == 1 && p[0].contains("odd multiplicity"), "\(p)")
        },
        Check("build.calc.validate.OHradical") {
            var s = baseSpec(.optimize); s.multiplicity = 2
            try expect(s.validate(molecule: oh(charge: 0, mult: 2)).isEmpty, "\(s.validate(molecule: oh(charge: 0, mult: 2)))")
        },
        Check("build.calc.validate.OHminus") {
            var s = baseSpec(.optimize); s.charge = -1; s.multiplicity = 1
            try expect(s.validate(molecule: oh(charge: -1, mult: 1)).isEmpty, "\(s.validate(molecule: oh(charge: -1, mult: 1)))")
            s.charge = 0 // 9 electrons with singlet
            try expect(s.validate(molecule: oh(charge: 0, mult: 1)).count == 1, "odd electrons singlet must fail")
        },
        Check("build.calc.validate.misc") {
            var s = baseSpec(.optimize)
            try expect(s.validate(molecule: Molecule()).contains("The molecule has no atoms."), "empty")
            s.multiplicity = 0
            try expect(s.validate(molecule: water()).contains("Multiplicity must be at least 1."), "mult0")
            s.multiplicity = 13   // > electrons + 1 (11)
            try expect(s.validate(molecule: water()).contains { $0.contains("too high") }, "mult13")
            s.multiplicity = 1; s.method = ""; s.basis = ""
            let p = s.validate(molecule: water())
            try expect(p.contains("Choose a method.") && p.contains("Choose a basis set."), "\(p)")
            s = baseSpec(.scan)
            try expect(s.validate(molecule: water()).contains("Add at least one scan coordinate."), "scan empty")
            s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 4], steps: 3, stepSize: 0.1)]
            try expect(s.validate(molecule: water()).contains { $0.contains("out of range") }, "scan range")
            s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 3, stepSize: 0.1)]
            try expect(s.validate(molecule: water()).isEmpty, "scan ok")
        },
    ]
}

private func setup(_ p: MolBuild.QCProgram, _ job: JobType) -> CalcSetup {
    var s = CalcSetup(molecule: water(), program: p)
    s.jobType = job; s.nprocs = 4; s.memoryMB = 4096; s.title = "Water"
    return s
}

private func has(_ text: String, _ tokens: String...) throws {
    for t in tokens { try expect(text.contains(t), "missing '\(t)' in:\n\(text)") }
}
private func hasNot(_ text: String, _ tokens: String...) throws {
    for t in tokens { try expect(!text.contains(t), "unexpected '\(t)' in:\n\(text)") }
}

extension Checks {
    static let buildCalcPrograms: [Check] = [
        Check("build.calc.program.metadata") {
            try expect(MolBuild.QCProgram.allCases.map(\.inputExtension) == ["gjf", "inp", "in", "xyz"], "in ext")
            try expect(MolBuild.QCProgram.allCases.map(\.outputExtension) == ["log", "out", "out", "out"], "out ext")
            try expect(CalcSetup.bases(for: .xtb).isEmpty, "xtb has no bases")
            try expect(!CalcSetup.supportedJobTypes(for: .xtb).contains(.excitedStates), "xtb TD")
            for p in MolBuild.QCProgram.allCases { try expect(!CalcSetup.methods(for: p).isEmpty, "\(p) methods") }
            try expect(CalcSetup.solventKeyword("DMSO", program: .gaussian) == "DiMethylSulfoxide", "gauss dmso")
            try expect(CalcSetup.solventKeyword("Dichloromethane", program: .xtb) == "ch2cl2", "xtb dcm")
            try expect(CalcSetup.solventKeyword("Water", program: .qchem) == "water", "qchem water")
        },
        Check("build.calc.orca.allJobs") {
            for job in CalcSetup.supportedJobTypes(for: .orca) {
                var s = setup(.orca, job)
                if job == .scan { s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 10, stepSize: 0.1)] }
                let t = s.inputText(molecule: water())
                try has(t, "! B3LYP def2-SVP", "%pal nprocs 4 end", "%maxcore 1024", "* xyz 0 1\n", "\n*\n")
                try expect(t.hasSuffix("\n*\n"), "terminator for \(job)")
                try expect(s.validate(molecule: water()).isEmpty, "\(job): \(s.validate(molecule: water()))")
                switch job {
                case .energy: try has(t, " SP")
                case .optimize: try has(t, " Opt")
                case .frequency: try has(t, " Freq")
                case .optFreq: try has(t, "Opt Freq")
                case .transitionState: try has(t, "OptTS", "%geom\n  Calc_Hess true\nend")
                case .irc: try has(t, " IRC", "%irc", "Direction both")
                case .excitedStates: try has(t, "%tddft\n  nroots 10\nend")
                case .nmr: try has(t, " NMR")
                case .scan: try has(t, "%geom\n  Scan\n    B 0 1 = ", ", 11\n  end\nend")
                }
            }
        },
        Check("build.calc.orca.scanStart") {
            var s = setup(.orca, .scan)
            s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .angle, atoms: [2, 1, 3], steps: 4, stepSize: 5)]
            let t = s.inputText(molecule: water())
            // H-O-H angle of the fixture, 5 points, 0-based atom numbers
            let a = s.scanCoordinates[0].currentValue(in: water())!
            try expect(abs(a - 104.12) < 0.05, "angle \(a)")
            try has(t, "    A 1 0 2 = ", ", 5\n")
        },
        Check("build.calc.orca.solvationAndPal") {
            var s = setup(.orca, .optimize)
            s.solvation = .pcm("Water"); s.nprocs = 1; s.memoryMB = 2000
            var t = s.inputText(molecule: water())
            try has(t, "CPCM(Water)", "%maxcore 2000"); try hasNot(t, "%pal")
            s.solvation = .smd("Water"); s.nprocs = 4
            t = s.inputText(molecule: water())
            try has(t, "! B3LYP def2-SVP Opt CPCM", "%cpcm\n  smd true\n  SMDsolvent \"water\"\nend")
        },
        Check("build.calc.qchem.allJobs") {
            for job in CalcSetup.supportedJobTypes(for: .qchem) {
                var s = setup(.qchem, job)
                if job == .scan { s.scanCoordinates = [MolBuild.ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 10, stepSize: 0.1)] }
                let t = s.inputText(molecule: water())
                try has(t, "$molecule\n0 1\n", "$rem", "METHOD B3LYP", "BASIS 6-31G*", "MEM_TOTAL 4096", "$end")
                try expect(s.validate(molecule: water()).isEmpty, "\(job): \(s.validate(molecule: water()))")
                let jobs = t.components(separatedBy: "@@@").count - 1
                switch job {
                case .energy: try has(t, "JOBTYPE sp")
                case .optimize: try has(t, "JOBTYPE opt")
                case .frequency: try has(t, "JOBTYPE freq")
                case .optFreq:
                    try expect(jobs == 1, "one @@@")
                    try has(t, "JOBTYPE opt", "JOBTYPE freq", "$molecule\nread\n$end", "SCF_GUESS READ")
                case .transitionState: try has(t, "JOBTYPE ts")
                case .irc: try has(t, "JOBTYPE rpath", "RPATH_MAX_CYCLES 20")
                case .excitedStates: try has(t, "CIS_N_ROOTS 10", "RPA TRUE")
                case .nmr: try has(t, "JOBTYPE nmr")
                case .scan: try has(t, "JOBTYPE pes_scan", "$scan\nstre 1 2 ")
                }
                if job != .optFreq { try expect(jobs == 0, "no @@@ for \(job)") }
            }
        },
        Check("build.calc.qchem.solvationAndSpin") {
            var s = setup(.qchem, .energy)
            s.solvation = .pcm("Water")
            var t = s.inputText(molecule: water())
            try has(t, "SOLVENT_METHOD pcm", "$solvent\nSolventName water\n$end")
            s.solvation = .smd("Acetonitrile")
            t = s.inputText(molecule: water())
            try has(t, "SOLVENT_METHOD smd", "$smx\nsolvent acetonitrile\n$end")
            s.multiplicity = 3; s.tdSpin = .triplets; s.jobType = .excitedStates
            t = s.inputText(molecule: water())
            try has(t, "UNRESTRICTED TRUE", "CIS_TRIPLETS TRUE", "CIS_SINGLETS FALSE")
        },
        Check("build.calc.xtb.allJobs") {
            let want: [JobType: String] = [.energy: "", .optimize: "--opt", .frequency: "--hess", .optFreq: "--ohess"]
            try expect(Set(CalcSetup.supportedJobTypes(for: .xtb)) == Set(want.keys), "xtb job list")
            for job in CalcSetup.supportedJobTypes(for: .xtb) {
                let s = setup(.xtb, job)
                let args = s.commandArguments(inputFileName: "job.xyz")
                try expect(args.first == "job.xyz", "\(args)")
                if let f = want[job], !f.isEmpty { try expect(args.contains(f), "\(job) \(args)") }
                try expect(!args.contains("--opt") || job == .optimize, "\(job) \(args)")
                try expect(args.suffix(8) == ["--chrg", "0", "--uhf", "0", "--gfn", "2", "-P", "4"], "\(args)")
                try expect(s.validate(molecule: water()).isEmpty, "\(job)")
                let x = s.inputText(molecule: water())
                try expect(x.hasPrefix("3\nWater\nO "), "xyz:\n\(x)")
            }
        },
        Check("build.calc.xtb.options") {
            var s = setup(.xtb, .optFreq)
            s.charge = -1; s.multiplicity = 2; s.xtbMethod = .gfnff; s.solvation = .pcm("DMSO"); s.nprocs = 2
            let a = s.commandArguments(inputFileName: "a.xyz")
            try expect(a == ["a.xyz", "--ohess", "--chrg", "-1", "--uhf", "1", "--gfnff", "--alpb", "dmso", "-P", "2"], "\(a)")
            s.xtbMethod = .gfn1; s.solvation = .none; s.extraKeywords = "--verbose"
            try expect(s.commandArguments(inputFileName: "a.xyz").contains("1") && s.commandArguments(inputFileName: "a.xyz").last == "--verbose", "gfn1/extra")
        },
        Check("build.calc.validate.programs") {
            var s = setup(.xtb, .excitedStates)
            try expect(s.validate(molecule: water()).contains { $0.contains("does not support") }, "xtb TD")
            s = setup(.xtb, .optimize); s.solvation = .pcm("Heptane")
            try expect(s.validate(molecule: water()).contains { $0.contains("ALPB") }, "xtb heptane")
            s.solvation = .smd("Water")
            try expect(s.validate(molecule: water()).contains { $0.contains("SMD") }, "xtb smd")
            s = setup(.orca, .optimize); s.setProgram(.xtb)
            try expect(s.program == .xtb && s.basis.isEmpty && s.method == "GFN2-xTB", "setProgram")
            s.setProgram(.qchem)
            try expect(s.method == "B3LYP" && s.basis == "6-31G*", "setProgram qchem \(s.method) \(s.basis)")
            s = setup(.orca, .optimize); s.method = "r2SCAN-3c"; s.basis = ""
            try expect(s.validate(molecule: water()).isEmpty, "3c needs no basis")
        },
    ]
}
