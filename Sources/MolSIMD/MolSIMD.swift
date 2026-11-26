// MolSIMD: portable stand-in for Apple's `simd` module.
//
// On Apple platforms this file only re-exports `simd`, so behaviour there is byte-for-byte Apple's.
// Elsewhere (Windows, Linux) it provides a pure-Swift implementation of the subset of the simd API
// used by the portable modules (MolCore, MolIO, MolBuild, MolAnalysis, MolCompute, MolCommand,
// MolChecks non-render checks). Semantics follow Apple's headers (simd/geometry.h, simd/matrix.h,
// simd/quaternion.h): matrices are COLUMN-major, `m[c]` is column c, `m[c][r]` is row r of column c.
//
// API (non-Apple platforms):
//   Typealiases   simd_double2/3/4, simd_float2/3/4
//   Vectors       simd_dot, simd_length, simd_length_squared, simd_distance, simd_distance_squared,
//                 simd_normalize (zero vector -> NaN, like Apple), simd_cross (SIMD3, and SIMD2 -> SIMD3),
//                 simd_min, simd_max, simd_clamp, simd_abs, simd_mix, simd_reduce_add/min/max
//                 (vector and scalar overloads, Double and Float)
//   Matrices      simd_double3x3, simd_float3x3 (generic `MolSIMDMatrix3x3<Scalar>`):
//                 init(), init(_ scalar:), init(diagonal:), init(columns: (c0, c1, c2)), init(_ c0, _ c1, _ c2),
//                 init(_ columns: [SIMD3]), init(rows: [SIMD3]), init(_ quaternion:),
//                 .columns (tuple, get/set), subscript [column] and [column, row] (get/set),
//                 .transpose, .inverse, .determinant,
//                 + - (binary, unary), scalar * m, m * scalar, m * v, v * m, m * m, += -= *=, ==
//                 matrix_identity_double3x3, matrix_identity_float3x3,
//                 simd_transpose, simd_inverse, simd_determinant, simd_mul, simd_add, simd_sub,
//                 simd_diagonal_matrix, simd_matrix(_:_:_:), simd_matrix3x3(quat), simd_equal, simd_almost_equal_elements
//   Quaternions   simd_quatd, simd_quatf (generic `MolSIMDQuaternion<Scalar>`):
//                 init(), init(vector:), init(ix:iy:iz:r:), init(real:imag:), init(angle:axis:) (axis NOT
//                 normalized, exactly like Apple), init(from:to:), init(_ rotationMatrix3x3:)
//                 .vector, .real, .imag, .angle, .axis, .length, .normalized, .conjugate, .inverse, .act(_:)
//                 + - * (quat/quat, scalar), / scalar, ==,
//                 simd_quaternion(...) family, simd_act, simd_mul, simd_conjugate, simd_inverse,
//                 simd_normalize, simd_length, simd_dot, simd_angle, simd_axis, simd_real, simd_imag, simd_slerp

#if canImport(simd)
@_exported import simd
#else
import Foundation

// MARK: - Scalar support

/// Floating-point scalar usable in MolSIMD matrices / quaternions (Double and Float).
public protocol MolSIMDReal: BinaryFloatingPoint, SIMDScalar, Sendable {
    static func _molSin(_ x: Self) -> Self
    static func _molCos(_ x: Self) -> Self
    static func _molAcos(_ x: Self) -> Self
    static func _molAtan2(_ y: Self, _ x: Self) -> Self
}

extension Double: MolSIMDReal {
    @inlinable public static func _molSin(_ x: Double) -> Double { sin(x) }
    @inlinable public static func _molCos(_ x: Double) -> Double { cos(x) }
    @inlinable public static func _molAcos(_ x: Double) -> Double { acos(x) }
    @inlinable public static func _molAtan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) }
}

extension Float: MolSIMDReal {
    @inlinable public static func _molSin(_ x: Float) -> Float { sin(x) }
    @inlinable public static func _molCos(_ x: Float) -> Float { cos(x) }
    @inlinable public static func _molAcos(_ x: Float) -> Float { acos(x) }
    @inlinable public static func _molAtan2(_ y: Float, _ x: Float) -> Float { atan2(y, x) }
}

// MARK: - Typealiases

public typealias simd_double2 = SIMD2<Double>
public typealias simd_double3 = SIMD3<Double>
public typealias simd_double4 = SIMD4<Double>
public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>

// MARK: - Vector functions

@inlinable public func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
@inlinable public func simd_length_squared<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { (v * v).sum() }
@inlinable public func simd_length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { (v * v).sum().squareRoot() }
@inlinable public func simd_distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(a - b) }
@inlinable public func simd_distance_squared<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length_squared(a - b) }
/// `v * (1 / |v|)` (Apple's precise normalize). A zero vector yields NaN components, as on Apple.
@inlinable public func simd_normalize<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint {
    v * (1 / simd_length(v))
}
@inlinable public func simd_cross<S: SIMDScalar & FloatingPoint>(_ a: SIMD3<S>, _ b: SIMD3<S>) -> SIMD3<S> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inlinable public func simd_cross<S: SIMDScalar & FloatingPoint>(_ a: SIMD2<S>, _ b: SIMD2<S>) -> SIMD3<S> {
    SIMD3(0, 0, a.x * b.y - a.y * b.x)
}
@inlinable public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FloatingPoint { pointwiseMin(a, b) }
@inlinable public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FloatingPoint { pointwiseMax(a, b) }
@inlinable public func simd_min(_ a: Double, _ b: Double) -> Double { Swift.min(a, b) }
@inlinable public func simd_max(_ a: Double, _ b: Double) -> Double { Swift.max(a, b) }
@inlinable public func simd_min(_ a: Float, _ b: Float) -> Float { Swift.min(a, b) }
@inlinable public func simd_max(_ a: Float, _ b: Float) -> Float { Swift.max(a, b) }
@inlinable public func simd_clamp<V: SIMD>(_ x: V, _ lo: V, _ hi: V) -> V where V.Scalar: FloatingPoint {
    pointwiseMin(pointwiseMax(x, lo), hi)
}
@inlinable public func simd_clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(x, lo), hi) }
@inlinable public func simd_clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(x, lo), hi) }
@inlinable public func simd_abs<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint {
    var r = v
    for i in r.indices { r[i] = Swift.abs(v[i]) }
    return r
}
@inlinable public func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V where V.Scalar: FloatingPoint { a + t * (b - a) }
@inlinable public func simd_mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + t * (b - a) }
@inlinable public func simd_mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + t * (b - a) }
@inlinable public func simd_reduce_add<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { v.sum() }
@inlinable public func simd_reduce_min<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { v.min() }
@inlinable public func simd_reduce_max<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { v.max() }

// MARK: - 3x3 matrix (column-major)

public struct MolSIMDMatrix3x3<Scalar: MolSIMDReal>: Sendable {
    public typealias Column = SIMD3<Scalar>
    public var columns: (Column, Column, Column)

    /// Zero matrix (Apple: `simd_double3x3()` is all zeros).
    @inlinable public init() { columns = (.zero, .zero, .zero) }
    /// Scalar on the diagonal.
    @inlinable public init(_ scalar: Scalar) { self.init(diagonal: Column(repeating: scalar)) }
    @inlinable public init(diagonal d: Column) {
        columns = (Column(d.x, 0, 0), Column(0, d.y, 0), Column(0, 0, d.z))
    }
    @inlinable public init(columns: (Column, Column, Column)) { self.columns = columns }
    @inlinable public init(_ c0: Column, _ c1: Column, _ c2: Column) { columns = (c0, c1, c2) }
    /// Columns from an array (must have exactly 3 elements, like Apple).
    @inlinable public init(_ columns: [Column]) {
        precondition(columns.count == 3, "Requires array of 3 vectors.")
        self.columns = (columns[0], columns[1], columns[2])
    }
    @inlinable public init(rows: [Column]) {
        precondition(rows.count == 3, "Requires array of 3 vectors.")
        self.init(rows[0], rows[1], rows[2])
        self = self.transpose
    }
    /// Rotation matrix of a quaternion (Apple's simd_matrix3x3(q)).
    @inlinable public init(_ q: MolSIMDQuaternion<Scalar>) {
        let v = q.vector
        let xx = v.x * v.x, yy = v.y * v.y, zz = v.z * v.z
        let xy = v.x * v.y, xz = v.x * v.z, yz = v.y * v.z
        let xw = v.x * v.w, yw = v.y * v.w, zw = v.z * v.w
        columns = (Column(1 - 2 * (yy + zz), 2 * (xy + zw), 2 * (xz - yw)),
                   Column(2 * (xy - zw), 1 - 2 * (xx + zz), 2 * (yz + xw)),
                   Column(2 * (xz + yw), 2 * (yz - xw), 1 - 2 * (xx + yy)))
    }

    @inlinable public subscript(column: Int) -> Column {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: preconditionFailure("Column index out of range")
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: preconditionFailure("Column index out of range")
            }
        }
    }
    @inlinable public subscript(column: Int, row: Int) -> Scalar {
        get { self[column][row] }
        set { self[column][row] = newValue }
    }

    @inlinable public var transpose: MolSIMDMatrix3x3 {
        let (a, b, c) = columns
        return MolSIMDMatrix3x3(Column(a.x, b.x, c.x), Column(a.y, b.y, c.y), Column(a.z, b.z, c.z))
    }
    @inlinable public var determinant: Scalar {
        let (a, b, c) = columns
        return simd_dot(a, simd_cross(b, c))
    }
    /// Inverse via adjugate / determinant (a singular matrix gives non-finite entries, like Apple).
    @inlinable public var inverse: MolSIMDMatrix3x3 {
        let (a, b, c) = columns
        let r0 = simd_cross(b, c), r1 = simd_cross(c, a), r2 = simd_cross(a, b)
        let invDet = 1 / simd_dot(a, r0)
        // rows of the inverse are r0, r1, r2 (scaled)
        return MolSIMDMatrix3x3(rows: [r0 * invDet, r1 * invDet, r2 * invDet])
    }
}

public typealias simd_double3x3 = MolSIMDMatrix3x3<Double>
public typealias simd_float3x3 = MolSIMDMatrix3x3<Float>
public typealias matrix_double3x3 = simd_double3x3
public typealias matrix_float3x3 = simd_float3x3

public let matrix_identity_double3x3 = simd_double3x3(diagonal: SIMD3<Double>(1, 1, 1))
public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))

extension MolSIMDMatrix3x3: Equatable {
    @inlinable public static func == (l: MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) -> Bool {
        l.columns.0 == r.columns.0 && l.columns.1 == r.columns.1 && l.columns.2 == r.columns.2
    }
}

extension MolSIMDMatrix3x3: CustomDebugStringConvertible {
    public var debugDescription: String {
        "simd_\(Scalar.self == Double.self ? "double" : "float")3x3([\(columns.0), \(columns.1), \(columns.2)])"
    }
}

extension MolSIMDMatrix3x3 {
    @inlinable public static func + (l: MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) -> MolSIMDMatrix3x3 {
        MolSIMDMatrix3x3(l.columns.0 + r.columns.0, l.columns.1 + r.columns.1, l.columns.2 + r.columns.2)
    }
    @inlinable public static func - (l: MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) -> MolSIMDMatrix3x3 {
        MolSIMDMatrix3x3(l.columns.0 - r.columns.0, l.columns.1 - r.columns.1, l.columns.2 - r.columns.2)
    }
    @inlinable public static prefix func - (m: MolSIMDMatrix3x3) -> MolSIMDMatrix3x3 {
        MolSIMDMatrix3x3(-m.columns.0, -m.columns.1, -m.columns.2)
    }
    @inlinable public static func * (s: Scalar, m: MolSIMDMatrix3x3) -> MolSIMDMatrix3x3 {
        MolSIMDMatrix3x3(s * m.columns.0, s * m.columns.1, s * m.columns.2)
    }
    @inlinable public static func * (m: MolSIMDMatrix3x3, s: Scalar) -> MolSIMDMatrix3x3 { s * m }
    /// Matrix × column vector.
    @inlinable public static func * (m: MolSIMDMatrix3x3, v: Column) -> Column {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z
    }
    /// Row vector × matrix.
    @inlinable public static func * (v: Column, m: MolSIMDMatrix3x3) -> Column {
        Column(simd_dot(v, m.columns.0), simd_dot(v, m.columns.1), simd_dot(v, m.columns.2))
    }
    @inlinable public static func * (l: MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) -> MolSIMDMatrix3x3 {
        MolSIMDMatrix3x3(l * r.columns.0, l * r.columns.1, l * r.columns.2)
    }
    @inlinable public static func += (l: inout MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) { l = l + r }
    @inlinable public static func -= (l: inout MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) { l = l - r }
    @inlinable public static func *= (l: inout MolSIMDMatrix3x3, r: MolSIMDMatrix3x3) { l = l * r }
    @inlinable public static func *= (l: inout MolSIMDMatrix3x3, s: Scalar) { l = s * l }
}

@inlinable public func simd_transpose<S>(_ m: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { m.transpose }
@inlinable public func simd_inverse<S>(_ m: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { m.inverse }
@inlinable public func simd_determinant<S>(_ m: MolSIMDMatrix3x3<S>) -> S { m.determinant }
@inlinable public func simd_mul<S>(_ a: MolSIMDMatrix3x3<S>, _ b: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { a * b }
@inlinable public func simd_mul<S>(_ m: MolSIMDMatrix3x3<S>, _ v: SIMD3<S>) -> SIMD3<S> { m * v }
@inlinable public func simd_mul<S>(_ v: SIMD3<S>, _ m: MolSIMDMatrix3x3<S>) -> SIMD3<S> { v * m }
@inlinable public func simd_mul<S>(_ s: S, _ m: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { s * m }
@inlinable public func simd_add<S>(_ a: MolSIMDMatrix3x3<S>, _ b: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { a + b }
@inlinable public func simd_sub<S>(_ a: MolSIMDMatrix3x3<S>, _ b: MolSIMDMatrix3x3<S>) -> MolSIMDMatrix3x3<S> { a - b }
@inlinable public func simd_diagonal_matrix<S>(_ d: SIMD3<S>) -> MolSIMDMatrix3x3<S> { MolSIMDMatrix3x3(diagonal: d) }
@inlinable public func simd_matrix<S>(_ c0: SIMD3<S>, _ c1: SIMD3<S>, _ c2: SIMD3<S>) -> MolSIMDMatrix3x3<S> {
    MolSIMDMatrix3x3(c0, c1, c2)
}
@inlinable public func simd_matrix_from_rows<S>(_ r0: SIMD3<S>, _ r1: SIMD3<S>, _ r2: SIMD3<S>) -> MolSIMDMatrix3x3<S> {
    MolSIMDMatrix3x3(rows: [r0, r1, r2])
}
@inlinable public func simd_matrix3x3<S>(_ q: MolSIMDQuaternion<S>) -> MolSIMDMatrix3x3<S> { MolSIMDMatrix3x3(q) }
@inlinable public func simd_equal<S>(_ a: MolSIMDMatrix3x3<S>, _ b: MolSIMDMatrix3x3<S>) -> Bool { a == b }
@inlinable public func simd_almost_equal_elements<S>(_ a: MolSIMDMatrix3x3<S>, _ b: MolSIMDMatrix3x3<S>, _ tol: S) -> Bool {
    for c in 0..<3 { for r in 0..<3 where Swift.abs(a[c][r] - b[c][r]) > tol { return false } }
    return true
}

// MARK: - Quaternion

/// Quaternion stored as `vector = (ix, iy, iz, r)`, like Apple's simd_quatd / simd_quatf.
public struct MolSIMDQuaternion<Scalar: MolSIMDReal>: Sendable, Equatable {
    public var vector: SIMD4<Scalar>

    @inlinable public init() { vector = .zero }
    @inlinable public init(vector: SIMD4<Scalar>) { self.vector = vector }
    @inlinable public init(ix: Scalar, iy: Scalar, iz: Scalar, r: Scalar) { vector = SIMD4(ix, iy, iz, r) }
    @inlinable public init(real: Scalar, imag: SIMD3<Scalar>) { vector = SIMD4(imag.x, imag.y, imag.z, real) }
    /// Rotation by `angle` radians about `axis`. As on Apple, `axis` is used as given (pass a unit vector).
    @inlinable public init(angle: Scalar, axis: SIMD3<Scalar>) {
        let h = angle / 2
        self.init(real: Scalar._molCos(h), imag: Scalar._molSin(h) * axis)
    }
    /// Shortest-arc rotation taking unit vector `from` to unit vector `to` (Apple's simd_quaternion(from, to)).
    @inlinable public init(from: SIMD3<Scalar>, to: SIMD3<Scalar>) {
        let d = simd_dot(from, to)
        if d >= 0 {
            // half-way vector method
            self = MolSIMDQuaternion._between(from, to)
        } else {
            // Rotate by 180° about an axis perpendicular to `from`, then the remaining (acute) arc.
            let a = Swift.abs(from.x) <= Swift.abs(from.y) && Swift.abs(from.x) <= Swift.abs(from.z)
                ? SIMD3<Scalar>(1, 0, 0)
                : (Swift.abs(from.y) <= Swift.abs(from.z) ? SIMD3<Scalar>(0, 1, 0) : SIMD3<Scalar>(0, 0, 1))
            let mid = simd_normalize(simd_cross(from, a))
            self = MolSIMDQuaternion._between(mid, to) * MolSIMDQuaternion._between(from, mid)
        }
    }
    @inlinable static func _between(_ a: SIMD3<Scalar>, _ b: SIMD3<Scalar>) -> MolSIMDQuaternion {
        let h = simd_normalize(a + b)
        return MolSIMDQuaternion(real: simd_dot(a, h), imag: simd_cross(a, h))
    }
    /// From a rotation matrix (Shepperd's method).
    @inlinable public init(_ m: MolSIMDMatrix3x3<Scalar>) {
        let m00 = m[0][0], m11 = m[1][1], m22 = m[2][2]
        let trace = m00 + m11 + m22
        if trace >= 0 {
            let r = 2 * (1 + trace).squareRoot()
            self.init(ix: (m[1][2] - m[2][1]) / r, iy: (m[2][0] - m[0][2]) / r, iz: (m[0][1] - m[1][0]) / r, r: r / 4)
        } else if m00 >= m11 && m00 >= m22 {
            let r = 2 * (1 - m11 - m22 + m00).squareRoot()
            self.init(ix: r / 4, iy: (m[0][1] + m[1][0]) / r, iz: (m[0][2] + m[2][0]) / r, r: (m[1][2] - m[2][1]) / r)
        } else if m11 >= m22 {
            let r = 2 * (1 - m00 - m22 + m11).squareRoot()
            self.init(ix: (m[0][1] + m[1][0]) / r, iy: r / 4, iz: (m[1][2] + m[2][1]) / r, r: (m[2][0] - m[0][2]) / r)
        } else {
            let r = 2 * (1 - m00 - m11 + m22).squareRoot()
            self.init(ix: (m[0][2] + m[2][0]) / r, iy: (m[1][2] + m[2][1]) / r, iz: r / 4, r: (m[0][1] - m[1][0]) / r)
        }
    }

    @inlinable public var real: Scalar {
        get { vector.w }
        set { vector.w = newValue }
    }
    @inlinable public var imag: SIMD3<Scalar> {
        get { SIMD3(vector.x, vector.y, vector.z) }
        set { vector = SIMD4(newValue.x, newValue.y, newValue.z, vector.w) }
    }
    /// Rotation angle in radians: 2·atan2(|imag|, real).
    @inlinable public var angle: Scalar { 2 * Scalar._molAtan2(simd_length(imag), real) }
    /// Normalized rotation axis (NaN for the identity rotation, like Apple).
    @inlinable public var axis: SIMD3<Scalar> { simd_normalize(imag) }
    @inlinable public var length: Scalar { simd_length(vector) }
    @inlinable public var normalized: MolSIMDQuaternion { MolSIMDQuaternion(vector: simd_normalize(vector)) }
    @inlinable public var conjugate: MolSIMDQuaternion { MolSIMDQuaternion(real: real, imag: -imag) }
    @inlinable public var inverse: MolSIMDQuaternion {
        let c = conjugate
        return MolSIMDQuaternion(vector: c.vector / simd_length_squared(vector))
    }
    /// Rotate `v` by this quaternion: imag(q · (v, 0) · conj(q)).
    @inlinable public func act(_ v: SIMD3<Scalar>) -> SIMD3<Scalar> {
        (self * MolSIMDQuaternion(real: 0, imag: v) * conjugate).imag
    }

    @inlinable public static func + (l: MolSIMDQuaternion, r: MolSIMDQuaternion) -> MolSIMDQuaternion {
        MolSIMDQuaternion(vector: l.vector + r.vector)
    }
    @inlinable public static func - (l: MolSIMDQuaternion, r: MolSIMDQuaternion) -> MolSIMDQuaternion {
        MolSIMDQuaternion(vector: l.vector - r.vector)
    }
    @inlinable public static prefix func - (q: MolSIMDQuaternion) -> MolSIMDQuaternion { MolSIMDQuaternion(vector: -q.vector) }
    /// Hamilton product.
    @inlinable public static func * (l: MolSIMDQuaternion, r: MolSIMDQuaternion) -> MolSIMDQuaternion {
        let lr = l.real, rr = r.real, li = l.imag, ri = r.imag
        return MolSIMDQuaternion(real: lr * rr - simd_dot(li, ri), imag: lr * ri + rr * li + simd_cross(li, ri))
    }
    @inlinable public static func * (s: Scalar, q: MolSIMDQuaternion) -> MolSIMDQuaternion { MolSIMDQuaternion(vector: s * q.vector) }
    @inlinable public static func * (q: MolSIMDQuaternion, s: Scalar) -> MolSIMDQuaternion { MolSIMDQuaternion(vector: q.vector * s) }
    @inlinable public static func / (q: MolSIMDQuaternion, s: Scalar) -> MolSIMDQuaternion { MolSIMDQuaternion(vector: q.vector / s) }
    @inlinable public static func / (l: MolSIMDQuaternion, r: MolSIMDQuaternion) -> MolSIMDQuaternion { l * r.inverse }
    @inlinable public static func += (l: inout MolSIMDQuaternion, r: MolSIMDQuaternion) { l = l + r }
    @inlinable public static func -= (l: inout MolSIMDQuaternion, r: MolSIMDQuaternion) { l = l - r }
    @inlinable public static func *= (l: inout MolSIMDQuaternion, r: MolSIMDQuaternion) { l = l * r }
    @inlinable public static func *= (l: inout MolSIMDQuaternion, s: Scalar) { l = l * s }
}

extension MolSIMDQuaternion: CustomDebugStringConvertible {
    public var debugDescription: String {
        "simd_quat\(Scalar.self == Double.self ? "d" : "f")(real: \(real), imag: \(imag))"
    }
}

public typealias simd_quatd = MolSIMDQuaternion<Double>
public typealias simd_quatf = MolSIMDQuaternion<Float>

@inlinable public func simd_quaternion<S>(_ ix: S, _ iy: S, _ iz: S, _ r: S) -> MolSIMDQuaternion<S> {
    MolSIMDQuaternion(ix: ix, iy: iy, iz: iz, r: r)
}
@inlinable public func simd_quaternion<S>(_ v: SIMD4<S>) -> MolSIMDQuaternion<S> { MolSIMDQuaternion(vector: v) }
@inlinable public func simd_quaternion<S>(_ imag: SIMD3<S>, _ real: S) -> MolSIMDQuaternion<S> {
    MolSIMDQuaternion(real: real, imag: imag)
}
@inlinable public func simd_quaternion<S>(_ angle: S, _ axis: SIMD3<S>) -> MolSIMDQuaternion<S> {
    MolSIMDQuaternion(angle: angle, axis: axis)
}
@inlinable public func simd_quaternion<S>(_ from: SIMD3<S>, _ to: SIMD3<S>) -> MolSIMDQuaternion<S> {
    MolSIMDQuaternion(from: from, to: to)
}
@inlinable public func simd_quaternion<S>(_ m: MolSIMDMatrix3x3<S>) -> MolSIMDQuaternion<S> { MolSIMDQuaternion(m) }
@inlinable public func simd_act<S>(_ q: MolSIMDQuaternion<S>, _ v: SIMD3<S>) -> SIMD3<S> { q.act(v) }
@inlinable public func simd_mul<S>(_ a: MolSIMDQuaternion<S>, _ b: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { a * b }
@inlinable public func simd_add<S>(_ a: MolSIMDQuaternion<S>, _ b: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { a + b }
@inlinable public func simd_sub<S>(_ a: MolSIMDQuaternion<S>, _ b: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { a - b }
@inlinable public func simd_conjugate<S>(_ q: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { q.conjugate }
@inlinable public func simd_inverse<S>(_ q: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { q.inverse }
@inlinable public func simd_normalize<S>(_ q: MolSIMDQuaternion<S>) -> MolSIMDQuaternion<S> { q.normalized }
@inlinable public func simd_length<S>(_ q: MolSIMDQuaternion<S>) -> S { q.length }
@inlinable public func simd_dot<S>(_ a: MolSIMDQuaternion<S>, _ b: MolSIMDQuaternion<S>) -> S { simd_dot(a.vector, b.vector) }
@inlinable public func simd_angle<S>(_ q: MolSIMDQuaternion<S>) -> S { q.angle }
@inlinable public func simd_axis<S>(_ q: MolSIMDQuaternion<S>) -> SIMD3<S> { q.axis }
@inlinable public func simd_real<S>(_ q: MolSIMDQuaternion<S>) -> S { q.real }
@inlinable public func simd_imag<S>(_ q: MolSIMDQuaternion<S>) -> SIMD3<S> { q.imag }
/// Shortest-path spherical interpolation (Apple's simd_slerp).
@inlinable public func simd_slerp<S>(_ q0: MolSIMDQuaternion<S>, _ q1: MolSIMDQuaternion<S>, _ t: S) -> MolSIMDQuaternion<S> {
    var b = q1
    if simd_dot(q0, q1) < 0 { b = -q1 }
    let d = Swift.min(Swift.max(simd_dot(q0, b) / (q0.length * b.length), -1), 1)
    let theta = S._molAcos(d)
    if theta < S(1e-6) { return MolSIMDQuaternion(vector: q0.vector + t * (b.vector - q0.vector)).normalized }
    let s = S._molSin(theta)
    let w0 = S._molSin((1 - t) * theta) / s, w1 = S._molSin(t * theta) / s
    return MolSIMDQuaternion(vector: w0 * q0.vector + w1 * b.vector)
}
#endif
