// swift-tools-version:6.0
import PackageDescription

// Release builds of molscope-check: MolChecks uses `@testable import` for some modules, which only resolves
// when those modules are compiled with -enable-testing (debug builds do that automatically). Without this,
// `swift build -c release` fails with "unable to resolve Swift module dependency to a compatible module".
let testable: [SwiftSetting] = [.unsafeFlags(["-enable-testing"], .when(configuration: .release))]

let package = Package(
    name: "MolScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeView", targets: ["MolScopeApp"]),
        .executable(name: "molscope-check", targets: ["MolChecks"]),
        .library(name: "MolCore", targets: ["MolCore"]),
        .library(name: "MolIO", targets: ["MolIO"]),
    ],
    targets: [
        .target(name: "MolCore", swiftSettings: testable),
        .target(name: "MolIO", dependencies: ["MolCore"], swiftSettings: testable),
        .target(name: "MolBuild", dependencies: ["MolCore"], swiftSettings: testable),
        .target(name: "MolAnalysis", dependencies: ["MolCore", "MolIO"], swiftSettings: testable),
        .target(name: "MolRender", dependencies: ["MolCore", "MolAnalysis"], swiftSettings: testable),
        .target(name: "MolCompute", dependencies: ["MolCore", "MolIO", "MolBuild"], swiftSettings: testable),
        .target(name: "MolCommand", dependencies: ["MolCore", "MolIO"], swiftSettings: testable),
        .executableTarget(
            name: "MolScopeApp",
            dependencies: ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolRender", "MolCompute", "MolCommand"]
        ),
        // XCTest/Swift Testing are unavailable without full Xcode; checks run as an executable:
        //   swift run molscope-check [filter]
        .executableTarget(
            name: "MolChecks",
            dependencies: ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolRender", "MolCompute", "MolCommand"],
            resources: [.copy("TestData")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
