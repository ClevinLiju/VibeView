import Foundation
import MolCore
import MolIO

// Calculation-setup extraction (CalculationInfo) from real ORCA 6.1.1 outputs in TestData/io/orca/.

fileprivate func orcaInfo(_ name: String) throws -> CalculationInfo {
    let out = try OrcaOutput.parse(try readText(testDataURL("io/orca/" + name)))
    guard let info = out.result.extras?.info else { throw CheckFailure(description: "\(name): no info") }
    return info
}

extension Checks {
    static let ioRunInfo: [Check] = [
        Check("io.orca.info.dft_optfreq") {
            let i = try orcaInfo("h2co_optfreq.out")
            try expect(i.method == "B3LYP", "method \(String(describing: i.method))")
            try expect(i.methodFamily == "DFT")
            try expect(i.basisSet == "def2-SVP", "basis \(String(describing: i.basisSet))")
            try expect(i.auxiliaryBasis == "def2/J", "aux \(String(describing: i.auxiliaryBasis))")
            try expect(i.jobTypes == ["Optimization", "Frequencies"], "jobs \(i.jobTypes)")
            try expect(i.exchangeFunctional == "B88" && i.correlationFunctional == "LYP")
            try expectClose(i.exactExchange ?? -1, 0.2)
            try expect(i.reference == "RKS", "ref \(String(describing: i.reference))")
            try expect(i.charge == 0 && i.multiplicity == 1 && i.electrons == 16 && i.basisFunctions == 38)
            try expect(i.cores == 1, "cores \(String(describing: i.cores))")
            try expectClose(i.wallTimeSeconds ?? -1, 57.742, tol: 1e-6)
            try expect(i.solvationModel == nil && i.solvationLabel == "Gas phase")
            try expect(i.levelOfTheory == "B3LYP/def2-SVP", "lot \(String(describing: i.levelOfTheory))")
            try expect(i.keywords == ["! B3LYP def2-SVP Opt Freq"], "keywords \(i.keywords)")
        },
        Check("io.orca.info.tddft_smd") {
            let i = try orcaInfo("water_td_smd.out")
            try expect(i.method == "B3LYP" && i.basisSet == "STO-3G")
            try expect(i.solvationModel == "SMD", "model \(String(describing: i.solvationModel))")
            try expect(i.solvent == "water", "solvent \(String(describing: i.solvent))")
            try expect(i.solvationLabel == "SMD (water)")
            try expectClose(i.dielectric ?? -1, 78.355, tol: 1e-3)
            try expect(i.jobTypes == ["TD-DFT (3 roots)"], "jobs \(i.jobTypes)")
            try expect(i.memoryPerCoreMB == 1000, "maxcore \(String(describing: i.memoryPerCoreMB))")
        },
        Check("io.orca.info.uhf_and_hf") {
            let u = try orcaInfo("oh_uhf.out")
            try expect(u.method == "HF" && u.methodFamily == "HF", "method \(String(describing: u.method))")
            try expect(u.reference == "UHF" && u.multiplicity == 2, "ref \(String(describing: u.reference)) mult \(String(describing: u.multiplicity))")
            try expect(u.exchangeFunctional == nil && u.exactExchange == nil)
            try expect(u.jobTypes == ["Single point"], "jobs \(u.jobTypes)")
            let w = try orcaInfo("water_optfreq.out")
            try expect(w.method == "HF" && w.reference == "RHF" && w.basisSet == "STO-3G")
            try expect(w.jobTypes == ["Optimization", "Frequencies"])
        },
        Check("io.orca.info.scan") {
            let i = try orcaInfo("water_scan.out")
            try expect(i.jobTypes.first == "Relaxed scan", "jobs \(i.jobTypes)")
        },
        Check("io.orca.info.keyword_forms") {
            // Synthetic input echo: composite method, dispersion, keyword solvation, PAL, grid.
            let lines = ["! r2SCAN-3c TightOpt Freq CPCM(toluene) PAL8 DEFGRID3", "%maxcore 3000"]
            let i = OrcaOutput.runInfo(text: "", inputLines: lines, keywordLines: [lines[0]])
            try expect(i.method == "r2SCAN-3c" && i.methodFamily == "Composite")
            try expect(i.levelOfTheory == "r2SCAN-3c", "composite carries its own basis: \(String(describing: i.levelOfTheory))")
            try expect(i.solvationModel == "CPCM" && i.solvent == "toluene")
            try expect(i.cores == 8 && i.memoryPerCoreMB == 3000 && i.integrationGrid == "DEFGRID3")
            try expect(i.jobTypes == ["Optimization", "Frequencies"])
            let d = OrcaOutput.runInfo(text: "", inputLines: [], keywordLines: ["! wB97X-D3 def2-TZVP D3BJ RIJCOSX def2/J"])
            try expect(d.method == "wB97X-D3" && d.basisSet == "def2-TZVP" && d.dispersion == "D3BJ")
            try expect(d.approximations == ["RIJCOSX"] && d.auxiliaryBasis == "def2/J")
            try expect(d.levelOfTheory == "wB97X-D3-D3BJ/def2-TZVP")
        },
        Check("io.orca.info.truncated_never_crashes") {
            let text = try readText(testDataURL("io/orca/h2co_optfreq.out"))
            let L = text.components(separatedBy: "\n")
            for cut in stride(from: 0, to: L.count, by: max(1, L.count / 40)) {
                let part = L.prefix(cut).joined(separator: "\n")
                _ = OrcaOutput.runInfo(text: part, inputLines: [], keywordLines: [])
                if let o = try? OrcaOutput.parse(part) { _ = o.result.extras?.info }
            }
        },
        Check("io.orca.info.run_time_parse") {
            try expectClose(OrcaOutput.totalRunTime("TOTAL RUN TIME: 1 days 2 hours 3 minutes 4 seconds 500 msec") ?? -1, 93784.5)
            try expect(OrcaOutput.totalRunTime("no timing here") == nil)
        },
    ]
}
