import Foundation
import MolCore
@testable import MolIO

// I/O team checks (Lead 2). Sub-arrays live in IOChecks+<Area>.swift, one per worker.
extension Checks {
    static let io: [Check] = ioCommon + ioGaussianInput + ioGaussianOutput + ioFormats + ioOrca + ioXTB + ioMolden + ioQChem + ioCalcSpec + ioDetect + ioRunInfo

    static let ioCommon: [Check] = [
        Check("io.common.elements") {
            try expect(IOElements.atomicNumber(label: "C1") == 6)
            try expect(IOElements.atomicNumber(label: "Cl-CL-0.1") == 17)
            try expect(IOElements.atomicNumber(label: "8") == 8)
            try expect(IOElements.symbol(26) == "Fe")
        },
        Check("io.common.fortranDouble") {
            try expectClose(parseFortranDouble("1.5D-02")!, 0.015)
        },
        Check("io.basis.counts") {
            let sp = BasisSet.Shell(atomIndex: 0, center: .zero, angularMomentum: 1, isSP: true, isPure: false, exponents: [1], coefficients: [1], spCoefficients: [1])
            let d5 = BasisSet.Shell(atomIndex: 0, center: .zero, angularMomentum: 2, isPure: true, exponents: [1], coefficients: [1])
            let f10 = BasisSet.Shell(atomIndex: 0, center: .zero, angularMomentum: 3, isPure: false, exponents: [1], coefficients: [1])
            let b = BasisSet(shells: [sp, d5, f10])
            try expect(b.functionCount == 19 && b.shellOffsets == [0, 4, 9])
            try expect(BasisSet.cartesianOrder(4).count == 15 && BasisSet.pureOrder(2) == [0, 1, -1, 2, -2])
        },
    ]
}
