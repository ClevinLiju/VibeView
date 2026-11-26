import Foundation

/// What the PE header of a Windows executable says: CPU architecture and link date. Used to adapt Gaussian
/// input to the installed build (32-bit Gaussian 09W can't allocate %mem of about 1.7 GB or more, and builds
/// older than G09 rev. D.01 lack def2 basis names and GD3/GD3BJ dispersion).
public struct ExecutableInfo: Sendable, Equatable {
    public enum Architecture: String, Sendable { case x86, x64, arm64, other }
    public var architecture: Architecture
    /// Link time stamp from the COFF header (nil when it is 0 or the build is reproducible with a hash there).
    public var linkDate: Date?

    public var is32Bit: Bool { architecture == .x86 }
    public var linkYear: Int? {
        guard let d = linkDate else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.year, from: d)
    }

    public init(architecture: Architecture, linkDate: Date?) { self.architecture = architecture; self.linkDate = linkDate }

    /// Parse the header bytes of a PE file (the first 4 KB are enough). Nil when it isn't a PE image.
    public static func parse(_ data: Data) -> ExecutableInfo? {
        let b = [UInt8](data.prefix(4096))
        func u16(_ o: Int) -> Int? { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? {
            o + 4 <= b.count ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 : nil
        }
        guard b.count >= 64, b[0] == 0x4D, b[1] == 0x5A, let pe = u32(0x3C).map(Int.init), pe > 0,
              pe + 24 <= b.count, b[pe] == 0x50, b[pe + 1] == 0x45, b[pe + 2] == 0, b[pe + 3] == 0,
              let machine = u16(pe + 4), let stamp = u32(pe + 8) else { return nil }
        let arch: Architecture
        switch machine {
        case 0x014C: arch = .x86
        case 0x8664: arch = .x64
        case 0xAA64: arch = .arm64
        default: arch = .other
        }
        // Reproducible builds store a hash, which can land anywhere: accept 1995 ... now + 1 day only.
        let date = Date(timeIntervalSince1970: TimeInterval(stamp))
        let plausible = stamp > 788_918_400 && date < Date().addingTimeInterval(86_400)
        return ExecutableInfo(architecture: arch, linkDate: plausible ? date : nil)
    }

    /// Read the header of `url`; nil when the file is missing or not a PE image (e.g. a .bat, or a Unix binary).
    public static func read(_ url: URL) -> ExecutableInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4096) else { return nil }
        return parse(d)
    }
}
