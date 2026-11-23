import Foundation
import MolCore
import MolBuild

// Checks for CalcSpec (route + input generation + validation). Expected strings are hand-written.

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

private func baseSpec(_ job: JobType) -> CalcSpec {
    var s = CalcSpec()
    s.jobType = job
    s.method = "B3LYP"; s.basis = "6-31G(d)"
    s.nprocShared = 4; s.memory = "4GB"; s.checkpoint = "water"
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
    static let buildCalc: [Check] = [
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
                ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 10, stepSize: 0.1),
                ScanCoordinate(kind: .angle, atoms: [2, 1, 3], steps: 10, stepSize: 5),
            ]
            let got = s.inputText(molecule: water())
            try expect(got == expected("#p B3LYP/6-31G(d) Opt=ModRedundant", trailer: ["B 1 2 S 10 0.100000", "A 2 1 3 S 10 5.000000"]), "got:\n\(got)")
            s.scanCoordinates = [ScanCoordinate(kind: .dihedral, atoms: [1, 2, 3, 1], steps: 36, stepSize: 10)]
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
            s.nprocShared = 8; s.memory = "16GB"; s.checkpoint = nil
            s.printLevel = .normal; s.extraKeywords = " Int=UltraFine  "
            var got = s.inputText(molecule: water())
            try expect(got == expected("# B3LYP/6-31G(d) Opt Int=UltraFine", link0: ["%nprocshared=8", "%mem=16GB"]), "got:\n\(got)")
            s.nprocShared = 0; s.memory = ""; s.checkpoint = "run1.chk"; s.printLevel = .terse
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
            s.scanCoordinates = [ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 5, stepSize: 0.2)]
            let d = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(CalcSpec.self, from: d)
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
            s.scanCoordinates = [ScanCoordinate(kind: .bond, atoms: [1, 4], steps: 3, stepSize: 0.1)]
            try expect(s.validate(molecule: water()).contains { $0.contains("out of range") }, "scan range")
            s.scanCoordinates = [ScanCoordinate(kind: .bond, atoms: [1, 2], steps: 3, stepSize: 0.1)]
            try expect(s.validate(molecule: water()).isEmpty, "scan ok")
        },
    ]
}
