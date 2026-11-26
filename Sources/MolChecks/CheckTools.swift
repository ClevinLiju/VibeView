import Foundation

// Portable stand-ins for the Unix tools the compute checks drive through ProgramRunner.
// On macOS/Linux these are the real tools (/bin/echo, /bin/sh, ...), exactly as before.
// On Windows there is no /bin, so the check executable runs itself as the tool:
//   molscope-check.exe --tool <name> [args...]
// Output is written as raw bytes with "\n" line ends (no CRT text-mode CRLF translation), so the
// expected strings in the checks are the same on every platform.

struct CheckTool: Sendable {
    let executable: URL
    let prefix: [String]
    func args(_ a: [String]) -> [String] { prefix + a }

    static let flag = "--tool"

    #if os(Windows)
    private static var selfURL: URL {
        if let u = Bundle.main.executableURL { return u }
        return URL(fileURLWithPath: CommandLine.arguments[0])
    }
    private static func helper(_ name: String) -> CheckTool { CheckTool(executable: selfURL, prefix: [flag, name]) }
    static var echo: CheckTool { helper("echo") }
    static var falseTool: CheckTool { helper("false") }
    static var cat: CheckTool { helper("cat") }
    static var sleep: CheckTool { helper("sleep") }
    /// `for i in 1 2 3; do echo line$i; echo err$i >&2; echo file$i >> job.out; sleep 0.4; done`
    static var streamScript: CheckTool { helper("stream3") }
    /// `echo begin; sleep 30; echo never`
    static var beginSleep: CheckTool { helper("beginSleep") }
    /// Text the `.started` command line must contain.
    static var shellName: String { "molscope-check" }
    /// A program every machine has, for ProgramLocator checks.
    static let locatorPrograms = ["cmd", "where"]
    #else
    private static func bin(_ path: String, _ prefix: [String] = []) -> CheckTool {
        CheckTool(executable: URL(fileURLWithPath: path), prefix: prefix)
    }
    static var echo: CheckTool { bin("/bin/echo") }
    static var falseTool: CheckTool { bin("/usr/bin/false") }
    static var cat: CheckTool { bin("/bin/cat") }
    static var sleep: CheckTool { bin("/bin/sleep") }
    static var streamScript: CheckTool {
        bin("/bin/sh", ["-c", "for i in 1 2 3; do echo line$i; echo err$i >&2; echo file$i >> job.out; sleep 0.4; done"])
    }
    static var beginSleep: CheckTool { bin("/bin/sh", ["-c", "echo begin; sleep 30; echo never"]) }
    static var shellName: String { "/bin/sh" }
    static let locatorPrograms = ["sh", "ls"]
    #endif

    #if os(Windows)
    private static func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    private static func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    /// Runs a helper tool and exits; never returns.
    static func runHelper(_ argv: [String]) -> Never {
        let name = argv.first ?? ""
        let rest = Array(argv.dropFirst())
        switch name {
        case "echo":
            out(rest.joined(separator: " ") + "\n")
            exit(0)
        case "false":
            exit(1)
        case "cat":
            let d = FileHandle.standardInput.readDataToEndOfFile()
            FileHandle.standardOutput.write(d)
            exit(0)
        case "sleep":
            Thread.sleep(forTimeInterval: Double(rest.first ?? "0") ?? 0)
            exit(0)
        case "stream3":
            let job = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("job.out")
            for i in 1...3 {
                out("line\(i)\n")
                err("err\(i)\n")
                let line = Data("file\(i)\n".utf8)
                if let h = try? FileHandle(forWritingTo: job) {
                    h.seekToEndOfFile(); h.write(line); try? h.close()
                } else {
                    try? line.write(to: job)
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            exit(0)
        case "beginSleep":
            out("begin\n")
            Thread.sleep(forTimeInterval: 30)
            out("never\n")
            exit(0)
        default:
            err("unknown tool \(name)\n")
            exit(2)
        }
    }

    /// Number of running processes whose command line mentions `pattern` (the `pgrep -f` equivalent).
    static func processCount(matching pattern: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
                              + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        // Split the pattern so this PowerShell process does not match itself.
        let half = pattern.count / 2
        let a = String(pattern.prefix(half)), b = String(pattern.dropFirst(half))
        p.arguments = ["-NoProfile", "-NonInteractive", "-Command",
                       "@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ('*' + '\(a)' + '\(b)' + '*') -and $_.ProcessId -ne $PID }).Count"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return 0 }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Int(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    #endif
}
