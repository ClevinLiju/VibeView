import Foundation

/// Command-line history with up/down navigation.
public struct CommandHistory: Sendable, Equatable {
    public private(set) var entries: [String]
    public var maxCount: Int
    /// Index into `entries`; `entries.count` means "past the newest" (the empty draft).
    public private(set) var cursor: Int

    public init(maxCount: Int = 500, entries: [String] = []) {
        self.maxCount = max(1, maxCount)
        self.entries = Array(entries.suffix(max(1, maxCount)))
        self.cursor = self.entries.count
    }

    /// Adds a line (trimmed, newlines flattened). Empty lines and consecutive duplicates are ignored.
    /// Resets the navigation cursor.
    public mutating func add(_ line: String) {
        let t = line.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        defer { cursor = entries.count }
        guard !t.isEmpty, entries.last != t else { return }
        entries.append(t)
        if entries.count > maxCount { entries.removeFirst(entries.count - maxCount) }
    }

    /// Moves to the next older entry (stays on the oldest).
    public mutating func previous() -> String? {
        guard !entries.isEmpty else { return nil }
        cursor = max(0, cursor - 1)
        return entries[cursor]
    }

    /// Moves to the next newer entry; returns nil once past the newest (restore the draft).
    public mutating func next() -> String? {
        guard cursor < entries.count else { return nil }
        cursor += 1
        return cursor < entries.count ? entries[cursor] : nil
    }

    public mutating func resetCursor() { cursor = entries.count }
    public mutating func clear() { entries = []; cursor = 0 }

    /// Plain text, one command per line.
    public func save(to url: URL) throws {
        try (entries.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replaces entries with the file's lines (missing file is an error).
    public mutating func load(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        entries = []
        for l in text.split(separator: "\n", omittingEmptySubsequences: true) { add(String(l)) }
        cursor = entries.count
    }
}
