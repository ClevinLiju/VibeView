import Foundation
import simd
import MolCore
@testable import MolIO

// Gaussian input (.gjf/.com) checks (worker A).

fileprivate let giFixtures = [
    "input_water_optfreq.gjf", "input_zmat_variables.gjf", "input_oniom.com", "input_modredundant.gjf",
    "input_connectivity.gjf", "input_link1.gjf", "input_gen_pcm.gjf", "input_dexp.gjf",
]

fileprivate func giLoad(_ name: String) throws -> [GaussianJob] {
    try GaussianInputReader.read(url: testDataURL("io/" + name))
}
fileprivate func giText(_ name: String) throws -> String {
    try String(contentsOf: testDataURL("io/" + name), encoding: .utf8)
}
fileprivate func giThrows(_ text: String, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws {
    do {
        let r = try GaussianInputReader.parse(text)
        throw CheckFailure(description: "\(file):\(line) expected an error for \(what), got \(r.count) job(s)")
    } catch is MolIOError { }
}
fileprivate func giDist(_ a: Vec3, _ b: Vec3) -> Double { simd_length(a - b) }
fileprivate func giAngle(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
    let u = simd_normalize(a - b), v = simd_normalize(c - b)
    return acos(max(-1, min(1, simd_dot(u, v)))) * 180 / .pi
}
fileprivate func giDihedral(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3) -> Double {
    let b1 = p1 - p0, b2 = p2 - p1, b3 = p3 - p2
    let n1 = simd_cross(b1, b2), n2 = simd_cross(b2, b3)
    return atan2(simd_length(b2) * simd_dot(b1, n2), simd_dot(n1, n2)) * 180 / .pi
}
fileprivate func giSameJob(_ a: GaussianJob, _ b: GaussianJob, tol: Double = 1e-5, file: StaticString = #fileID, line: UInt = #line) throws {
    try expect(a.molecule.atoms.count == b.molecule.atoms.count, "atom count", file: file, line: line)
    for (x, y) in zip(a.molecule.atoms, b.molecule.atoms) {
        try expect(x.atomicNumber == y.atomicNumber && x.id == y.id && x.label == y.label, "atom identity \(x.id)", file: file, line: line)
        try expect(giDist(x.position, y.position) < tol, "position of atom \(x.id)", file: file, line: line)
    }
    var a2 = a, b2 = b
    a2.molecule.atoms = b.molecule.atoms
    a2.molecule.bonds.sort { ($0.a, $0.b) < ($1.a, $1.b) }
    b2.molecule.bonds.sort { ($0.a, $0.b) < ($1.a, $1.b) }
    try expect(a2 == b2, "jobs differ after round trip:\n\(a2)\nvs\n\(b2)", file: file, line: line)
}

fileprivate func giBigInput(_ n: Int, connectivity: Bool = false) -> (String, [Vec3]) {
    var s = "%mem=1GB\n# hf/sto-3g" + (connectivity ? " geom=connectivity" : "") + "\n\nbig\n\n0 1\n"
    var pos: [Vec3] = []
    pos.reserveCapacity(n)
    let syms = ["C", "H", "O", "N", "Cl"]
    for i in 0..<n {
        let p = Vec3(Double(i % 37) * 1.5 - 20, Double((i / 37) % 41) * 1.25 + 0.123456, Double(i / 1517) * 2.0 - 0.5)
        pos.append(p)
        s += "\(syms[i % 5]) \(String(format: "%.6f %.6f %.6f", p.x, p.y, p.z))\n"
    }
    s += "\n"
    if connectivity {
        for i in 1...n { s += i < n ? "\(i) \(i + 1) 1.0\n" : "\(i)\n" }
        s += "\n"
    }
    return (s, pos)
}

extension Checks {
    static let ioGaussianInput: [Check] = [
        Check("io.gjf.water.values") {
            let jobs = try giLoad("input_water_optfreq.gjf")
            try expect(jobs.count == 1)
            let j = jobs[0]
            try expect(j.link0.checkpoint == "water.chk" && j.link0.memory == "16GB" && j.link0.nprocShared == 8)
            try expect(j.route.printLevel == "#" && j.route.method == "b3lyp" && j.route.basis == "6-31+G(d,p)")
            try expect(j.route.jobTypes == ["opt", "freq"], "\(j.route.jobTypes)")
            try expect(j.route.keywords == ["int=ultrafine"], "\(j.route.keywords)")
            try expect(j.route.solvation == GaussianSolvation(model: "smd", solvent: "water"), "\(String(describing: j.route.solvation))")
            try expect(j.title == "Water optimization and frequencies")
            try expect(j.molecule.charge == 0 && j.molecule.multiplicity == 1 && j.chargeMultiplicities == [ChargeMultiplicity(charge: 0, multiplicity: 1)])
            try expect(j.molecule.atoms.map { $0.atomicNumber } == [8, 1, 1])
            try expect(j.molecule.atoms.enumerated().allSatisfy { $0.offset == $0.element.id })
            try expectClose(j.molecule.atoms[0].position.z, 0.117790)
            try expectClose(j.molecule.atoms[2].position.y, -0.755453)
            try expect(j.molecule.bonds.isEmpty && j.zMatrix == nil && j.modRedundant.isEmpty && j.extraSections.isEmpty)
            try expect(j.molecule.title == j.title)
            try expect(j.atomSpecs.count == 3 && j.atomSpecs[0].label == "O" && j.atomSpecs[0].freeze == 0 && j.atomSpecs[0].layer == nil)
        },
        Check("io.gjf.route.parse") {
            let r = GaussianRoute(parsing: "#P Opt(ModRedundant, CalcFC) FREQ=NoRaman B3LYP/6-31+G(d,p)\n EmpiricalDispersion=GD3BJ  SCRF(CPCM,Solvent=Water)")
            try expect(r.printLevel == "#P" && r.method == "B3LYP" && r.basis == "6-31+G(d,p)", "\(r)")
            try expect(r.jobTypes == ["Opt(ModRedundant,CalcFC)", "FREQ=NoRaman"], "\(r.jobTypes)")
            try expect(r.keywords == ["EmpiricalDispersion=GD3BJ"], "\(r.keywords)")
            try expect(r.solvation?.model == "CPCM" && r.solvation?.solvent == "Water")
            try expect(r.readsModRedundant && !r.readsConnectivity && r.hasOption("calcfc", of: "OPT"))
            let o = GaussianRoute(parsing: "# ONIOM(B3LYP/6-31G(d):UFF)=EmbedCharge opt")
            try expect(o.method == "ONIOM(B3LYP/6-31G(d):UFF)=EmbedCharge" && o.basis == nil && o.jobTypes == ["opt"], "\(o)")
            let o2 = GaussianRoute(parsing: "#n ONIOM(B3LYP/6-31G(d):UFF) opt")
            try expect(o2.printLevel == "#N" && o2.method == "ONIOM(B3LYP/6-31G(d):UFF)" && o2.basis == nil)
            let m = GaussianRoute(parsing: "#t mp2 sp geom = ( allcheck , NoCrowd ) guess = read td = (nstates = 6, root=1)")
            try expect(m.printLevel == "#T" && m.method == "mp2" && m.basis == nil, "\(m)")
            try expect(m.readsEverythingFromCheckpoint && m.hasOption("nocrowd", of: "geom"), "\(m.keywords)")
            try expect(m.jobTypes == ["sp", "td=(nstates=6,root=1)"], "\(m.jobTypes)")
            try expect(m.options(of: "td")! == ["nstates=6", "root=1"])
            let pbe = GaussianRoute(parsing: "#PBE1PBE/def2SVP")
            try expect(pbe.printLevel == "#" && pbe.method == "PBE1PBE" && pbe.basis == "def2SVP", "\(pbe)")
            let g = GaussianRoute(parsing: "# opt freq wb97xd gen pseudo=read")
            try expect(g.method == "wb97xd" && g.keywords == ["gen", "pseudo=read"], "\(g)")
            try expect(GaussianRoute(parsing: "").printLevel == "#")
        },
        Check("io.gjf.route.roundTrip") {
            for t in ["# opt freq b3lyp/6-31g(d)", "#p td(nstates=10) cam-b3lyp/def2tzvp scrf=(smd,solvent=acetonitrile) nosymm",
                      "#N ONIOM(B3LYP/6-31G(d):UFF) opt=(modredundant,calcfc)", "# um062x/gen geom=connectivity pop=full",
                      "#T HF/STO-3G", "# irc=(calcfc,maxpoints=30) hf/3-21g scrf=pcm", "# opt = ( tight , calcfc ) b3lyp / 6-31g"] {
                let r = GaussianRoute(parsing: t)
                let r2 = GaussianRoute(parsing: r.text)
                try expect(r == r2, "route round trip failed for '\(t)': \(r) vs \(r2)")
                try expect(r.text == r2.text)
            }
            try expect(GaussianRoute(parsing: "# opt freq b3lyp/6-31g(d)").text == "# b3lyp/6-31g(d) opt freq")
        },
        Check("io.gjf.link0") {
            var l = Link0()
            l.absorb("%NProc=4"); l.absorb("%OldChk = a.chk ! comment"); l.absorb("%rwf=/tmp/x.rwf"); l.absorb("%cpu=0-3"); l.absorb("%nprocl=2")
            try expect(l.nprocShared == 4 && l.oldCheckpoint == "a.chk" && l.cpu == "0-3")
            try expect(l.other == ["%rwf=/tmp/x.rwf", "%nprocl=2"], "\(l.other)")
            let text = "%oldchk=a.chk\n%chk=b.chk\n%mem=500MB\n%nprocshared=2\n%rwf=x\n# hf/sto-3g\n\nt\n\n0 1\nH 0 0 0\nH 0 0 0.74\n\n"
            let j = try GaussianInputReader.parse(text)[0]
            try expect(j.link0.lines == ["%oldchk=a.chk", "%chk=b.chk", "%mem=500MB", "%nprocshared=2", "%rwf=x"])
            try expect(j.inputText.hasPrefix(j.link0.lines.joined(separator: "\n") + "\n# hf/sto-3g\n"))
        },
        Check("io.gjf.zmatrix.geometry") {
            let j = try giLoad("input_zmat_variables.gjf")[0]
            let z = try { () throws -> GaussianZMatrix in guard let z = j.zMatrix else { throw CheckFailure(description: "no zMatrix") }; return z }()
            try expect(z.entries.count == 5 && z.entries[0].isDummy && z.entries[0].references.isEmpty)
            try expect(z.variables.map { $0.name } == ["r1", "r2", "a1", "d0", "d1"] && z.variables.allSatisfy { !$0.isConstant })
            try expect(j.molecule.atoms.map { $0.atomicNumber } == [8, 8, 1, 1], "dummy dropped: \(j.molecule.atoms.map { $0.atomicNumber })")
            try expect(j.atomSpecs.count == 4 && j.chargeMultiplicities == [ChargeMultiplicity(charge: 0, multiplicity: 1)])
            let all = try z.rowPositions()
            try expect(all.count == 5 && simd_length(all[0]) < 1e-12)
            let p = j.molecule.atoms.map { $0.position }
            try expectClose(giDist(p[0], p[1]), 1.45, tol: 1e-9)
            try expectClose(giDist(all[0], p[0]), 1.0, tol: 1e-9)
            try expectClose(giAngle(all[0], p[0], p[1]), 90, tol: 1e-7)
            try expectClose(giDist(p[2], p[0]), 0.96, tol: 1e-9)
            try expectClose(giAngle(p[2], p[0], p[1]), 100, tol: 1e-7)
            try expectClose(abs(giDihedral(p[2], p[0], p[1], all[0])), 180, tol: 1e-6)
            try expectClose(giDist(p[3], p[1]), 0.96, tol: 1e-9)
            try expectClose(giAngle(p[3], p[1], p[0]), 100, tol: 1e-7)
            try expectClose(giDihedral(p[3], p[1], p[0], p[2]), 120, tol: 1e-6)
            // Variables with negative sign usage.
            let t = "# hf/sto-3g\n\nneg\n\n0 1\nO\nH 1 r\nH 1 r 2 a\n\nr 0.96\na 104.5\n\n"
            let k = try GaussianInputReader.parse(t)[0].molecule.atoms.map { $0.position }
            try expectClose(giAngle(k[1], k[0], k[2]), 104.5, tol: 1e-7)
            let t2 = "# hf/sto-3g\n\nneg\n\n0 1\nC\nC 1 1.5\nC 2 1.5 1 110.0\nC 3 1.5 2 110.0 1 d\nH 4 1.0 3 109.0 2 -d\n\nd=60.0\n\n"
            let q = try GaussianInputReader.parse(t2)[0].molecule.atoms.map { $0.position }
            try expectClose(giDihedral(q[3], q[2], q[1], q[0]), 60, tol: 1e-6)
            try expectClose(giDihedral(q[4], q[3], q[2], q[1]), -60, tol: 1e-6)
            // Constants section and label references.
            let t3 = "# hf/sto-3g\n\nc\n\n0 1\nO1\nH1 O1 rr\nH2 O1 rr H1 aa\n\nVariables:\nrr 0.96\nConstants:\naa 104.5\n\n"
            let j3 = try GaussianInputReader.parse(t3)[0]
            try expect(j3.zMatrix?.variables.map { $0.isConstant } == [false, true])
            let c = j3.molecule.atoms.map { $0.position }
            try expectClose(giAngle(c[1], c[0], c[2]), 104.5, tol: 1e-7)
            // Mixed Cartesian + Z-matrix.
            let t4 = "# hf/sto-3g\n\nmix\n\n0 1\nC 1.0 2.0 3.0\nH 1 1.1\nH 1 1.1 2 109.5\n\n"
            let m = try GaussianInputReader.parse(t4)[0].molecule.atoms.map { $0.position }
            try expectClose(giDist(m[0], Vec3(1, 2, 3)), 0, tol: 1e-12)
            try expectClose(giDist(m[1], m[0]), 1.1, tol: 1e-9)
            try expectClose(giAngle(m[1], m[0], m[2]), 109.5, tol: 1e-7)
        },
        Check("io.gjf.zmatrix.errors") {
            let h = "# hf/sto-3g\n\nt\n\n0 1\n"
            try giThrows(h + "O\nH 1 r\n\n", "undefined variable, no variables section")
            try giThrows(h + "O\nH 1 r\n\nq 1.0\n\n", "undefined variable r")
            try giThrows(h + "O\nH 5 1.0\n", "reference to a later atom")
            try giThrows(h + "O\nH 1 1.0\nH 1 1.0\n", "missing angle")
            try giThrows(h + "O\nH 1 1.0 2 90.0\n", "too many refs for atom 2")
            try giThrows(h + "O\nH Q 1.0\n", "undefined label reference")
            try giThrows(h + "O\nH 1 1.0\nH 1 1.0 1 90.0\n", "duplicate refs")
            try giThrows(h + "O\nH 1 *\n", "bad value")
            try giThrows(h + "O\nH 1 r\n\nr abc\n\n", "bad variable value")
            // "H 1 1.0 2" has 3 numeric fields and is a valid Cartesian line (H at 1,1,2), so it is not an
            // error; odd field counts are tested on Z-matrix rows that cannot be Cartesian.
            try expect(try GaussianInputReader.parse(h + "C\nH 1 1.0 2\n\n")[0].molecule.atoms[1].position == Vec3(1, 1, 2))
            try giThrows(h + "C\nH 1 1.0\nH 1 1.0 2 90.0 7\n", "odd field count (extra field on atom 3)")
            try giThrows(h + "C\nH 1 1.0 2 90.0 3\n", "odd field count on atom 2")
        },
        Check("io.gjf.oniom") {
            let j = try giLoad("input_oniom.com")[0]
            try expect(j.link0.nprocShared == 4)
            try expect(j.route.printLevel == "#P" && j.route.method == "ONIOM(B3LYP/6-31G(d):UFF)" && j.route.jobTypes == ["opt"], "\(j.route)")
            try expect(j.chargeMultiplicities.count == 3 && j.molecule.charge == 0 && j.molecule.multiplicity == 1)
            try expect(j.molecule.atoms.map { $0.atomicNumber } == [6, 1, 1, 6, 1])
            try expect(j.atomSpecs.map { $0.layer } == ["H", "H", "L", "L", "L"], "\(j.atomSpecs.map { $0.layer })")
            try expect(j.atomSpecs[0].label == "C-CA--0.25" && j.atomSpecs[2].freeze == -1 && j.atomSpecs[1].freeze == 0)
            try expect(j.atomSpecs[3].linkAtom == "H-HA-0.1 1", "\(String(describing: j.atomSpecs[3].linkAtom))")
            try expect(j.atomSpecs[4].linkAtom == nil && j.molecule.atoms[4].label == nil)
            try expectClose(j.molecule.atoms[3].position.x, -1.5)
            let r = try GaussianInputReader.parse(j.inputText)[0]
            try giSameJob(j, r)
            try expect(j.inputText.contains("L H-HA-0.1 1"))
            // layer without freeze column written back with a freeze column
            let k = try GaussianInputReader.parse("# hf/sto-3g\n\nt\n\n0 1\nC 0 0 0 H\nH 0 0 1 L\n\n")[0]
            try expect(k.atomSpecs.map { $0.layer } == ["H", "L"] && k.molecule.atoms[1].position.z == 1)
            try giSameJob(k, try GaussianInputReader.parse(k.inputText)[0])
        },
        Check("io.gjf.cartesian.variants") {
            let t = """
            # hf/sto-3g

            variants

            0 3
            6 0.0 0.0 0.0
            O,0.0,0.0,1.2
            Cl(Fragment=2) -1 0.0 0.0 5.0
            Bq 0 0.0 0.0 7.0
            c 1.0 1.0 1.0
            H(Iso=2) 0 1.0 1.0 2.0

            """
            let j = try GaussianInputReader.parse(t)[0]
            try expect(j.molecule.atoms.map { $0.atomicNumber } == [6, 8, 17, 0, 6, 1], "\(j.molecule.atoms.map { $0.atomicNumber })")
            try expect(j.molecule.multiplicity == 3)
            try expect(j.atomSpecs[2].fragment == 2 && j.atomSpecs[2].freeze == -1 && j.atomSpecs[0].freeze == 0)
            try expect(j.molecule.atoms[0].label == "6" && j.molecule.atoms[4].label == nil && j.molecule.atoms[3].label == "Bq" && j.molecule.atoms[5].label == "H(Iso=2)")
            try giSameJob(j, try GaussianInputReader.parse(j.inputText)[0])
            // Freeze with 4 fields where x=0 and no freeze column: "C 0 0 0"
            let z = try GaussianInputReader.parse("# hf\n\nt\n\n0 1\nC 0 0 0\nC 0 0 1.5\n\n")[0]
            try expect(z.molecule.atoms.count == 2 && z.atomSpecs.allSatisfy { $0.freeze == 0 })
            try expectClose(z.molecule.atoms[1].position.z, 1.5)
            // comments and blank-separated multi-line title
            let c = try GaussianInputReader.parse("%chk=a.chk ! cp\n! full comment\n# hf/sto-3g ! route comment\n   opt\n\nline one\nline two\n\n0 1\nH 0 0 0 ! first\nH 0 0 0.74\n\nextra block\nsecond line\n\nanother\n")[0]
            try expect(c.title == "line one\nline two" && c.route.jobTypes == ["opt"] && c.link0.checkpoint == "a.chk")
            try expect(c.molecule.atoms.count == 2 && c.extraSections == ["extra block\nsecond line", "another"], "\(c.extraSections)")
            // file without trailing newline
            let n = try GaussianInputReader.parse("# hf\n\nt\n\n0 1\nH 0 0 0\nH 0 0 0.7")[0]
            try expect(n.molecule.atoms.count == 2)
        },
        Check("io.gjf.modredundant") {
            let j = try giLoad("input_modredundant.gjf")[0]
            try expect(j.route.readsModRedundant && j.route.method == "b3lyp")
            try expect(j.molecule.atoms.count == 8)
            try expect(j.modRedundant == ["B 1 2 S 10 0.05", "D 3 1 2 6 F", "A 3 1 2 F"], "\(j.modRedundant)")
            try expect(j.extraSections.isEmpty)
            try giSameJob(j, try GaussianInputReader.parse(j.inputText)[0])
            // Opt(ModRedundant,...) form and an extra section after the redundant lines
            let t = "# opt(modredundant,calcfc) hf/sto-3g\n\nt\n\n0 1\nH 0 0 0\nH 0 0 0.7\n\nB 1 2 F\n\nsome extra\n\n"
            let k = try GaussianInputReader.parse(t)[0]
            try expect(k.modRedundant == ["B 1 2 F"] && k.extraSections == ["some extra"])
            // Without the keyword the block is an extra section
            let k2 = try GaussianInputReader.parse("# opt hf/sto-3g\n\nt\n\n0 1\nH 0 0 0\nH 0 0 0.7\n\nB 1 2 F\n\n")[0]
            try expect(k2.modRedundant.isEmpty && k2.extraSections == ["B 1 2 F"])
        },
        Check("io.gjf.connectivity") {
            let j = try giLoad("input_connectivity.gjf")[0]
            try expect(j.route.readsConnectivity && j.molecule.atoms.count == 6)
            try expect(j.molecule.bonds.count == 5, "\(j.molecule.bonds)")
            try expect(j.molecule.bonds.first == Bond(0, 1, order: .double))
            try expect(Set(j.molecule.bonds.map { "\($0.a)-\($0.b)" }) == ["0-1", "0-2", "0-3", "1-4", "1-5"])
            try expect(j.molecule.bonds.filter { $0.order == .single }.count == 4)
            try giSameJob(j, try GaussianInputReader.parse(j.inputText)[0])
            let h = "# hf/sto-3g geom=connectivity\n\nt\n\n0 1\nC 0 0 0\nC 0 0 1.4\nC 0 0 2.8\n\n"
            let b = try GaussianInputReader.parse(h + "1 2 1.5\n2 3 3.0\n3 2 3.0\n\n")[0]
            try expect(b.molecule.bonds == [Bond(0, 1, order: .aromatic), Bond(1, 2, order: .triple)], "\(b.molecule.bonds)")
            try giThrows(h + "1 9 1.0\n", "bad atom")
            try giThrows(h + "1 2 1.7\n", "bad order")
            try giThrows(h + "1 2\n", "odd entries")
            try giThrows(h, "missing section")
            try giThrows(h + "x 2 1.0\n", "non-numeric index")
            // Connectivity with a Z-matrix dummy: input numbering includes the dummy.
            let zt = "# hf/sto-3g geom=connectivity\n\nt\n\n0 1\nX\nO 1 1.0\nH 2 0.96 1 90.0\n\n1\n2 3 1.0\n3\n\n"
            let zj = try GaussianInputReader.parse(zt)[0]
            try expect(zj.molecule.bonds == [Bond(0, 1)], "\(zj.molecule.bonds)")
            try giSameJob(zj, try GaussianInputReader.parse(zj.inputText)[0])
        },
        Check("io.gjf.link1") {
            let jobs = try giLoad("input_link1.gjf")
            try expect(jobs.count == 2)
            try expect(jobs[0].molecule.charge == -1 && jobs[0].molecule.multiplicity == 2 && jobs[0].molecule.atoms.count == 2)
            try expect(jobs[1].molecule.atoms.isEmpty && jobs[1].title.isEmpty && jobs[1].chargeMultiplicities.isEmpty)
            try expect(jobs[1].route.readsEverythingFromCheckpoint && jobs[1].route.jobTypes == ["freq"] && jobs[1].link0.checkpoint == "job.chk")
            try expect(jobs[0].link0.memory == "2GB" && jobs[1].link0.memory == nil)
            let text = GaussianInputWriter.write(jobs)
            try expect(text.contains("--Link1--\n"))
            let again = try GaussianInputReader.parse(text)
            try expect(again.count == 2)
            for (a, b) in zip(jobs, again) { try giSameJob(a, b) }
            // Geom=Check keeps title and charge line but no geometry.
            let c = try GaussianInputReader.parse("%chk=a.chk\n# hf/sto-3g geom=check guess=read\n\nsecond\n\n1 2\n\n--Link1--\n# freq geom=allcheck\n\n")
            try expect(c.count == 2 && c[0].molecule.atoms.isEmpty && c[0].title == "second" && c[0].molecule.charge == 1 && c[0].molecule.multiplicity == 2)
            try giSameJob(c[0], try GaussianInputReader.parse(c[0].inputText)[0])
            // AllCheck as the very last thing without trailing blank line
            let d = try GaussianInputReader.parse("# freq geom=allcheck")
            try expect(d.count == 1 && d[0].molecule.atoms.isEmpty)
            // Three steps with different geometries.
            let three = "# hf\n\na\n\n0 1\nH 0 0 0\nH 0 0 0.7\n\n--Link1--\n# hf\n\nb\n\n0 1\nHe 0 0 0\n\n--link1--\n# hf\n\nc\n\n0 1\nNe 0 0 0\n\n"
            let t3 = try GaussianInputReader.parse(three)
            try expect(t3.map { $0.title } == ["a", "b", "c"] && t3.map { $0.molecule.atoms.count } == [2, 1, 1])
        },
        Check("io.gjf.extras.genPcm") {
            let j = try giLoad("input_gen_pcm.gjf")[0]
            try expect(j.route.printLevel == "#N" && j.route.method == "M062X" && j.route.basis == "Gen", "\(j.route)")
            try expect(j.route.jobTypes == ["td(nstates=6,50-50)"] && j.route.keywords == ["pseudo=read"], "\(j.route)")
            try expect(j.route.solvation == GaussianSolvation(model: "pcm", solvent: "ethanol", options: ["read"]), "\(String(describing: j.route.solvation))")
            try expect(j.molecule.charge == 1 && j.molecule.multiplicity == 2)
            try expect(j.molecule.atoms.map { $0.atomicNumber } == [26, 17])
            try expect(j.atomSpecs.map { $0.fragment } == [1, 2] && j.atomSpecs[0].label == "Fe(Fragment=1)")
            try expect(j.extraSections.count == 3, "\(j.extraSections.count)")
            try expect(j.extraSections[0] == "C H 0\n6-31G(d)\n****\nFe 0\nLANL2DZ\n****", "\(j.extraSections[0])")
            try expect(j.extraSections[2] == "Radii=Bondi\nAlpha=1.2")
            try giSameJob(j, try GaussianInputReader.parse(j.inputText)[0])
        },
        Check("io.gjf.dExponents") {
            let j = try giLoad("input_dexp.gjf")[0]
            try expectClose(j.molecule.atoms[0].position.z, 0.11779, tol: 1e-12)
            try expectClose(j.molecule.atoms[1].position.y, 0.755453, tol: 1e-12)
            try expectClose(j.molecule.atoms[2].position.y, -0.755453, tol: 1e-12)
            try giSameJob(j, try GaussianInputReader.parse(j.inputText)[0])
            let z = try GaussianInputReader.parse("# hf\n\nt\n\n0 1\nO\nH 1 9.6D-01\nH 1 0.96d+0 2 1.045D+02\n\n")[0]
            try expectClose(giDist(z.molecule.atoms[0].position, z.molecule.atoms[1].position), 0.96, tol: 1e-12)
            try expectClose(giAngle(z.molecule.atoms[1].position, z.molecule.atoms[0].position, z.molecule.atoms[2].position), 104.5, tol: 1e-7)
            let v = try GaussianInputReader.parse("# hf\n\nt\n\n0 1\nO\nH 1 r\n\nr 9.6D-01\n\n")[0]
            try expectClose(v.molecule.atoms[1].position.z, 0.96, tol: 1e-12)
        },
        Check("io.gjf.roundTrip.fixtures") {
            for f in giFixtures {
                let jobs = try giLoad(f)
                let text = GaussianInputWriter.write(jobs)
                let again = try GaussianInputReader.parse(text)
                try expect(jobs.count == again.count, "\(f) job count")
                for (a, b) in zip(jobs, again) { try giSameJob(a, b) }
                // idempotent text
                try expect(GaussianInputWriter.write(again) == text, "\(f) writer not idempotent")
            }
        },
        Check("io.gjf.crlf") {
            for f in giFixtures {
                let text = try giText(f)
                let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
                let cr = text.replacingOccurrences(of: "\n", with: "\r")
                let a = try GaussianInputReader.parse(text), b = try GaussianInputReader.parse(crlf), c = try GaussianInputReader.parse(cr)
                try expect(a == b && a == c, "\(f) differs with \\r\\n / \\r line endings")
            }
        },
        Check("io.gjf.writer.fromMolecule") {
            var m = Molecule()
            m.atoms = [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1177900049)),
                       Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.755453, -0.47116)),
                       Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.755453, -0.47116))]
            m.charge = 1; m.multiplicity = 2
            var route = GaussianRoute(method: "B3LYP", basis: "6-31G(d)", jobTypes: ["Opt", "Freq"])
            route.solvation = GaussianSolvation(model: "SMD", solvent: "Water")
            var job = GaussianJob(molecule: m, route: route, title: "built")
            job.link0.checkpoint = "built.chk"; job.link0.memory = "4GB"; job.link0.nprocShared = 4
            job.atomSpecs[1].freeze = -1
            let text = job.inputText
            let expected = "%chk=built.chk\n%mem=4GB\n%nprocshared=4\n# B3LYP/6-31G(d) Opt Freq SCRF=(SMD,Solvent=Water)\n\nbuilt\n\n1 2\n"
            try expect(text.hasPrefix(expected), "got:\n\(text)")
            try expect(text.hasSuffix("\n\n"))
            try expect(text.contains("H -1 0.00000000 0.75545300 -0.47116000"), text)
            let r = try GaussianInputReader.parse(text)[0]
            try expect(r.molecule.charge == 1 && r.molecule.multiplicity == 2 && r.title == "built")
            try expect(r.atomSpecs.map { $0.freeze } == [0, -1, 0])
            for (a, b) in zip(m.atoms, r.molecule.atoms) { try expect(giDist(a.position, b.position) < 1e-7) }
            try expect(r.route == route)
            // precision of at least 6 decimals
            try expect(text.contains("0.11779000"))
            // dummy (Z=0) atoms and atom labels survive
            var m2 = m
            m2.atoms[0].label = "O1"
            m2.atoms.append(Atom(id: 3, atomicNumber: 0, position: Vec3(1, 1, 1)))
            let r2 = try GaussianInputReader.parse(GaussianJob(molecule: m2, route: route, title: "").inputText)[0]
            try expect(r2.molecule.atoms.map { $0.atomicNumber } == [8, 1, 1, 0] && r2.molecule.atoms[0].label == "O1")
            try expect(r2.title == "Title Card Required" || !r2.title.isEmpty)
            // Fragment index added when label lacks it
            var j3 = GaussianJob(molecule: m, route: route, title: "f")
            j3.atomSpecs[2].fragment = 2
            let r3 = try GaussianInputReader.parse(j3.inputText)[0]
            try expect(r3.atomSpecs[2].fragment == 2 && r3.molecule.atoms[2].atomicNumber == 1)
            // mismatched atomSpecs fall back to atom data
            var j4 = job; j4.atomSpecs = []
            let j4n = try GaussianInputReader.parse(j4.inputText)[0].molecule.atoms.count
            try expect(j4n == 3)
            // Codable
            let data = try JSONEncoder().encode(job)
            let decoded = try JSONDecoder().decode(GaussianJob.self, from: data)
            try expect(decoded == job)
        },
        Check("io.gjf.writer.zmatrix") {
            let j = try giLoad("input_zmat_variables.gjf")[0]
            let text = j.inputText
            try expect(text.contains("\nX\nO 1 1.0\nO 2 r1 1 90.0\nH 2 r2 3 a1 1 d0\nH 3 r2 2 a1 4 d1\n\nVariables:\nr1=1.45\n"), text)
            let r = try GaussianInputReader.parse(text)[0]
            try giSameJob(j, r)
            // the Z-matrix survives; positions come from the matrix
            try expect(r.zMatrix == j.zMatrix)
        },
        Check("io.gjf.malformed") {
            let ok = "# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 0\nH 0 0 0.74\n\n"
            _ = try GaussianInputReader.parse(ok)
            try giThrows("", "empty file")
            try giThrows("\n\n  \n", "blank file")
            try giThrows("%chk=a.chk\n", "link0 only")
            try giThrows("hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 0\n\n", "missing route #")
            try giThrows("# hf/sto-3g\n", "route only")
            try giThrows("# hf/sto-3g\n\n", "no title")
            try giThrows("# hf/sto-3g\n\ntitle\n", "no charge")
            try giThrows("# hf/sto-3g\n\ntitle\n\n", "no charge 2")
            try giThrows("# hf/sto-3g\n\ntitle\n\n\n0 1\nH 0 0 0\n", "empty line instead of charge")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0\nH 0 0 0\n", "charge without multiplicity")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1 0\nH 0 0 0\n", "odd charge list")
            try giThrows("# hf/sto-3g\n\ntitle\n\na b\nH 0 0 0\n", "non-numeric charge")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 0\nH 0 0 0\n", "multiplicity 0")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\n", "no geometry")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\n\nH 0 0 0\n", "blank geometry")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0\n", "two coordinates")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 0 0 0\n", "five numbers")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 abc\n", "bad number")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 nan\n", "nan")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 1e999\n", "inf")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nZz 0 0 0\n", "unknown element")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\n1.5 0 0 0\n", "numeric element")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 0\nH\n", "bare atom after first")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH\n\n--Link1--\n", "empty second step")
            try giThrows("# hf/sto-3g\n\ntitle\n\n0 1\nH 0 0 0\n\n--Link1--\n\n", "blank second step")
            try giThrows(ok + "--Link1--\n# hf\n\nt\n\n0 1\nH 0 0\n", "malformed second step")
            // errors carry line numbers
            do { _ = try GaussianInputReader.parse("# hf\n\nt\n\n0 1\nH 0 0 0\nH 0 oops 1\n\n"); throw CheckFailure(description: "no throw") }
            catch let e as MolIOError {
                guard case .parse(_, let line, _) = e else { throw CheckFailure(description: "wrong error \(e)") }
                try expect(line == 7, "line number \(String(describing: line))")
            }
        },
        Check("io.gjf.truncated") {
            for f in giFixtures {
                let text = try giText(f)
                let chars = Array(text)
                var cut = 0
                // never crash on any prefix
                while cut <= chars.count {
                    _ = try? GaussianInputReader.parse(String(chars[0..<cut]))
                    cut += 3
                }
                _ = try? GaussianInputReader.parse(String(chars.dropLast()))
            }
            // Cut points before the end of the charge line must throw (unless the step legitimately ends there).
            let text = try giText("input_water_optfreq.gjf")
            let chargeEnd = text.range(of: "0 1\n")!.upperBound
            let chars = text[..<chargeEnd]
            var idx = chars.startIndex
            while idx < chargeEnd {
                let pre = String(text[..<idx])
                if pre.contains("#") {
                    try giThrows(pre, "water fixture truncated at \(pre.count)")
                }
                idx = text.index(after: idx)
            }
            // cut inside the first atom line (two coordinates) must throw
            let cutAtom = text.range(of: "0.000000    0.000000    0.117790")!.lowerBound
            let partial = String(text[..<cutAtom]) + "0.000000"
            try giThrows(partial, "cut inside first atom line")
            // truncated Z-matrix inside variables
            let zt = try giText("input_zmat_variables.gjf")
            let cutV = zt.range(of: "Variables:")!.lowerBound
            try giThrows(String(zt[..<cutV]), "z-matrix without its variables")
            // truncated connectivity: missing section
            let ct = try giText("input_connectivity.gjf")
            let cutC = ct.range(of: "1 2 2.0")!.lowerBound
            try giThrows(String(ct[..<cutC]), "connectivity cut")
            // truncated link1 second step with route only but no geometry
            try giThrows("# hf\n\nt\n\n0 1\nH 0 0 0\n\n--Link1--\n# hf geom=check\n\ntitle\n", "check step without charge")
        },
        Check("io.gjf.large.cartesian") {
            let n = 20000
            let (text, pos) = giBigInput(n)
            let t0 = Date()
            let jobs = try GaussianInputReader.parse(text)
            let dt = Date().timeIntervalSince(t0)
            try expect(dt < 15, "parse took \(dt)s")
            try expect(jobs.count == 1 && jobs[0].molecule.atoms.count == n && jobs[0].atomSpecs.count == n)
            let a = jobs[0].molecule.atoms
            try expect(a[0].atomicNumber == 6 && a[1].atomicNumber == 1 && a[4].atomicNumber == 17 && a[n - 1].id == n - 1)
            for k in stride(from: 0, to: n, by: 997) { try expect(giDist(a[k].position, pos[k]) < 1e-6, "atom \(k)") }
            let out = GaussianInputWriter.write(jobs)
            let again = try GaussianInputReader.parse(out)
            try giSameJob(jobs[0], again[0])
            let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
            let crlfN = try GaussianInputReader.parse(crlf)[0].molecule.atoms.count
            try expect(crlfN == n)
        },
        Check("io.gjf.large.connectivityAndZmatrix") {
            let n = 20000
            let (text, _) = giBigInput(n, connectivity: true)
            let j = try GaussianInputReader.parse(text)[0]
            try expect(j.molecule.atoms.count == n && j.molecule.bonds.count == n - 1)
            let again = try GaussianInputReader.parse(j.inputText)[0]
            try expect(again.molecule.bonds.count == n - 1)
            // long chain Z-matrix: every bond 1.5, angle 110, alternating dihedral 180
            var z = "# hf/sto-3g\n\nchain\n\n0 1\nC\nC 1 1.5\nC 2 1.5 1 110.0\n"
            for i in 4...5000 { z += "C \(i - 1) 1.5 \(i - 2) 110.0 \(i - 3) 180.0\n" }
            z += "\n"
            let t0 = Date()
            let zj = try GaussianInputReader.parse(z)[0]
            try expect(Date().timeIntervalSince(t0) < 15)
            let p = zj.molecule.atoms.map { $0.position }
            try expect(p.count == 5000)
            for k in stride(from: 3, to: 5000, by: 499) {
                try expectClose(giDist(p[k], p[k - 1]), 1.5, tol: 1e-6)
                try expectClose(giAngle(p[k], p[k - 1], p[k - 2]), 110, tol: 1e-6)
                try expectClose(abs(giDihedral(p[k], p[k - 1], p[k - 2], p[k - 3])), 180, tol: 1e-4)
            }
            try giSameJob(zj, try GaussianInputReader.parse(zj.inputText)[0], tol: 1e-6)
        },
    ]
}
