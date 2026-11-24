import Foundation
import MolCore
import MolIO

// Calculation-setup extraction (CalculationInfo) for Gaussian logs, Q-Chem outputs and xtb outputs.

fileprivate func gInfo(_ route: String, extra: String = "") -> CalculationInfo {
    let text = "\(extra)\n ----------------------\n \(route)\n ----------------------\n"
    return GaussianLog.runInfo(text: text)
}

fileprivate func qInfo(_ text: String) -> CalculationInfo {
    QChemOutput.runInfo(lines: text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
}

fileprivate func xInfo(_ text: String) -> CalculationInfo {
    XTBOutput.runInfo(lines: text.components(separatedBy: "\n"))
}

extension Checks {
    static let ioRunInfo2: [Check] = [
        // MARK: Gaussian
        Check("io.gaussian.info.fixture") {
            let log = try GaussianLog.parse(try readText(testDataURL("io/gaussian/water_optfreq_td.log")))
            guard let i = log.result.extras?.info else { throw CheckFailure(description: "no info") }
            try expect(i.method == "HF" && i.methodFamily == "HF", "method \(String(describing: i.method))")
            try expect(i.basisSet == "STO-3G", "basis \(String(describing: i.basisSet))")
            try expect(i.reference == "RHF", "ref \(String(describing: i.reference))")
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expect(i.charge == 0 && i.multiplicity == 1)
            try expect(i.keywords.count == 2 && i.keywords[0] == "#p hf/sto-3g opt freq", "kw \(i.keywords)")
            try expect(i.solvationModel == nil && i.solvationLabel == "Gas phase")
            try expect(i.levelOfTheory == "HF/STO-3G", "lot \(String(describing: i.levelOfTheory))")
        },
        Check("io.gaussian.info.dft_full_route") {
            let text = """
             %nprocshared=4
             %mem=8GB
             ----------------------
             #p ub3lyp/6-31+g(d,p) opt=(calcfc,ts) freq scrf=(smd,solvent=toluene) empiricaldispersion=gd3bj int=ultrafine td=(nstates=5)
             ----------------------
             Charge =  1 Multiplicity = 2
             NBasis=   120 NAE=9 NBE=8
                 9 alpha electrons        8 beta electrons
             SCF Done:  E(UB3LYP) =  -100.5  A.U. after 10 cycles
             Elapsed time:       0 days  0 hours  1 minutes 23.4 seconds.
            """
            let i = GaussianLog.runInfo(text: text)
            try expect(i.method == "B3LYP" && i.methodFamily == "DFT", "method \(String(describing: i.method))")
            try expect(i.basisSet == "6-31+G(d,p)", "basis \(String(describing: i.basisSet))")
            try expect(i.jobTypes == ["Transition state", "Frequencies", "TD-DFT (5 states)"], "jobs \(i.jobTypes)")
            try expect(i.solvationModel == "SMD" && i.solvent == "toluene", "solv \(i.solvationLabel)")
            try expect(i.dispersion == "D3BJ" && i.integrationGrid == "UltraFine")
            try expect(i.cores == 4 && i.memoryPerCoreMB == 2048, "cores \(String(describing: i.cores)) mem \(String(describing: i.memoryPerCoreMB))")
            try expect(i.charge == 1 && i.multiplicity == 2 && i.basisFunctions == 120 && i.electrons == 17)
            try expect(i.reference == "UKS", "ref \(String(describing: i.reference))")
            try expectClose(i.wallTimeSeconds ?? -1, 83.4, tol: 1e-6)
        },
        Check("io.gaussian.info.wrapped_route") {
            let text = """
             ----------------------------------------------------------------------
             #p b3lyp/6-31g(d) opt scrf=(smd,
             solvent=water) freq
             ----------------------------------------------------------------------
            """
            let i = GaussianLog.runInfo(text: text)
            try expect(i.solvationModel == "SMD" && i.solvent == "water", "solv \(i.solvationLabel)")
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expect(i.keywords == ["#p b3lyp/6-31g(d) opt scrf=(smd,solvent=water) freq"], "kw \(i.keywords)")
        },
        Check("io.gaussian.info.print_levels") {
            for pre in ["#", "#P", "#N", "#T", "#p"] {
                let i = gInfo("\(pre) B3LYP/6-31G(d)")
                try expect(i.method == "B3LYP" && i.basisSet == "6-31G(d)", "\(pre): \(String(describing: i.method)) \(String(describing: i.basisSet))")
                try expect(i.jobTypes == ["Single point"], "\(pre) jobs \(i.jobTypes)")
            }
        },
        Check("io.gaussian.info.scrf_defaults") {
            let a = gInfo("#n m062x/def2svp scrf")
            try expect(a.solvationModel == "PCM" && a.solvent == "water", "bare scrf: \(a.solvationLabel)")
            try expect(a.basisSet == "def2SVP" && a.method == "M062X", "basis \(String(describing: a.basisSet)) method \(String(describing: a.method))")
            let b = gInfo("#p b3lyp/6-31g scrf=cpcm")
            try expect(b.solvationModel == "CPCM" && b.solvent == "water")
            let c = gInfo("#p b3lyp/6-31g scrf=(iefpcm,solvent=methanol)")
            try expect(c.solvationModel == "PCM" && c.solvent == "methanol")
            let d = gInfo("#p b3lyp/6-31g scrf=(solvent=dmso)")
            try expect(d.solvationModel == "PCM" && d.solvent == "dmso")
            try expect(gInfo("#p b3lyp/6-31g").solvationModel == nil)
        },
        Check("io.gaussian.info.references") {
            try expect(gInfo("#p uhf/3-21g").reference == "UHF")
            try expect(gInfo("#p rohf/sto-3g").reference == "ROHF")
            try expect(gInfo("#p hf/sto-3g").reference == "RHF")
            let rb = gInfo("#p rb3lyp/6-31g")
            try expect(rb.method == "B3LYP" && rb.reference == "RKS", "rb3lyp: \(String(describing: rb.method)) \(String(describing: rb.reference))")
            let ub = gInfo("#p ub3lyp/6-31g")
            try expect(ub.method == "B3LYP" && ub.reference == "UKS")
            // No prefix and multiplicity 3: Gaussian goes unrestricted.
            let open = gInfo("#p b3lyp/6-31g", extra: " Charge =  0 Multiplicity = 3")
            try expect(open.reference == "UKS" && open.multiplicity == 3, "open shell: \(String(describing: open.reference))")
            let ohf = gInfo("#p hf/6-31g", extra: " Charge =  0 Multiplicity = 2")
            try expect(ohf.reference == "UHF")
            let roks = gInfo("#p rob3lyp/6-31g")
            try expect(roks.reference == "ROKS" && roks.method == "B3LYP", "ro: \(String(describing: roks.reference))")
        },
        Check("io.gaussian.info.families") {
            let mp2 = gInfo("#p mp2/cc-pvtz")
            try expect(mp2.methodFamily == "MP2" && mp2.basisSet == "cc-pVTZ" && mp2.reference == "RHF", "mp2: \(String(describing: mp2.basisSet))")
            let cc = gInfo("#p ccsd(t)/6-31g(d)")
            try expect(cc.methodFamily == "Coupled cluster" && cc.method == "CCSD(T)", "cc: \(String(describing: cc.method))")
            let pm6 = gInfo("#p pm6 opt")
            try expect(pm6.methodFamily == "Semiempirical" && pm6.method == "PM6" && pm6.basisSet == nil && pm6.reference == nil, "pm6")
            let wb = gInfo("#p wb97xd/def2tzvp")
            try expect(wb.method == "wB97XD" && wb.methodFamily == "DFT" && wb.dispersion == nil, "wb97xd: \(String(describing: wb.method))")
            let gen = gInfo("#p b3lyp/gen opt")
            try expect(gen.basisSet == "Gen", "gen \(String(describing: gen.basisSet))")
        },
        Check("io.gaussian.info.job_types") {
            try expect(gInfo("#p b3lyp/6-31g opt=ts freq").jobTypes == ["Transition state", "Frequencies"])
            try expect(gInfo("#p b3lyp/6-31g td").jobTypes == ["TD-DFT (3 states)"])
            try expect(gInfo("#p b3lyp/6-31g irc=(calcfc,maxpoints=20) nmr").jobTypes == ["IRC", "NMR"])
            try expect(gInfo("#p b3lyp/6-31g scan").jobTypes == ["Scan"])
            try expect(gInfo("#p b3lyp/6-31g opt=modredundant").jobTypes == ["Optimization"])
            let scan = gInfo("#p b3lyp/6-31g opt=modredundant",
                             extra: " The following ModRedundant input section has been read:\n D       1       2       3       4 S   10 10.0000")
            try expect(scan.jobTypes == ["Scan"], "scan: \(scan.jobTypes)")
            try expect(gInfo("#p b3lyp/6-31g freq=raman opt").jobTypes == ["Frequencies", "Optimization"], "route order")
        },
        Check("io.gaussian.info.dispersion_forms") {
            try expect(gInfo("#p b3lyp/6-31g empiricaldispersion=gd3").dispersion == "D3")
            try expect(gInfo("#p b3lyp/6-31g empiricaldispersion=gd2").dispersion == "D2")
            try expect(gInfo("#p b3lyp/6-31g empiricaldispersion=pfd").dispersion == "PFD")
            try expect(gInfo("#p b3lyp/6-31g EmpiricalDispersion=GD3BJ").dispersion == "D3BJ")
            try expect(gInfo("#p b3lyp/6-31g").dispersion == nil)
            try expect(gInfo("#p b3lyp/6-31g integral(grid=99590)").integrationGrid == "99590")
            try expect(gInfo("#p b3lyp/6-31g int=(grid=ultrafine)").integrationGrid == "UltraFine")
        },
        Check("io.gaussian.info.link0_memory") {
            let a = gInfo("#p hf/sto-3g", extra: " %nproc=2\n %mem=1000MB")
            try expect(a.cores == 2 && a.memoryPerCoreMB == 500, "a: \(String(describing: a.memoryPerCoreMB))")
            let b = gInfo("#p hf/sto-3g", extra: " %mem=64MW")
            try expect(b.cores == nil && b.memoryPerCoreMB == 512, "words: \(String(describing: b.memoryPerCoreMB))")
            try expect(gInfo("#p hf/sto-3g").memoryPerCoreMB == nil)
        },
        Check("io.gaussian.info.multi_step_time") {
            let text = """
             ----------------------
             #p b3lyp/6-31g opt
             ----------------------
             Charge =  0 Multiplicity = 1
             Job cpu time:       0 days  0 hours  1 minutes  0.0 seconds.
             Elapsed time:       0 days  0 hours  1 minutes 10.5 seconds.
             Link1:  Proceeding to internal job step number  2.
             ----------------------
             #p b3lyp/6-31g freq geom=allcheck
             ----------------------
             Elapsed time:       0 days  0 hours  0 minutes 20.0 seconds.
             Elapsed time:       0 days  1 hours  0 minutes  0.5 seconds.
            """
            let i = GaussianLog.runInfo(text: text)
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expectClose(i.wallTimeSeconds ?? -1, 70.5 + 20 + 3600.5, tol: 1e-6)
            try expect(i.keywords.count == 2)
        },
        Check("io.gaussian.info.truncated_never_crashes") {
            let text = try readText(testDataURL("io/gaussian/water_optfreq_td.log"))
            let L = text.components(separatedBy: "\n")
            for cut in stride(from: 0, to: L.count, by: 3) {
                _ = GaussianLog.runInfo(text: L.prefix(cut).joined(separator: "\n"))
            }
            _ = GaussianLog.runInfo(text: "")
            _ = gInfo("#")
            _ = gInfo("#p /")
            _ = gInfo("#p scrf=( td=(nstates=")
            _ = gInfo("#p oniom(b3lyp/6-31g:uff) opt")
        },

        // MARK: Q-Chem
        Check("io.qchem.info.optfreq_fixture") {
            let o = try QChemOutput.parse(try readText(testDataURL("io/qchem/water_optfreq.out")))
            guard let i = o.result.extras?.info else { throw CheckFailure(description: "no info") }
            try expect(i.method == "B3LYP" && i.methodFamily == "DFT", "method \(String(describing: i.method))")
            try expect(i.basisSet == "def2-SVP", "basis \(String(describing: i.basisSet))")
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expect(i.charge == 0 && i.multiplicity == 1 && i.electrons == 10, "charge/mult/electrons")
            try expect(i.reference == "RKS", "ref \(String(describing: i.reference))")
            try expectClose(i.wallTimeSeconds ?? -1, 1.23, tol: 1e-9)
            try expect(i.levelOfTheory == "B3LYP/def2-SVP")
            try expect(i.solvationModel == nil)
        },
        Check("io.qchem.info.tddft_fixture") {
            let o = try QChemOutput.parse(try readText(testDataURL("io/qchem/h2co_tddft.out")))
            guard let i = o.result.extras?.info else { throw CheckFailure(description: "no info") }
            try expect(i.method == "PBE0" && i.basisSet == "def2-SVP", "level \(String(describing: i.levelOfTheory))")
            try expect(i.jobTypes == ["Single point", "TD-DFT (2 roots)"], "jobs \(i.jobTypes)")
        },
        Check("io.qchem.info.smd_unrestricted_ts") {
            let text = """
             Q-Chem 6.2, Q-Chem, Inc.
             $molecule
             1 2
             O 0 0 0
             $end

             $rem
             Jobtype ts
             Method  wB97X-D
             Basis   6-31+g(d)
             SOLVENT_METHOD smd
             DFT_D D3_BJ
             UNRESTRICTED true
             $end

             $smx
             solvent water
             $end
             There are      12 shells and      62 basis functions
             There are       9 alpha and       8 beta electrons
             Total job time:  10.50s(wall), 40.00s(cpu)
            """
            let i = qInfo(text)
            try expect(i.method == "WB97X-D" && i.methodFamily == "DFT", "method \(String(describing: i.method))")
            try expect(i.basisSet == "6-31+G(d)", "basis \(String(describing: i.basisSet))")
            try expect(i.jobTypes == ["Transition state"], "jobs \(i.jobTypes)")
            try expect(i.solvationModel == "SMD" && i.solvent == "water", "solv \(i.solvationLabel)")
            try expect(i.dispersion == "D3BJ", "disp \(String(describing: i.dispersion))")
            try expect(i.reference == "UKS" && i.charge == 1 && i.multiplicity == 2)
            try expect(i.basisFunctions == 62 && i.electrons == 17, "counts")
            try expectClose(i.wallTimeSeconds ?? -1, 10.5, tol: 1e-9)
        },
        Check("io.qchem.info.pcm_and_hf") {
            let cp = qInfo("""
             $molecule
             0 1
             $end
             $rem
             JOBTYPE sp
             METHOD hf
             BASIS cc-pvdz
             SOLVENT_METHOD pcm
             $end
             $pcm
             theory cpcm
             $end
             $solvent
             SolventName acetonitrile
             Dielectric 35.69
             $end
            """)
            try expect(cp.method == "HF" && cp.methodFamily == "HF" && cp.reference == "RHF", "hf: \(String(describing: cp.reference))")
            try expect(cp.basisSet == "cc-pVDZ", "basis \(String(describing: cp.basisSet))")
            try expect(cp.solvationModel == "CPCM" && cp.solvent == "acetonitrile", "solv \(cp.solvationLabel)")
            try expectClose(cp.dielectric ?? -1, 35.69, tol: 1e-9)
            let ex = qInfo("$rem\n EXCHANGE pbe\n CORRELATION pbe\n BASIS sto-3g\n JOBTYPE force\n$end")
            try expect(ex.methodFamily == "DFT" && ex.method == "PBE" && ex.jobTypes == ["Gradient"], "exchange: \(String(describing: ex.method)) \(ex.jobTypes)")
        },
        Check("io.qchem.info.job_kinds_and_robustness") {
            for (jt, name) in [("opt", "Optimization"), ("freq", "Frequencies"), ("sp", "Single point"), ("force", "Gradient"), ("rpath", "IRC")] {
                let i = qInfo("$rem\nJOBTYPE \(jt)\nMETHOD b3lyp\nBASIS 6-31g\n$end")
                try expect(i.jobTypes == [name], "\(jt): \(i.jobTypes)")
            }
            // Case-insensitive keys, "key = value" form, and comments.
            let i = qInfo("$REM\nJobType = opt ! geometry\nmethod = PBE0\nBASIS = def2-tzvp\n$END")
            try expect(i.method == "PBE0" && i.basisSet == "def2-TZVP" && i.jobTypes == ["Optimization"], "mixed: \(String(describing: i.basisSet))")
            _ = qInfo("")
            _ = qInfo("$rem")
            _ = qInfo("$molecule\n$rem\nmethod\n$end $end")
            let text = try readText(testDataURL("io/qchem/water_optfreq.out"))
            let L = text.components(separatedBy: "\n")
            for cut in stride(from: 0, to: L.count, by: 5) { _ = qInfo(L.prefix(cut).joined(separator: "\n")) }
        },

        // MARK: xtb
        Check("io.xtb.info.fixture") {
            let o = try XTBOutput.parse(try readText(testDataURL("io/xtb/xtb_water.out")))
            guard let i = o.result.extras?.info else { throw CheckFailure(description: "no info") }
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expect(i.solvationModel == nil && i.solvationLabel == "Gas phase")
            try expect(i.basisSet == nil && i.wallTimeSeconds == nil)
        },
        Check("io.xtb.info.alpb_gfn2") {
            let text = """
               * xtb version 6.7.1 (edcfbbe) compiled by 'conda' on 2024-05-14
                   program call               : xtb coord --opt --gfn 2 --alpb water --chrg 0 --uhf 0
               * Using 4 OpenMP threads
                   :  # basis functions                   6          :
                   :  # electrons                         8          :
                   :  net charge                           0          :
                   :  unpaired electrons                   0          :
               * Solvation model:               ALPB
               Solvent                        water
               Parameter file                 internal GFN2-xTB/ALPB
               Dielectric constant                80.1000
               *** GEOMETRY OPTIMIZATION CONVERGED AFTER 5 ITERATIONS ***
               total:
               * wall-time:     0 d,  0 h,  1 min,  2.250 sec
            """
            let i = xInfo(text)
            try expect(i.method == "GFN2-xTB" && i.methodFamily == "Semiempirical" && i.basisSet == nil, "method \(String(describing: i.method))")
            try expect(i.solvationModel == "ALPB" && i.solvent == "water", "solv \(i.solvationLabel)")
            try expectClose(i.dielectric ?? -1, 80.1, tol: 1e-9)
            try expect(i.electrons == 8 && i.basisFunctions == 6 && i.charge == 0 && i.multiplicity == 1, "counts")
            try expect(i.cores == 4, "cores \(String(describing: i.cores))")
            try expect(i.jobTypes == ["Optimization"], "jobs \(i.jobTypes)")
            try expectClose(i.wallTimeSeconds ?? -1, 62.25, tol: 1e-9)
            try expect(i.keywords.count == 1 && i.keywords[0].hasPrefix("xtb coord --opt"), "kw \(i.keywords)")
        },
        Check("io.xtb.info.call_options") {
            let gbsa = xInfo("   * xtb version 6.5.0\n   program call               : xtb mol.xyz --gfn 1 --gbsa thf --chrg -1 --uhf 2 --ohess")
            try expect(gbsa.method == "GFN1-xTB", "gfn1 \(String(describing: gbsa.method))")
            try expect(gbsa.solvationModel == "GBSA" && gbsa.solvent == "thf", "solv \(gbsa.solvationLabel)")
            try expect(gbsa.charge == -1 && gbsa.multiplicity == 3, "charge/mult \(String(describing: gbsa.charge)) \(String(describing: gbsa.multiplicity))")
            try expect(gbsa.jobTypes == ["Optimization", "Frequencies"], "jobs \(gbsa.jobTypes)")
            let ff = xInfo("   * xtb version 6.6.0\n   program call               : xtb mol.xyz --gfnff")
            try expect(ff.method == "GFN-FF" && ff.methodFamily == "Force field" && ff.jobTypes == ["Single point"], "ff")
            let sp = xInfo("   * xtb version 6.6.0\n   :: total energy  -5.07 Eh ::")
            try expect(sp.method == nil && sp.jobTypes == ["Single point"])
        },
        Check("io.xtb.info.robust") {
            _ = xInfo("")
            _ = xInfo("program call :")
            _ = xInfo("* Solvation model:\nSolvent")
            _ = xInfo("* wall-time: ,,,")
            let text = try readText(testDataURL("io/xtb/xtb_water.out"))
            let L = text.components(separatedBy: "\n")
            for cut in stride(from: 0, to: L.count, by: 4) { _ = xInfo(L.prefix(cut).joined(separator: "\n")) }
        },
    ]
}
