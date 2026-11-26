import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    /// `data(for:)` that works on every platform. Darwin uses the native async API; elsewhere (Windows/Linux
    /// swift-corelibs-foundation) the completion-handler API is wrapped in a continuation, with Task cancellation
    /// cancelling the data task (it then fails with `URLError(.cancelled)`, like the Darwin API).
    func portableData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(Darwin)
        return try await data(for: request)
        #else
        let box = DataTaskBox()
        #if os(Windows)
        let probe = RefusalProbe.target(for: request, session: self)
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let once = ResumeOnce(cont)
                let task = dataTask(with: request) { data, response, error in
                    if let error { once.resume(throwing: error) }
                    else if let response { once.resume(returning: (data ?? Data(), response)) }
                    else { once.resume(throwing: URLError(.badServerResponse)) }
                }
                box.start(task)
                #if os(Windows)
                // FoundationNetworking on Windows never reports a refused connection: the request waits for its full
                // timeout and then fails with .timedOut. A direct connect attempt sees the RST, so a refusal ends the
                // request at once with .cannotConnectToHost, as on Darwin.
                if let probe {
                    let timeout = request.timeoutInterval
                    DispatchQueue.global().async {
                        if RefusalProbe.refused(probe, timeout: timeout),
                           once.resume(throwing: URLError(.cannotConnectToHost)) { box.cancel() }
                    }
                }
                #endif
            }
        } onCancel: {
            box.cancel()
        }
        #endif
    }
}

#if !canImport(Darwin)
/// Resumes a continuation at most once (the data task and the Windows refusal probe race).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = cont; cont = nil
        return c
    }
    @discardableResult func resume(returning v: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: v); return true
    }
    @discardableResult func resume(throwing e: Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: e); return true
    }
}

/// Holds the data task so a cancellation that races with its creation still cancels it.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ t: URLSessionDataTask) {
        lock.lock()
        task = t
        let c = cancelled
        lock.unlock()
        t.resume()
        if c { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}
#endif

#if os(Windows)
import WinSDK

/// Detects actively refused TCP connections (see `portableData`).
private enum RefusalProbe {
    struct Target: Sendable { let host: String; let port: Int }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reachable: [String: Date] = [:]   // "host:port" -> last successful connect

    /// The host and port to probe, or nil when a proxy is configured (the connection would go elsewhere) or the same
    /// host accepted a connection in the last minute.
    static func target(for request: URLRequest, session: URLSession) -> Target? {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let env = ProcessInfo.processInfo.environment
        for k in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] where !(env[k] ?? "").isEmpty { return nil }
        if let p = session.configuration.connectionProxyDictionary, !p.isEmpty { return nil }
        let t = Target(host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
        lock.lock(); defer { lock.unlock() }
        if let last = reachable["\(t.host):\(t.port)"], Date().timeIntervalSince(last) < 60 { return nil }
        return t
    }

    /// True when every address of the target actively refused (RST) a TCP connection within `timeout`.
    static func refused(_ t: Target, timeout: TimeInterval) -> Bool {
        var wsa = WSADATA()
        guard WSAStartup(0x0202, &wsa) == 0 else { return false }
        defer { WSACleanup() }
        var hints = ADDRINFOA()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<ADDRINFOA>?
        guard getaddrinfo(t.host, String(t.port), &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var sawAddress = false
        var cur: UnsafeMutablePointer<ADDRINFOA>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard s != INVALID_SOCKET else { continue }
            defer { closesocket(s) }
            sawAddress = true
            var nonBlocking: u_long = 1
            _ = ioctlsocket(s, Int32(bitPattern: 0x8004_667E), &nonBlocking)   // FIONBIO
            // Windows retries a refused SYN (about 2 s per address). SIO_TCP_INITIAL_RTO with
            // TCP_INITIAL_RTO_PARAMETERS { Rtt = TCP_INITIAL_RTO_UNSPECIFIED_RTT, MaxSynRetransmissions =
            // TCP_INITIAL_RTO_NO_SYN_RETRANSMISSIONS } (not imported into Swift) reports the first RST instead.
            var rto: (UInt16, UInt8, UInt8) = (0xFFFF, 0xFE, 0)
            var ret: DWORD = 0
            _ = WSAIoctl(s, 0x9800_0011, &rto, 4, nil, 0, &ret, nil, nil)
            if connect(s, ai.pointee.ai_addr, Int32(ai.pointee.ai_addrlen)) == 0 { markReachable(t); return false }
            guard WSAGetLastError() == WSAEWOULDBLOCK else { return false }
            var writable = fd_set(), failed = fd_set()
            writable.fd_count = 1; writable.fd_array.0 = s
            failed.fd_count = 1; failed.fd_array.0 = s
            let left = max(0, deadline.timeIntervalSinceNow)
            var tv = timeval(tv_sec: Int32(left), tv_usec: Int32((left - left.rounded(.down)) * 1e6))
            let n = select(0, nil, &writable, &failed, &tv)
            guard n > 0 else { return false }                                   // no answer in time
            if failed.fd_count == 0 { markReachable(t); return false }           // connected
            var err: Int32 = 0
            var len = Int32(MemoryLayout<Int32>.size)
            _ = withUnsafeMutablePointer(to: &err) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(s, SOL_SOCKET, SO_ERROR, $0, &len) }
            }
            guard err == WSAECONNREFUSED else { return false }
        }
        return sawAddress
    }

    private static func markReachable(_ t: Target) {
        lock.lock(); defer { lock.unlock() }
        reachable["\(t.host):\(t.port)"] = Date()
    }
}
#endif
