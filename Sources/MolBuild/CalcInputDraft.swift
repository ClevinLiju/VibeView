import Foundation

/// The text shown in the calculation setup's input preview. Until the user types in it, it follows the form
/// (`generated`). After the first edit it is detached: the edited text is kept as typed, form changes
/// only update `generated`, and `formChangedSinceEdit` says that the two no longer match. `revert()`
/// throws the edit away and the preview follows the form again.
public struct CalcInputDraft: Equatable, Sendable {
    public private(set) var generated: String
    public private(set) var edited: String?
    /// The generated text at the moment the edit started.
    public private(set) var generatedAtEdit: String?

    public init(generated: String = "") { self.generated = generated }

    public var isEdited: Bool { edited != nil }
    /// What Save, Copy and Run use.
    public var text: String { edited ?? generated }
    /// The form was changed after the edit started, so the edited text ignores those changes.
    public var formChangedSinceEdit: Bool { edited != nil && generatedAtEdit != generated }

    /// New text from the form. Never overwrites an edit.
    public mutating func updateGenerated(_ text: String) { generated = text }

    /// Text typed into the preview. Typing the generated text back exactly is not an edit.
    public mutating func setText(_ text: String) {
        if edited == nil {
            guard text != generated else { return }
            generatedAtEdit = generated
        }
        edited = text
    }

    public mutating func revert() { edited = nil; generatedAtEdit = nil }
}

/// The xtb "input" shown in the preview: the command line as a `# ` comment, then the XYZ file.
///
///     # xtb job.xyz --opt --chrg 0 --uhf 0 --gfn 2 -P 4
///     # job.xyz:
///
///     3
///     ...
public enum XTBInputPreview {
    public static func compose(arguments: [String], inputFileName: String, xyz: String, executable: String = "xtb") -> String {
        "# " + shellJoin([executable] + arguments) + "\n# \(inputFileName):\n\n" + xyz
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case missingCommandLine, notXTB(String), missingInputFile(String), emptyGeometry
        public var errorDescription: String? {
            switch self {
            case .missingCommandLine: "The first line must be the xtb command, e.g. “# xtb job.xyz --opt”."
            case .notXTB(let w): "The command must start with xtb (found “\(w)”)."
            case .missingInputFile(let f): "The command line must name the input file \(f)."
            case .emptyGeometry: "The XYZ geometry below the command line is empty."
            }
        }
    }

    /// Splits an (edited) preview into xtb arguments (without the executable) and the XYZ text.
    /// The command line must name `inputFileName`, the file the XYZ part is written to.
    public static func parse(_ text: String, inputFileName: String) throws -> (arguments: [String], xyz: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first, first.hasPrefix("#") else { throw ParseError.missingCommandLine }
        lines.removeFirst()
        let words = shellSplit(String(first.dropFirst()))
        guard let exe = words.first else { throw ParseError.missingCommandLine }
        guard isXTB(exe) else { throw ParseError.notXTB(exe) }
        let args = Array(words.dropFirst())
        guard args.contains(inputFileName) else { throw ParseError.missingInputFile(inputFileName) }
        // Skip the "# job.xyz:" marker and other comment lines, then blank lines.
        while let f = lines.first, f.hasPrefix("#") || f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        var xyz = lines.joined(separator: "\n")
        guard !xyz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.emptyGeometry }
        if !xyz.hasSuffix("\n") { xyz += "\n" }
        return (args, xyz)
    }

    /// The command names xtb: `xtb` or a path to it; on Windows also `xtb.exe`, in any case.
    static func isXTB(_ word: String) -> Bool {
        var name = word
        if let i = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: i)...]) }
        #if os(Windows)
        name = name.lowercased()
        if name.hasSuffix(".exe") { name = String(name.dropLast(4)) }
        #endif
        return name == "xtb"
    }

    /// Whitespace-separated words with '…' / "…" quoting and backslash escapes. On Windows a backslash escapes
    /// only a following quote character, so paths such as `C:\xtb\params.txt` stay as typed.
    public static func shellSplit(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character? = nil, escape = false
        let chars = Array(s)
        for (k, ch) in chars.enumerated() {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            #if os(Windows)
            let escapes = ch == "\\" && quote != "'" && k + 1 < chars.count && (chars[k + 1] == "\"" || chars[k + 1] == "'")
            #else
            let escapes = ch == "\\" && quote != "'" && k >= 0
            #endif
            if escapes { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch); inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }

    public static func shellJoin(_ words: [String]) -> String {
        words.map { w in
            #if os(Windows)
            let plain = "-_./=:,+@%\\"   // backslashes are literal on Windows (see shellSplit)
            #else
            let plain = "-_./=:,+@%"
            #endif
            let safe = !w.isEmpty && w.allSatisfy { $0.isLetter || $0.isNumber || plain.contains($0) }
            return safe ? w : "'" + w.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
