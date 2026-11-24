import Foundation
import MolCore
import MolAnalysis

// Lead 5 (Analysis). Check names all start with "analysis." so `molscope-check analysis` selects them.
// Sub-suites live in AnalysisChecks+Surface.swift, AnalysisChecks+Orbitals.swift, AnalysisChecks+Spectra.swift.
extension Checks {
    static let analysis: [Check] = analysisTypes + analysisSurface + analysisOrbitals + analysisSpectra + analysisRealData

    static let analysisTypes: [Check] = [
        Check("analysis.types.shellCounts") {
            let s = AnalysisShell(center: .zero, atomIndex: 0, l: 2, pure: true, exponents: [1], coefficients: [1])
            try expect(s.functionCount == 5)
            var c = s; c.pure = false
            try expect(c.functionCount == 6 && c.fchkShellType == 2 && s.fchkShellType == -2)
            let sp = AnalysisShell(center: .zero, atomIndex: 0, l: 1, pure: false, exponents: [1], coefficients: [1], spCoefficients: [1])
            try expect(sp.functionCount == 4 && sp.fchkShellType == -1)
        },
        Check("analysis.types.units") {
            try expectClose(EnergyUnit.kcalPerMol.fromHartree, 627.509474)
        },
    ]
}
