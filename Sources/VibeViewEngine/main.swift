import Foundation

// vibeview-engine: headless VibeView core for the Windows desktop front end (windows/).
// Protocol: docs/WINDOWS_PROTOCOL.md (newline-delimited JSON on stdin/stdout; diagnostics on stderr).

let arguments = Array(CommandLine.arguments.dropFirst())

func argumentValue(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--version") || arguments.contains("-v") {
    print("vibeview-engine \(engineVersion) (protocol \(protocolVersion), \(platformName))")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    usage: vibeview-engine [--stdio] [--wait-jobs]
           vibeview-engine --selftest [--data <TestData dir>]
           vibeview-engine --version

      --stdio       newline-delimited JSON requests on stdin, responses/events on stdout (default)
      --wait-jobs   at end of input, wait for running jobs instead of cancelling them
      --selftest    run in-process protocol round trips and exit 0 (pass) or 1 (fail)
      --data DIR    with --selftest: also open sample files from DIR (Sources/MolChecks/TestData)
    """)
    exit(0)
}

if arguments.contains("--selftest") {
    let ok = await SelfTest.run(dataDirectory: argumentValue("--data"))
    exit(ok ? 0 : 1)
}

await StdioServer.run(waitForJobs: arguments.contains("--wait-jobs"))
exit(0)
