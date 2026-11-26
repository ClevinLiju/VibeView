import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Thin wrappers over the handful of Accelerate kernels MolAnalysis uses. On Apple platforms they forward to
/// vDSP / vForce / BLAS (unchanged behaviour); elsewhere they run portable pure-Swift loops over raw pointers.
enum PortableLA {

    /// Σ a[i]·b[i].
    @inline(__always)
    static func dot(_ a: UnsafePointer<Double>, _ b: UnsafePointer<Double>, count n: Int) -> Double {
        #if canImport(Accelerate)
        var s = 0.0
        vDSP_dotprD(a, 1, b, 1, &s, vDSP_Length(n))
        return s
        #else
        // Four independent accumulators: lets the optimiser vectorise and limits rounding drift.
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0
        var i = 0
        while i + 4 <= n {
            s0 += a[i] * b[i]; s1 += a[i + 1] * b[i + 1]; s2 += a[i + 2] * b[i + 2]; s3 += a[i + 3] * b[i + 3]
            i += 4
        }
        while i < n { s0 += a[i] * b[i]; i += 1 }
        return (s0 + s1) + (s2 + s3)
        #endif
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count)
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            guard let x = pa.baseAddress, let y = pb.baseAddress else { return 0 }
            return dot(x, y, count: pa.count)
        } }
    }

    /// One Gaussian primitive of a contracted radial part:
    /// `e = exp(-alpha·r2)`, `rad += c·e`, and if `srad` is given `srad += cs·e`. `tmp` is n-long scratch.
    @inline(__always)
    static func accumulateGaussian(r2: UnsafePointer<Double>, alpha: Double, count n: Int, tmp: UnsafeMutablePointer<Double>,
                                   c: Double, rad: UnsafeMutablePointer<Double>,
                                   cs: Double = 0, srad: UnsafeMutablePointer<Double>? = nil) {
        #if canImport(Accelerate)
        var na = -alpha, cnt = Int32(n), cc = c
        vDSP_vsmulD(r2, 1, &na, tmp, 1, vDSP_Length(n))
        vvexp(tmp, tmp, &cnt)
        vDSP_vsmaD(tmp, 1, &cc, rad, 1, rad, 1, vDSP_Length(n))
        if let srad { var ccs = cs; vDSP_vsmaD(tmp, 1, &ccs, srad, 1, srad, 1, vDSP_Length(n)) }
        #else
        let na = -alpha
        if let srad {
            for t in 0..<n { let e = exp(na * r2[t]); tmp[t] = e; rad[t] += c * e; srad[t] += cs * e }
        } else {
            for t in 0..<n { let e = exp(na * r2[t]); tmp[t] = e; rad[t] += c * e }
        }
        #endif
    }

    /// Row-major `C(m×n) = A(m×k) · B(k×n)` (alpha = 1, beta = 0), i.e.
    /// `cblas_dgemm(RowMajor, NoTrans, NoTrans, m, n, k, 1, A, lda, B, ldb, 0, C, ldc)`.
    static func gemm(m: Int, n: Int, k: Int,
                     _ A: UnsafePointer<Double>, lda: Int,
                     _ B: UnsafePointer<Double>, ldb: Int,
                     _ C: UnsafeMutablePointer<Double>, ldc: Int) {
        guard m > 0, n > 0 else { return }
        #if canImport(Accelerate)
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(m), Int32(n), Int32(k),
                    1, A, Int32(lda), B, Int32(ldb), 0, C, Int32(ldc))
        #else
        for i in 0..<m { (C + i * ldc).update(repeating: 0, count: n) }
        guard k > 0 else { return }
        if n == 1 {
            // Matrix-vector: one dot product per row (B is a column with stride ldb).
            if ldb == 1 {
                for i in 0..<m { C[i * ldc] = dot(A + i * lda, B, count: k) }
            } else {
                for i in 0..<m {
                    let a = A + i * lda
                    var s = 0.0
                    for p in 0..<k { let v = a[p]; if v != 0 { s += v * B[p * ldb] } }
                    C[i * ldc] = s
                }
            }
            return
        }
        // i-p-j ordering (inner loop streams contiguous rows of B and C, vectorisable), blocked over p and j so a
        // panel of B stays in L2 while every row of A is applied to it. Zero entries of A are skipped: basis-value
        // matrices are mostly zero outside the shell cutoffs, which makes this far cheaper than a dense product.
        let kBlock = 64
        let nBlock = 512
        var j0 = 0
        while j0 < n {
            let jn = min(nBlock, n - j0)
            var p0 = 0
            while p0 < k {
                let p1 = min(k, p0 + kBlock)
                for i in 0..<m {
                    let a = A + i * lda
                    let c = C + i * ldc + j0
                    for p in p0..<p1 {
                        let av = a[p]
                        if av == 0 { continue }
                        let b = B + p * ldb + j0
                        for j in 0..<jn { c[j] += av * b[j] }
                    }
                }
                p0 = p1
            }
            j0 += jn
        }
        #endif
    }

    /// Array convenience for `gemm` with packed leading dimensions.
    static func gemm(m: Int, n: Int, k: Int, _ A: [Double], _ B: [Double], _ C: inout [Double]) {
        precondition(A.count >= m * k && B.count >= k * n && C.count >= m * n)
        A.withUnsafeBufferPointer { pa in B.withUnsafeBufferPointer { pb in C.withUnsafeMutableBufferPointer { pc in
            guard let c = pc.baseAddress else { return }
            guard k > 0, let a = pa.baseAddress, let b = pb.baseAddress else {
                c.update(repeating: 0, count: m * n); return
            }
            gemm(m: m, n: n, k: k, a, lda: k, b, ldb: n, c, ldc: n)
        } } }
    }
}
