// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MolScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MolScope", targets: ["MolScopeApp"]),
        .executable(name: "molscope-check", targets: ["MolChecks"]),
        .library(name: "MolCore", targets: ["MolCore"]),
        .library(name: "MolIO", targets: ["MolIO"]),
    ],
    targets: [
        .target(name: "MolCore"),
        .target(name: "MolIO", dependencies: ["MolCore"]),
        .target(name: "MolBuild", dependencies: ["MolCore"]),
        .target(name: "MolAnalysis", dependencies: ["MolCore", "MolIO"]),
        .target(name: "MolRender", dependencies: ["MolCore", "MolAnalysis"]),
        .target(name: "MolCompute", dependencies: ["MolCore", "MolIO", "MolBuild"]),
        .target(name: "MolCommand", dependencies: ["MolCore", "MolIO"]),
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
