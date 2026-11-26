import Foundation

/// What `export gif|mp4 <path> vibration N|trajectory|spin [options]` asked for, independent of the renderer.
public struct AnimationExportRequest: Equatable, Sendable {
    public enum Format: String, Sendable, CaseIterable { case gif, mp4, mov }
    public enum Source: Equatable, Sendable {
        /// 1-based normal mode number.
        case vibration(Int)
        case trajectory
        /// Turntable: one full turn about the screen axis.
        case spin
    }
    public enum SpinAxis: String, Sendable { case x, y }

    public var format: Format = .gif
    public var source: Source = .spin
    /// Final pixel size; nil follows the view (width 800 by default, height from the view's aspect).
    public var width: Int?
    public var height: Int?
    public var fps: Double = 24
    /// Seconds for one loop (vibration cycle / turntable turn); nil = default (1 s vibration, 4 s spin).
    /// Ignored for trajectories, which show every `step`-th frame at `fps`.
    public var duration: Double?
    /// How many times the loop repeats inside the file (vibration cycles, spin turns, trajectory passes).
    public var loops: Int = 1
    /// GIF loop count in viewers (0 = forever).
    public var gifLoopCount: Int = 0
    /// 0...1: video bit rate / GIF supersampling.
    public var quality: Double = 0.8
    /// Render look name (studio, whitepaper, darkstage, illustration); nil keeps the current look.
    public var look: String?
    public var transparent = false
    /// Vibration amplitude (Å, largest atom displacement).
    public var amplitude: Double = 0.5
    /// Trajectory: every Nth frame.
    public var step: Int = 1
    public var axis: SpinAxis = .y

    public init() {}

    public static let usage = "export gif|mp4|mov <path> vibration N|trajectory|spin [W H] [width W] [height H] [fps F] "
        + "[duration S] [loops N] [quality Q] [look studio|whitepaper|darkstage|illustration] [amplitude A] [step N] [axis x|y] [transparent]"

    /// Frames in one loop (vibration / spin); trajectories use their own frame count.
    public var framesPerLoop: Int {
        let d = duration ?? (source == .spin ? 4 : 1)
        return max(2, Int((d * fps).rounded()))
    }

    /// Parses the words after `export <format> <path>`.
    public static func parse(format fmtWord: String, path: String, words: [String]) throws -> AnimationExportRequest {
        var r = AnimationExportRequest()
        guard let f = Format(rawValue: fmtWord.lowercased()) else { throw CommandError("unknown animation format '\(fmtWord)' (gif, mp4, mov)") }
        r.format = f
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty && ext != f.rawValue { throw CommandError("the file should end in .\(f.rawValue), not .\(ext)") }
        guard let first = words.first?.lowercased() else { throw CommandError("usage: " + usage) }
        var i = 1
        switch first {
        case "vibration", "vib", "mode":
            guard words.count > 1, let n = Int(words[1]), n >= 1 else { throw CommandError("vibration needs a mode number from 1") }
            r.source = .vibration(n); i = 2
        case "trajectory", "traj", "frames": r.source = .trajectory
        case "spin", "turntable", "rotate": r.source = .spin
        default: throw CommandError("animate vibration N, trajectory or spin (got '\(words[0])')")
        }
        func number(_ s: String, _ what: String) throws -> Double {
            guard let v = Double(s), v > 0, v.isFinite else { throw CommandError("'\(s)' is not a valid \(what)") }
            return v
        }
        func pixels(_ s: String) throws -> Int {
            guard let n = Int(s), n >= 16, n <= 4096 else { throw CommandError("'\(s)' is not a pixel size (16–4096)") }
            return n
        }
        var positional: [Int] = []
        while i < words.count {
            let w = words[i].lowercased()
            func value() throws -> String {
                guard i + 1 < words.count else { throw CommandError("'\(w)' needs a value") }
                i += 1
                return words[i]
            }
            switch w {
            case "width", "w": r.width = try pixels(try value())
            case "height", "h": r.height = try pixels(try value())
            case "fps":
                let v = try number(try value(), "frame rate")
                guard v <= 60 else { throw CommandError("fps must be 60 or less") }
                r.fps = v
            case "duration", "seconds": r.duration = try number(try value(), "duration")
            case "loops", "cycles", "repeat":
                guard let n = Int(try value()), (1...100).contains(n) else { throw CommandError("loops must be 1–100") }
                r.loops = n
            case "quality", "q":
                let q = try number(try value(), "quality")
                r.quality = q > 1 ? min(q / 100, 1) : q
            case "look":
                let l = try value().lowercased()
                guard ImageExportRequest.looks.contains(l) else { throw CommandError("unknown look '\(l)' (\(ImageExportRequest.looks.joined(separator: ", ")))") }
                r.look = l
            case "amplitude", "amp": r.amplitude = try number(try value(), "amplitude")
            case "step", "every":
                guard let n = Int(try value()), n >= 1 else { throw CommandError("step must be a whole number from 1") }
                r.step = n
            case "axis":
                guard let a = SpinAxis(rawValue: try value().lowercased()) else { throw CommandError("axis must be x or y") }
                r.axis = a
            case "transparent": r.transparent = true
            case "once": r.gifLoopCount = 1
            default:
                guard positional.count < 2, Int(w) != nil else { throw CommandError("unknown animation option '\(words[i])'") }
                positional.append(try pixels(w))
            }
            i += 1
        }
        if positional.count == 1 { throw CommandError("give both width and height, or use 'width W'") }
        if positional.count == 2 { r.width = positional[0]; r.height = positional[1] }
        if r.transparent && r.format != .gif { throw CommandError("only GIF animations can be transparent") }
        return r
    }
}

/// `export csv <path> frequencies|orbitals|states|energies|charges`.
public enum CSVTableName: String, Sendable, CaseIterable {
    case frequencies, orbitals, states, energies, charges
    public static func parse(_ s: String) -> CSVTableName? {
        switch s.lowercased() {
        case "frequencies", "freq", "modes", "ir", "raman", "vibrations": .frequencies
        case "orbitals", "mo", "mos": .orbitals
        case "states", "excited", "uvvis", "excitations": .states
        case "energies", "energy", "trajectory": .energies
        case "charges", "charge": .charges
        default: nil
        }
    }
}
