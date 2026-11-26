import Foundation

/// Runs blocking, CPU-bound `work` on a global queue and awaits its result, forwarding Swift task
/// cancellation to the work through the `isCancelled` closure it receives.
///
/// Cancellation is observed by polling `Task.isCancelled` from the awaiting side rather than with
/// `withTaskCancellationHandler`: awaiting a detached task inside a cancellation handler aborted with
/// "freed pointer was not the last allocation" on the macOS 15 concurrency runtime when the handler
/// fired. The poll interval bounds the extra cancellation latency.
///
/// Windows: values holding a `SIMD3<Double>` (GridSpec, VolumeGrid) must not be parameters of an async function
/// (Swift 6.4.3 x64 codegen bug), so callers capture their inputs in `AsyncCapture` inside `work`; the result
/// comes back through a lock-protected box, never as an async parameter.
///
/// Returns nil when the work returned nil (it saw the cancellation) or the task was cancelled.
func runCancellableWork<T>(pollInterval: UInt64 = 20_000_000,
                           _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> T?) async -> T? {
    let flag = EvaluatorCancelFlag()
    let box = CancellableWorkBox<T>()
    DispatchQueue.global(qos: .userInitiated).async {
        box.finish(work({ flag.isSet }))
    }
    while !box.isDone {
        if Task.isCancelled { flag.set() }
        try? await Task.sleep(nanoseconds: pollInterval)
    }
    if Task.isCancelled { return nil }
    return box.value
}

private final class CancellableWorkBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var result: T?
    func finish(_ v: T?) { lock.lock(); result = v; done = true; lock.unlock() }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var value: T? { lock.lock(); defer { lock.unlock() }; return result }
}
