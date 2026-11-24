import Foundation
import MolBuild

/// Optional iteration limits layered on top of the generated input (blank = program default).
struct CalcIterations: Equatable, Sendable {
    /// SCF iterations (ORCA `%scf MaxIter`, Gaussian `SCF=(MaxCycle=N)`).
    var scfMaxIter: Int? = nil
    /// Geometry-optimization steps (ORCA `%geom MaxIter`, Gaussian `Opt=(MaxCycles=N)`).
    var optMaxIter: Int? = nil

    var isEmpty: Bool { scfMaxIter == nil && optMaxIter == nil }

    static func supports(_ p: QCProgram) -> Bool { p == .orca || p == .gaussian }

    /// The input text with the limits merged in.
    func apply(to text: String, program: QCProgram, jobType: JobType) -> String {
        guard !isEmpty else { return text }
        switch program {
        case .orca: return applyORCA(text, jobType: jobType)
        case .gaussian: return applyGaussian(text)
        default: return text
        }
    }

    private static let orcaOptJobs: Set<JobType> = [.optimize, .optFreq, .scan, .transitionState, .irc]

    private func applyORCA(_ text: String, jobType: JobType) -> String {
        var add: [String] = []
        if let n = scfMaxIter, n > 0 { add.append("%scf MaxIter \(n) end") }
        if let n = optMaxIter, n > 0, Self.orcaOptJobs.contains(jobType) { add.append("%geom MaxIter \(n) end") }
        guard !add.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        // Blocks go before the coordinates ("* xyz ...").
        guard let i = lines.firstIndex(where: { $0.hasPrefix("* ") || $0.hasPrefix("*xyz") }) else { return text }
        lines.insert(contentsOf: add, at: i)
        return lines.joined(separator: "\n")
    }

    private func applyGaussian(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("#") }) else { return text }
        var route = lines[i]
        if let n = optMaxIter, n > 0 { route = Self.merge(route, keyword: "Opt", option: "MaxCycles=\(n)", marker: "maxcycles") }
        if let n = scfMaxIter, n > 0 { route = Self.merge(route, keyword: "SCF", option: "MaxCycle=\(n)", marker: "maxcycle") }
        lines[i] = route
        return lines.joined(separator: "\n")
    }

    /// Splits a route line into top-level tokens (parentheses keep their spaces together).
    static func routeTokens(_ route: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        for ch in route {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == " " && depth == 0 { if !cur.isEmpty { out.append(cur); cur = "" } } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Adds `option` to the route keyword (`Opt`, `Opt=TS`, `Opt=(TS,CalcFC)` -> `Opt=(TS,CalcFC,MaxCycles=N)`).
    /// If the keyword is absent, the route is returned unchanged for Opt, and `SCF=(MaxCycle=N)` is appended for SCF.
    static func merge(_ route: String, keyword: String, option: String, marker: String) -> String {
        var tokens = routeTokens(route)
        let kw = keyword.lowercased()
        var found = false
        for (idx, t) in tokens.enumerated() {
            let low = t.lowercased()
            let isKw = low == kw || low.hasPrefix(kw + "=") || low.hasPrefix(kw + "(")
            guard isKw else { continue }
            found = true
            if low.contains(marker) { break }          // the user already set it
            if low == kw {
                tokens[idx] = "\(t)=(\(option))"
            } else {
                var body = String(t.dropFirst(kw.count))      // "=TS", "=(TS,CalcFC)" or "(TS)"
                if body.hasPrefix("=") { body.removeFirst() }
                if body.hasPrefix("("), body.hasSuffix(")") { body = String(body.dropFirst().dropLast()) }
                tokens[idx] = "\(t.prefix(kw.count))=(\(body),\(option))"
            }
            break
        }
        if !found && keyword == "SCF" { tokens.append("SCF=(\(option))") }
        return tokens.joined(separator: " ")
    }
}
