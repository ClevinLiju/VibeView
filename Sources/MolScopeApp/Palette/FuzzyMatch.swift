import Foundation

enum FuzzyMatch {
    /// Case-insensitive subsequence match. Returns nil if `query` is not a subsequence of `candidate`.
    /// `matched` holds character offsets (into `candidate`) that matched.
    static func score(_ query: String, _ candidate: String) -> (score: Int, matched: [Int])? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let c = Array(candidate)
        let cl = Array(candidate.lowercased())
        guard cl.count == c.count else { return nil }
        if q.isEmpty { return (0, []) }
        if q.count > cl.count { return nil }

        func isStart(_ i: Int) -> Bool {
            i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) || (c[i - 1].isLowercase && c[i].isUppercase)
        }

        // Contiguous substring: strongest signal.
        for start in 0...(cl.count - q.count) where Array(cl[start..<(start + q.count)]) == q {
            var s = 1000 - start
            if start == 0 { s += 200 }
            if isStart(start) { s += 120 }
            if q.count == cl.count { s += 200 }
            return (s, Array(start..<(start + q.count)))
        }

        // Greedy subsequence with bonuses.
        var idx: [Int] = []
        var score = 0
        var pos = 0
        var prev = -2
        for ch in q {
            var found = -1
            // Prefer a word-start occurrence if one exists later in the string.
            var j = pos
            var firstAny = -1
            while j < cl.count {
                if cl[j] == ch {
                    if firstAny < 0 { firstAny = j }
                    if isStart(j) { found = j; break }
                }
                j += 1
            }
            if found < 0 { found = firstAny }
            if found < 0 { return nil }
            score += 10
            if isStart(found) { score += 40 }
            if found == prev + 1 { score += 30 }
            score -= min(found - pos, 8)
            idx.append(found); prev = found; pos = found + 1
        }
        return (score, idx)
    }
}
