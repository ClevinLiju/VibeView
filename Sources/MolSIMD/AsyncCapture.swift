/// Passes values into an async closure (`Task.detached { ... }`) as a single class reference.
///
/// Why: Swift 6.x on Windows x64 miscompiles async (`swifttailcc`) closures whose captures contain SIMD
/// vectors held inline, such as `Vec3` (`SIMD3<Double>`) inside `GridSpec` or `VolumeGrid`. The
/// compiler-generated partial-apply thunk forwards the vector halves as stack arguments with aligned SSE
/// stores (`movapd`) at offsets only 8 bytes apart. One of them is misaligned, and the process crashes with an
/// access violation (seen in `OrbitalSurfaceService.gridTimed`, debug build, Swift 6.4.3). When the closure
/// captures this box instead, only a pointer crosses the async calling convention. The fields are read inside
/// the closure body, where they are ordinary locals.
///
/// Use it for any detached or async closure that would otherwise capture a SIMD-holding struct by value.
/// The box costs nothing measurable, and Darwin uses the same code.
///
/// The same bug affects async functions that take such a value as a parameter: the callee faults on entry.
/// Don't give an async function a parameter that holds an inline SIMD value. Take `@autoclosure () -> T` and
/// evaluate it first (see `OrbitalEvaluator.evaluateAsync`), take this box, or pass the scalars. Returning
/// such values from async functions has worked so far (`VolumeGrid`).
public final class AsyncCapture<Value: Sendable>: Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
