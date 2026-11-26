import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// The subset of `vDSP` used by the force-field minimiser, with the same call shapes. Forwards to Accelerate on
/// Apple platforms (unchanged behaviour) and uses plain Swift loops elsewhere.
enum VecOps {
    #if canImport(Accelerate)
    @inline(__always) static func multiply(_ a: [Double], _ b: [Double], result: inout [Double]) { vDSP.multiply(a, b, result: &result) }
    @inline(__always) static func multiply(_ s: Double, _ v: [Double]) -> [Double] { vDSP.multiply(s, v) }
    @inline(__always) static func add(_ a: [Double], _ b: [Double]) -> [Double] { vDSP.add(a, b) }
    @inline(__always) static func subtract(_ a: [Double], _ b: [Double]) -> [Double] { vDSP.subtract(a, b) }
    @inline(__always) static func dot(_ a: [Double], _ b: [Double]) -> Double { vDSP.dot(a, b) }
    @inline(__always) static func sumOfSquares(_ v: [Double]) -> Double { vDSP.sumOfSquares(v) }
    @inline(__always) static func maximumMagnitude(_ v: [Double]) -> Double { vDSP.maximumMagnitude(v) }
    #else
    static func multiply(_ a: [Double], _ b: [Double], result: inout [Double]) {
        precondition(a.count == b.count && result.count == a.count)
        for i in result.indices { result[i] = a[i] * b[i] }
    }
    static func multiply(_ s: Double, _ v: [Double]) -> [Double] { v.map { s * $0 } }
    static func add(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count)
        return [Double](unsafeUninitializedCapacity: a.count) { buf, n in
            for i in 0..<a.count { buf[i] = a[i] + b[i] }
            n = a.count
        }
    }
    static func subtract(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count)
        return [Double](unsafeUninitializedCapacity: a.count) { buf, n in
            for i in 0..<a.count { buf[i] = a[i] - b[i] }
            n = a.count
        }
    }
    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count)
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }
    static func sumOfSquares(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
    static func maximumMagnitude(_ v: [Double]) -> Double { v.reduce(0) { max($0, abs($1)) } }
    #endif
}
