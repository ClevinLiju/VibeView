// swift-tools-version:6.0
import PackageDescription

// Release builds of molscope-check: MolChecks uses `@testable import` for some modules, which only resolves
// when those modules are compiled with -enable-testing (debug builds do that automatically). Without this,
// `swift build -c release` fails with "unable to resolve Swift module dependency to a compatible module".
let testable: [SwiftSetting] = [.unsafeFlags(["-enable-testing"], .when(configuration: .release))]

// Portable core plus the headless engine for the Windows app (windows/). See docs/WINDOWS.md.
var targets: [Target] = [
    // `simd` replacement: re-exports Apple's simd on Darwin, pure-Swift implementation elsewhere.
    .target(name: "MolSIMD", swiftSettings: testable),
    .target(name: "MolCore", dependencies: ["MolSIMD"], swiftSettings: testable),
    .target(name: "MolIO", dependencies: ["MolCore", "MolSIMD"], swiftSettings: testable),
    .target(name: "MolBuild", dependencies: ["MolCore", "MolSIMD"], swiftSettings: testable),
    .target(name: "MolAnalysis", dependencies: ["MolCore", "MolIO", "MolSIMD"], swiftSettings: testable),
    .target(name: "MolCompute", dependencies: ["MolCore", "MolIO", "MolBuild"], swiftSettings: testable),
    .target(name: "MolCommand", dependencies: ["MolCore", "MolIO"], swiftSettings: testable),
    // Headless JSON-RPC engine (stdio) that the Windows desktop front end (windows/) drives. Portable.
    .executableTarget(
        name: "VibeViewEngine",
        dependencies: ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolCompute", "MolCommand", "MolSIMD"],
        swiftSettings: testable
    ),
]
var products: [Product] = [
    .executable(name: "molscope-check", targets: ["MolChecks"]),
    .executable(name: "vibeview-engine", targets: ["VibeViewEngine"]),
    .library(name: "MolCore", targets: ["MolCore"]),
    .library(name: "MolIO", targets: ["MolIO"]),
]
var checkDeps: [Target.Dependency] = ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolCompute", "MolCommand", "MolSIMD"]

// XCTest/Swift Testing are unavailable without full Xcode; checks run as an executable:
//   swift run molscope-check [filter]
targets.append(
    .executableTarget(name: "MolChecks", dependencies: checkDeps, resources: [.copy("TestData")])
)

let package = Package(
    name: "MolScope",
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
