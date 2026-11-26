import Foundation
import MolSIMD

/// Lock-protected flag shared between a request task's cancellation handler and synchronous worker code.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs CPU-heavy synchronous work off the request task and makes it cancellable.
///
/// - The input travels as one `AsyncCapture` box, so no struct holding an inline SIMD value (GridSpec,
///   VolumeGrid, CalculationResult, …) is captured by an async closure (Swift 6.4.3 Windows codegen bug,
///   see MolSIMD/AsyncCapture.swift). Create and consume such values inside `body`.
/// - `body` gets a `cancelled()` probe to poll; returning nil means "stopped early".
/// - When the request is cancelled, `run` throws `CancellationError` at once (the protocol's `cancelled` answer)
///   instead of waiting for `body`, which keeps running in the background until it next polls the probe.
enum Offload {
    static func run<I: Sendable, T: Sendable>(_ input: AsyncCapture<I>,
                                               _ body: @escaping @Sendable (AsyncCapture<I>, @escaping @Sendable () -> Bool) -> T?) async throws -> T {
        let flag = CancelFlag()
        let box = ResultBox<T>()
        let result: T? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T?, Error>) in
                box.install(cont)
                Thread.detachNewThreadWithLargeStack {
                    let r = body(input) { flag.isSet }
                    box.resume(.success(r))
                }
            }
        } onCancel: {
            flag.set()
            box.resume(.failure(CancellationError()))
        }
        guard let result, !flag.isSet else { throw CancellationError() }
        return result
    }
}

/// One-shot continuation holder: the first of (work finished, request cancelled) resumes it.
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T?, Error>?
    private var early: Result<T?, Error>?
    private var done = false

    func install(_ c: CheckedContinuation<T?, Error>) {
        lock.lock()
        if let e = early { done = true; lock.unlock(); c.resume(with: e); return }
        cont = c
        lock.unlock()
    }

    func resume(_ r: Result<T?, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        guard let c = cont else {
            if early == nil { early = r }
            lock.unlock(); return
        }
        done = true; cont = nil
        lock.unlock()
        c.resume(with: r)
    }
}

extension Thread {
    /// Windows threads default to a 1 MB stack; give worker code (marching cubes, symmetry, bond perception
    /// on large molecules, mesh processing) 16 MB.
    static func detachNewThreadWithLargeStack(_ body: @escaping @Sendable () -> Void) {
        let t = Thread { body() }
        t.stackSize = 16 << 20
        t.start()
    }
}

/// Wraps a non-Sendable value (a command context used by one worker at a time) for `Offload`.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
