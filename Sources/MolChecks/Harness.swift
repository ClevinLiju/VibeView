import Foundation

// Minimal test harness. Each team adds a file `<Team>Checks.swift` with
//   extension Checks { static let core: [Check] = [ Check("name") { try expect(...) } ] }
// and registers its array in `allChecks` below (one line per team).

struct Check {
    let name: String
    let body: () throws -> Void
    init(_ name: String, _ body: @escaping () throws -> Void) { self.name = name; self.body = body }
}

struct CheckFailure: Error, CustomStringConvertible { let description: String }

func expect(_ cond: @autoclosure () throws -> Bool, _ msg: @autoclosure () throws -> String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    if try !cond() { throw CheckFailure(description: "\(file):\(line) \(try msg())") }
}

func expectClose(_ a: Double, _ b: Double, tol: Double = 1e-6, file: StaticString = #fileID, line: UInt = #line) throws {
    try expect(abs(a - b) <= tol, "\(a) != \(b) (tol \(tol))", file: file, line: line)
}

func testDataURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "TestData", withExtension: nil)!.appendingPathComponent(name)
}

enum Checks {}

let allChecks: [Check] = ([
    // TEAM REGISTRATION — add one line each, e.g.  Checks.core,
    Checks.core,
    Checks.io,
    Checks.command,
    Checks.analysis,
    Checks.compute,
    Checks.buildCore + Checks.buildCalc + Checks.buildPlacement + Checks.buildGroups,
] as [[Check]]).flatMap { $0 }  // each team registers an array (fix by Lead 5, see CONTRACTS change log)

@main
struct CheckRunner {
    static func main() {
        #if os(Windows)
        // `molscope-check --tool <name> ...`: stand-ins for /bin/echo, /bin/sh etc. (see CheckTools.swift).
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == CheckTool.flag { CheckTool.runHelper(Array(CommandLine.arguments.dropFirst(2))) }
        #endif
        let filter = CommandLine.arguments.dropFirst().first
        var failed = 0, ran = 0
        for c in allChecks where filter == nil || c.name.contains(filter!) {
            ran += 1
            do { try c.body(); print("PASS \(c.name)") } catch { failed += 1; print("FAIL \(c.name): \(error)") }
            fflush(stdout)  // when output is piped, a crash would otherwise lose the buffered results
        }
        print("\(ran - failed)/\(ran) checks passed")
        exit(failed == 0 ? 0 : 1)
    }
}
