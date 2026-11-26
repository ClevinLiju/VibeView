import Foundation

/// One command split out of an input line.
public struct ParsedCommand: Sendable, Equatable {
    /// Lower-cased command word (first word).
    public var name: String
    /// Remaining words, quotes removed and escapes resolved.
    public var arguments: [String]
    /// Source text of this command (comment stripped, trimmed).
    public var raw: String
    public init(name: String, arguments: [String], raw: String) {
        self.name = name; self.arguments = arguments; self.raw = raw
    }
}

/// A syntax error with a 1-based column on the line where it occurred.
public struct TokenizerError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var column: Int
    public init(message: String, column: Int) { self.message = message; self.column = column }
    public var description: String { "\(message) (column \(column))" }
}

/// Splits command lines into commands and words.
///
/// Rules: words are separated by whitespace; `'...'` and `"..."` group text (backslash escapes
/// `\\ \" \' \n \t` work inside quotes, and `\x` yields `x` outside quotes); `;` and newlines
/// separate commands; `#` at the START of a word begins a comment to end of line, except when it
/// looks like a colour literal (`#` + 3, 6 or 8 hex digits followed by a delimiter), so
/// `color all #ff8800` works. On Windows backslashes are literal (paths) except `\\`/`\"`/`\'` inside quotes
/// and `\<space>`, `\;`, `\#`, `\"`, `\'` outside quotes.
public enum CommandTokenizer {
    public static func parse(_ text: String) throws -> [ParsedCommand] {
        let chars = Array(text)
        var result: [ParsedCommand] = []
        var words: [String] = []
        var cur = ""
        var inWord = false
        var segStart = 0
        var rawEnd: Int? = nil
        var lineStart = 0
        var i = 0

        func flushWord() { if inWord { words.append(cur); cur = ""; inWord = false } }
        func flushCommand(end: Int) {
            flushWord()
            if !words.isEmpty {
                let e = rawEnd ?? end
                let raw = String(chars[segStart..<max(segStart, min(e, chars.count))]).trimmingCharacters(in: .whitespaces)
                result.append(ParsedCommand(name: words[0].lowercased(), arguments: Array(words.dropFirst()), raw: raw))
            }
            words = []; rawEnd = nil
        }
        func isDelimiter(_ c: Character) -> Bool { c.isWhitespace || c == ";" }

        // "\r\n" is ONE Character in Swift, so test all three line-break forms.
        func isLineBreak(_ c: Character) -> Bool { c == "\n" || c == "\r\n" || c == "\r" }

        while i < chars.count {
            let c = chars[i]
            if isLineBreak(c) {
                flushCommand(end: i); segStart = i + 1; lineStart = i + 1
            } else if c == ";" {
                flushCommand(end: i); segStart = i + 1
            } else if c.isWhitespace {
                flushWord()
            } else if c == "#" && !inWord {
                var j = i + 1
                while j < chars.count, chars[j].isHexDigit { j += 1 }
                let n = j - i - 1
                let endsOK = j >= chars.count || isDelimiter(chars[j])
                if endsOK && (n == 3 || n == 6 || n == 8) {
                    cur.append(contentsOf: chars[i..<j]); inWord = true; i = j; continue
                }
                // comment
                flushWord()
                if rawEnd == nil { rawEnd = i }
                while i < chars.count, !isLineBreak(chars[i]) { i += 1 }
                continue
            } else if c == "\"" || c == "'" {
                let quote = c
                let openCol = i - lineStart + 1
                inWord = true
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    #if os(Windows)
                    // Windows paths are full of backslashes: inside quotes only `\\` and `\<quote>` are
                    // escapes (and `\<quote>` only when that quote is not the closing one, i.e. not followed
                    // by end of input or a delimiter, so "C:\dir\" works). Everything else is literal.
                    if d == "\\", i + 1 < chars.count {
                        let e = chars[i + 1]
                        if e == "\\" { cur.append("\\"); i += 2; continue }
                        if e == quote {
                            let after = i + 2 < chars.count ? chars[i + 2] : nil
                            if let a = after, !isDelimiter(a) { cur.append(e); i += 2; continue }
                        }
                        cur.append(d); i += 1; continue
                    }
                    #endif
                    if d == "\\", i + 1 < chars.count {
                        let e = chars[i + 1]
                        switch e {
                        case "n": cur.append("\n")
                        case "t": cur.append("\t")
                        default: cur.append(e)
                        }
                        i += 2; continue
                    }
                    if d == quote { closed = true; break }
                    cur.append(d); i += 1
                }
                if !closed { throw TokenizerError(message: "unterminated \(quote == "\"" ? "double" : "single") quote", column: openCol) }
            } else if c == "\\" {
                inWord = true
                #if os(Windows)
                // Outside quotes a backslash only escapes whitespace, `;`, `#` and quotes; otherwise it is a
                // literal path separator (C:\data\x.xyz, \\server\share).
                if i + 1 < chars.count, !isLineBreak(chars[i + 1]),
                   chars[i + 1].isWhitespace || ";#\"'".contains(chars[i + 1]) {
                    cur.append(chars[i + 1]); i += 1
                } else { cur.append("\\") }
                #else
                if i + 1 < chars.count, !isLineBreak(chars[i + 1]) { cur.append(chars[i + 1]); i += 1 } else { cur.append("\\") }
                #endif
            } else {
                cur.append(c); inWord = true
            }
            i += 1
        }
        flushCommand(end: chars.count)
        return result
    }

    /// Words of the first command in `text` (convenience for tests and completion).
    public static func words(_ text: String) throws -> [String] {
        guard let c = try parse(text).first else { return [] }
        return [c.name] + c.arguments
    }
}
