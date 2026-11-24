import Foundation

public enum ComputeError: Error, LocalizedError, Sendable, Equatable {
    case notInstalled(program: String, searched: [String])
    case offline
    case timeout
    case notFound(String)
    case httpStatus(Int)
    case processFailed(code: Int32, stderr: String)
    case parse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let p, let s):
            let hint = p == "xtb" ? " Install it with `conda install -c conda-forge xtb` or `brew install xtb`." : ""
            return "\(p) is not installed.\(hint) Searched: \(s.joined(separator: ", "))"
        case .offline: return "No internet connection."
        case .timeout: return "The operation timed out."
        case .notFound(let q): return "Nothing found for \"\(q)\"."
        case .httpStatus(let c): return "The server returned HTTP status \(c)."
        case .processFailed(let c, let e):
            return "Process failed with exit code \(c): \(e.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))"
        case .parse(let m): return "Could not parse output: \(m)"
        case .cancelled: return "The operation was cancelled."
        }
    }
}
